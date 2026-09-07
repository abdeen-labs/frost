//
//  SystemHooks.swift
//  frost
//
//  LockController's seam onto process-level hooks — termination signal
//  sources (+ the wedge watchdog), the global lock-hotkey key monitor, the
//  distributed Accessibility-trust observer, and app termination — so
//  state-machine tests can drive the SIGTERM teardown contract without
//  installing real handlers into (or terminating) the test-host process.
//

import AppKit
import CoreGraphics
import Foundation
import os

@MainActor
protocol SystemHooking: AnyObject {
    /// Install DispatchSource handlers for SIGTERM/SIGINT/SIGHUP that invoke
    /// `onSignal` on the main actor, plus the off-main watchdog that
    /// force-exits if clean teardown wedges.
    func installTerminationHandlers(onSignal: @escaping @MainActor () -> Void)
    /// Global keyDown monitor for the optional lock hotkey. Replaces any
    /// previously installed monitor.
    func installLockHotKeyMonitor(
        onKeyDown: @escaping @MainActor (UInt16, NSEvent.ModifierFlags) -> Void)
    func removeLockHotKeyMonitor()
    /// Distributed-notification observer for Accessibility-trust changes.
    func observeAccessibilityTrustChanges(onChange: @escaping @MainActor () -> Void)
    /// Terminate the app (the tail of the clean signal path).
    func terminateApp()
    /// Remove everything installed above (deinit path).
    func removeAll()
}

@MainActor
final class SystemHooks: SystemHooking {
    private var signalSources: [any DispatchSourceSignal] = []
    private var lockHotKeyMonitor: Any?
    private var accessibilityObserver: (any NSObjectProtocol)?

    /// Catch SIGTERM (e.g. from `pkill`/`kill` over SSH) so we can restore the
    /// cursor + release the tap before exiting — never die with the cursor still
    /// decoupled from the mouse. SIGINT and SIGHUP get the same treatment: the
    /// documented "terminal opened before locking" escape route can also deliver
    /// Ctrl-C or a hangup on session close, whose default action would kill the
    /// process without any teardown.
    func installTerminationHandlers(onSignal: @escaping @MainActor () -> Void) {
        // Deliberately NOT the main queue: the watchdog's whole point is to act
        // when the main thread is wedged.
        let watchdogQueue = DispatchQueue(label: "dev.abdeen.frost.termination-watchdog")
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task { @MainActor in onSignal() }
            }
            source.resume()
            signalSources.append(source)

            // Watchdog: the clean handler above runs on the main queue, and the
            // signal's default action was replaced with SIG_IGN — so if the main
            // thread ever wedges while locked, `pkill -ix frost` would otherwise
            // be silently ignored and the remote-kill contract would be dead.
            // If the process is still alive this long after the signal, the
            // clean path failed: restore the cursor association (best effort,
            // callable off-main) and force-exit — macOS reclaims the tap and
            // presentation options at process death. `_exit` skips atexit
            // handlers, which could block on the wedged main thread.
            let watchdog = DispatchSource.makeSignalSource(signal: sig, queue: watchdogQueue)
            watchdog.setEventHandler { @Sendable in
                Thread.sleep(forTimeInterval: 5)
                CGAssociateMouseAndMouseCursorPosition(1)
                Logger(subsystem: "dev.abdeen.frost", category: "Lock")
                    .fault("Teardown did not finish after a termination signal; force-exiting")
                _exit(EXIT_FAILURE)
            }
            watchdog.resume()
            signalSources.append(watchdog)
        }
    }

    /// Optional system-wide hotkey that STARTS a lock. A non-consuming global
    /// monitor is enough: it only needs to trigger a lock, and it never fires
    /// while Frost itself is frontmost (so it won't clash with the recorder).
    ///
    /// `NSEvent` global *keyboard* monitors only deliver events while the
    /// process is trusted for Accessibility.
    func installLockHotKeyMonitor(
        onKeyDown: @escaping @MainActor (UInt16, NSEvent.ModifierFlags) -> Void
    ) {
        removeLockHotKeyMonitor()
        lockHotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Pull the Sendable bits out here; hop to the main actor to act.
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            Task { @MainActor in onKeyDown(keyCode, modifiers) }
        }
    }

    func removeLockHotKeyMonitor() {
        if let lockHotKeyMonitor {
            NSEvent.removeMonitor(lockHotKeyMonitor)
            self.lockHotKeyMonitor = nil
        }
    }

    func observeAccessibilityTrustChanges(onChange: @escaping @MainActor () -> Void) {
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in onChange() }
        }
    }

    func terminateApp() {
        NSApp.terminate(nil)
    }

    func removeAll() {
        removeLockHotKeyMonitor()
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
    }
}
