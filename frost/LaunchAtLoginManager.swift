//
//  LaunchAtLoginManager.swift
//  frost
//
//  Wraps SMAppService.mainApp so Settings can register/unregister Frost as a
//  login item without adding a helper app.
//

import Combine
import Foundation
import os
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let log = Logger(subsystem: "dev.abdeen.frost", category: "LaunchAtLogin")

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        // `.requiresApproval` counts as ON. register() commonly SUCCEEDS into
        // that status — the registration is recorded, macOS just wants the user
        // to confirm it in Login Items. Reporting it as off made the toggle
        // spring back under the user's finger, which reads as a rejected input
        // long before anyone reads the footer explaining the remaining step.
        isEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Not error.localizedDescription: SMAppService surfaces failures as
            // "The operation couldn't be completed. (SMAppServiceErrorDomain
            // error 1.)", which tells the user nothing they can act on.
            errorMessage = enabled
                ? "Frost couldn't register as a login item. Add it manually in System Settings → General → Login Items."
                : "Frost couldn't remove itself from login items. Remove it in System Settings → General → Login Items."
            log.error("SMAppService \(enabled ? "register" : "unregister", privacy: .public) failed: \(error)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
