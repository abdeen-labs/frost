//
//  InactivityLockMonitor.swift
//  frost
//
//  Polls macOS session idle time while Frost is unlocked and triggers the normal
//  lock path when the selected inactivity threshold is exceeded.
//

import Combine
import CoreGraphics
import Foundation
import os

/// LockController's seam onto the auto-lock monitor, so the lock state machine
/// can be tested without a live polling task.
@MainActor
protocol InactivityMonitoring: AnyObject {
    func start(settings: SettingsStore, lock: LockController)
    func stop()
    func resetIdleBaseline()
    func snoozeAfterFailedLock()
}

@MainActor
final class InactivityLockMonitor: InactivityMonitoring {
    private weak var settings: SettingsStore?
    private var isLocked: (() -> Bool)?
    private var lockAction: (() -> Void)?
    private var pollTask: Task<Void, Never>?
    /// Remembered from `start()` so the settings-driven restart honours the
    /// test seam that suppresses automatic polling.
    private var pollAutomatically = true
    private var inactivitySettingCancellable: AnyCancellable?
    private var snoozedUntil: Date?
    private var baselineDate: Date?
    private var observedInactivityLock: InactivityLockOption?
    private let failedLockSnoozeSeconds: TimeInterval = 60
    /// Directly bounds auto-lock latency: a threshold can overshoot by up to
    /// one poll interval.
    private let pollIntervalSeconds: TimeInterval = 5
    private let log = Logger(subsystem: "dev.abdeen.frost", category: "Inactivity")
    private let now: () -> Date
    private let idleSeconds: () -> TimeInterval

    /// `kCGAnyInputEventType` (raw value `0xFFFFFFFF`): the documented sentinel
    /// for "seconds since the last event of ANY type", i.e. true input idle time.
    /// The C constant isn't bridged into Swift, so we build a `CGEventType` with
    /// the same raw value — `CGEventSource.secondsSinceLastEventType` reads only
    /// the raw value, so this is correct even though Swift happens to name that
    /// case `.tapDisabledByUserInput`. Do NOT "simplify" this back to `.null`
    /// (raw value 0): that measures idle time since the last *null* event, which
    /// real input never resets, so auto-lock would misfire.
    nonisolated private static var anyInputEventType: CGEventType {
        CGEventType(rawValue: ~0)!
    }

    init(
        now: @escaping () -> Date = { Date() },
        idleSeconds: @escaping () -> TimeInterval = InactivityLockMonitor.sessionIdleSeconds
    ) {
        self.now = now
        self.idleSeconds = idleSeconds
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    func start(settings: SettingsStore, lock: LockController) {
        start(
            settings: settings,
            isLocked: { [weak lock] in lock?.isLocked ?? true },
            lock: { [weak lock] in lock?.lock() }
        )
    }

    func start(
        settings: SettingsStore,
        isLocked: @escaping () -> Bool,
        lock: @escaping () -> Void,
        pollAutomatically: Bool = true
    ) {
        self.settings = settings
        self.isLocked = isLocked
        self.lockAction = lock
        self.pollAutomatically = pollAutomatically
        observedInactivityLock = settings.inactivityLock
        resetIdleBaseline()
        pollTask?.cancel()
        pollTask = nil

        // Drive the loop from the setting instead of running it unconditionally.
        // With auto-lock Off — the default — poll() bailed at the threshold
        // guard anyway, so the old loop woke the main thread every 5 seconds for
        // the whole life of the process to do nothing.
        inactivitySettingCancellable = settings.$inactivityLock
            .sink { [weak self] option in
                Task { @MainActor in self?.applyPollingState(for: option) }
            }
        applyPollingState(for: settings.inactivityLock)
    }

    /// Start or stop the poll loop to match the current setting.
    private func applyPollingState(for option: InactivityLockOption) {
        guard pollAutomatically else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard option != .off else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        startPolling()
    }

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            let interval = self?.pollIntervalSeconds ?? 5
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                self?.poll()
            }
        }
    }

    /// True when the poll loop has anything to do. With auto-lock Off — the
    /// default — poll() bails immediately at the threshold guard, so the loop
    /// was waking the main thread every 5 seconds for the app's entire lifetime
    /// to do nothing, defeating timer coalescing and App Nap for the session.
    var isPolling: Bool { pollTask != nil }

    func stop() {
        inactivitySettingCancellable = nil
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reset Frost's local auto-lock clock after user-visible actions that may not
    /// update CoreGraphics' keyboard/mouse idle timer (notably Touch ID unlock).
    /// Deliberately preserves an active failed-lock snooze: teardown() calls this
    /// on every path out of recovery, and clearing the snooze here is what made
    /// the failed-lock debounce dead code (it never survived into a state where
    /// poll() actually runs).
    func resetIdleBaseline() {
        baselineDate = now()
    }

    func snoozeAfterFailedLock() {
        let date = now()
        baselineDate = date
        snoozedUntil = date.addingTimeInterval(failedLockSnoozeSeconds)
    }

    func poll() {
        guard let settings,
              let isLocked,
              let lockAction,
              !isLocked()
        else { return }

        // Track option changes BEFORE the threshold guard, so Off is observed
        // too — otherwise toggling X → Off → X keeps a stale baseline and the
        // "changing settings never immediately re-locks" contract breaks.
        if settings.inactivityLock != observedInactivityLock {
            observedInactivityLock = settings.inactivityLock
            resetIdleBaseline()
            return
        }

        guard let threshold = settings.inactivityLock.seconds else { return }

        if let snoozedUntil {
            guard now() >= snoozedUntil else { return }
            self.snoozedUntil = nil
        }

        guard let baselineDate,
              now().timeIntervalSince(baselineDate) >= threshold
        else { return }

        let idleSeconds = idleSeconds()
        if idleSeconds >= threshold {
            log.info("Inactivity threshold reached; locking")
            lockAction()
        }
    }

    nonisolated private static func sessionIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: Self.anyInputEventType
        )
    }
}
