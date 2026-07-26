//
//  LockController.swift
//  frost
//
//  Central coordinator for a lock session. Wires PermissionManager,
//  EventTapManager, OverlayCoordinator, and UnlockCoordinator together and owns
//  the state machine + the DEBUG auto-unlock safety net.
//
//  SAFETY: independent ways out of a lock:
//    1. The unlock chord (⌃⌥⌘U) → Touch ID.
//    2. The DEBUG auto-unlock timer (debug builds only).
//    3. Sending SIGTERM (e.g. `pkill -x frost` / `kill` over SSH) — caught
//       below and torn down cleanly, independent of app state.
//

import AppKit
import Combine
import Foundation
import os

enum LockState: Equatable {
    case unlocked
    case locked
    case authenticating
    case recovery(RecoveryState)
}

struct RecoveryState: Equatable {
    var title = "Input Not Locked"
    var message: String
    var showsAccessibilitySettings = false
    var allowsRetry = true
}

@MainActor
final class LockController: ObservableObject {
    @Published private(set) var state: LockState = .unlocked
    @Published private(set) var tapRecoveryNotice: String?
    /// Set while secure event input is held by another process during a lock.
    /// Kept separate from `tapRecoveryNotice` so the two warnings can coexist
    /// and neither clears the other.
    @Published private(set) var secureInputNotice: String?
    #if DEBUG
    @Published private(set) var debugSecondsRemaining: Int?
    #endif

    private let permissions: any AccessibilityChecking
    private let tap: any InputSuppressing
    private let overlay: any OverlayPresenting
    private let unlocker: any UnlockAuthenticating
    private let sleep: any SleepAsserting
    private let inactivity: any InactivityMonitoring
    private let kiosk: any KioskModeControlling
    private let hooks: any SystemHooking
    private let settings: SettingsStore
    /// False in unit tests: skips registering this controller as
    /// `Self.shared` so a test-injected controller can't steal it from the
    /// app instance hosting the test run.
    private let registersAsShared: Bool
    private let log = Logger(subsystem: "dev.abdeen.frost", category: "Lock")
    private var accessibilityTrustedAtLaunch = false
    private var accessibilityRequiresRelaunch = false

    /// Weak global handle so UpdaterController can reach the live controller
    /// without holding a strong reference to it.
    nonisolated(unsafe) static weak var shared: LockController?
    /// Whether `hooks.installLockHotKeyMonitor` currently has a live monitor
    /// installed. `SystemHooking` doesn't expose its internal monitor state,
    /// so this mirrors it here.
    private var lockHotKeyMonitorInstalled = false
    /// Internal get so state-machine tests can await the in-flight evaluation.
    private(set) var authenticationTask: Task<Void, Never>?

    /// How often to re-check secure event input while locked.
    private let secureInputPollSeconds: Double = 2
    private var secureInputWatchTask: Task<Void, Never>?

    #if DEBUG
    /// DEBUG-only: the lock always tears down after this many seconds, no matter
    /// what. Never compiled into release builds.
    private let debugAutoUnlockSeconds = 20
    private var debugTask: Task<Void, Never>?
    #endif

    var isLocked: Bool { state != .unlocked }
    /// True only while input is genuinely suppressed. Distinct from `isLocked`,
    /// which includes recovery — where input is explicitly NOT locked and the
    /// menu bar must not claim otherwise.
    var isSuppressingInput: Bool { state == .locked || state == .authenticating }
    /// True while a Touch ID evaluation is live. The overlay reads this to avoid
    /// rebuilding (and thereby churning window focus) while the prompt is up.
    var isAuthenticating: Bool { state == .authenticating }

    /// The configured unlock shortcut, formatted for the overlay hint.
    var unlockShortcutDisplay: String { settings.unlockShortcut.displayString }
    /// VoiceOver-friendly spelling of the unlock shortcut, e.g. "Control Option
    /// Command U".
    var unlockShortcutSpoken: String { settings.unlockShortcut.spokenString }
    /// Optional owner-supplied message shown on the locked overlay (empty = none).
    var lockMessage: String { settings.lockMessage }
    /// True when the user opted in to Apple Watch unlock. With it on, a Mac with
    /// no Touch ID sensor at all can enter a lock (the preflight accepts a paired
    /// Watch instead), so the overlay must not name Touch ID as the only way out.
    var allowsWatchUnlock: Bool { settings.allowWatchUnlock }
    /// How the overlay should name the unlock method it is asking for.
    var unlockMethodLabel: String {
        settings.allowWatchUnlock ? "Touch ID or Apple Watch" : "Touch ID"
    }
    /// The current recovery message, if a recovery overlay is showing. Lets a
    /// non-visual caller (the Lock Input intent) report WHY a lock did not
    /// happen instead of failing opaquely.
    var recoveryMessage: String? {
        guard case .recovery(let recovery) = state else { return nil }
        return recovery.message
    }

    /// Collaborators default (nil) to the real implementations, constructed in
    /// the body because default-argument expressions are nonisolated and the
    /// real initializers are main-actor-isolated. Tests inject fakes via
    /// `hooks:` and pass `registersAsShared: false`.
    init(
        settings: SettingsStore,
        permissions: (any AccessibilityChecking)? = nil,
        tap: (any InputSuppressing)? = nil,
        overlay: (any OverlayPresenting)? = nil,
        unlocker: (any UnlockAuthenticating)? = nil,
        sleep: (any SleepAsserting)? = nil,
        inactivity: (any InactivityMonitoring)? = nil,
        kiosk: (any KioskModeControlling)? = nil,
        hooks: (any SystemHooking)? = nil,
        registersAsShared: Bool = true
    ) {
        self.settings = settings
        self.permissions = permissions ?? PermissionManager()
        self.tap = tap ?? EventTapManager()
        self.overlay = overlay ?? OverlayCoordinator()
        self.unlocker = unlocker ?? UnlockCoordinator(allowWatch: { settings.allowWatchUnlock })
        self.sleep = sleep ?? SleepAssertionManager()
        self.inactivity = inactivity ?? InactivityLockMonitor()
        self.kiosk = kiosk ?? SystemKioskMode()
        self.hooks = hooks ?? SystemHooks()
        self.registersAsShared = registersAsShared
        accessibilityTrustedAtLaunch = self.permissions.hasAccessibility()
        self.tap.unlockShortcut = settings.unlockShortcut
        // Defer to the next main-loop tick so we never mutate the tap from
        // inside its own callback.
        self.tap.onUnlockChord = { [weak self] in
            Task { @MainActor in self?.requestUnlock() }
        }
        self.tap.onTapReenabled = { [weak self] message in
            self?.tapRecoveryNotice = message
        }
        self.tap.onTapReviveFailed = { [weak self] in
            self?.handleTapReviveFailure()
        }
        if registersAsShared {
            // UpdaterController reads Self.shared; a test-injected controller
            // must not steal it from the app instance hosting the test run.
            Self.shared = self
        }
        self.hooks.installTerminationHandlers { [weak self] in
            self?.handleTerminationSignal()
        }
        self.hooks.observeAccessibilityTrustChanges { [weak self] in
            self?.refreshLockHotKeyMonitor(reinstall: true)
        }
        refreshLockHotKeyMonitor()
        self.inactivity.start(settings: settings, lock: self)
    }

    /// Only detaches the process-level hooks. Resource teardown (tap, cursor,
    /// assertions, overlays) is owned by `teardown()` and the
    /// `applicationWillTerminate` backstop: while locked, the presented overlay
    /// retains this controller, so deinit can never run in a state that still
    /// holds those resources — re-listing them here would be dead code that
    /// reads like a safety net.
    deinit {
        MainActor.assumeIsolated {
            hooks.removeAll()
            if Self.shared === self {
                Self.shared = nil
            }
        }
    }

    /// Install only when Accessibility was active at launch and remains active
    /// now. A new grant needs a Frost relaunch before the lock hotkey or event
    /// tap are considered usable.
    private func refreshLockHotKeyMonitor(reinstall: Bool = false) {
        let currentlyTrusted = permissions.hasAccessibility()
        if !currentlyTrusted {
            accessibilityRequiresRelaunch = true
        } else if accessibilityTrustedAtLaunch {
            // Trust is back AND this process had a usable grant at launch, so
            // the tap and the global monitor still work — nothing needs a
            // relaunch. Without this the latch was one-way: toggling Frost off
            // and back on in System Settings (exactly what a user does while
            // troubleshooting) permanently killed the lock hotkey, silently.
            accessibilityRequiresRelaunch = false
        }

        guard accessibilityTrustedAtLaunch,
              !accessibilityRequiresRelaunch,
              currentlyTrusted
        else {
            hooks.removeLockHotKeyMonitor()
            lockHotKeyMonitorInstalled = false
            return
        }

        if reinstall {
            hooks.removeLockHotKeyMonitor()
            lockHotKeyMonitorInstalled = false
        } else if lockHotKeyMonitorInstalled {
            return
        }

        hooks.installLockHotKeyMonitor { [weak self] keyCode, modifiers in
            self?.handleLockHotKey(keyCode: keyCode, modifiers: modifiers)
        }
        lockHotKeyMonitorInstalled = true
    }

    private func hasUsableAccessibility() -> Bool {
        accessibilityTrustedAtLaunch
            && !accessibilityRequiresRelaunch
            && permissions.hasAccessibility()
    }

    private func handleLockHotKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard state == .unlocked, let shortcut = settings.lockShortcut else { return }
        if shortcut.matches(keyCode: keyCode, modifiers: modifiers) { lock() }
    }

    private func handleTerminationSignal() {
        log.notice("Termination signal received; tearing down before exit")
        teardown()
        hooks.terminateApp()
    }

    // MARK: - Lock

    func lock() {
        guard state == .unlocked else { return }

        switch unlocker.checkTouchIDAvailability() {
        case .available:
            break
        case .unavailable(let message, let allowsRetry):
            enterRecovery(RecoveryState(
                title: "\(unlockMethodLabel) Required",
                message: message,
                allowsRetry: allowsRetry
            ))
            return
        }

        // Secure event input steals keyboard events from session-level taps, so
        // the tap would be created, the pointer frozen and ⌘Tab/Force Quit
        // disabled — while the in-tap unlock chord could never fire. Refuse the
        // lock rather than enter one with no in-app way out.
        guard !permissions.isSecureInputActive() else {
            enterRecovery(RecoveryState(
                message: """
                Another app has secure keyboard entry turned on, so Frost can't \
                see the keyboard — including your unlock shortcut. Close any \
                open password field or password-manager window and try again. \
                Input is NOT locked.
                """
            ))
            return
        }

        // Without Accessibility the tap can't suppress input. Prompt, then show
        // the recovery state — never a lock the user can't escape. A fresh grant
        // often is not usable by the current process, so the user must relaunch
        // Frost before locking.
        guard hasUsableAccessibility() else {
            if !permissions.hasAccessibility() {
                permissions.requestAccessibility()
            }
            accessibilityRequiresRelaunch = true
            enterRecovery(RecoveryState(
                message: """
                Frost needs Accessibility. Enable it for \
                Frost in System Settings → Privacy & Security, then choose \
                Quit & Reopen so the new permission takes effect. \
                Input is NOT locked.
                """,
                showsAccessibilitySettings: true,
                allowsRetry: false
            ))
            return
        }
        refreshLockHotKeyMonitor()

        // Recognize the latest configured unlock shortcut for this session.
        tap.unlockShortcut = settings.unlockShortcut

        // Arm the DEBUG safety net BEFORE enabling any input-suppressing tap.
        // If startup fails, we stop it immediately because input was not locked.
        startDebugAutoUnlock()
        guard tap.start() else {
            stopDebugAutoUnlock()
            enterRecovery(RecoveryState(
                message: """
                Frost couldn't start blocking input. Confirm Accessibility is \
                enabled for Frost, then try again. Input is NOT locked.
                """
            ))
            return
        }

        // No overlay window means no on-screen explanation, no unlock-shortcut
        // hint and no warning surface — an invisible lock. Back the tap out
        // rather than suppress input behind nothing.
        guard overlay.present(controller: self, level: .screenSaver) else {
            overlay.dismiss()
            tap.stop()
            stopDebugAutoUnlock()
            enterRecovery(RecoveryState(
                message: """
                Frost couldn't put its overlay on any display, so it did not \
                lock input. Try again once your displays have settled.
                """
            ))
            return
        }
        kiosk.enterKioskMode()
        sleep.apply(preventScreenSaver: settings.preventScreenSaver,
                    preventSleep: settings.preventSleep)
        tapRecoveryNotice = nil
        startSecureInputWatch()
        state = .locked

        // Optionally open Touch ID right away instead of waiting for the unlock
        // shortcut. The overlay is already presented, so the system prompt comes
        // straight up. If Touch ID is unavailable, armAuthentication leaves us
        // idle with a notice — the shortcut can retry.
        if settings.startTouchIDWhenLocked {
            armAuthentication()
        }
        log.info("Locked")
    }

    // MARK: - Unlock

    /// The unlock shortcut opens the system Touch ID prompt from the idle
    /// locked state. Touch ID is not armed automatically, so this is the entry
    /// point into authentication.
    func requestUnlock() {
        guard state == .locked else { return }
        armAuthentication()
    }

    /// Flips into the authenticating state, lets Esc through, and presents the
    /// standard system Touch ID prompt. On success Frost unlocks; on cancel or
    /// failure it returns to the idle locked state (the shortcut re-opens the
    /// prompt); if Touch ID has become unavailable it re-locks with a notice so
    /// the user is never stranded. Only acts from the idle locked state.
    @discardableResult
    private func armAuthentication() -> Bool {
        guard state == .locked else { return false }
        authenticationTask?.cancel()
        authenticationTask = nil

        state = .authenticating

        // Bring Frost forward and re-key the active-display window before
        // evaluating. Frost is an LSUIElement agent, so it must be active for the
        // system Touch ID prompt to take focus, and keying the active-display
        // window biases the prompt onto the display where the lock was triggered.
        overlay.focusAuthenticationWindow()

        // Keep the screen covered and input frozen while the system prompt is up.
        // Esc is allowed through so the user can cancel and remain locked.
        tap.setAuthenticating(true)

        authenticationTask = Task { [weak self] in
            guard let self else { return }
            // Re-check BEFORE the suspension point. This task is created
            // synchronously but its body doesn't start until the main actor
            // yields, so teardown() — from the tap-revive failure, the SIGTERM
            // handler, or the DEBUG timer — can run first. Its unlocker.cancel()
            // is a no-op then (no context exists yet), so without this the
            // evaluation would still start and raise a Touch ID prompt after the
            // lock was already gone.
            guard !Task.isCancelled, self.state == .authenticating else { return }
            let result = await self.unlocker.authenticate(reason: "Unlock Frost")
            if Task.isCancelled { return }
            self.authenticationTask = nil
            guard self.state == .authenticating else { return } // safety net won the race
            switch result {
            case .success:
                self.finishUnlock()
            case .unavailable(let message):
                self.reLock(notice: message)
            case .failed:
                // Three bad reads in one prompt. Confirm the failure wasn't a
                // glitch — a silent flip back to "Input Locked" reads as one.
                self.reLock(notice: """
                    Touch ID didn't match. Press \
                    \(self.settings.unlockShortcut.displayString) to try again.
                    """)
            case .cancelled:
                // Return to the idle locked state; the shortcut re-opens Touch ID.
                self.reLock()
            }
        }
        return true
    }

    private func reLock(notice: String? = nil) {
        // The overlay never hid and the tap never stopped suppressing; just
        // re-freeze Esc and return to the locked state.
        tap.setAuthenticating(false)
        if let notice {
            tapRecoveryNotice = notice
        }
        state = .locked
        // A screen-parameters change may have been deferred while we were
        // authenticating; apply it now that the prompt is gone and rebuilding is
        // safe, so the overlay reflects any real display change.
        overlay.rebuildIfDeferred()
        log.info("Re-locked after failed/cancelled auth")
    }

    private func finishUnlock() {
        teardown()
        log.info("Unlocked")
    }

    /// macOS disabled the event tap and it could not be re-enabled while locked,
    /// so input is no longer suppressed and the in-tap unlock chord is dead.
    /// Restore everything and escalate to a prominent recovery overlay — whose
    /// buttons are clickable now that the pointer is live again — rather than
    /// leaving the user behind a passive notice that falsely implies success.
    private func handleTapReviveFailure() {
        guard state == .locked || state == .authenticating else { return }
        log.fault("Event tap could not be re-enabled; unlocking and showing recovery")
        teardown()
        enterRecovery(RecoveryState(
            message: """
            macOS stopped Frost's input blocking and it could not be restored, \
            so input has been unlocked. Press Try Again to re-lock, or Dismiss \
            to stay unlocked.
            """
        ))
    }

    // MARK: - Recovery

    private func enterRecovery(_ recovery: RecoveryState) {
        inactivity.snoozeAfterFailedLock()
        state = .recovery(recovery)
        // Input is NOT locked in recovery, so the overlay doesn't need to sit
        // above everything — .floating keeps system dialogs (the Accessibility
        // TCC prompt in particular) visible and clickable above it.
        overlay.present(controller: self, level: .floating)
    }

    func retryRecovery() {
        guard case .recovery = state else { return }
        teardown()
        lock()
    }

    func dismissRecovery() {
        guard case .recovery = state else { return }
        teardown()
    }

    /// Open the Accessibility pane, and only then tear the recovery card down.
    /// The old order dismissed first and discarded `open`'s result, so if the
    /// legacy pane URL ever stops resolving the user's card vanished, nothing
    /// opened, and — with the menu-bar icon hidden — Frost had no UI left at all.
    func openAccessibilitySettings() {
        guard case .recovery(let recovery) = state else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url)
        else {
            log.error("Could not open the Accessibility settings pane")
            state = .recovery(RecoveryState(
                title: recovery.title,
                message: """
                    Frost couldn't open System Settings. Open it yourself and \
                    enable Frost under Privacy & Security → Accessibility, then \
                    choose Quit & Reopen. Input is NOT locked.
                    """,
                showsAccessibilitySettings: recovery.showsAccessibilitySettings,
                allowsRetry: recovery.allowsRetry
            ))
            return
        }
        dismissRecovery()
    }

    /// Quit and reopen in one action: a fresh Accessibility grant usually isn't
    /// usable by the running process, and an LSUIElement agent leaves no visual
    /// trace after quitting — the user shouldn't have to remember to find Frost
    /// in Spotlight. Terminates only once the new instance has launched; if the
    /// relaunch fails, Frost stays running rather than stranding the user with
    /// nothing.
    func quitAndReopenFrost() {
        let previousRecovery: RecoveryState?
        if case .recovery(let recovery) = state {
            previousRecovery = recovery
        } else {
            previousRecovery = nil
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Tell the new instance it was launched by this flow so it opens
        // Settings. A plain launch deliberately shows nothing (so login stays
        // silent), which left this action — the documented exit from the
        // Accessibility dead end — relaunching into an invisible app at exactly
        // the moment the user needs confirmation the new grant took effect.
        configuration.arguments = [Self.showSettingsLaunchArgument]
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor in
                guard error == nil else {
                    // Keep the user where they were rather than silently doing
                    // nothing: the old code returned here having ALREADY torn
                    // the recovery card down.
                    self?.log.error("Relaunch failed; staying alive")
                    if let previousRecovery {
                        self?.state = .recovery(RecoveryState(
                            title: previousRecovery.title,
                            message: """
                                Frost couldn't relaunch itself. Quit Frost from \
                                the menu bar and open it again so the new \
                                permission takes effect. Input is NOT locked.
                                """,
                            showsAccessibilitySettings: previousRecovery.showsAccessibilitySettings,
                            allowsRetry: previousRecovery.allowsRetry
                        ))
                    }
                    return
                }
                // Only now is the replacement definitely running.
                self?.teardown()
                NSApp.terminate(nil)
            }
        }
    }

    /// Launch argument that asks a freshly-launched Frost to open Settings.
    /// Only `quitAndReopenFrost` passes it, so a login-item launch stays silent.
    static let showSettingsLaunchArgument = "--show-settings"

    // MARK: - Teardown

    private func teardown() {
        stopDebugAutoUnlock()
        stopSecureInputWatch()
        kiosk.exitKioskMode()
        sleep.releaseAll()
        tap.stop()
        authenticationTask?.cancel()
        authenticationTask = nil
        tapRecoveryNotice = nil
        unlocker.cancel()
        overlay.dismiss()
        state = .unlocked
        inactivity.resetIdleBaseline()
        log.info("Teardown complete: tap released, cursor restored, presentation options cleared, assertions released")
    }

    /// Final backstop for process-termination paths that bypass `teardown()`
    /// (e.g. `NSApp.terminate` from the menu or Settings, which otherwise rely on
    /// `@StateObject` deinit running at exit — not guaranteed by SwiftUI).
    /// Idempotent and a no-op when already unlocked; called from
    /// `AppDelegate.applicationWillTerminate` on the main thread.
    func tearDownForTermination() {
        guard state != .unlocked else { return }
        log.notice("Termination while active; running teardown backstop")
        teardown()
    }

    // MARK: - Secure input watch

    /// Secure event input can also be turned on AFTER a lock begins, which kills
    /// the in-tap unlock chord mid-session. Watch for it and say so on the
    /// overlay.
    ///
    /// This deliberately WARNS rather than tearing the lock down the way
    /// `handleTapReviveFailure` does. Auto-unlocking on this signal would mean a
    /// false positive silently unlocks an unattended Mac — the worst failure
    /// this app has — and the system authentication prompt may itself hold
    /// secure input while it is up. The check is therefore skipped outside the
    /// idle locked state, and the response is a visible warning naming the
    /// remote-kill route that still works.
    ///
    /// NEEDS HARDWARE VERIFICATION: confirm whether the LocalAuthentication
    /// prompt toggles secure input on this OS before considering escalation.
    private func startSecureInputWatch() {
        secureInputWatchTask?.cancel()
        secureInputNotice = nil
        secureInputWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(secureInputPollSeconds))
                if Task.isCancelled { return }
                guard let self else { return }
                // Only from the idle locked state — see the note above.
                guard self.state == .locked else { continue }
                self.secureInputNotice = self.permissions.isSecureInputActive()
                    ? """
                      Another app turned on secure keyboard entry, so \
                      \(self.settings.unlockShortcut.displayString) may not reach Frost. \
                      If it doesn't work, run `pkill -x frost` over SSH from another device.
                      """
                    : nil
            }
        }
    }

    private func stopSecureInputWatch() {
        secureInputWatchTask?.cancel()
        secureInputWatchTask = nil
        secureInputNotice = nil
    }

    // MARK: - DEBUG auto-unlock safety net

    private func startDebugAutoUnlock() {
        #if DEBUG
        debugSecondsRemaining = debugAutoUnlockSeconds
        log.notice("DEBUG auto-unlock armed")
        debugTask?.cancel()
        debugTask = Task { [weak self] in
            guard let self else { return }
            var remaining = self.debugAutoUnlockSeconds
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
                self.debugSecondsRemaining = remaining
            }
            self.log.notice("DEBUG auto-unlock fired")
            self.teardown()
        }
        #endif
    }

    private func stopDebugAutoUnlock() {
        #if DEBUG
        debugTask?.cancel()
        debugTask = nil
        debugSecondsRemaining = nil
        #endif
    }
}

// MARK: - Kiosk presentation seam

/// LockController's seam onto the NSApp presentation calls, so state-machine
/// tests don't hide the real Dock and menu bar of the machine running them.
@MainActor
protocol KioskModeControlling: AnyObject {
    func enterKioskMode()
    func exitKioskMode()
}

// Trackpad swipes for Mission Control / Spaces / App Exposé, ⌘-Tab, and the
// ⌘⌥Esc Force Quit panel are handled by the Dock / WindowServer above the
// HID layer, so the event tap can't swallow them. The only supported way to
// disable them is kiosk presentation options — and macOS REQUIRES the Dock
// and menu bar to be hidden for the disable* flags to be legal (an invalid
// combination raises an exception that would crash the lock). So blocking
// the gestures and hiding the Dock are one and the same switch; they cannot
// be separated. Force Quit is disabled because opening ⌘⌥Esc while the Touch
// ID prompt is up steals its focus and strands the user. ALWAYS undone in
// teardown so the desktop returns to normal.
@MainActor
final class SystemKioskMode: KioskModeControlling {
    func enterKioskMode() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableForceQuit,
            .disableAppleMenu,
        ]
    }

    func exitKioskMode() {
        NSApp.presentationOptions = []
    }
}
