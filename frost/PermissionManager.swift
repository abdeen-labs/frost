//
//  PermissionManager.swift
//  frost
//
//  Checks and requests the permission an active (suppressing) session event tap
//  needs. Accessibility is TCC-mediated and granted by the user in System
//  Settings → Privacy & Security. It is not an entitlement.
//

import ApplicationServices
import Carbon.HIToolbox

/// LockController's seam onto the Accessibility (TCC) check, so the lock state
/// machine can be tested without depending on the test host's real trust state.
@MainActor
protocol AccessibilityChecking: AnyObject {
    func hasAccessibility() -> Bool
    @discardableResult
    func requestAccessibility() -> Bool
    /// True when some process holds secure event input.
    func isSecureInputActive() -> Bool
}

@MainActor
final class PermissionManager: AccessibilityChecking {
    /// Accessibility trust without showing the system prompt.
    func hasAccessibility() -> Bool {
        checkAccessibility(prompt: false)
    }

    /// Shows the system Accessibility prompt if not yet granted.
    @discardableResult
    func requestAccessibility() -> Bool {
        checkAccessibility(prompt: true)
    }

    /// While secure event input is held, the WindowServer routes keyboard events
    /// only to the holder — they never reach a session-level CGEventTap. Frost's
    /// tap would still be created successfully, and the lock would still freeze
    /// the pointer and disable ⌘Tab and Force Quit, but the unlock chord is
    /// recognized INSIDE that tap callback, so it could never fire. That is a
    /// lock with no in-app way out.
    ///
    /// The state is not exotic: a password field that crashed without balancing
    /// its EnableSecureEventInput leaves it stuck on system-wide.
    func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    private func checkAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
