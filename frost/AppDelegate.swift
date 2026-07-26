//
//  AppDelegate.swift
//  frost
//
//  Bridges the AppKit launch hooks SwiftUI doesn't expose, in service of one
//  rule: the user must always have a way back into Settings — even with the menu
//  bar icon hidden, which removes Frost's only other UI.
//
//  Frost never opens a window on launch: at login it must come up silently in
//  the background, like any other menu-bar agent. The way back into Settings
//  when the icon is hidden is to relaunch Frost (from Finder/Spotlight) while
//  it's already running — that delivers a reopen, which opens Settings. A reopen
//  fired during the initial launch (the system relaunching Frost at login) is
//  ignored, so booting stays silent.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Gate for `applicationShouldHandleReopen`. macOS can deliver a reopen Apple
    // event as part of a login-item launch (and when "Reopen windows when
    // logging back in" relaunches Frost) — indistinguishable from the user
    // double-clicking Frost while it's running. Left ungated, that login-time
    // reopen would pop Settings on boot. We only honor reopens once the initial
    // launch batch has drained.
    private var didFinishInitialLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deliberately open nothing here — a login launch must stay silent.
        //
        // The one exception is a relaunch started by "Quit & Reopen Frost",
        // which passes an explicit argument. That flow exists to make a fresh
        // Accessibility grant usable, and it is the moment the user most needs
        // to see that the relaunch worked; without this it relaunched into an
        // invisible app (and, with the menu-bar icon hidden, no UI at all).
        // A login item never passes the argument, so boot stays silent.
        if CommandLine.arguments.contains(LockController.showSettingsLaunchArgument) {
            SettingsWindowController.shared.show()
        }

        // Defer past the current run-loop turn so a reopen event delivered in
        // this same launch batch (the system relaunching Frost at login) is
        // still seen as "mid-launch" by the reopen handler and ignored. Genuine
        // user reopens arrive later, once this flag is set.
        DispatchQueue.main.async { [weak self] in
            self?.didFinishInitialLaunch = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A reopen during the initial launch is the system relaunching Frost
        // (login item / window restoration), not a user asking for Settings.
        guard didFinishInitialLaunch else { return true }

        // Never churn window focus while a lock is active: `show()` activates
        // the app and keys the Settings window, which competes with the system
        // Touch ID prompt — and a reopen can arrive mid-lock (e.g. `open -a
        // Frost` from a remote shell, or Quit & Reopen racing a new lock).
        if LockController.shared?.isLocked != true {
            SettingsWindowController.shared.show()
        }
        return true
    }

    // Safety backstop: if Frost is told to terminate while a lock (or recovery)
    // is still active — e.g. a plain NSApp.terminate that bypasses teardown() —
    // restore the cursor, presentation options, tap, and power assertions here
    // rather than depending on @StateObject deinit running at exit. Runs on the
    // main thread, so the @MainActor hop is safe; no-op when already unlocked.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            LockController.shared?.tearDownForTermination()
        }
    }
}
