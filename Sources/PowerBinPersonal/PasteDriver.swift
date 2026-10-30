import AppKit
import Carbon.HIToolbox

/// Activates Premiere Pro and injects a paste keystroke after a preset is loaded.
/// Used when `AppSettings.autoPasteAfterLoad` is on.
enum PasteDriver {
    private static let focusPollInterval: TimeInterval = 0.025
    private static let frontmostSettleDelay: TimeInterval = 0.04
    private static let clipboardSettleDelay: TimeInterval = 0.06
    private static let preReturnClipboardSettleDelay: TimeInterval = 0.04
    private static let excaliburDownDelay: TimeInterval = 0.32
    private static let excaliburReturnDelay: TimeInterval = 0.05
    private static let modifierStepDelay: TimeInterval = 0.003
    private static let keyHoldDelay: TimeInterval = 0.008

    static func run(settings: AppSettings,
                    pasteMode: PasteMode? = nil,
                    beforeInjection: (() -> Bool)? = nil,
                    beforeExcaliburReturn: (() -> Bool)? = nil) {
        let mode = pasteMode ?? currentPasteMode(fallback: settings.pasteMode)
        let combo = combo(for: mode, settings: settings)
        guard !combo.isEmpty else {
            Log.line(" paste failed — empty combo for mode=\(mode.rawValue)")
            return
        }
        guard PermissionsService.status(.accessibility) == .granted else {
            Log.line(" paste blocked — Accessibility permission is not granted for PowerBin")
            return
        }
        guard let app = premiereApplication(bundleID: settings.premiereBundleID) else {
            Log.line(" paste failed — Premiere not running for bundleID=\(settings.premiereBundleID)")
            return
        }

        Log.line(" paste requested — mode=\(mode.rawValue) combo=\(combo)")
        if !isPremiereFrontmost(app: app) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        waitForPremiereFocus(app: app, attemptsRemaining: 16) {
            let inject = {
                switch mode {
                case .excalibur:
                    injectExcaliburSequence(combo: combo, beforeReturn: beforeExcaliburReturn)
                default:
                    injectKeystroke(combo)
                }
            }

            if let beforeInjection {
                guard beforeInjection() else {
                    Log.line(" paste aborted — before-injection step failed")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardSettleDelay) {
                    inject()
                }
            } else {
                inject()
            }
        }
    }

    @discardableResult
    static func activatePremiere(bundleID: String) -> Bool {
        guard let app = premiereApplication(bundleID: bundleID) else { return false }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    /// Adobe bumps the bundle id every major release (`com.adobe.PremierePro.24` ->
    /// `.25` -> `.26`), so a configured id goes stale the moment the user updates
    /// Premiere. Match the versionless prefix instead, and only fall back to the app
    /// name when that finds nothing.
    static func premiereApplication(bundleID: String) -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }

        // `.regular` only. XPC services inherit their host's name — with Premiere open,
        // "Open and Save Panel Service (Adobe Premiere Pro 2025)" and an AutoFill helper
        // both match a bare `contains("premiere")` scan, and `runningApplications` is in
        // no documented order, so a name-first search can return a helper and paste into
        // a save dialog.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        if let app = apps.first(where: {
            ($0.bundleIdentifier ?? "").lowercased().hasPrefix(premiereBundleIDPrefix)
        }) {
            return app
        }

        // "premiere pro", not "premiere" — Premiere Rush is a different app that would
        // otherwise match here.
        return apps.first(where: {
            ($0.localizedName ?? "").lowercased().contains("premiere pro")
        })
    }

    static let premiereBundleIDPrefix = "com.adobe.premierepro"

    private static func waitForPremiereFocus(app: NSRunningApplication,
                                             attemptsRemaining: Int,
                                             completion: @escaping () -> Void) {
        if isPremiereFrontmost(app: app) || attemptsRemaining <= 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + frontmostSettleDelay) {
                completion()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + focusPollInterval) {
            waitForPremiereFocus(app: app, attemptsRemaining: attemptsRemaining - 1, completion: completion)
        }
    }

    private static func isPremiereFrontmost(app: NSRunningApplication) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return frontmost?.processIdentifier == app.processIdentifier
            || (frontmost?.bundleIdentifier ?? "").lowercased().hasPrefix(premiereBundleIDPrefix)
    }

    private static func combo(for mode: PasteMode, settings: AppSettings) -> String {
        switch mode {
        case .native:
            return "cmd+v"
        case .excalibur:
            let stored = UserDefaults.standard.string(forKey: "excaliburHotkey") ?? settings.excaliburHotkey
            let combo = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return combo.isEmpty ? "alt+cmd+shift+;" : combo
        case .custom:
            let stored = UserDefaults.standard.string(forKey: "customPasteHotkey") ?? settings.customPasteHotkey
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func currentPasteMode(fallback: PasteMode) -> PasteMode {
        guard let raw = UserDefaults.standard.string(forKey: "pasteMode") else { return fallback }
        return PasteMode(rawValue: raw) ?? fallback
    }

    // MARK: - Keystroke injection via CGEvent

    private static func injectExcaliburSequence(combo: String, beforeReturn: (() -> Bool)? = nil) {
        Log.line(" paste excalibur sequence — hotkey=\(combo) then down then return")
        injectKeystroke(combo)
        DispatchQueue.main.asyncAfter(deadline: .now() + excaliburDownDelay) {
            injectKeystroke("down")
            DispatchQueue.main.asyncAfter(deadline: .now() + excaliburReturnDelay) {
                if let beforeReturn {
                    guard beforeReturn() else {
                        Log.line(" paste aborted — before-return clipboard restore failed")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + preReturnClipboardSettleDelay) {
                        injectKeystroke("return")
                    }
                    return
                }
                injectKeystroke("return")
            }
        }
    }

    static func injectKeystroke(_ combo: String) {
        guard let parsed = parseCombo(combo) else {
            Log.line(" paste failed — could not parse combo=\(combo)")
            return
        }
        Log.line(" paste inject — combo=\(combo) keyCode=\(parsed.keyCode) flags=\(parsed.flags.rawValue)")
        postKeystroke(keyCode: parsed.keyCode, flags: parsed.flags)
    }

    static func parseCombo(_ combo: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var keyToken: String?
        for token in parts {
            switch token {
            case "ctrl", "control":   flags.insert(.maskControl)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "cmd", "command":    flags.insert(.maskCommand)
            case "shift":             flags.insert(.maskShift)
            default: keyToken = token
            }
        }
        guard let kt = keyToken, let code = virtualKey(for: kt) else { return nil }
        return (code, flags)
    }

    private struct ModifierKey {
        let keyCode: CGKeyCode
        let flag: CGEventFlags
    }

    /// Serial, so the down/up pairs of one combo stay ordered and consecutive combos in the
    /// Excalibur sequence can't interleave.
    private static let injectionQueue = DispatchQueue(
        label: "com.adityavishwakarma.powerbin.keystroke",
        qos: .userInitiated
    )

    private static func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        // A combo spends ~35ms in `Thread.sleep` spacing the modifier and key events out
        // far enough for Premiere to see them. That used to run on the main thread — a
        // stall right at the moment the panel is animating away. The gaps between the
        // Excalibur steps are 50–320ms, so a serial queue keeps the ordering intact.
        injectionQueue.async {
            let src = CGEventSource(stateID: .hidSystemState)
            let modifiers = modifierKeys(for: flags)
            var activeFlags: CGEventFlags = []

            for modifier in modifiers {
                activeFlags.insert(modifier.flag)
                postKey(modifier.keyCode, keyDown: true, flags: activeFlags, source: src)
                Thread.sleep(forTimeInterval: modifierStepDelay)
            }

            postKey(keyCode, keyDown: true, flags: flags, source: src)
            Thread.sleep(forTimeInterval: keyHoldDelay)
            postKey(keyCode, keyDown: false, flags: flags, source: src)
            Thread.sleep(forTimeInterval: modifierStepDelay)

            for modifier in modifiers.reversed() {
                activeFlags.remove(modifier.flag)
                postKey(modifier.keyCode, keyDown: false, flags: activeFlags, source: src)
                Thread.sleep(forTimeInterval: modifierStepDelay)
            }
        }
    }

    private static func postKey(_ keyCode: CGKeyCode,
                                keyDown: Bool,
                                flags: CGEventFlags,
                                source: CGEventSource?) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private static func modifierKeys(for flags: CGEventFlags) -> [ModifierKey] {
        var modifiers: [ModifierKey] = []
        if flags.contains(.maskControl) {
            modifiers.append(ModifierKey(keyCode: CGKeyCode(kVK_Control), flag: .maskControl))
        }
        if flags.contains(.maskAlternate) {
            modifiers.append(ModifierKey(keyCode: CGKeyCode(kVK_Option), flag: .maskAlternate))
        }
        if flags.contains(.maskShift) {
            modifiers.append(ModifierKey(keyCode: CGKeyCode(kVK_Shift), flag: .maskShift))
        }
        if flags.contains(.maskCommand) {
            modifiers.append(ModifierKey(keyCode: CGKeyCode(kVK_Command), flag: .maskCommand))
        }
        return modifiers
    }

    /// Keys emitted by HotkeyRecorder. Keep this in sync with recorder output.
    private static func virtualKey(for token: String) -> CGKeyCode? {
        let normalized = normalizeKeyToken(token)
        let map: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
            "9": kVK_ANSI_9, "0": kVK_ANSI_0,
            "=": kVK_ANSI_Equal, "-": kVK_ANSI_Minus, "]": kVK_ANSI_RightBracket,
            "[": kVK_ANSI_LeftBracket, "'": kVK_ANSI_Quote, ";": kVK_ANSI_Semicolon,
            "\\": kVK_ANSI_Backslash, ",": kVK_ANSI_Comma, "/": kVK_ANSI_Slash,
            ".": kVK_ANSI_Period, "`": kVK_ANSI_Grave,
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
            "tab": kVK_Tab, "delete": kVK_Delete, "escape": kVK_Escape, "esc": kVK_Escape,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "down": kVK_DownArrow, "up": kVK_UpArrow,
            "arrowleft": kVK_LeftArrow, "arrowright": kVK_RightArrow,
            "arrowdown": kVK_DownArrow, "arrowup": kVK_UpArrow,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
            "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16,
            "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        ]
        return map[normalized].map { CGKeyCode($0) }
    }

    private static func normalizeKeyToken(_ token: String) -> String {
        switch token {
        case ":": return ";"
        case "\"": return "'"
        case "?": return "/"
        case "<": return ","
        case ">": return "."
        case "_": return "-"
        case "+": return "="
        case "{": return "["
        case "}": return "]"
        case "|": return "\\"
        case "~": return "`"
        case "!": return "1"
        case "@": return "2"
        case "#": return "3"
        case "$": return "4"
        case "%": return "5"
        case "^": return "6"
        case "&": return "7"
        case "*": return "8"
        case "(": return "9"
        case ")": return "0"
        default: return token
        }
    }
}
