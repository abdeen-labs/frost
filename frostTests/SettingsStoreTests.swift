//
//  SettingsStoreTests.swift
//  frostTests
//
//  Persistence behavior of SettingsStore. Each test runs against a private,
//  uniquely-named UserDefaults suite so the real app preferences are never
//  touched, and the suite is torn down afterwards.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import Frost

@MainActor
final class SettingsStoreTests {

    /// Mirrors `SettingsStore.Key` (which is `private` in the source). Kept in
    /// sync by hand so tests can seed/inspect raw defaults.
    private enum Key {
        static let unlock = "unlockShortcut"
        static let lock = "lockShortcut"
        static let inactivity = "inactivityLock"
        static let startTouchID = "startTouchIDWhenLocked"
        static let preventScreenSaver = "preventScreenSaver"
        static let preventSleep = "preventSleep"
        static let lockMessage = "lockMessage"
    }

    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "dev.abdeen.frost.tests.\(UUID().uuidString)"
        // A freshly-named suite is always creatable; force-unwrap is safe here.
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        // Only touches the Sendable suite name, so it's safe from a nonisolated
        // deinit. Wipes the on-disk plist this test created.
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Factory defaults

    @Test func freshStoreHasFactoryDefaults() {
        let store = SettingsStore(defaults: defaults)
        #expect(store.unlockShortcut == .defaultUnlock)
        #expect(store.lockShortcut == nil)
        #expect(store.inactivityLock == .off)
        #expect(store.startTouchIDWhenLocked == false)
        #expect(store.preventScreenSaver == false)
        #expect(store.preventSleep == false)
    }

    // MARK: - Round-trip persistence

    @Test func unlockShortcutPersistsAcrossInstances() {
        let custom = Shortcut(keyCode: UInt16(kVK_ANSI_L), modifierFlags: [.command, .shift])
        let store = SettingsStore(defaults: defaults)
        store.unlockShortcut = custom

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.unlockShortcut == custom)
    }

    @Test func lockShortcutPersistsThenClears() {
        let custom = Shortcut(keyCode: UInt16(kVK_ANSI_J), modifierFlags: [.control, .option])
        let store = SettingsStore(defaults: defaults)

        store.lockShortcut = custom
        #expect(SettingsStore(defaults: defaults).lockShortcut == custom)

        store.lockShortcut = nil
        #expect(defaults.data(forKey: Key.lock) == nil)
        #expect(SettingsStore(defaults: defaults).lockShortcut == nil)
    }

    @Test func powerAndInactivityPreferencesPersist() {
        let store = SettingsStore(defaults: defaults)
        store.inactivityLock = .fiveMinutes
        store.startTouchIDWhenLocked = true
        store.preventScreenSaver = true
        store.preventSleep = true

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.inactivityLock == .fiveMinutes)
        #expect(reloaded.startTouchIDWhenLocked)
        #expect(reloaded.preventScreenSaver)
        #expect(reloaded.preventSleep)
    }

    @Test func lockMessagePersistsAcrossInstances() {
        let store = SettingsStore(defaults: defaults)
        #expect(store.lockMessage == "")

        store.lockMessage = "Agent run in progress — do not touch"
        #expect(SettingsStore(defaults: defaults).lockMessage == "Agent run in progress — do not touch")
    }

    @Test func allowWatchUnlockDefaultsFalseAndPersists() {
        let store = SettingsStore(defaults: defaults)
        #expect(store.allowWatchUnlock == false)

        store.allowWatchUnlock = true
        #expect(SettingsStore(defaults: defaults).allowWatchUnlock)
    }

    @Test func settingUnlockShortcutWritesImmediately() {
        let custom = Shortcut(keyCode: UInt16(kVK_ANSI_P), modifierFlags: [.command, .option])
        let store = SettingsStore(defaults: defaults)
        store.unlockShortcut = custom
        // didSet should have persisted without needing a new instance.
        #expect(defaults.data(forKey: Key.unlock) != nil)
    }

    // MARK: - Init-time reconciliation

    @Test func initClearsLockShortcutWhenItEqualsUnlock() throws {
        // Seed both keys with the SAME shortcut, as a stale install might.
        let shared = Shortcut(keyCode: UInt16(kVK_ANSI_K), modifierFlags: [.command, .control])
        let data = try JSONEncoder().encode(shared)
        defaults.set(data, forKey: Key.unlock)
        defaults.set(data, forKey: Key.lock)

        let store = SettingsStore(defaults: defaults)
        #expect(store.unlockShortcut == shared)
        #expect(store.lockShortcut == nil)
        // The collision is also scrubbed from persistence.
        #expect(defaults.data(forKey: Key.lock) == nil)
    }

    @Test func initKeepsDistinctLockShortcut() throws {
        let unlock = Shortcut(keyCode: UInt16(kVK_ANSI_U), modifierFlags: [.command, .control])
        let lock = Shortcut(keyCode: UInt16(kVK_ANSI_L), modifierFlags: [.command, .control])
        defaults.set(try JSONEncoder().encode(unlock), forKey: Key.unlock)
        defaults.set(try JSONEncoder().encode(lock), forKey: Key.lock)

        let store = SettingsStore(defaults: defaults)
        #expect(store.unlockShortcut == unlock)
        #expect(store.lockShortcut == lock)
    }

    // MARK: - Resilience to bad stored data

    @Test func invalidStoredInactivityFallsBackToOff() {
        defaults.set(45, forKey: Key.inactivity)   // not a valid raw value
        #expect(SettingsStore(defaults: defaults).inactivityLock == .off)

        defaults.set(300, forKey: Key.inactivity)
        #expect(SettingsStore(defaults: defaults).inactivityLock == .fiveMinutes)
    }

    @Test func corruptUnlockShortcutDataFallsBackToDefault() {
        defaults.set(Data("not valid json".utf8), forKey: Key.unlock)
        #expect(SettingsStore(defaults: defaults).unlockShortcut == .defaultUnlock)
    }

    @Test func corruptLockShortcutDataDecodesToNil() {
        defaults.set(Data("not valid json".utf8), forKey: Key.lock)
        #expect(SettingsStore(defaults: defaults).lockShortcut == nil)
    }

    @Test func storedUnlockShortcutWithIrrelevantFlagBitsIsNormalized() {
        // Valid JSON whose flags carry a non-chord bit: decode must normalize
        // it (via the custom Shortcut init) so the chord still matches events.
        let raw = NSEvent.ModifierFlags([.command, .control, .capsLock]).rawValue
        let json = Data(#"{"keyCode": \#(kVK_ANSI_U), "modifierFlagsRawValue": \#(raw)}"#.utf8)
        defaults.set(json, forKey: Key.unlock)

        let store = SettingsStore(defaults: defaults)
        #expect(store.unlockShortcut
                == Shortcut(keyCode: UInt16(kVK_ANSI_U), modifierFlags: [.command, .control]))
    }

    @Test func modifierlessStoredUnlockShortcutFallsBackToDefault() {
        let json = Data(#"{"keyCode": \#(kVK_ANSI_K), "modifierFlagsRawValue": 0}"#.utf8)
        defaults.set(json, forKey: Key.unlock)
        #expect(SettingsStore(defaults: defaults).unlockShortcut == .defaultUnlock)
    }
}
