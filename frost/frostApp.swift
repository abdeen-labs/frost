//
//  frostApp.swift
//  frost
//

import SwiftUI
import AppKit

@main
struct frostApp: App {
    // Reopens Settings when the user relaunches Frost while the menu bar icon is
    // hidden - the only way back in once the icon is gone. Never opens on launch,
    // so starting at login stays silent.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Owns Sparkle for the app's lifetime. Created once here so the updater
    // starts (and begins its scheduled background checks) at launch.
    @StateObject private var updater: UpdaterController
    @StateObject private var settings: SettingsStore
    @StateObject private var launchAtLogin: LaunchAtLoginManager
    @StateObject private var lock: LockController
    // Backed by UserDefaults (not the @Published store) so writing it back from
    // MenuBarExtra(isInserted:) during a scene update doesn't publish a change.
    @AppStorage(SettingsStore.showInMenuBarKey) private var showInMenuBar = true

    init() {
        // SettingsStore is created first so the lock controller can read the
        // user's shortcuts/power preferences from the same instance the
        // Settings window edits.
        let settings = SettingsStore()
        let launchAtLogin = LaunchAtLoginManager()
        let updater = UpdaterController()
        _settings = StateObject(wrappedValue: settings)
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin)
        _updater = StateObject(wrappedValue: updater)
        _lock = StateObject(wrappedValue: LockController(settings: settings))
        SettingsWindowController.shared.configure(
            settings: settings,
            launchAtLogin: launchAtLogin,
            updater: updater
        )
    }

    private var menuTitle: String {
        if lock.isSuppressingInput { return "Locked" }
        if lock.isHoldingLock { return "Locked — Input Not Blocked" }
        return lock.isLocked ? "Input Not Locked" : "Lock Input"
    }

    var body: some Scene {
        // LSUIElement agent: no Dock icon, no window — the menu bar is the UI.
        // `isInserted` lets the user hide the icon from Settings.
        MenuBarExtra("Frost", image: "MenuBarIcon", isInserted: $showInMenuBar) {
            // Three distinct truths, none of which may be misreported:
            //   • suppressing        -> "Locked"
            //   • holding but macOS killed the tap -> input is flowing again,
            //     but Frost still requires authentication to let go
            //   • recovery           -> the lock never started
            Button(menuTitle) { lock.lock() }
                .disabled(lock.isLocked)

            Divider()

            Button("Settings…") {
                SettingsWindowController.shared.show()
            }
            .keyboardShortcut(",")

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Divider()

            Button("Quit Frost") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

    }
}
