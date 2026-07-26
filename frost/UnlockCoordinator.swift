//
//  UnlockCoordinator.swift
//  frost
//
//  Wraps LocalAuthentication. Frost is Touch ID by default: the event tap
//  suppresses keyboard input while locked, so a typed password is not a
//  viable unlock path. Unlocking evaluates the biometrics-only policy on a
//  fresh LAContext, which presents the standard system Touch ID prompt. If
//  the user has opted in to Apple Watch unlock (default off), the biometrics-
//  or-watch variant is evaluated instead (see `effectivePolicy`) — still
//  out-of-band from the suppressed keyboard, so the no-typed-password
//  rationale holds.
//

import Foundation
import LocalAuthentication
import os

enum TouchIDCheck: Equatable {
    case available
    /// `allowsRetry: false` when the failure is permanent (no sensor at all),
    /// so recovery doesn't offer a "Try Again" that can never succeed.
    case unavailable(message: String, allowsRetry: Bool)
}

/// Outcome of *evaluating* Touch ID.
enum AuthenticationResult: Equatable {
    case success
    case cancelled
    case failed
    case unavailable(String)
}

/// LockController's seam onto LocalAuthentication, so the lock state machine
/// can be tested without presenting real Touch ID prompts.
@MainActor
protocol UnlockAuthenticating: AnyObject {
    func checkTouchIDAvailability() -> TouchIDCheck
    func authenticate(reason: String) async -> AuthenticationResult
    func cancel()
}

@MainActor
final class UnlockCoordinator: UnlockAuthenticating {
    private var context: LAContext?
    private let log = Logger(subsystem: "dev.abdeen.frost", category: "Unlock")

    /// True when the user has opted in to Apple Watch unlock. Injected as a
    /// closure so the coordinator reads the CURRENT setting at each preflight/
    /// evaluation without owning the settings store.
    private let allowWatch: () -> Bool

    init(allowWatch: @escaping () -> Bool = { false }) {
        self.allowWatch = allowWatch
    }

    /// Touch ID only by default; adds Watch when the user opted in. Internal so
    /// tests can pin the selection logic.
    var effectivePolicy: LAPolicy {
        allowWatch() ? .deviceOwnerAuthenticationWithBiometricsOrWatch
                     : .deviceOwnerAuthenticationWithBiometrics
    }

    /// Check before suppressing input so machines without a usable unlock
    /// path (per `effectivePolicy`) never enter a lock.
    func checkTouchIDAvailability() -> TouchIDCheck {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(effectivePolicy, error: &error),
              allowWatch() || context.biometryType == .touchID
        else {
            return .unavailable(
                message: Self.touchIDUnavailableMessage(error, whileLocked: false, allowsWatch: allowWatch()),
                allowsRetry: !Self.isPermanentTouchIDAbsence(error)
            )
        }
        return .available
    }

    /// `.biometryNotAvailable` means macOS reports no usable sensor at all —
    /// retrying in place can never succeed. The other preflight failures
    /// (enrollment, passcode, lockout) are fixable without relaunching Frost.
    nonisolated private static func isPermanentTouchIDAbsence(_ error: NSError?) -> Bool {
        guard let error, error.domain == LAError.errorDomain else { return false }
        return LAError.Code(rawValue: error.code) == .biometryNotAvailable
    }

    /// Presents the standard system Touch ID prompt and evaluates it. A fresh
    /// `LAContext` is created per call (a context evaluates only once) and held so
    /// an in-flight prompt can be cancelled via `cancel()`; it is cleared when the
    /// evaluation ends.
    func authenticate(reason: String) async -> AuthenticationResult {
        let context = LAContext()
        // Empty fallback title hides the password button — Touch ID only.
        context.localizedFallbackTitle = ""
        var error: NSError?
        let allowsWatch = allowWatch()

        guard context.canEvaluatePolicy(effectivePolicy, error: &error),
              allowsWatch || context.biometryType == .touchID
        else {
            return .unavailable(Self.touchIDUnavailableMessage(error, whileLocked: true, allowsWatch: allowsWatch))
        }

        self.context = context
        let result: AuthenticationResult = await withCheckedContinuation { continuation in
            context.evaluatePolicy(effectivePolicy,
                                   localizedReason: reason) { success, error in
                continuation.resume(returning: Self.authenticationResult(
                    success: success, error: error, allowsWatch: allowsWatch))
            }
        }

        if self.context === context {
            self.context = nil
        }
        switch result {
        case .success: log.info("Touch ID succeeded")
        case .cancelled: log.info("Touch ID cancelled")
        case .failed: log.info("Touch ID failed")
        case .unavailable: log.error("Touch ID unavailable during unlock")
        }
        return result
    }

    /// Cancels an in-flight prompt — used by the DEBUG auto-unlock safety net so
    /// a stale Touch ID dialog doesn't linger after a forced teardown.
    func cancel() {
        context?.invalidate()
        context = nil
    }

    nonisolated static func authenticationResult(
        success: Bool,
        error: Error?,
        allowsWatch: Bool
    ) -> AuthenticationResult {
        guard !success else { return .success }
        guard let error else { return .failed }
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: nsError.code)
        else {
            return .failed
        }

        switch code {
        case .userCancel, .systemCancel, .appCancel:
            return .cancelled
        case .invalidContext, .notInteractive:
            // Neither is a rejected fingerprint. Reporting them as .failed told
            // the user "Touch ID didn't match", which is simply untrue and sends
            // them back to the sensor instead of re-opening the prompt.
            return .cancelled
        case .authenticationFailed, .userFallback:
            return .failed
        case .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            return .unavailable(touchIDUnavailableMessage(nsError, whileLocked: true, allowsWatch: allowsWatch))
        case .biometryDisconnected, .biometryNotPaired, .watchNotAvailable:
            // The sensor or Watch went away mid-session — e.g. a Magic Keyboard
            // with Touch ID dropping its Bluetooth link on a Mac mini/Studio.
            // As .failed this told the user their fingerprint was rejected and
            // to press a chord on a keyboard that is no longer connected.
            return .unavailable(touchIDUnavailableMessage(nsError, whileLocked: true, allowsWatch: allowsWatch))
        default:
            return .failed
        }
    }

    nonisolated private static func touchIDUnavailableMessage(
        _ error: NSError?,
        whileLocked: Bool,
        allowsWatch: Bool
    ) -> String {
        if whileLocked {
            // Lockout is terminal while input is suppressed: it clears only via
            // a typed password, which the tap makes impossible. "Try again"
            // would be false hope — every retry fails instantly. Say so, and
            // give the two exits that actually work.
            if let error,
               error.domain == LAError.errorDomain,
               LAError.Code(rawValue: error.code) == .biometryLockout {
                return """
                    Touch ID is locked after too many failed attempts and \
                    cannot recover while input is locked. From another device, \
                    run `pkill -x frost` over SSH (Remote Login must already \
                    be on), or press and hold the power button to shut down \
                    this Mac.
                    """
            }
            return """
                Touch ID is not available right now. Press the unlock shortcut \
                to try again. If Touch ID remains unavailable, use Remote Login \
                from another device, or a terminal opened before locking, to run \
                `pkill -x frost`.
                """
        }

        guard let error,
              error.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: error.code)
        else {
            return """
                Frost could not verify that Touch ID is available, so input was \
                not locked.
                """
        }

        switch code {
        case .biometryNotAvailable:
            if allowsWatch {
                return """
                    Frost requires Touch ID or a paired, unlocked Apple Watch. \
                    Neither is available right now, so input was not locked.
                    """
            }
            return """
                Frost requires Touch ID. This Mac does not report a usable Touch \
                ID sensor, so input was not locked.
                """
        case .biometryNotEnrolled:
            return """
                Frost requires Touch ID. Add a fingerprint in System Settings, \
                then try again. Input was not locked.
                """
        case .biometryLockout:
            return """
                Touch ID is temporarily locked after too many attempts. Unlock \
                the Mac normally with your password, then try Frost again. Input \
                was not locked.
                """
        case .passcodeNotSet:
            return """
                Touch ID needs a Mac login password before Frost can use it. Set \
                one up in System Settings, then try again. Input was not locked.
                """
        case .biometryDisconnected, .biometryNotPaired:
            return """
                Frost can't reach the Touch ID sensor — a keyboard with Touch ID \
                may have disconnected. Reconnect it and try again. Input was not \
                locked.
                """
        case .watchNotAvailable:
            return """
                Frost can't reach your Apple Watch. Make sure it is unlocked and \
                nearby, then try again. Input was not locked.
                """
        default:
            return """
                Touch ID is not available right now. Frost did not lock input.
                """
        }
    }
}
