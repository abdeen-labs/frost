//
//  UnlockCoordinatorTests.swift
//  frostTests
//
//  Covers the pure LAError → AuthenticationResult mapping that decides what
//  happens after a Touch ID evaluation: unlock, return to idle, or re-lock
//  with a notice. Getting a code wrong here either unlocks on failure or
//  strands the user behind a misleading message.
//

import Foundation
import LocalAuthentication
import Testing

@testable import frost

@MainActor
struct UnlockCoordinatorTests {

    private func laError(_ code: LAError.Code) -> NSError {
        NSError(domain: LAError.errorDomain, code: code.rawValue)
    }

    @Test func successWinsRegardlessOfError() {
        #expect(UnlockCoordinator.authenticationResult(
            success: true, error: nil, allowsWatch: false) == .success)
        #expect(UnlockCoordinator.authenticationResult(
            success: true, error: laError(.systemCancel), allowsWatch: false) == .success)
    }

    @Test func failureWithoutErrorIsFailed() {
        #expect(UnlockCoordinator.authenticationResult(
            success: false, error: nil, allowsWatch: false) == .failed)
    }

    // invalidContext and notInteractive are included deliberately: neither is a
    // rejected fingerprint, and reporting them as .failed told a locked user
    // "Touch ID didn't match" and sent them back to the sensor.
    @Test(arguments: [
        LAError.userCancel, .systemCancel, .appCancel,
        .invalidContext, .notInteractive,
    ])
    func cancellationCodesMapToCancelled(code: LAError.Code) {
        #expect(UnlockCoordinator.authenticationResult(
            success: false, error: laError(code), allowsWatch: false) == .cancelled)
    }

    @Test(arguments: [LAError.authenticationFailed, .userFallback])
    func failureCodesMapToFailed(code: LAError.Code) {
        #expect(UnlockCoordinator.authenticationResult(
            success: false, error: laError(code), allowsWatch: false) == .failed)
    }

    // biometryDisconnected / biometryNotPaired / watchNotAvailable are included
    // deliberately: a Magic Keyboard with Touch ID dropping its Bluetooth link
    // used to be reported as a rejected fingerprint, telling the user to press a
    // chord on a keyboard that is no longer connected.
    @Test(arguments: [
        LAError.biometryLockout, .biometryNotAvailable, .biometryNotEnrolled,
        .passcodeNotSet, .biometryDisconnected, .biometryNotPaired,
        .watchNotAvailable,
    ])
    func unavailabilityCodesMapToUnavailable(code: LAError.Code) {
        let result = UnlockCoordinator.authenticationResult(
            success: false, error: laError(code), allowsWatch: false)
        guard case .unavailable = result else {
            Issue.record("\(code) mapped to \(result), expected .unavailable")
            return
        }
    }

    /// Lockout is terminal while input is suppressed — the message must give
    /// the exits that work and must not suggest retrying.
    @Test func lockoutMessageGivesWorkableExitsOnly() {
        let result = UnlockCoordinator.authenticationResult(
            success: false, error: laError(.biometryLockout), allowsWatch: false)
        guard case .unavailable(let message) = result else {
            Issue.record("biometryLockout did not map to .unavailable")
            return
        }
        #expect(message.contains("pkill -x frost"))
        #expect(message.contains("power button"))
        #expect(!message.lowercased().contains("try again"))
    }

    @Test func transientUnavailabilityMessageOffersRetry() {
        let result = UnlockCoordinator.authenticationResult(
            success: false, error: laError(.biometryNotAvailable), allowsWatch: false)
        guard case .unavailable(let message) = result else {
            Issue.record("biometryNotAvailable did not map to .unavailable")
            return
        }
        #expect(message.contains("unlock shortcut"))
    }

    @Test func nonLAErrorDomainIsFailed() {
        let error = NSError(domain: "dev.abdeen.frost.tests", code: 1)
        #expect(UnlockCoordinator.authenticationResult(
            success: false, error: error, allowsWatch: false) == .failed)
    }

    @Test func unknownLAErrorCodeIsFailed() {
        let error = NSError(domain: LAError.errorDomain, code: 9999)
        #expect(UnlockCoordinator.authenticationResult(
            success: false, error: error, allowsWatch: false) == .failed)
    }

    // MARK: - Policy selection

    /// The chosen `LAPolicy` must follow the injected `allowWatch` closure —
    /// Touch ID only by default, Touch ID-or-Watch when the user opted in —
    /// and must consult the closure on every read, not just at construction,
    /// so a live setting change takes effect on the next lock/unlock.
    @Test func policySelectionFollowsTheWatchSetting() {
        let alwaysOff = UnlockCoordinator(allowWatch: { false })
        #expect(alwaysOff.effectivePolicy == .deviceOwnerAuthenticationWithBiometrics)

        let alwaysOn = UnlockCoordinator(allowWatch: { true })
        #expect(alwaysOn.effectivePolicy == .deviceOwnerAuthenticationWithBiometricsOrWatch)

        var flag = false
        let dynamic = UnlockCoordinator(allowWatch: { flag })
        #expect(dynamic.effectivePolicy == .deviceOwnerAuthenticationWithBiometrics)
        flag = true
        #expect(dynamic.effectivePolicy == .deviceOwnerAuthenticationWithBiometricsOrWatch)
    }
}
