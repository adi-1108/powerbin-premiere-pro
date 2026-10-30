import AppKit
import ApplicationServices
import Carbon

final class HotkeyService {
    private let handler: () -> Void
    private var activeHotkey: RegisteredHotkey?

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    deinit {
        activeHotkey?.unregister()
    }

    /// `combo` format: "ctrl+alt+cmd+p" or "f13".
    /// Returns true on successful registration.
    @discardableResult
    func apply(_ combo: String) -> Bool {
        activeHotkey?.unregister()
        activeHotkey = nil

        guard let parsed = Self.parse(combo) else {
            Log.line(" hotkey parse failed: \(combo)")
            return false
        }

        let hotkey = RegisteredHotkey(parsed: parsed, handler: handler)
        let registered = hotkey.register()
        activeHotkey = hotkey
        Log.line(" hotkey registered=\(registered) combo=\(combo) keyCode=\(parsed.keyCode) modifiers=\(parsed.modifiers) standaloneFn=\(parsed.isStandaloneFunctionKey)")
        return registered
    }

    static func parse(_ combo: String) -> ParsedHotkey? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers: UInt32 = 0
        var keyToken: String?

        for token in parts {
            switch token {
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "alt", "opt", "option": modifiers |= UInt32(optionKey)
            case "cmd", "command", "meta": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: keyToken = token
            }
        }

        guard let token = keyToken, let key = keyCode(for: token) else { return nil }
        return ParsedHotkey(keyCode: key.code, modifiers: modifiers, keyName: key.name)
    }

    private static func keyCode(for token: String) -> (code: UInt32, name: String?)? {
        let normalized = token.lowercased()
        if let code = keyCodes[normalized] {
            return (code, functionKeyNames[code] ?? keyDisplayNames[code])
        }
        return nil
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
        "tab": UInt32(kVK_Tab), "space": UInt32(kVK_Space),
        "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
        "delete": UInt32(kVK_Delete),
        "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow),
        "down": UInt32(kVK_DownArrow), "up": UInt32(kVK_UpArrow),
        "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3),
        "f4": UInt32(kVK_F4), "f5": UInt32(kVK_F5), "f6": UInt32(kVK_F6),
        "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8), "f9": UInt32(kVK_F9),
        "f10": UInt32(kVK_F10), "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12),
        "f13": UInt32(kVK_F13), "f14": UInt32(kVK_F14), "f15": UInt32(kVK_F15),
        "f16": UInt32(kVK_F16), "f17": UInt32(kVK_F17), "f18": UInt32(kVK_F18),
        "f19": UInt32(kVK_F19), "f20": UInt32(kVK_F20),
    ]

    private static let keyDisplayNames: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]

    private static let functionKeyNames: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]
}

struct ParsedHotkey {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String?

    var isStandaloneFunctionKey: Bool {
        modifiers == 0 && HotkeyService.isFunctionKey(keyCode)
    }
}

private final class RegisteredHotkey {
    private let parsed: ParsedHotkey
    private let handler: () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var lastTriggerUptime: TimeInterval = 0
    private let hotKeyID = EventHotKeyID(signature: fourCharacterCode("PWRB"), id: 1)

    init(parsed: ParsedHotkey, handler: @escaping () -> Void) {
        self.parsed = parsed
        self.handler = handler
    }

    deinit {
        unregister()
    }

    @discardableResult
    func register() -> Bool {
        installEventMonitors()
        installEventTapIfNeeded()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let hotkey = Unmanaged<RegisteredHotkey>.fromOpaque(userData).takeUnretainedValue()

                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )

                guard status == noErr, pressedID.id == hotkey.hotKeyID.id else {
                    return noErr
                }

                DispatchQueue.main.async {
                    hotkey.performHandlerIfNeeded()
                }

                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )

        if handlerStatus != noErr {
            Log.line(" hotkey handler install failed: \(handlerStatus)")
        }

        let registerStatus = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            Log.line(" hotkey carbon registration failed: \(registerStatus)")
        }

        return registerStatus == noErr || parsed.isStandaloneFunctionKey
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
    }

    private func installEventMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.matches(event) else { return event }

            DispatchQueue.main.async {
                self.performHandlerIfNeeded()
            }

            return nil
        }

        guard parsed.isStandaloneFunctionKey else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.matches(event) else { return }

            DispatchQueue.main.async {
                self.performHandlerIfNeeded()
            }
        }
    }

    private func installEventTapIfNeeded() {
        guard parsed.isStandaloneFunctionKey else { return }

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let hotkey = Unmanaged<RegisteredHotkey>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let eventTap = hotkey.eventTap {
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown, hotkey.matches(event) else {
                    return Unmanaged.passUnretained(event)
                }

                DispatchQueue.main.async {
                    hotkey.performHandlerIfNeeded()
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            Log.line(" hotkey event tap unavailable; Carbon/global monitors still active")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let eventTapRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == parsed.keyCode && carbonModifiers(from: event.modifierFlags) == parsed.modifiers
    }

    private func matches(_ event: CGEvent) -> Bool {
        let eventKeyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        return eventKeyCode == parsed.keyCode && carbonModifiers(from: event.flags) == parsed.modifiers
    }

    private func performHandlerIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerUptime > 0.12 else { return }
        lastTriggerUptime = now
        handler()
    }
}

extension HotkeyService {
    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeyCodeSet.contains(keyCode)
    }

    private static let functionKeyCodeSet: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]
}

private func fourCharacterCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}

private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0

    if flags.contains(.command) {
        modifiers |= UInt32(cmdKey)
    }

    if flags.contains(.control) {
        modifiers |= UInt32(controlKey)
    }

    if flags.contains(.option) {
        modifiers |= UInt32(optionKey)
    }

    if flags.contains(.shift) {
        modifiers |= UInt32(shiftKey)
    }

    return modifiers
}

private func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
    var modifiers: UInt32 = 0

    if flags.contains(.maskCommand) {
        modifiers |= UInt32(cmdKey)
    }

    if flags.contains(.maskControl) {
        modifiers |= UInt32(controlKey)
    }

    if flags.contains(.maskAlternate) {
        modifiers |= UInt32(optionKey)
    }

    if flags.contains(.maskShift) {
        modifiers |= UInt32(shiftKey)
    }

    return modifiers
}
