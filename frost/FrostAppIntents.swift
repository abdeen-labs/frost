//
//  FrostAppIntents.swift
//  frost
//
//  App Intents surface: a single "Lock Input" action so Shortcuts (and
//  `shortcuts run "Lock Input"` from a terminal or build script) can start a
//  lock programmatically — the product's core workflow is "start an
//  unattended task, then lock the desk".
//
//  SAFETY: the intent can only LOCK, never unlock. It calls the same
//  LockController.lock() entry point as the menu item, so every preflight
//  (Touch ID availability, Accessibility) and every recovery/escape hatch
//  applies unchanged. If the app is already locked or in recovery, the
//  intent is a no-op.
//

import AppIntents

struct LockInputIntent: AppIntent {
    // Mirror the Debug/Release bundle split (dev.abdeen.frost.debug /
    // "Frost (Dev)") so a dev build's action is distinguishable from the
    // installed app's in the Shortcuts gallery.
    #if DEBUG
    static let title: LocalizedStringResource = "Lock Input (Dev)"
    #else
    static let title: LocalizedStringResource = "Lock Input"
    #endif
    static let description = IntentDescription(
        "Locks keyboard, mouse, and trackpad input until unlocked with Touch ID."
    )
    // Menu-bar agent: the lock overlay is the UI; never open a window.
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        // The controller is created by the SwiftUI App on launch. If this
        // intent launched the app, the scene may still be building — give it
        // a short beat rather than failing spuriously.
        for _ in 0..<50 where LockController.shared == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let lock = LockController.shared else {
            throw LockInputIntentError.notReady
        }
        // `isSuppressingInput`, not `isLocked`: the latter is also true during
        // recovery, where input is explicitly NOT locked. Short-circuiting on it
        // meant a stale recovery card from an earlier failed lock made this
        // intent report success while the desk sat unlocked.
        guard !lock.isSuppressingInput else {
            return .result()   // already suppressing input: no-op
        }
        lock.lock()

        // lock() is non-throwing and resolves to input-suppressed OR one of
        // three recovery states (Touch ID unavailable, Accessibility missing,
        // tap start failed). Returning .result() unconditionally reported
        // success for all four. The documented usage is
        // `shortcuts run "Lock Input"` from a script, so a caller that cannot
        // observe the difference proceeds with an unattended task on an
        // unlocked machine — exactly the outcome it asked to prevent.
        guard lock.isSuppressingInput else {
            throw LockInputIntentError.lockFailed(lock.recoveryMessage)
        }
        return .result()
    }
}

enum LockInputIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case lockFailed(String?)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            return "Frost is still starting. Try again in a moment."
        case .lockFailed(let reason):
            guard let reason else {
                return "Frost could not lock input. Input is NOT locked."
            }
            return "Frost could not lock input: \(reason)"
        }
    }
}

/// Publishes the intent as an App Shortcut so it exists in Shortcuts (and is
/// runnable via `shortcuts run`) without the user assembling anything.
struct FrostShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        #if DEBUG
        AppShortcut(
            intent: LockInputIntent(),
            phrases: ["Lock input with \(.applicationName)"],
            shortTitle: "Lock Input (Dev)",
            systemImageName: "lock.fill"
        )
        #else
        AppShortcut(
            intent: LockInputIntent(),
            phrases: ["Lock input with \(.applicationName)"],
            shortTitle: "Lock Input",
            systemImageName: "lock.fill"
        )
        #endif
    }
}
