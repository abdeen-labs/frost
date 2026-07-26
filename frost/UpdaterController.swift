//
//  UpdaterController.swift
//  frost
//
//  Thin wrapper around Sparkle's SPUStandardUpdaterController so SwiftUI can
//  drive "Check for Updates…" and reflect whether a check is currently allowed.
//

import Combine
import Foundation
import Sparkle

/// Owns the Sparkle updater for the app's lifetime.
///
/// Sparkle is the *only* component in Frost that touches the network — it
/// fetches the appcast at `SUFeedURL` and verifies downloads against
/// `SUPublicEDKey` (both in Info.plist). There is no telemetry and no other
/// network use.
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    /// Sparkle holds its delegate weakly; keep it alive here.
    private let delegate = FrostUpdaterDelegate()

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item can disable
    /// itself while an update session is already in flight.
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater: true → Sparkle starts immediately and schedules its
        // automatic background checks using the Info.plist configuration.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Triggers a user-initiated update check (shows Sparkle's standard UI).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Defers Sparkle's checks while input is suppressed: an update alert appearing
/// mid-lock would sit below the overlay and compete with the Touch ID prompt
/// for key-window status. Sparkle retries deferred scheduled checks on its own;
/// recovery (input NOT locked) is deliberately not gated. Sparkle invokes its
/// delegate on the main thread.
@MainActor
private final class FrostUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // isHoldingLock, not isSuppressingInput: if macOS killed the tap the
        // overlay is still up demanding authentication, and an update alert
        // must not compete with that prompt for focus.
        if LockController.shared?.isHoldingLock == true {
            throw NSError(
                domain: "dev.abdeen.frost",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Frost is locked; update checks resume after unlock."]
            )
        }
    }
}
