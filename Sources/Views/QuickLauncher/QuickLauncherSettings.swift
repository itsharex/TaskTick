import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// User-facing config for the quick launcher. Stored in UserDefaults and
/// observed via Combine so the Settings UI reacts to recorder updates without
/// SwiftData involvement.
@MainActor
final class QuickLauncherSettings: ObservableObject {

    static let shared = QuickLauncherSettings()

    private let enabledKey = "quickLauncher.enabled"
    private let keyCodeKey = "quickLauncher.keyCode"
    private let modifiersKey = "quickLauncher.modifiers"

    /// Default binding: ⌘⌥T. Picked because the T-for-TaskTick mnemonic is
    /// memorable and this combo is rarely claimed by other apps.
    private let defaultKeyCode = kVK_ANSI_T
    private let defaultModifiers: NSEvent.ModifierFlags = [.command, .option]

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            applyToHotkey()
        }
    }

    @Published var keyCode: Int {
        didSet {
            UserDefaults.standard.set(keyCode, forKey: keyCodeKey)
            applyToHotkey()
        }
    }

    @Published var modifiers: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(Int(modifiers.rawValue), forKey: modifiersKey)
            applyToHotkey()
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        self.isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        self.keyCode = defaults.object(forKey: keyCodeKey) as? Int ?? defaultKeyCode
        let rawMods = defaults.object(forKey: modifiersKey) as? Int ?? Int(defaultModifiers.rawValue)
        self.modifiers = NSEvent.ModifierFlags(rawValue: UInt(rawMods))
    }

    /// Re-register the global hotkey based on current state. Called both on
    /// settings change (didSet) and once at app launch from `applyOnLaunch()`.
    func applyToHotkey() {
        if isEnabled {
            GlobalHotkey.shared.register(keyCode: keyCode, modifiers: modifiers) {
                Task { @MainActor in
                    QuickLauncherController.shared.toggle()
                }
            }
        } else {
            GlobalHotkey.shared.register(keyCode: nil, modifiers: []) {}
        }
    }

    /// Human-readable representation: ⌘⌥T, ⇧⌘Space, etc. Empty string when
    /// no key is bound.
    var displayString: String {
        HotkeyFormatter.format(keyCode: keyCode, modifiers: modifiers)
    }

    /// Per-glyph chips for kbd-style rendering (one chip per modifier + key).
    var displayChips: [String] {
        HotkeyFormatter.chips(keyCode: keyCode, modifiers: modifiers)
    }
}

/// Translates `(keyCode, modifiers)` into the conventional macOS glyph string.
/// Source of truth for both the Settings recorder display and any future menu
/// bar shortcut hint.
enum HotkeyFormatter {
    static func format(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
        chips(keyCode: keyCode, modifiers: modifiers).joined()
    }

    /// Same shortcut, but split per glyph so callers can render each modifier
    /// in its own kbd-style pill (1Password / Raycast convention).
    static func chips(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts
    }

    private static func keyName(for keyCode: Int) -> String {
        // Cover the common keys; rarely-used codes fall through to "?". The
        // recorder limits user input to printable keys plus a few function
        // keys, so the table is small on purpose.
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↵"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "esc"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "?"
        }
    }
}
