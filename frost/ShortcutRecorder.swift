//
//  ShortcutRecorder.swift
//  frost
//
//  A small click-to-record keyboard-shortcut field. SwiftUI has no native
//  recorder, so this wraps a focus-capturing NSView: click it, press a combo,
//  and it reports the captured Shortcut. Every Frost shortcut needs at least
//  one of ⌃⌥⌘ — a bare or shift-only key is rejected, because ⇧F as a global
//  lock hotkey would fire while typing a capital F anywhere. Esc cancels
//  recording and Delete clears (when clearing is allowed).
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    /// When false (the required unlock field) Delete won't clear the value.
    var allowsClear: Bool
    /// Distinct VoiceOver label per recorder — a form with two fields that both
    /// announce "Keyboard shortcut" is un-navigable by ear.
    var accessibilityLabel = "Keyboard shortcut"

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.allowsClear = allowsClear
        field.accessibilityLabelText = accessibilityLabel
        field.shortcut = shortcut
        field.onChange = { context.coordinator.commit($0) }
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        context.coordinator.binding = $shortcut
        field.allowsClear = allowsClear
        field.accessibilityLabelText = accessibilityLabel
        // Don't stomp on the value the user is mid-recording.
        if !field.isRecording { field.shortcut = shortcut }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $shortcut) }

    final class Coordinator {
        var binding: Binding<Shortcut?>
        init(binding: Binding<Shortcut?>) { self.binding = binding }
        func commit(_ shortcut: Shortcut?) { binding.wrappedValue = shortcut }
    }
}

/// The focus-capturing control behind ShortcutRecorder.
final class RecorderField: NSView {
    var allowsClear = false
    var accessibilityLabelText = "Keyboard shortcut"
    var onChange: ((Shortcut?) -> Void)?

    var shortcut: Shortcut? {
        didSet { refresh() }
    }
    private(set) var isRecording = false {
        didSet { refresh() }
    }
    /// Set when a keypress was refused, so the field can SAY why instead of only
    /// beeping. A beep is no feedback at all on a muted Mac, and the rule
    /// (at least one of ⌃⌥⌘) appears nowhere else in the UI, so a user trying
    /// ⇧F, then F5, then K gets three silences and concludes the field is broken.
    private var rejectionNotice: String?
    private var rejectionResetWorkItem: DispatchWorkItem?

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        focusRingType = .exterior

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    // The view joins the key-view loop, so Tab lands on it with Full Keyboard
    // Access on — but recording could only be started by a click, so a keyboard
    // user could reach the field and had no way to use it. Draw a focus ring so
    // focus is visible, and let Space/Return start recording the way any other
    // AppKit control responds to activation.
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    // VoiceOver: present as a button whose value is the spoken shortcut, since the
    // glyph label ("⌃⌥⌘U") is announced poorly.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityLabelText }
    override func accessibilityValue() -> Any? {
        if isRecording { return "Recording. Type a shortcut." }
        return shortcut?.spokenString ?? "Not set"
    }
    override func accessibilityHelp() -> String? {
        allowsClear
            ? "Press to record a shortcut. While recording, press Delete to clear or Escape to cancel."
            : "Press to record a shortcut. While recording, press Escape to cancel."
    }
    override func accessibilityPerformPress() -> Bool {
        if isRecording { stopRecording() } else { startRecording() }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { isRecording = false }
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    private static let activationKeyCodes: Set<Int> = [
        kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter,
    ]

    /// Start recording. Shared by click, VoiceOver press, and keyboard
    /// activation so all three routes behave identically.
    private func startRecording() {
        window?.makeFirstResponder(self)
        clearRejectionNotice()
        isRecording = true
    }

    /// Say why a keypress was refused, instead of only beeping. Reverts to the
    /// normal recording prompt after a beat so the field doesn't get stuck
    /// showing an error.
    private func rejectShortcut() {
        NSSound.beep()
        rejectionResetWorkItem?.cancel()
        rejectionNotice = "Add ⌃, ⌥, or ⌘"
        refresh()

        let reset = DispatchWorkItem { [weak self] in
            guard let self, self.rejectionNotice != nil else { return }
            self.rejectionNotice = nil
            self.refresh()
        }
        rejectionResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    }

    private func clearRejectionNotice() {
        rejectionResetWorkItem?.cancel()
        rejectionResetWorkItem = nil
        rejectionNotice = nil
    }

    // ⌘-based combos arrive as key equivalents; intercept them while recording
    // so the menu doesn't eat them first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // Not recording: Space/Return activate the field, matching how every
            // other AppKit control responds to keyboard activation. Without this
            // a Tab-focused field beeps and can never be used without a mouse.
            // (Written as an `if`, not a multi-pattern `case ... where bare`: in
            // Swift a where clause binds only to the pattern it follows, so the
            // switch form would have activated on ⌘Space too.)
            let bare = event.modifierFlags.intersection(Shortcut.relevantModifiers).isEmpty
            if bare, Self.activationKeyCodes.contains(Int(event.keyCode)) {
                startRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        _ = capture(event)
    }

    /// Returns true if the event was consumed.
    private func capture(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let unmodified = modifiers.isEmpty

        // Bare Esc cancels; bare Delete clears (when allowed). With modifiers,
        // these are normal keys and fall through to be recorded as a shortcut.
        if unmodified {
            switch Int(event.keyCode) {
            case kVK_Escape:
                stopRecording()
                return true
            case kVK_Delete, kVK_ForwardDelete:
                if allowsClear {
                    shortcut = nil
                    onChange?(nil)
                }
                stopRecording()
                return true
            default:
                // No modifier and not a control key — keep waiting for a combo.
                rejectShortcut()
                return true
            }
        }

        // Shift alone can't anchor a system-wide hotkey — it fires during
        // ordinary typing. Keep waiting for a combo with at least one of ⌃⌥⌘.
        guard !modifiers.subtracting(.shift).isEmpty else {
            rejectShortcut()
            return true
        }

        let captured = Shortcut(keyCode: event.keyCode, modifierFlags: modifiers)
        shortcut = captured
        onChange?(captured)
        stopRecording()
        return true
    }

    private func stopRecording() {
        clearRejectionNotice()
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    private func refresh() {
        label.stringValue = displayText
        if rejectionNotice != nil {
            label.textColor = .systemRed
        } else {
            label.textColor = (shortcut == nil && !isRecording) ? .secondaryLabelColor : .labelColor
        }
        let border: NSColor
        if rejectionNotice != nil {
            border = .systemRed
        } else if isRecording {
            border = .controlAccentColor
        } else {
            border = .separatorColor
        }
        layer?.borderColor = border.cgColor
    }

    private var displayText: String {
        if let rejectionNotice { return rejectionNotice }
        if isRecording { return "Type shortcut…" }
        if let shortcut { return shortcut.displayString }
        return allowsClear ? "Click to record" : "Click to set"
    }
}
