//
//  Shortcut.swift
//  frost
//
//  A persistable keyboard shortcut: a virtual key code plus the subset of
//  modifier flags we care about (⌃⌥⇧⌘). Used in two places that speak different
//  event dialects, so it knows how to match both a CGEvent (inside the event
//  tap, for unlock) and an NSEvent (the global monitor, for lock), and how to
//  render itself for the UI.
//

import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    /// Carbon virtual key code (matches `CGKeyCode` / `NSEvent.keyCode`).
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue`, normalized to the four relevant flags.
    var modifierFlagsRawValue: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifierFlags.intersection(Self.relevantModifiers).rawValue
    }

    /// Decoding must route through the normalizing init: `matches()` compares a
    /// normalized incoming mask against the stored flags, so a persisted value
    /// with an irrelevant bit (hand-edited or stale plist) would never match any
    /// event — fatal when it's the unlock chord. Bare and shift-only values are
    /// rejected for the same reason the recorder refuses them (⇧F as a global
    /// hotkey fires while typing); callers fall back to a safe default on
    /// decode failure.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let rawFlags = try container.decode(UInt.self, forKey: .modifierFlagsRawValue)
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags).intersection(Self.relevantModifiers)
        guard !flags.subtracting(.shift).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .modifierFlagsRawValue,
                in: container,
                debugDescription: "Shortcut requires at least one of ⌃⌥⌘"
            )
        }
        // The key code needs the same treatment as the modifiers, and for the
        // same reason. Frost is non-sandboxed, so any process running as the
        // user can write ~/Library/Preferences/dev.abdeen.frost.plist (and it
        // can simply be corrupt). A stored key code that maps to no physical key
        // decodes happily, renders as "⌃⌥⌘Key 999" on the overlay, and can never
        // match an event — so with auto-lock on, the next launch locks input
        // behind an unpressable chord. Throwing here makes SettingsStore.read
        // return nil and fall back to `.defaultUnlock`.
        guard Self.isResolvableKeyCode(keyCode) else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyCode,
                in: container,
                debugDescription: "Key code \(keyCode) does not map to a key on this layout"
            )
        }
        self.init(keyCode: keyCode, modifierFlags: flags)
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifierFlagsRawValue
    }

    /// Frost's factory unlock chord: ⌃⌥⌘U.
    static let defaultUnlock = Shortcut(
        keyCode: UInt16(kVK_ANSI_U),
        modifierFlags: [.control, .option, .command]
    )

    // MARK: - Matching

    func matches(keyCode otherKeyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        otherKeyCode == keyCode
            && modifiers.intersection(Self.relevantModifiers) == modifierFlags
    }

    /// Match against an `NSEvent` (the lock-hotkey dialect). Kept as part of the
    /// three-dialect matching surface and exercised by `ShortcutTests`.
    func matches(nsEvent event: NSEvent) -> Bool {
        matches(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    /// Match against a tap callback's CGEvent (CGEventFlags → ModifierFlags).
    func matches(cgEvent event: CGEvent) -> Bool {
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var mods: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { mods.insert(.command) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskControl) { mods.insert(.control) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        return matches(keyCode: code, modifiers: mods)
    }

    // MARK: - Display

    /// Human-readable form, e.g. "⌃⌥⌘U". Modifiers in canonical macOS order.
    var displayString: String {
        var out = ""
        if modifierFlags.contains(.control) { out += "⌃" }
        if modifierFlags.contains(.option) { out += "⌥" }
        if modifierFlags.contains(.shift) { out += "⇧" }
        if modifierFlags.contains(.command) { out += "⌘" }
        out += Self.keyName(for: keyCode)
        return out
    }

    /// VoiceOver-friendly spelling, e.g. "Control Option Command U". The glyph
    /// `displayString` is announced poorly by VoiceOver, so accessibility labels
    /// should use this spoken form instead.
    var spokenString: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("Control") }
        if modifierFlags.contains(.option) { parts.append("Option") }
        if modifierFlags.contains(.shift) { parts.append("Shift") }
        if modifierFlags.contains(.command) { parts.append("Command") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined(separator: " ")
    }

    /// True when the key code names a key Frost can render and match: either a
    /// known special key, or one that produces a character on the current
    /// layout. Internal so the decode guard is directly testable.
    static func isResolvableKeyCode(_ keyCode: UInt16) -> Bool {
        if specialKeyNames[Int(keyCode)] != nil { return true }
        if let character = character(forKeyCode: keyCode), !character.isEmpty { return true }
        return false
    }

    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        if let character = character(forKeyCode: keyCode), !character.isEmpty {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// Glyphs for keys that have no printable character.
    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_ANSI_KeypadEnter: "⌅",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The character a key produces under the current keyboard layout (no
    /// modifiers applied), so the recorder shows "U" / "É" / "ñ" correctly.
    private static func character(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = unsafeBitCast(layoutPointer, to: CFData.self) as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        // UCKeyTranslate's length params are `UniCharCount` (C `unsigned long`),
        // which Swift surfaces as `UInt` — the name `UniCharCount` isn't bridged.
        var actualLength: UInt = 0

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                Int(UInt(chars.count)),
                &actualLength,
                &chars
            )
        }

        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: Int(actualLength))
    }
}
