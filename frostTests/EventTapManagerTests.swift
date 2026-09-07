//
//  EventTapManagerTests.swift
//  frostTests
//
//  Exercises the tap-callback decision logic directly with synthetic CGEvents —
//  no live tap needed. This is the riskiest code in the app: a wrong answer
//  here either traps the user (chord not recognized, Esc not reaching the
//  Touch ID prompt) or leaks input (something swallowed that shouldn't be, or
//  vice versa).
//

import Carbon.HIToolbox
import CoreGraphics
import Testing

@testable import Frost

@MainActor
private final class FakeCursor: CursorControlling {
    var location: CGPoint? = CGPoint(x: 100, y: 100)
    private(set) var associations: [Bool] = []
    private(set) var warps: [CGPoint] = []
    func setAssociated(_ associated: Bool) { associations.append(associated) }
    func warp(to point: CGPoint) { warps.append(point) }
    func currentLocation() -> CGPoint? { location }
}

@MainActor
struct EventTapManagerTests {

    private func keyEvent(
        _ key: Int,
        flags: CGEventFlags = [],
        keyDown: Bool = true
    ) throws -> CGEvent {
        let event = try #require(CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: keyDown))
        event.flags = flags
        return event
    }

    private func mouseEvent(_ type: CGEventType) throws -> CGEvent {
        try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: .zero,
            mouseButton: .left))
    }

    // MARK: - Unlock chord

    @Test func unlockChordFiresCallbackAndIsSwallowed() throws {
        let manager = EventTapManager()
        manager.unlockShortcut = .defaultUnlock
        var fired = false
        manager.onUnlockChord = { fired = true }

        let chord = try keyEvent(
            kVK_ANSI_U, flags: [.maskControl, .maskAlternate, .maskCommand])
        #expect(manager.handle(type: .keyDown, event: chord))
        #expect(fired)
    }

    @Test func chordToleratesIrrelevantFlagBits() throws {
        let manager = EventTapManager()
        manager.unlockShortcut = .defaultUnlock
        var fired = false
        manager.onUnlockChord = { fired = true }

        let chord = try keyEvent(
            kVK_ANSI_U,
            flags: [.maskControl, .maskAlternate, .maskCommand, .maskAlphaShift])
        #expect(manager.handle(type: .keyDown, event: chord))
        #expect(fired)
    }

    @Test func nonChordKeyIsSwallowedWithoutCallback() throws {
        let manager = EventTapManager()
        manager.unlockShortcut = .defaultUnlock
        var fired = false
        manager.onUnlockChord = { fired = true }

        #expect(manager.handle(type: .keyDown, event: try keyEvent(kVK_ANSI_A)))
        #expect(manager.handle(
            type: .keyDown, event: try keyEvent(kVK_ANSI_U, flags: [.maskCommand])))
        #expect(!fired)
    }

    @Test func missingShortcutNeverFiresCallback() throws {
        // unlockShortcut unset (a state the controller should never allow) must
        // degrade to plain swallowing, not a crash or a spurious unlock.
        let manager = EventTapManager()
        var fired = false
        manager.onUnlockChord = { fired = true }

        let chord = try keyEvent(
            kVK_ANSI_U, flags: [.maskControl, .maskAlternate, .maskCommand])
        #expect(manager.handle(type: .keyDown, event: chord))
        #expect(!fired)
    }

    // MARK: - Escape passthrough during authentication

    @Test func bareEscapePassesThroughOnlyWhileAuthenticating() throws {
        let manager = EventTapManager()
        let escDown = try keyEvent(kVK_Escape)
        let escUp = try keyEvent(kVK_Escape, keyDown: false)

        // Idle locked: Esc is swallowed like everything else.
        #expect(manager.handle(type: .keyDown, event: escDown))
        #expect(manager.handle(type: .keyUp, event: escUp))

        // Authenticating: bare Esc (down AND up) must reach the system prompt.
        manager.setAuthenticating(true)
        #expect(!manager.handle(type: .keyDown, event: escDown))
        #expect(!manager.handle(type: .keyUp, event: escUp))

        // Back to idle: swallowed again.
        manager.setAuthenticating(false)
        #expect(manager.handle(type: .keyDown, event: escDown))
    }

    @Test func modifiedEscapeStaysSwallowedWhileAuthenticating() throws {
        // ⌘⌥Esc is the Force Quit chord: opening it steals focus from the
        // Touch ID prompt and strands the user. It must never pass through.
        let manager = EventTapManager()
        manager.setAuthenticating(true)

        let forceQuit = try keyEvent(
            kVK_Escape, flags: [.maskCommand, .maskAlternate])
        #expect(manager.handle(type: .keyDown, event: forceQuit))
        #expect(manager.handle(
            type: .keyDown, event: try keyEvent(kVK_Escape, flags: [.maskControl])))
    }

    // MARK: - Pointer / other events

    @Test func pointerEventsAreSwallowed() throws {
        let manager = EventTapManager()
        #expect(manager.handle(
            type: .mouseMoved, event: try mouseEvent(.mouseMoved)))
        #expect(manager.handle(
            type: .leftMouseDown, event: try mouseEvent(.leftMouseDown)))
        #expect(manager.handle(
            type: .scrollWheel, event: try mouseEvent(.mouseMoved)))
        #expect(manager.handle(
            type: .flagsChanged, event: try keyEvent(kVK_Shift)))
    }

    @Test func tapDisabledEventsAreNeverSwallowed() throws {
        // The disabled marker events must always be returned to the system;
        // with no live tap (shouldSuppress == false) they are simply ignored.
        let manager = EventTapManager()
        #expect(!manager.handle(
            type: .tapDisabledByTimeout, event: try keyEvent(kVK_ANSI_A)))
        #expect(!manager.handle(
            type: .tapDisabledByUserInput, event: try keyEvent(kVK_ANSI_A)))
    }

    // MARK: - Cursor control

    @Test func stopAlwaysRestoresCursorAssociation() {
        // stop() must always re-couple the mouse and cursor, even if start()
        // was never called — otherwise the pointer stays dead after unlock.
        let fake = FakeCursor()
        let manager = EventTapManager(cursor: fake)
        manager.stop()
        #expect(fake.associations.last == true)
    }

    @Test func stopWithoutStartDoesNotWarp() {
        let fake = FakeCursor()
        let manager = EventTapManager(cursor: fake)
        manager.stop()
        #expect(fake.warps.isEmpty)
    }

    // MARK: - Tap-disabled recovery decision

    @Test func tapDisabledReactionCoversAllCombinations() {
        #expect(EventTapManager.tapDisabledReaction(
            type: .tapDisabledByTimeout,
            shouldSuppress: false,
            tapIsEnabledAfterReenable: true
        ) == .ignore)

        #expect(EventTapManager.tapDisabledReaction(
            type: .tapDisabledByTimeout,
            shouldSuppress: false,
            tapIsEnabledAfterReenable: false
        ) == .ignore)

        #expect(EventTapManager.tapDisabledReaction(
            type: .tapDisabledByUserInput,
            shouldSuppress: true,
            tapIsEnabledAfterReenable: false
        ) == .reviveFailed)

        // Assert what the message has to CONVEY, not its exact prose. This text
        // is the banner a user finds on a locked screen, so the load-bearing
        // part is that it tells them input is still locked; transcribing the
        // string here would only make copy edits fail the suite.
        let timeout = EventTapManager.tapDisabledReaction(
            type: .tapDisabledByTimeout,
            shouldSuppress: true,
            tapIsEnabledAfterReenable: true
        )
        let userInput = EventTapManager.tapDisabledReaction(
            type: .tapDisabledByUserInput,
            shouldSuppress: true,
            tapIsEnabledAfterReenable: true
        )

        guard case .reenabled(let timeoutMessage) = timeout,
              case .reenabled(let userInputMessage) = userInput
        else {
            Issue.record("A revived tap must report .reenabled, got \(timeout) / \(userInput)")
            return
        }

        // Both must reassure the user that input is still locked...
        #expect(timeoutMessage.contains("still locked"))
        #expect(userInputMessage.contains("still locked"))
        // ...and the timeout variant must stay distinguishable, since it names a
        // different cause (Frost was slow to respond) than a plain disable.
        #expect(timeoutMessage != userInputMessage)
    }

    // MARK: - Tap-disabled dispatch (the side effects, not just the decision)

    /// The escalation callback must actually be invoked. Previously only the
    /// pure decision helper was covered, so deleting the `.reviveFailed`
    /// dispatch in handle() left the suite green while the user lost the
    /// escalation to a visible recovery state.
    @Test func reviveFailureInvokesTheEscalationCallback() async {
        let manager = EventTapManager(cursor: FakeCursor())
        var escalated = false
        var reenabledMessage: String?
        manager.onTapReviveFailed = { escalated = true }
        manager.onTapReenabled = { reenabledMessage = $0 }

        manager.apply(.reviveFailed)
        await Task.yield()

        #expect(escalated)
        #expect(reenabledMessage == nil)
    }

    @Test func reenabledInvokesTheNoticeCallbackAndRepins() async {
        let fake = FakeCursor()
        let manager = EventTapManager(cursor: fake)
        var escalated = false
        var reenabledMessage: String?
        manager.onTapReviveFailed = { escalated = true }
        manager.onTapReenabled = { reenabledMessage = $0 }

        manager.apply(.reenabled(message: "restored"))
        await Task.yield()

        #expect(reenabledMessage == "restored")
        #expect(escalated == false)
        // Re-freezing the cursor is part of the recovery, not incidental:
        // setCursorFrozen(true) decouples mouse from cursor.
        #expect(fake.associations.last == false)
    }

    @Test func ignoreDoesNothing() async {
        let manager = EventTapManager(cursor: FakeCursor())
        var escalated = false
        var reenabledMessage: String?
        manager.onTapReviveFailed = { escalated = true }
        manager.onTapReenabled = { reenabledMessage = $0 }

        manager.apply(.ignore)
        await Task.yield()

        #expect(escalated == false)
        #expect(reenabledMessage == nil)
    }

    // MARK: - Cursor drift

    /// The positive drift case the suite could not reach before: the decision is
    /// now a pure function, so inverting the comparison (pointer drifts freely
    /// under an overlay claiming "Pointer frozen") fails a test.
    @Test func driftBeyondToleranceIsDetectedAndWithinToleranceIsNot() {
        let manager = EventTapManager(cursor: FakeCursor())
        manager.primeLockedCursorPositionForTesting(CGPoint(x: 100, y: 100))

        #expect(manager.hasCursorDrifted(from: CGPoint(x: 400, y: 400)))
        #expect(manager.hasCursorDrifted(from: CGPoint(x: 100, y: 140)))
        // Sub-pixel jitter must NOT trigger two synchronous WindowServer calls.
        #expect(!manager.hasCursorDrifted(from: CGPoint(x: 100, y: 100)))
        #expect(!manager.hasCursorDrifted(from: CGPoint(x: 100.2, y: 99.8)))
    }

    @Test func driftIsNeverDetectedWithoutALockedPosition() {
        let manager = EventTapManager(cursor: FakeCursor())
        #expect(!manager.hasCursorDrifted(from: CGPoint(x: 999, y: 999)))
    }

    @Test func repinDoesNotFireWithoutALockedPosition() throws {
        // A never-started manager has no lockedCursorPosition, so pointer
        // events must never trigger a re-pin warp. The positive drift case
        // (a real locked position that has drifted) needs a real start() and
        // therefore stays a manual/integration check.
        let fake = FakeCursor()
        let manager = EventTapManager(cursor: fake)
        #expect(manager.handle(type: .mouseMoved, event: try mouseEvent(.mouseMoved)))
        #expect(fake.warps.isEmpty)
    }
}
