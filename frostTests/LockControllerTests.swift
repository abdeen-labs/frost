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
import Carbon.HIToolbox
import Foundation
import Testing

@testable import frost

// MARK: - Fakes

/// Shared ordered call log. AGENTS.md fixes the order in which a lock takes
/// resources ("SIGTERM handler -> debug auto-unlock -> recovery UI come before
/// any input-suppressing code"), and call counts alone cannot observe order —
/// so swapping two lines in lock() used to leave the whole suite green.
@MainActor
final class EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

@MainActor
private final class FakeTap: InputSuppressing {
    var onUnlockChord: (() -> Void)?
    var onTapReenabled: ((String) -> Void)?
    var onTapReviveFailed: (() -> Void)?
    var unlockShortcut: Shortcut?
    var startSucceeds = true
    /// Runs inside start(), so a test can observe controller state at the exact
    /// moment input suppression begins.
    var onStart: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var authenticating: Bool?
    private let log: EventLog
    init(log: EventLog) { self.log = log }
    func start() -> Bool {
        startCount += 1
        log.record("tap.start")
        onStart?()
        return startSucceeds
    }
    func setAuthenticating(_ on: Bool) { authenticating = on }
    func stop() {
        stopCount += 1
        log.record("tap.stop")
    }
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
    private let log: EventLog
    init(log: EventLog) { self.log = log }
    @discardableResult
    func present(controller: LockController, level: NSWindow.Level) -> Bool {
        presentCount += 1
        lastLevel = level
        log.record("overlay.present")
        return presentSucceeds
    }
    func focusAuthenticationWindow() { focusCount += 1 }
    func dismiss() {
        dismissCount += 1
        log.record("overlay.dismiss")
    }
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
    private let log: EventLog
    init(log: EventLog) { self.log = log }
    func apply(preventScreenSaver: Bool, preventSleep: Bool) {
        lastApply = (preventScreenSaver, preventSleep)
        log.record("sleep.apply")
    }
    func releaseAll() {
        releaseCount += 1
        log.record("sleep.releaseAll")
    }
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
    private let log: EventLog
    init(log: EventLog) { self.log = log }
    func enterKioskMode() {
        enterCount += 1
        log.record("kiosk.enter")
    }
    func exitKioskMode() {
        exitCount += 1
        log.record("kiosk.exit")
    }
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
    private let unlocker = FakeUnlocker()
    private let inactivity = FakeInactivity()
    private let hooks = FakeSystemHooks()
    private let eventLog = EventLog()
    private let tap: FakeTap
    private let overlay: FakeOverlay
    private let sleep: FakeSleep
    private let kiosk: FakeKiosk

    init() {
        suiteName = "dev.abdeen.frost.lock-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = SettingsStore(defaults: defaults)
        let log = eventLog
        tap = FakeTap(log: log)
        overlay = FakeOverlay(log: log)
        sleep = FakeSleep(log: log)
        kiosk = FakeKiosk(log: log)
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
        // The ORDER, not just the counts: the overlay must exist before kiosk
        // mode hides the Dock and menu bar, and power assertions come last.
        #expect(eventLog.events == ["tap.start", "overlay.present", "kiosk.enter", "sleep.apply"])
        #expect(tap.unlockShortcut == settings.unlockShortcut)
        #expect(overlay.lastLevel == .screenSaver)
        #expect(sleep.lastApply?.preventScreenSaver == true)
        #expect(sleep.lastApply?.preventSleep == false)
    }

    #if DEBUG
    /// AGENTS.md escape hatch #2 and its ordering rule: the DEBUG auto-unlock
    /// must be armed BEFORE any input-suppressing code runs, so a hang between
    /// the two can never trap the user. Swapping those two lines in lock() left
    /// every previous assertion green.
    @Test func debugSafetyNetIsArmedBeforeTheTapStarts() {
        let controller = makeController()
        defer { controller.tearDownForTermination() }
        var armedWhenTapStarted: Bool?
        tap.onStart = { armedWhenTapStarted = controller.debugSecondsRemaining != nil }

        controller.lock()

        #expect(armedWhenTapStarted == true)
    }

    /// The positive case the suite never had: both existing assertions were
    /// `== nil`, so emptying startDebugAutoUnlock() passed.
    @Test func lockArmsTheDebugAutoUnlockCountdown() {
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()

        #expect(controller.debugSecondsRemaining != nil)
        #expect((controller.debugSecondsRemaining ?? 0) > 0)
    }
    #endif

    /// lock() reads the CURRENT unlock shortcut, not the one captured at init.
    /// The old assertion could not tell the two apart, so deleting the lock-time
    /// refresh left the suite green and the overlay's displayed chord dead.
    @Test func lockRefreshesTheTapWithTheCurrentlyConfiguredUnlockShortcut() {
        let controller = makeController()
        defer { controller.tearDownForTermination() }
        let changed = Shortcut(keyCode: UInt16(kVK_ANSI_K),
                               modifierFlags: [.control, .option, .command])
        settings.unlockShortcut = changed

        controller.lock()

        #expect(tap.unlockShortcut == changed)
        #expect(tap.unlockShortcut?.keyCode == UInt16(kVK_ANSI_K))
    }

    /// A revived tap must surface a VISIBLE warning without leaving the locked
    /// state. FakeTap.onTapReenabled existed but no test ever invoked it, so the
    /// whole wiring could be deleted with the suite green.
    @Test func tapReenabledSurfacesAVisibleWarningAndStaysLocked() {
        let controller = makeController()
        defer { controller.tearDownForTermination() }
        controller.lock()

        tap.onTapReenabled?("macOS briefly stopped Frost's input blocking.")

        #expect(controller.tapRecoveryNotice == "macOS briefly stopped Frost's input blocking.")
        #expect(controller.state == .locked)
        #expect(tap.stopCount == 0)
    }

    // MARK: Preflight refusals

    /// Secure event input steals keyboard events from session taps, so the
    /// in-tap unlock chord could never fire. Refuse the lock outright.
    @Test func secureInputRefusesTheLockWithoutStartingTheTap() {
        permissions.secureInputActive = true
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()

        guard case .recovery = controller.state else {
            Issue.record("Expected recovery, got \(controller.state)")
            return
        }
        #expect(tap.startCount == 0)
        #expect(kiosk.enterCount == 0)
    }

    /// No overlay window means no unlock hint and no warning surface. Suppressing
    /// input behind nothing is exactly the trap the recovery state exists for.
    @Test func overlayWithNoDisplaysBacksTheLockOutAndShowsRecovery() {
        overlay.presentSucceeds = false
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()

        guard case .recovery = controller.state else {
            Issue.record("Expected recovery, got \(controller.state)")
            return
        }
        #expect(tap.stopCount >= 1)          // the tap was backed out
        #expect(kiosk.enterCount == 0)       // never entered kiosk mode
        #if DEBUG
        #expect(controller.debugSecondsRemaining == nil)
        #endif
    }

    // MARK: Lock hotkey and the Accessibility gate

    /// The global hotkey must fire only for the configured LOCK shortcut. The
    /// captured callback was recorded by the fake and read by nothing, so a
    /// regression matching the UNLOCK chord here would have shipped green.
    @Test func lockHotKeyFiresOnlyForTheConfiguredLockShortcut() {
        let lockChord = Shortcut(keyCode: UInt16(kVK_ANSI_L),
                                 modifierFlags: [.control, .option, .command])
        settings.lockShortcut = lockChord
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        // A non-matching chord must do nothing.
        hooks.onLockHotKey?(UInt16(kVK_ANSI_J), [.control, .option, .command])
        #expect(controller.state == .unlocked)
        #expect(tap.startCount == 0)

        hooks.onLockHotKey?(lockChord.keyCode, lockChord.modifierFlags)
        #expect(controller.state == .locked)
    }

    /// With no lock shortcut configured, the hotkey path must never lock.
    @Test func lockHotKeyDoesNothingWithoutAConfiguredLockShortcut() {
        settings.lockShortcut = nil
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        hooks.onLockHotKey?(UInt16(kVK_ANSI_L), [.control, .option, .command])

        #expect(controller.state == .unlocked)
        #expect(tap.startCount == 0)
    }

    /// Accessibility missing at launch means the grant is not usable by this
    /// process, so no global monitor may be installed — installing one would let
    /// a hotkey start a lock the tap cannot actually enforce.
    @Test func noLockHotKeyMonitorWhenAccessibilityWasMissingAtLaunch() {
        permissions.trusted = false
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        #expect(hooks.onLockHotKey == nil)
        #expect(controller.state == .unlocked)
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

    // MARK: Tap revive failure — HOLD the lock, never self-unlock

    /// THE INVARIANT: Frost never returns the machine without authentication.
    /// macOS can kill the event tap, and Frost cannot stop that — but losing
    /// the ability to BLOCK input must not become permission to RELEASE it.
    /// Frost previously tore everything down here and showed a "Dismiss" card,
    /// leaving the Mac wide open with no fingerprint involved.
    @Test func tapReviveFailureHoldsTheLockAndNeverSelfUnlocks() {
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        tap.onTapReviveFailed?()

        // Still holding the lock, still demanding authentication.
        #expect(controller.state == .locked)
        #expect(controller.isHoldingLock)
        // The overlay stays up and kiosk options stay on.
        #expect(overlay.dismissCount == 0)
        #expect(kiosk.exitCount == 0)
        #expect(overlay.lastLevel == .screenSaver)
        // But Frost stops CLAIMING to block input, because it no longer does.
        #expect(controller.isSuppressingInput == false)
        #expect(controller.inputSuppressionFailed)
        // The dead tap is released — which also re-couples the pointer, so the
        // authenticate button is reachable.
        #expect(tap.stopCount == 1)
        // And the user is told, rather than left behind a silent broken lock.
        #expect(controller.tapRecoveryNotice != nil)
    }

    /// The chord died with the tap, so the overlay button is the only remaining
    /// route to the prompt. It must still lead to real authentication.
    @Test func authenticatingFromTheOverlayIsTheOnlyWayOutAfterReviveFailure() async {
        unlocker.result = .success
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        tap.onTapReviveFailed?()
        #expect(controller.state == .locked)

        controller.authenticateFromOverlay()
        if let task = controller.authenticationTask {
            await task.value
        }

        #expect(unlocker.authenticateCount == 1)
        #expect(controller.state == .unlocked)
    }

    /// A failed fingerprint after the tap died must NOT fall through to an
    /// unlock. The lock is held until authentication actually succeeds.
    @Test func failedAuthenticationAfterReviveFailureKeepsHoldingTheLock() async {
        unlocker.result = .failed
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        tap.onTapReviveFailed?()
        controller.authenticateFromOverlay()
        if let task = controller.authenticationTask {
            await task.value
        }

        #expect(controller.state == .locked)
        #expect(controller.isHoldingLock)
        #expect(overlay.dismissCount == 0)
    }

    /// Losing Touch ID entirely mid-lock is NOT a reason to unlock. There is no
    /// way to tell a locked-out owner from someone else at the keyboard, and
    /// Frost will not make that judgement — the documented exits are a remote
    /// `pkill` over SSH or a hard power-off.
    @Test func authenticationBecomingUnavailableMidLockNeverUnlocks() async {
        unlocker.result = .unavailable("Touch ID is locked after too many attempts.")
        let controller = makeController()
        defer { controller.tearDownForTermination() }

        controller.lock()
        controller.requestUnlock()
        if let task = controller.authenticationTask {
            await task.value
        }

        #expect(controller.state == .locked)
        #expect(controller.isSuppressingInput)
        #expect(overlay.dismissCount == 0)
        #expect(tap.stopCount == 0)
        #expect(controller.tapRecoveryNotice != nil)
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
