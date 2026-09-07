//
//  SettingsView.swift
//  frost
//
//  The preferences window: configure the lock/unlock shortcuts and the
//  while-locked power behavior.
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var updater: UpdaterController
    // Shares the menu-bar flag with the App via UserDefaults (see SettingsStore).
    @AppStorage(SettingsStore.showInMenuBarKey) private var showInMenuBar = true
    /// Inline notice shown when a lock/unlock shortcut collision changes the
    /// lock shortcut — the beep alone is inaudible with sound muted, and the
    /// field silently flipping to "Click to record" reads as data loss.
    @State private var lockShortcutNotice: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Unlock")
                    Spacer()
                    ShortcutRecorder(shortcut: unlockBinding, allowsClear: false,
                                     accessibilityLabel: "Unlock shortcut")
                        .frame(width: 170, height: 24)
                }
                Toggle("Start Touch ID automatically when locked", isOn: $settings.startTouchIDWhenLocked)
                Toggle("Allow Apple Watch to unlock", isOn: $settings.allowWatchUnlock)
            } header: {
                Text("Unlock")
            } footer: {
                Text("Required. Press this while locked to bring up Touch ID. Click the field (or focus it and press Space) and press a new combo to change it, or ⎋ to cancel. Shortcuts must include at least one of ⌃, ⌥, or ⌘. Turn on automatic start to show Touch ID as soon as a lock begins. Frost requires Touch ID — or, if enabled, a paired, unlocked Apple Watch (double-press its side button when prompted).\n\nEmergency exit: if Touch ID can't unlock, run `pkill -ix frost` over SSH from another device. Turn on Remote Login in System Settings before you rely on Frost.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Lock")
                    Spacer()
                    ShortcutRecorder(shortcut: lockBinding, allowsClear: true,
                                     accessibilityLabel: "Lock shortcut")
                        .frame(width: 170, height: 24)
                    Button("Clear") {
                        settings.lockShortcut = nil
                        lockShortcutNotice = nil
                    }
                    .disabled(settings.lockShortcut == nil)
                }
            } header: {
                Text("Lock Shortcut")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let lockShortcutNotice {
                        Text(lockShortcutNotice)
                            .foregroundStyle(.orange)
                    }
                    Text("Optional. A system-wide hotkey that locks input from anywhere. Click the field (or focus it and press Space) and press a combo to set it; press ⌫ or Clear to remove it, or ⎋ to cancel. Shortcuts must include at least one of ⌃, ⌥, or ⌘. It can't match Unlock — changing Unlock to match will clear it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Auto-lock", selection: $settings.inactivityLock) {
                    ForEach(InactivityLockOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Inactivity")
            } footer: {
                Text("Locks after the selected time without keyboard, mouse, or trackpad input. Passive reading still counts as idle. With automatic Touch ID start on, an auto-lock also opens the Touch ID prompt; input stays locked until Touch ID succeeds.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Prevent screen saver", isOn: $settings.preventScreenSaver)
                Toggle("Prevent sleep", isOn: $settings.preventSleep)
            } header: {
                Text("While Locked")
            } footer: {
                Text("Keep the screen on and the Mac awake while input is locked. Released automatically on unlock.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Message", text: $settings.lockMessage,
                          prompt: Text("Optional, e.g. \u{201C}Agent run in progress — do not touch\u{201D}"))
                    .onChange(of: settings.lockMessage) { _, new in
                        // Bound at the source as well as on the overlay: while
                        // input is suppressed the user can neither scroll the
                        // card nor switch away, so an over-long message must
                        // never be able to displace the unlock hint.
                        if new.count > Self.lockMessageLimit {
                            settings.lockMessage = String(new.prefix(Self.lockMessageLimit))
                        }
                    }
            } header: {
                Text("Overlay Message")
            } footer: {
                Text("Shown on the locked overlay while input is suppressed. Leave empty for none. Long messages are shortened so the unlock shortcut stays visible.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.requiresApproval {
                    Button("Open Login Items Settings") {
                        launchAtLogin.openLoginItemsSettings()
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                if let message = launchAtLogin.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                } else if launchAtLogin.requiresApproval {
                    Text("macOS needs approval in Login Items before Frost can launch at login.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
            } header: {
                Text("Menu Bar")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !showInMenuBar && settings.lockShortcut == nil
                        && settings.inactivityLock == .off {
                        Text("With the icon hidden and no lock shortcut or auto-lock set, nothing can start a lock.")
                            .foregroundStyle(.orange)
                    }
                    Text("When off, the menu bar icon is hidden and Frost keeps running quietly in the background, even on first launch. Open Frost again to return to this window; use Quit below to stop it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("Frost \(Self.appVersion) — checks automatically in the background. Use this to check right now.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Quit Frost") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 320)
        .onAppear {
            // An LSUIElement agent doesn't auto-focus its windows; pull the
            // Settings window to the front so the user can interact with it.
            NSApp.activate(ignoringOtherApps: true)
            launchAtLogin.refresh()
        }
    }

    /// Upper bound on the owner message. Generous enough for a sentence or two
    /// of instructions, short enough that the locked card cannot outgrow a
    /// display and push the unlock-shortcut hint off-screen.
    private static let lockMessageLimit = 280

    /// Marketing version for the Updates footer — a Sparkle-updated app should
    /// say somewhere what version is running.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
    }

    /// The unlock field is required, so adapt the non-optional store value to the
    /// recorder's optional binding and ignore any nil (clearing is disabled).
    private var unlockBinding: Binding<Shortcut?> {
        Binding(
            get: { settings.unlockShortcut },
            set: {
                if let new = $0 {
                    settings.unlockShortcut = new
                    if settings.lockShortcut == new {
                        settings.lockShortcut = nil
                        lockShortcutNotice = "Lock shortcut removed — it matched the new unlock shortcut."
                    }
                }
            }
        )
    }

    private var lockBinding: Binding<Shortcut?> {
        Binding(
            get: { settings.lockShortcut },
            set: {
                // Reject WITHOUT mutating. Assigning nil here used to delete a
                // lock shortcut the user had already configured — so mistakenly
                // recording the unlock chord silently disabled the global lock
                // hotkey, under a notice that said "Not saved". The unlock-side
                // binding still has to clear (there the collision is created by
                // changing the OTHER shortcut, and something must give), but
                // nothing forces a clear on this path.
                guard $0 != settings.unlockShortcut else {
                    lockShortcutNotice = "Not saved — the lock shortcut can't match the unlock shortcut."
                    NSSound.beep()
                    return
                }
                settings.lockShortcut = $0
                lockShortcutNotice = nil
            }
        )
    }
}
