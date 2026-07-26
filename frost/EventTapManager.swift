//
//  EventTapManager.swift
//  frost
//
//  Owns the CGEvent tap that suppresses keyboard + pointer input. The tap is
//  ACTIVE (.defaultTap): the callback returns nil to swallow every event. The
//  unlock chord is recognized HERE, inside the callback, because normal key
//  routing is dead while input is suppressed.
//
//  During authentication the tap stays active and the cursor stays frozen — the
//  screen is never exposed — but the Esc key is allowed through so the user can
//  cancel the LocalAuthentication prompt and stay locked.
//
//  Placement: .cgSessionEventTap. The HID-entry tap is earlier in the event
//  stream, but Apple's SDK requires root for kCGHIDEventTap. Frost deliberately
//  runs as the logged-in user, so the session-level tap is the honest target.
//
//  The tap source is added to the MAIN run loop, so the C callback runs on the
//  main thread; we assert main-actor isolation to call back into this class.
//

import AppKit
import CoreGraphics
import Foundation
import os

// kVK_Escape — passed through during auth so the user can cancel the prompt.
private let kEscapeKeyCode: Int64 = 0x35

// NX_SYSDEFINED. Media/system keys (volume, brightness, play/pause, eject)
// arrive as system-defined events, not keyDown, so without this bit they pass
// straight through while locked. CGEventType has no Swift case for it.
private let kSystemDefinedEventType: UInt32 = 14

/// LockController's seam onto the event tap, so the lock state machine can be
/// tested without creating a real (Accessibility-gated) CGEvent tap.
@MainActor
protocol InputSuppressing: AnyObject {
    var onUnlockChord: (() -> Void)? { get set }
    var onTapReenabled: ((String) -> Void)? { get set }
    var onTapReviveFailed: (() -> Void)? { get set }
    var unlockShortcut: Shortcut? { get set }
    func start() -> Bool
    func setAuthenticating(_ on: Bool)
    func stop()
}

/// EventTapManager's seam onto the WindowServer cursor calls, so tests can
/// assert freeze/restore/re-pin behavior without decoupling the real mouse
/// from the cursor of the machine running them.
@MainActor
protocol CursorControlling: AnyObject {
    /// Couple (true) or decouple (false) the mouse and the on-screen cursor.
    func setAssociated(_ associated: Bool)
    func warp(to point: CGPoint)
    /// The current cursor location, captured at lock time for pinning.
    func currentLocation() -> CGPoint?
}

@MainActor
final class SystemCursorControl: CursorControlling {
    func setAssociated(_ associated: Bool) {
        _ = CGAssociateMouseAndMouseCursorPosition(associated ? 1 : 0)
    }
    func warp(to point: CGPoint) { CGWarpMouseCursorPosition(point) }
    func currentLocation() -> CGPoint? { CGEvent(source: nil)?.location }
}

@MainActor
final class EventTapManager: InputSuppressing {
    /// Invoked on the main actor when the unlock shortcut is pressed.
    var onUnlockChord: (() -> Void)?
    /// Invoked if macOS disables the tap and Frost re-enables it.
    var onTapReenabled: ((String) -> Void)?
    /// Invoked if macOS disables the tap and Frost CANNOT re-enable it. Input
    /// suppression is then gone — and so is the unlock chord, which is
    /// recognized only inside this callback. The controller does NOT unlock:
    /// it holds the lock, keeps the overlay up, and requires authentication to
    /// dismiss (see THE INVARIANT in LockController).
    var onTapReviveFailed: (() -> Void)?

    /// The shortcut that triggers unlock, recognized inside the callback while
    /// input is suppressed. Set by LockController from the user's settings.
    var unlockShortcut: Shortcut?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Our INTENT to suppress. Distinguishes "user disabled the tap for auth"
    /// from "the system disabled the tap" so we never re-enable against intent.
    private var shouldSuppress = false
    /// While authenticating, the Esc key is the ONE event we let through (so the
    /// LocalAuthentication prompt can be cancelled). Everything else stays
    /// suppressed and the cursor stays frozen — the screen is never exposed.
    private var passEscapeToSystem = false
    private var lockedCursorPosition: CGPoint?
    /// Observer for display reconfiguration, so the pin point can be re-seated
    /// onto a display that still exists. Installed only while suppressing.
    private var screenChangeObserver: (any NSObjectProtocol)?
    private let log = Logger(subsystem: "dev.abdeen.frost", category: "EventTap")
    private let cursor: any CursorControlling

    /// `cursor` defaults (nil) to the real WindowServer-backed implementation,
    /// constructed in the body because default-argument expressions are
    /// nonisolated and the real initializer is main-actor-isolated. Tests
    /// inject a fake.
    init(cursor: (any CursorControlling)? = nil) {
        self.cursor = cursor ?? SystemCursorControl()
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    /// Creates and enables the tap. Returns `false` if creation fails at every
    /// placement — almost always missing Accessibility. The
    /// caller MUST then surface the recovery state; input is NOT suppressed.
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << kSystemDefinedEventType)
        )

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: frostEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("CGEvent.tapCreate failed (missing Accessibility?)")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            // Fails safe: no source means no suppression, so report failure and
            // let the caller show recovery rather than crash at lock start.
            log.fault("CFMachPortCreateRunLoopSource returned nil")
            CFMachPortInvalidate(port)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            log.fault("CGEvent tap was created but could not be enabled")
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(port)
            return false
        }

        tap = port
        runLoopSource = source
        shouldSuppress = true
        lockedCursorPosition = cursor.currentLocation()
        setCursorFrozen(true)
        pinCursor()
        observeScreenChanges()

        log.info("Event tap started at session level")
        return true
    }

    /// Enter/leave authentication mode WITHOUT changing suppression: the tap
    /// stays active, input stays swallowed, and the cursor stays frozen, so the
    /// screen is never exposed while the LocalAuthentication prompt is up. The
    /// only difference is that Esc is allowed through, letting the user cancel
    /// the prompt and remain locked. Leaving auth mode re-freezes Esc.
    func setAuthenticating(_ on: Bool) {
        passEscapeToSystem = on
    }

    /// Fully tears the tap down; input + cursor return to normal.
    func stop() {
        shouldSuppress = false
        passEscapeToSystem = false
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        lockedCursorPosition = nil
        setCursorFrozen(false)   // ALWAYS restore the cursor
        log.info("Event tap stopped")
    }

    // Freeze/unfreeze the on-screen cursor. Swallowing mouseMoved stops apps
    // from seeing movement, but the WindowServer still moves the cursor sprite;
    // decoupling the device from the cursor is what actually freezes it.
    private func setCursorFrozen(_ frozen: Bool) {
        cursor.setAssociated(!frozen)
    }

    private func pinCursor() {
        guard let lockedCursorPosition else { return }
        cursor.warp(to: lockedCursorPosition)
        setCursorFrozen(true)
    }

    /// Exact CGPoint inequality made this permanently true once the pin point
    /// stopped being reachable — after a display is disconnected the
    /// WindowServer clamps the cursor into the remaining bounds, so the warp can
    /// never land on the stored point again. The "only re-pin on drift"
    /// optimization then inverted into two synchronous WindowServer calls on
    /// every pointer event, at up-to-1000 Hz. Compare with a tolerance instead.
    /// Internal so the drift decision is directly testable.
    func hasCursorDrifted(from location: CGPoint) -> Bool {
        guard let lockedCursorPosition else { return false }
        return abs(location.x - lockedCursorPosition.x) > Self.cursorDriftTolerance
            || abs(location.y - lockedCursorPosition.y) > Self.cursorDriftTolerance
    }

    static let cursorDriftTolerance: CGFloat = 0.5

    #if DEBUG
    /// Test seam: `lockedCursorPosition` is otherwise only set inside `start()`,
    /// which needs a real Accessibility-gated tap — so the drift branch could
    /// never be reached from a test.
    func primeLockedCursorPositionForTesting(_ point: CGPoint) {
        lockedCursorPosition = point
    }
    #endif

    private func observeScreenChanges() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.reseatCursorPin() }
        }
    }

    /// Re-seat the pin point after a display reconfiguration, clamping it onto a
    /// display that still exists. Called by LockController, which already
    /// observes screen changes for the overlay.
    func reseatCursorPin() {
        guard shouldSuppress else { return }
        guard let current = cursor.currentLocation() else { return }
        lockedCursorPosition = current
        pinCursor()
    }

    /// What the callback should do when macOS delivers a tap-disabled marker.
    /// Pure decision logic, separated from the CGEvent.tapEnable side effects so
    /// all (suppressing × revive-succeeded) combinations are testable — getting
    /// this wrong either strands the user behind a misleading "re-enabled"
    /// notice or escalates when nothing is wrong.
    enum TapDisabledReaction: Equatable {
        case ignore                      // not suppressing: not our tap state
        case reenabled(message: String)  // revived: re-pin cursor + notify
        case reviveFailed                // dead tap: escalate to recovery
    }

    /// tapEnable returns no status, so the caller must confirm the re-enable
    /// actually took (`tapIsEnabledAfterReenable`) before reassuring the user.
    /// If it did NOT, input is no longer suppressed and the in-tap unlock
    /// chord is dead — report that instead of a misleading "re-enabled" notice,
    /// so the controller can hold the lock and demand authentication.
    static func tapDisabledReaction(
        type: CGEventType,
        shouldSuppress: Bool,
        tapIsEnabledAfterReenable: Bool
    ) -> TapDisabledReaction {
        guard shouldSuppress else { return .ignore }
        guard tapIsEnabledAfterReenable else { return .reviveFailed }
        // User-facing copy, so it names the outcome rather than the mechanism:
        // "input tap" is a CGEventTap implementation detail, and the reader is
        // someone who just found an alarm banner on a locked screen and needs to
        // know whether their input is still locked. Matches the vocabulary
        // LockController already uses ("Frost's input blocking").
        let message = type == .tapDisabledByTimeout
            ? "macOS briefly stopped Frost's input blocking because Frost was slow to respond. It has been restored — input is still locked."
            : "macOS briefly stopped Frost's input blocking. It has been restored — input is still locked."
        return .reenabled(message: message)
    }

    /// The side effects of a tap-disabled reaction, split out from `handle()`.
    ///
    /// `handle()`'s branch is gated on `shouldSuppress` and a live `tap`, both of
    /// which only exist after a real Accessibility-gated `start()` — so no test
    /// could ever execute it, and the escalation dispatch could be deleted
    /// outright with the suite green. Internal so the dispatch is directly
    /// callable.
    func apply(_ reaction: TapDisabledReaction) {
        switch reaction {
        case .ignore:
            break
        case .reenabled(let message):
            setCursorFrozen(true)
            pinCursor()
            log.error("Tap disabled by system; re-enabled")
            Task { @MainActor [weak self] in self?.onTapReenabled?(message) }
        case .reviveFailed:
            log.fault("Tap disabled by system and re-enable FAILED; holding the lock, authentication required")
            Task { @MainActor [weak self] in self?.onTapReviveFailed?() }
        }
    }

    // MARK: - Callback handling (main actor)

    /// Returns `true` if the event should be swallowed. Internal (not
    /// fileprivate) so the decision logic — the code whose failure either traps
    /// the user or leaks input — is directly testable with synthetic CGEvents.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if shouldSuppress, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                apply(Self.tapDisabledReaction(
                    type: type,
                    shouldSuppress: shouldSuppress,
                    tapIsEnabledAfterReenable: CGEvent.tapIsEnabled(tap: tap)
                ))
            }
            return false
        case .keyDown:
            // While authenticating, Esc must reach the system prompt so the user
            // can cancel and stay locked. Everything else stays suppressed.
            if passEscapeToSystem, isEscape(event) { return false }
            if isUnlockChord(event) { onUnlockChord?() }
            return true
        case .keyUp:
            if passEscapeToSystem, isEscape(event) { return false }
            return true
        default:
            // The cursor is disassociated for the whole session, so the sprite
            // normally can't move and the event's own location (free to read)
            // stays at the pinned point. Re-pin — two synchronous WindowServer
            // calls — only when the location shows it actually drifted, instead
            // of on every pointer event at up-to-1000 Hz polling rates.
            if isPointerEvent(type), hasCursorDrifted(from: event.location) {
                pinCursor()
            }
            return true
        }
    }

    // Pointer events that move or click the cursor and therefore warrant a
    // re-pin. Scroll-wheel events are still swallowed (the default branch returns
    // true) but never move the cursor, so re-pinning on them is wasted work.
    private func isPointerEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .mouseMoved,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private func isEscape(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == kEscapeKeyCode else {
            return false
        }
        // Only BARE Esc cancels the prompt. A modified combo (e.g. ⌘⌥Esc, the
        // Force Quit chord) must stay swallowed — it should never reach the
        // system while we're locked.
        let flags = event.flags
        return !flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)
    }

    private func isUnlockChord(_ event: CGEvent) -> Bool {
        guard let unlockShortcut else { return false }
        return unlockShortcut.matches(cgEvent: event)
    }
}

// C-compatible trampoline. The `CGEventTapCallBack` type is `@convention(c)`,
// so this closure is non-capturing and nonisolated; we hop to the main actor
// (we are already on its run loop) to touch EventTapManager.
private let frostEventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated {
        manager.handle(type: type, event: event)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
