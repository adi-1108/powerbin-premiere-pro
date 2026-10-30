import AppKit
import ApplicationServices
import IOKit.hid

/// Wraps the two macOS permissions PowerBin actually needs:
///   - Accessibility            : required for CGEvent keystroke injection (auto-paste)
///   - Input Monitoring         : required for NSEvent global key listeners / IOHID
///
/// There used to be a third, Automation (Premiere Pro), on the theory that bringing
/// Premiere forward needed an Apple Event. It doesn't — PasteDriver uses
/// `NSRunningApplication.activate`, which needs no TCC grant, and the app sends no Apple
/// Events at all. So the row asked customers for a permission the app never uses, and
/// because Automation status cannot be queried without firing an event, its badge sat on a
/// permanent orange "?" that no amount of granting would clear.
enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring

    var id: String { rawValue }
    var label: String {
        switch self {
        case .accessibility:    return "Accessibility"
        case .inputMonitoring:  return "Input Monitoring"
        }
    }
    var reason: String {
        switch self {
        case .accessibility:
            return "Needed to send ⌘V into Premiere Pro after loading a preset."
        case .inputMonitoring:
            return "Needed to listen for the global toggle hotkey."
        }
    }
    var settingsURL: URL {
        let s: String
        switch self {
        case .accessibility:    s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:  s = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }
        return URL(string: s)!
    }
}

enum PermissionStatus { case granted, denied, unknown }

enum PermissionsService {
    // MARK: - Status

    /// Input Monitoring, once seen as granted, is remembered for the rest of the session.
    ///
    /// The only reliable probe is "can I actually create a keyboard event tap?", and that
    /// allocates a real Mach port every time it is asked. `PermissionsView` polls all
    /// permissions on a 1-second timer while the onboarding window is open, so this was
    /// creating and tearing down an event tap once a second for as long as the window
    /// stayed up. Grants effectively never go backwards inside one launch, and the app
    /// stops working anyway if the OS revokes the tap.
    private static var inputMonitoringGranted = false

    static func status(_ k: PermissionKind) -> PermissionStatus {
        switch k {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            if inputMonitoringGranted { return .granted }
            if canCreateKeyboardListenEventTap() {
                inputMonitoringGranted = true
                return .granted
            }
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted:
                inputMonitoringGranted = true
                return .granted
            // `kIOHIDAccessTypeDenied` means the user actually said no — show it as denied
            // so the row goes red and offers a Grant button, and so `anyMissing()` counts
            // it. It used to be folded into `.unknown`, which left a permanently orange "?"
            // that nothing could clear and hid a genuinely missing permission from
            // onboarding. `kIOHIDAccessTypeUnknown` (not yet asked) stays unknown.
            case kIOHIDAccessTypeDenied:  return .denied
            default:                       return .unknown
            }
        }
    }

    // MARK: - Request (prompts the OS dialog)

    /// Triggers the system prompt for the given permission, if possible.
    static func request(_ k: PermissionKind) {
        switch k {
        case .accessibility:
            // Prompts on first call; subsequent calls just return current state.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    static func openSettings(_ k: PermissionKind) {
        NSWorkspace.shared.open(k.settingsURL)
    }

    static func anyMissing() -> [PermissionKind] {
        PermissionKind.allCases.filter { status($0) == .denied }
    }

    private static func canCreateKeyboardListenEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in
                Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            return false
        }

        CFMachPortInvalidate(tap)
        return true
    }
}
