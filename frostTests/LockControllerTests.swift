//
//  LockControllerTests.swift
//  frostTests
//
//  State-machine coverage for LockController via injected fakes: every
//  transition that decides whether input gets suppressed, whether resources
//  are released, and whether the user is shown recovery instead of being
//  trapped. No real tap, overlay, Touch ID prompt, kiosk options, or signal
//  handlers are involved — process-level hooks are replaced with
//  FakeSystemHooks, and the controller is constructed with
//  `registersAsShared: false` so it never steals `LockController.shared`
//  from the test-host process.
//

import AppKit
import Foundation
import Testing

@testable import frost

// MARK: - Fakes

@MainActor
private final class FakeTap: InputSuppressing {
    var onUnlockChord: (() -> Void)?
    var onTapReenabled: ((String) -> Void)?
    var onTapReviveFailed: (() -> Void)?
    var unlockShortcut: Shortcut?
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var authenticating: Bool?
    func start() -> Bool {
        startCount += 1
        return startSucceeds
    }
    func setAuthenticating(_ on: Bool) { authenticating = on }
    func stop() { stopCount += 1 }
}

@MainActor
private final class FakeOverlay: OverlayPresenting {
    private(set) var presentCount = 0
    private(set) var lastLevel: NSWindow.Level?
    private(set) var focusCount = 0
    private(set) var dismissCount = 0
    private(set) var rebuildIfDeferredCount = 0
    /// Simulates "no display could host an overlay" so the caller's refusal to
    /// lock behind an invisible overlay is testable.
    var presentSucceeds = true
    @discardableResult
    func present(controller: LockController, level: NSWindow.Level) -> Bool {
        presentCount += 1
        lastLevel = level
        return presentSucceeds
    }
    func focusAuthenticationWindow() { focusCount += 1 }
    func dismiss() { dismissCount += 1 }
    func rebuildIfDeferred() { rebuildIfDeferredCount += 1 }
}

@MainActor
private final class FakeUnlocker: UnlockAuthenticating {
    var availability: TouchIDCheck = .available
    var result: AuthenticationResult = .success
    private(set) var authenticateCount = 0
    private(set) var cancelCount = 0
    func checkTouchIDAvailability() -> TouchIDCheck { availability }
    func authenticate(reason: String) async -> AuthenticationResult {
        authenticateCount += 1
        return result
    }
    func cancel() { cancelCount += 1 }
}

@MainActor
private final class FakePermissions: AccessibilityChecking {
    var trusted = true
    private(set) var requestCount = 0
    var secureInputActive = false
    func hasAccessibility() -> Bool { trusted }
    @discardableResult
    func requestAccessibility() -> Bool {
        requestCount += 1
        return trusted
    }
    func isSecureInputActive() -> Bool { secureInputActive }
}

@MainActor
private final class FakeSleep: SleepAsserting {
    private(set) var lastApply: (preventScreenSaver: Bool, preventSleep: Bool)?
    private(set) var releaseCount = 0
    func apply(preventScreenSaver: Bool, preventSleep: Bool) {
        lastApply = (preventScreenSaver, preventSleep)
    }
    func releaseAll() { releaseCount += 1 }
}

@MainActor
private final class FakeInactivity: InactivityMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resetCount = 0
    private(set) var snoozeCount = 0
    func start(settings: SettingsStore, lock: LockController) { startCount += 1 }
    func stop() { stopCount += 1 }
    func resetIdleBaseline() { resetCount += 1 }
    func snoozeAfterFailedLock() { snoozeCount += 1 }
}

@MainActor
private final class FakeKiosk: KioskModeControlling {
    private(set) var enterCount = 0
    private(set) var exitCount = 0
    func enterKioskMode() { enterCount += 1 }
    func exitKioskMode() { exitCount += 1 }
}

@MainActor
private final class FakeSystemHooks: SystemHooking {
    private(set) var onSignal: (@MainActor () -> Void)?
    private(set) var onLockHotKey: (@MainActor (UInt16, NSEvent.ModifierFlags) -> Void)?
    private(set) var onAccessibilityChange: (@MainActor () -> Void)?
    private(set) var terminateCount = 0
    private(set) var removeMonitorCount = 0
    private(set) var removeAllCount = 0
    func installTerminationHandlers(onSignal: @escaping @MainActor () -> Void) { self.onSignal = onSignal }
    func installLockHotKeyMonitor(onKeyDown: @escaping @MainActor (UInt16, NSEvent.ModifierFlags) -> Void) { onLockHotKey = onKeyDown }
    func removeLockHotKeyMonitor() { removeMonitorCount += 1 }
    func observeAccessibilityTrustChanges(onChange: @escaping @MainActor () -> Void) { onAccessibilityChange = onChange }
    func terminateApp() { terminateCount += 1 }
    func removeAll() { removeAllCount += 1 }
}

// MARK: - Tests

@MainActor
final class LockControllerTests {
    private let suiteName: String
    private let defaults: UserDefaults
    private let settings: SettingsStore
    private let permissions = FakePermissions()
    private let tap = FakeTap()
    private let overlay = FakeOverlay()
    private let unlocker = FakeUnlocker()
    private let sleep = FakeSleep()
    private let inactivity = FakeInactivity()
    private let kiosk = FakeKiosk()
    private let hooks = FakeSystemHooks()

    init() {
        suiteName = "dev.abdeen.frost.lock-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = SettingsStore(defaults: defaults)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeController() -> LockController {
        LockController(
            settings: settings,
            permissions: permissions,
            tap: tap,
            overlay: overlay,
            unlocker: unlocker,
            sleep: sleep,
            inactivity: inactivity,
            kiosk: kiosk,
            hooks: hooks,
            registersAsShared: false
        )
    }

    // MARK: Locking

    @Test func lockTakesAllResourcesInOrder() {
        settings.preventScreenSaver = true
        settings.preventSleep = false
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()

        #expect(controller.state == .locked)
        #expect(tap.startCount == 1)
        #expect(tap.unlockShortcut == settings.unlockShortcut)
        #expect(overlay.presentCount == 1)
        #expect(overlay.lastLevel == .screenSaver)
        #expect(kiosk.enterCount == 1)
        #expect(sleep.lastApply?.preventScreenSaver == true)
        #expect(sleep.lastApply?.preventSleep == false)
    }

    @Test func lockWhileLockedIsANoOp() {
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        controller.lock()

        #expect(tap.startCount == 1)
        #expect(overlay.presentCount == 1)
    }

    @Test func startTouchIDWhenLockedArmsAuthenticationImmediately() async {
        settings.startTouchIDWhenLocked = true
        let controller = makeController()

        controller.lock()
        #expect(controller.state == .authenticating)

        await controller.authenticationTask?.value
        #expect(controller.state == .unlocked)
    }

    // MARK: Preflight failures — must never suppress input

    @Test func touchIDUnavailableEntersRecoveryWithoutStartingTap() {
        unlocker.availability = .unavailable(message: "no sensor", allowsRetry: false)
        let controller = makeController()

        controller.lock()

        guard case .recovery(let recovery) = controller.state else {
            Issue.record("expected .recovery, got \(controller.state)")
            return
        }
        #expect(recovery.title == "Touch ID Required")
        #expect(recovery.message == "no sensor")
        // Permanent absence must not offer a Try Again that can never succeed.
        #expect(!recovery.allowsRetry)
        #expect(tap.startCount == 0)
        #expect(kiosk.enterCount == 0)
        #expect(inactivity.snoozeCount == 1)
        // Recovery presents below system dialogs — input is not locked.
        #expect(overlay.lastLevel == .floating)
    }

    @Test func missingAccessibilityPromptsAndEntersRecovery() {
        permissions.trusted = false
        let controller = makeController()

        controller.lock()

        guard case .recovery(let recovery) = controller.state else {
            Issue.record("expected .recovery, got \(controller.state)")
            return
        }
        #expect(permissions.requestCount == 1)
        #expect(recovery.showsAccessibilitySettings)
        #expect(!recovery.allowsRetry)
        #expect(tap.startCount == 0)
    }

    @Test func accessibilityGrantedAfterLaunchStillRequiresRelaunch() {
        // Untrusted at launch; granted while running. A fresh TCC grant is not
        // usable by the current process, so lock() must refuse until relaunch.
        permissions.trusted = false
        let controller = makeController()
        permissions.trusted = true

        controller.lock()

        guard case .recovery(let recovery) = controller.state else {
            Issue.record("expected .recovery, got \(controller.state)")
            return
        }
        #expect(recovery.showsAccessibilitySettings)
        #expect(permissions.requestCount == 0)   // already granted — no prompt
        #expect(tap.startCount == 0)
    }

    @Test func tapStartFailureEntersRecoveryWithoutResources() {
        tap.startSucceeds = false
        let controller = makeController()

        controller.lock()

        guard case .recovery(let recovery) = controller.state else {
            Issue.record("expected .recovery, got \(controller.state)")
            return
        }
        #expect(recovery.message.contains("Input is NOT locked"))
        #expect(kiosk.enterCount == 0)
        #expect(sleep.lastApply == nil)
        #if DEBUG
        // The DEBUG safety net armed before tap.start() must be disarmed again.
        #expect(controller.debugSecondsRemaining == nil)
        #endif
    }

    // MARK: Authentication outcomes

    @Test func requestUnlockArmsAuthenticationAndSuccessUnlocks() async {
        let controller = makeController()

        controller.lock()
        controller.requestUnlock()

        #expect(controller.state == .authenticating)
        #expect(tap.authenticating == true)
        #expect(overlay.focusCount == 1)

        await controller.authenticationTask?.value

        #expect(controller.state == .unlocked)
        #expect(tap.stopCount == 1)
        #expect(kiosk.exitCount >= 1)
        #expect(sleep.releaseCount >= 1)
        #expect(overlay.dismissCount == 1)
        #expect(inactivity.resetCount >= 1)
    }

    @Test func cancelledAuthenticationReturnsToIdleLocked() async {
        unlocker.result = .cancelled
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        controller.requestUnlock()
        await controller.authenticationTask?.value

        #expect(controller.state == .locked)
        #expect(tap.authenticating == false)
        #expect(controller.tapRecoveryNotice == nil)
        #expect(tap.stopCount == 0)                       // still suppressing
        #expect(overlay.rebuildIfDeferredCount == 1)      // deferred rebuild applied
    }

    @Test func failedAuthenticationReLocksWithRetryHint() async {
        unlocker.result = .failed
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        controller.requestUnlock()
        await controller.authenticationTask?.value

        #expect(controller.state == .locked)
        #expect(controller.tapRecoveryNotice?.contains("didn't match") == true)
        #expect(controller.tapRecoveryNotice?.contains(
            settings.unlockShortcut.displayString) == true)
        #expect(tap.stopCount == 0)
    }

    @Test func unavailableAuthenticationReLocksWithNotice() async {
        unlocker.result = .unavailable("locked out")
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        controller.requestUnlock()
        await controller.authenticationTask?.value

        #expect(controller.state == .locked)
        #expect(controller.tapRecoveryNotice == "locked out")
        #expect(tap.stopCount == 0)
    }

    @Test func requestUnlockOnlyActsFromIdleLocked() async {
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.requestUnlock()                        // unlocked: ignored
        #expect(controller.state == .unlocked)
        #expect(unlocker.authenticateCount == 0)

        controller.lock()
        controller.requestUnlock()
        controller.requestUnlock()                        // authenticating: ignored
        await controller.authenticationTask?.value
        #expect(unlocker.authenticateCount == 1)
    }

    @Test func unlockChordCallbackArmsAuthentication() async {
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        tap.onUnlockChord?()   // hops to the main actor via a spawned Task
        // Yield the main actor (no wall-clock sleeps) until the chord's deferred
        // hop has run requestUnlock() — observable as either the armed
        // authenticationTask or, if the whole instant-success flow already
        // finished, the terminal unlocked state. Then await the task so the
        // completion handler has run before asserting.
        var yields = 0
        while controller.authenticationTask == nil,
              controller.state != .unlocked,
              yields < 10_000 {
            await Task.yield()
            yields += 1
        }
        if let task = controller.authenticationTask {
            await task.value
        }
        #expect(controller.state == .unlocked)
        #expect(unlocker.authenticateCount == 1)
    }

    // MARK: Tap revive failure — escalate, never a silent broken lock

    @Test func tapReviveFailureUnlocksAndEntersInteractiveRecovery() {
        let controller = makeController()

        controller.lock()
        tap.onTapReviveFailed?()

        guard case .recovery(let recovery) = controller.state else {
            Issue.record("expected .recovery, got \(controller.state)")
            return
        }
        #expect(recovery.allowsRetry)
        #expect(tap.stopCount == 1)
        #expect(kiosk.exitCount >= 1)
        #expect(sleep.releaseCount >= 1)
        #expect(overlay.lastLevel == .floating)
    }

    @Test func retryFromRecoveryAttemptsAFreshLock() {
        tap.startSucceeds = false
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        guard case .recovery = controller.state else {
            Issue.record("expected .recovery, got \(controller.state)")
            return
        }

        tap.startSucceeds = true
        controller.retryRecovery()
        #expect(controller.state == .locked)
        #expect(tap.startCount == 2)
    }

    @Test func dismissRecoveryReturnsToUnlocked() {
        unlocker.availability = .unavailable(message: "no sensor", allowsRetry: false)
        let controller = makeController()

        controller.lock()
        controller.dismissRecovery()

        #expect(controller.state == .unlocked)
        #expect(overlay.dismissCount == 1)
    }

    // MARK: Teardown

    @Test func terminationTeardownIsIdempotent() {
        let controller = makeController()

        controller.lock()
        controller.tearDownForTermination()
        controller.tearDownForTermination()

        #expect(controller.state == .unlocked)
        #expect(tap.stopCount == 1)
        #expect(kiosk.exitCount == 1)
        #expect(sleep.releaseCount == 1)
        #expect(overlay.dismissCount == 1)
        #if DEBUG
        #expect(controller.debugSecondsRemaining == nil)
        #endif
    }

    // MARK: SIGTERM contract — the remote-kill path (AGENTS.md: "the SIGTERM
    // handler is the contract"). These drive FakeSystemHooks' captured
    // `onSignal` callback exactly as SystemHooks would invoke it from a real
    // signal source, without installing any process-level hooks.

    @Test func terminationSignalWhileLockedTearsDownEverythingThenTerminates() {
        let controller = makeController()

        controller.lock()
        #expect(controller.state == .locked)

        hooks.onSignal?()

        #expect(tap.stopCount == 1)
        #expect(kiosk.exitCount == 1)
        #expect(sleep.releaseCount >= 1)
        #expect(overlay.dismissCount == 1)
        #expect(unlocker.cancelCount >= 1)
        #expect(controller.state == .unlocked)
        #expect(hooks.terminateCount == 1)
    }

    @Test func terminationSignalWhileAuthenticatingCancelsAuthAndTerminates() async {
        let controller = makeController()

        controller.lock()
        controller.requestUnlock()
        #expect(controller.state == .authenticating)

        hooks.onSignal?()

        if let task = controller.authenticationTask {
            await task.value
        }

        #expect(controller.state == .unlocked)
        #expect(hooks.terminateCount == 1)
    }

    @Test func terminationSignalWhileUnlockedStillTerminatesCleanly() {
        let controller = makeController()

        hooks.onSignal?()

        #expect(controller.state == .unlocked)
        #expect(hooks.terminateCount == 1)
    }

    @Test func signalHandlersAreInstalledAtInit() {
        _ = makeController()

        #expect(hooks.onSignal != nil)
    }
}
