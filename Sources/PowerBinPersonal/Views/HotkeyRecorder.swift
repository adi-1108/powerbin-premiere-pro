import AppKit
import SwiftUI

/// Click → button enters recording state → next keystroke with modifiers is captured.
/// Emits combo string in PowerBin format ("ctrl+alt+cmd+p").
struct HotkeyRecorder: View {
    @Binding var combo: String
    var allowBareSpecialKeys = false
    var onChange: (String) -> Void = { _ in }

    @State private var recording = false
    @State private var localMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: recording ? "record.circle.fill" : "keyboard")
                        .foregroundStyle(recording ? .red : .secondary)
                    Text(recording ? "Press combo… (Esc to cancel)" : prettyCombo(combo))
                        .monospaced()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(recording ? Color.red : Color.gray.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recording
                                ? "Recording shortcut. Press a key combination, or Escape to cancel."
                                : "Shortcut: \(spokenCombo(combo)). Activate to record a new one.")

            if !combo.isEmpty {
                Button {
                    set("")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear hotkey")
                .accessibilityLabel("Clear shortcut")
            }
        }
        // Without this the local monitor outlives the view. Start recording, close the
        // Preferences window, and the monitor stays installed swallowing every keyDown —
        // the app's own text fields stop accepting input until relaunch.
        .onDisappear { stopRecording() }
    }

    // MARK: - Recording

    private func toggleRecording() {
        if recording { stopRecording(); return }
        startRecording()
    }

    private func startRecording() {
        recording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // swallow so the editor doesn't react
        }
    }

    private func stopRecording() {
        recording = false
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        // Esc → cancel without saving.
        if event.keyCode == 53 { // kVK_Escape
            stopRecording(); return
        }
        guard let captured = Self.comboString(from: event, allowBareSpecialKeys: allowBareSpecialKeys) else { return }
        set(captured)
        stopRecording()
    }

    private func set(_ value: String) {
        combo = value
        onChange(value)
    }

    // MARK: - Format

    /// macOS virtual key codes for F1..F20. Karabiner-Elements remaps mouse
    /// buttons to these — the keyDown event arrives with the same keyCode as
    /// a real F-key press.
    private static let fnKeyCodes: [UInt16: String] = [
        122: "f1",  120: "f2",  99:  "f3",  118: "f4",
        96:  "f5",  97:  "f6",  98:  "f7",  100: "f8",
        101: "f9",  109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15", 106: "f16",
        64:  "f17", 79:  "f18", 80:  "f19", 90:  "f20",
    ]

    private static let keyCodeTokens: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`",
    ]

    static func comboString(from event: NSEvent, allowBareSpecialKeys: Bool = false) -> String? {
        var parts: [String] = []
        let m = event.modifierFlags
        if m.contains(.control) { parts.append("ctrl") }
        if m.contains(.option)  { parts.append("alt") }
        if m.contains(.command) { parts.append("cmd") }
        if m.contains(.shift)   { parts.append("shift") }

        // F-keys first — keyCode is the source of truth.
        if let fname = fnKeyCodes[event.keyCode] {
            parts.append(fname)
            return parts.joined(separator: "+")  // F-keys may stand alone
        }

        // Named special keys by keyCode (avoid Unicode for these).
        switch event.keyCode {
        case 49: parts.append("space");  return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        case 36, 76: parts.append("return"); return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        case 48: parts.append("tab");    return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        case 51: parts.append("delete"); return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        case 123: parts.append("left");  return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        case 124: parts.append("right"); return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        case 125: parts.append("down");  return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        case 126: parts.append("up");    return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        default: break
        }

        if let token = keyCodeTokens[event.keyCode] {
            parts.append(token)
            return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
        }

        // Regular character key.
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let key = chars.first else { return nil }
        let s = String(key)
        // Reject anything still in the Cocoa function-key Unicode range.
        if let scalar = s.unicodeScalars.first,
           (0xF700...0xF8FF).contains(scalar.value) {
            return nil
        }
        parts.append(s)
        return joinedIfValid(parts, allowBare: allowBareSpecialKeys)
    }

    private static func joinedIfValid(_ parts: [String], allowBare: Bool) -> String? {
        guard allowBare || parts.count >= 2 else { return nil }  // require 1 modifier + key
        return parts.joined(separator: "+")
    }

    static func prettyCombo(_ combo: String) -> String {
        if combo.isEmpty { return "(none — click to set)" }
        return combo
            .replacingOccurrences(of: "ctrl",  with: "⌃")
            .replacingOccurrences(of: "alt",   with: "⌥")
            .replacingOccurrences(of: "cmd",   with: "⌘")
            .replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "+", with: " ")
            .uppercased()
    }

    private func prettyCombo(_ combo: String) -> String { Self.prettyCombo(combo) }

    /// VoiceOver reads "⌃⌥⌘P" as punctuation soup. Spell the modifiers out instead.
    static func spokenCombo(_ combo: String) -> String {
        if combo.isEmpty { return "none set" }
        return combo
            .replacingOccurrences(of: "ctrl",  with: "Control")
            .replacingOccurrences(of: "alt",   with: "Option")
            .replacingOccurrences(of: "cmd",   with: "Command")
            .replacingOccurrences(of: "shift", with: "Shift")
            .replacingOccurrences(of: "+", with: " ")
    }

    private func spokenCombo(_ combo: String) -> String { Self.spokenCombo(combo) }
}
