//
//  InactivityLockMonitorTests.swift
//  frostTests
//
//  Behavioral coverage for auto-lock timing. The monitor combines macOS' session
//  idle timer with Frost's own local baseline so changing settings or unlocking
//  via Touch ID does not immediately re-lock from stale global idle time.
//

import CoreGraphics
import Foundation
import Testing

@testable import frost

@MainActor
final class InactivityLockMonitorTests {
    private let suiteName: String
    private let defaults: UserDefaults
    private var now = Date(timeIntervalSinceReferenceDate: 0)
    private var systemIdleSeconds: TimeInterval = 0
    private var lockCount = 0
    private var locked = false

    init() {
        suiteName = "dev.abdeen.frost.monitor-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test func enablingAutoLockStartsAFreshLocalCountdown() {
        let settings = SettingsStore(defaults: defaults)
        let monitor = makeMonitor(settings: settings)
        defer { monitor.stop() }

        systemIdleSeconds = 999
        settings.inactivityLock = .thirtySeconds

        monitor.poll()
        #expect(lockCount == 0)

        advance(by: 29)
        monitor.poll()
        #expect(lockCount == 0)

        advance(by: 1)
        monitor.poll()
        #expect(lockCount == 1)
    }

    @Test func resetIdleBaselinePreventsImmediateRelockAfterUnlock() {
        let settings = SettingsStore(defaults: defaults)
        settings.inactivityLock = .thirtySeconds
        let monitor = makeMonitor(settings: settings)
        defer { monitor.stop() }

        systemIdleSeconds = 999
        advance(by: 30)
        monitor.poll()
        #expect(lockCount == 1)

        lockCount = 0
        monitor.resetIdleBaseline()
        monitor.poll()
        #expect(lockCount == 0)

        advance(by: 30)
        monitor.poll()
        #expect(lockCount == 1)
    }

    @Test func recentSystemInputStillPreventsLockAfterLocalBaselineElapses() {
        let settings = SettingsStore(defaults: defaults)
        settings.inactivityLock = .thirtySeconds
        let monitor = makeMonitor(settings: settings)
        defer { monitor.stop() }

        advance(by: 120)
        systemIdleSeconds = 5
        monitor.poll()
        #expect(lockCount == 0)

        systemIdleSeconds = 30
        monitor.poll()
        #expect(lockCount == 1)
    }

    @Test func failedLockSnoozeSuppressesRepeatedAttemptsTemporarily() {
        let settings = SettingsStore(defaults: defaults)
        settings.inactivityLock = .thirtySeconds
        let monitor = makeMonitor(settings: settings)
        defer { monitor.stop() }

        systemIdleSeconds = 999
        monitor.snoozeAfterFailedLock()

        advance(by: 59)
        monitor.poll()
        #expect(lockCount == 0)

        advance(by: 1)
        monitor.poll()
        #expect(lockCount == 1)
    }

    @Test func failedLockSnoozeSurvivesTeardownBaselineReset() {
        let settings = SettingsStore(defaults: defaults)
        settings.inactivityLock = .thirtySeconds
        let monitor = makeMonitor(settings: settings)
        defer { monitor.stop() }

        systemIdleSeconds = 999

        // Runtime sequence: auto-lock fails → enterRecovery snoozes (while the
        // controller is in .recovery, so polling is blocked) → the user exits
        // recovery → teardown() resets the baseline → polling resumes unlocked.
        locked = true
        monitor.snoozeAfterFailedLock()
        advance(by: 5)
        monitor.resetIdleBaseline()   // what teardown() calls
        locked = false

        monitor.poll()                // t=5s: snoozed until t=60
        #expect(lockCount == 0)

        advance(by: 54)               // t=59s
        monitor.poll()
        #expect(lockCount == 0)

        advance(by: 1)                // t=60s: snooze expired, baseline elapsed 55s ≥ 30s
        monitor.poll()
        #expect(lockCount == 1)
    }

    @Test func lockedStateSuppressesAutoLockAttempts() {
        let settings = SettingsStore(defaults: defaults)
        settings.inactivityLock = .thirtySeconds
        let monitor = makeMonitor(settings: settings)
        defer { monitor.stop() }

        locked = true
        systemIdleSeconds = 999
        advance(by: 999)
        monitor.poll()

        #expect(lockCount == 0)
    }

    private func makeMonitor(settings: SettingsStore) -> InactivityLockMonitor {
        let monitor = InactivityLockMonitor(
            now: { [weak self] in self?.now ?? Date() },
            idleSeconds: { [weak self] in self?.systemIdleSeconds ?? 0 }
        )
        monitor.start(
            settings: settings,
            isLocked: { [weak self] in self?.locked ?? true },
            lock: { [weak self] in self?.lockCount += 1 },
            pollAutomatically: false
        )
        return monitor
    }

    private func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    // MARK: - Poll lifecycle

    /// The loop must exist only when auto-lock is actually on. It used to run
    /// unconditionally for the life of the process, waking the main thread every
    /// 5 seconds to hit poll()'s threshold guard and return — with auto-lock Off
    /// being the default.
    @Test func pollLoopRunsOnlyWhileAutoLockIsEnabled() async {
        let settings = SettingsStore(defaults: defaults)
        let monitor = InactivityLockMonitor(
            now: { Date() },
            idleSeconds: { 0 }
        )
        defer { monitor.stop() }

        monitor.start(settings: settings, isLocked: { false }, lock: {})
        #expect(monitor.isPolling == false)   // default is .off

        settings.inactivityLock = .thirtySeconds
        await Task.yield()
        #expect(monitor.isPolling == true)

        settings.inactivityLock = .off
        await Task.yield()
        #expect(monitor.isPolling == false)
    }

    // MARK: - The kCGAnyInputEventType sentinel

    /// `CGEventSource.secondsSinceLastEventType` reads only the RAW value, and
    /// the sentinel for "any input" is 0xFFFFFFFF. Swift happens to name that
    /// case `.tapDisabledByUserInput`, which invites a "simplification" to
    /// `.null` (raw 0) — measuring idle time since the last null event, which
    /// real typing never resets. Auto-lock would then fire while the user works.
    @Test func anyInputEventTypeIsTheAnyInputSentinelNotNull() {
        #expect(InactivityLockMonitor.anyInputEventType.rawValue == 0xFFFF_FFFF)
        #expect(InactivityLockMonitor.anyInputEventType.rawValue != CGEventType.null.rawValue)
    }
}
