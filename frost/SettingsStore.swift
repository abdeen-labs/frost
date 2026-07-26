//
//  SettingsStore.swift
//  frost
//
//  User-facing preferences, persisted to UserDefaults:
//    • unlockShortcut    — REQUIRED; recognized inside the event tap to unlock.
//    • lockShortcut      — OPTIONAL; a global hotkey that starts a lock.
//    • inactivityLock    — OPTIONAL; locks after session idle time exceeds it.
//    • startTouchIDWhenLocked — OPTIONAL; opens Touch ID as soon as a lock begins
//                          instead of waiting for the unlock shortcut.
//    • preventScreenSaver / preventSleep — power assertions held while locked.
//    • lockMessage        — OPTIONAL; owner-supplied text shown on the locked
//                          overlay (empty = none).
//    • allowWatchUnlock   — OPTIONAL; also accepts a paired, unlocked Apple
//                          Watch as an unlock path. Defaults to false.
//
//  Published so the Settings UI updates live; LockController reads the current
//  values when a lock begins (settings can't change while locked — input is
//  frozen — so a snapshot at lock time is always current).
//

import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var unlockShortcut: Shortcut {
        didSet { write(unlockShortcut, forKey: Key.unlockShortcut) }
    }
    @Published var lockShortcut: Shortcut? {
        didSet { write(lockShortcut, forKey: Key.lockShortcut) }
    }
    @Published var inactivityLock: InactivityLockOption {
        didSet { defaults.set(inactivityLock.rawValue, forKey: Key.inactivityLock) }
    }
    @Published var startTouchIDWhenLocked: Bool {
        didSet { defaults.set(startTouchIDWhenLocked, forKey: Key.startTouchIDWhenLocked) }
    }
    @Published var preventScreenSaver: Bool {
        didSet { defaults.set(preventScreenSaver, forKey: Key.preventScreenSaver) }
    }
    @Published var preventSleep: Bool {
        didSet { defaults.set(preventSleep, forKey: Key.preventSleep) }
    }
    @Published var lockMessage: String {
        didSet { defaults.set(lockMessage, forKey: Key.lockMessage) }
    }
    @Published var allowWatchUnlock: Bool {
        didSet { defaults.set(allowWatchUnlock, forKey: Key.allowWatchUnlock) }
    }

    private let defaults: UserDefaults

    /// Key for the menu-bar-visibility flag. Deliberately NOT an @Published here:
    /// it's read via @AppStorage in the App/Settings views so binding it to
    /// MenuBarExtra(isInserted:) doesn't publish object changes during a view
    /// update. Defaults to `true`.
    static let showInMenuBarKey = "showInMenuBar"

    private enum Key {
        static let unlockShortcut = "unlockShortcut"
        static let lockShortcut = "lockShortcut"
        static let inactivityLock = "inactivityLock"
        static let startTouchIDWhenLocked = "startTouchIDWhenLocked"
        static let preventScreenSaver = "preventScreenSaver"
        static let preventSleep = "preventSleep"
        static let lockMessage = "lockMessage"
        static let allowWatchUnlock = "allowWatchUnlock"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // didSet does not fire during init, so these loads never re-persist.
        self.unlockShortcut = Self.read(Key.unlockShortcut, from: defaults) ?? .defaultUnlock
        self.lockShortcut = Self.read(Key.lockShortcut, from: defaults)
        self.inactivityLock = InactivityLockOption(
            rawValue: defaults.integer(forKey: Key.inactivityLock)
        ) ?? .off
        self.startTouchIDWhenLocked = defaults.bool(forKey: Key.startTouchIDWhenLocked)
        self.preventScreenSaver = defaults.bool(forKey: Key.preventScreenSaver)
        self.preventSleep = defaults.bool(forKey: Key.preventSleep)
        self.lockMessage = defaults.string(forKey: Key.lockMessage) ?? ""
        self.allowWatchUnlock = defaults.bool(forKey: Key.allowWatchUnlock)
        if self.lockShortcut == self.unlockShortcut {
            self.lockShortcut = nil
            write(nil, forKey: Key.lockShortcut)
        }
    }

    private func write(_ shortcut: Shortcut?, forKey key: String) {
        guard let shortcut else { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        }
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
}
