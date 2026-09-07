//
//  LockStateTests.swift
//  frostTests
//
//  Value semantics of the lock state machine's types: LockState, RecoveryState,
//  and the Touch ID / authentication result enums. These Equatable contracts are
//  what LockController's guards (`state == .locked`, `case .recovery`) rely on.
//

import Testing

@testable import Frost

@MainActor
struct LockStateTests {

    @Test func lockStatesAreDistinct() {
        #expect(LockState.unlocked == .unlocked)
        #expect(LockState.unlocked != .locked)
        #expect(LockState.locked != .authenticating)
        #expect(LockState.authenticating != .unlocked)
    }

    @Test func recoveryStatesCompareByContents() {
        let a = RecoveryState(message: "x")
        let b = RecoveryState(message: "x")
        let c = RecoveryState(message: "y")
        #expect(LockState.recovery(a) == .recovery(b))
        #expect(LockState.recovery(a) != .recovery(c))
        #expect(LockState.recovery(a) != .locked)
    }

    @Test func recoveryStateDefaults() {
        let r = RecoveryState(message: "needs attention")
        #expect(r.title == "Input Not Locked")
        #expect(r.message == "needs attention")
        #expect(r.showsAccessibilitySettings == false)
        #expect(r.allowsRetry == true)
    }

    @Test func recoveryStateEqualityIsFieldwise() {
        let base = RecoveryState(
            title: "T", message: "M",
            showsAccessibilitySettings: true, allowsRetry: false)
        #expect(base == RecoveryState(
            title: "T", message: "M",
            showsAccessibilitySettings: true, allowsRetry: false))
        #expect(base != RecoveryState(
            title: "T2", message: "M",
            showsAccessibilitySettings: true, allowsRetry: false))
        #expect(base != RecoveryState(
            title: "T", message: "M2",
            showsAccessibilitySettings: true, allowsRetry: false))
        #expect(base != RecoveryState(
            title: "T", message: "M",
            showsAccessibilitySettings: false, allowsRetry: false))
        #expect(base != RecoveryState(
            title: "T", message: "M",
            showsAccessibilitySettings: true, allowsRetry: true))
    }
}

@MainActor
struct AuthenticationResultTests {

    @Test func touchIDCheckEquality() {
        #expect(TouchIDCheck.available == .available)
        #expect(TouchIDCheck.unavailable(message: "a", allowsRetry: true)
                == .unavailable(message: "a", allowsRetry: true))
        #expect(TouchIDCheck.unavailable(message: "a", allowsRetry: true)
                != .unavailable(message: "b", allowsRetry: true))
        #expect(TouchIDCheck.unavailable(message: "a", allowsRetry: true)
                != .unavailable(message: "a", allowsRetry: false))
        #expect(TouchIDCheck.available != .unavailable(message: "a", allowsRetry: true))
    }

    @Test func authenticationResultEquality() {
        #expect(AuthenticationResult.success == .success)
        #expect(AuthenticationResult.cancelled == .cancelled)
        #expect(AuthenticationResult.cancelled != .failed)
        #expect(AuthenticationResult.success != .failed)
        #expect(AuthenticationResult.unavailable("x") == .unavailable("x"))
        #expect(AuthenticationResult.unavailable("x") != .unavailable("y"))
        #expect(AuthenticationResult.unavailable("x") != .failed)
    }
}
