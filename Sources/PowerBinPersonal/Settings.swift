import AppKit
import ServiceManagement
import SwiftUI

enum PasteMode: String, CaseIterable, Identifiable {
    case native       // ⌘V after activating Premiere
    case excalibur    // sends Excalibur paste-to-top-layer shortcut
    case custom       // user-recorded combo

    var id: String { rawValue }
    var label: String {
        switch self {
        case .native: return "Native ⌘V"
        case .excalibur: return "Excalibur (paste to top layer)"
        case .custom: return "Custom hotkey"
        }
    }
}

/// Every user-facing preference, and the side effects each one has to trigger.
///
/// These were `@AppStorage` properties. `@AppStorage` is a `DynamicProperty` built for use
/// *in a View*: inside an `ObservableObject` its setter writes to UserDefaults but never
/// fires `objectWillChange`, so no observing view redraws. In practice that meant the
/// Preferences controls did not reliably reflect their own value — flipping "Paste mode"
/// to Excalibur would not reveal the Excalibur shortcut row underneath it, and toggles
/// appeared not to take.
///
/// `@Published` + explicit UserDefaults writes fixes that and gives each setting a place to
/// apply its side effect (Dock policy, login item, hotkey re-registration) the moment it
/// changes, instead of at the next launch. The UserDefaults keys are unchanged, so an
/// existing install keeps its settings — `PasteDriver` also reads three of them directly.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    /// Guards the `didSet` side effects while `init` is populating the properties.
    private var isLoaded = false

    @Published var toggleHotkey: String {
        didSet { write(toggleHotkey, Keys.toggleHotkey) }
    }
    @Published var adobeOnlySnapshot: Bool {
        didSet { write(adobeOnlySnapshot, Keys.adobeOnlySnapshot) }
    }
    @Published var pasteModeRaw: String {
        didSet { write(pasteModeRaw, Keys.pasteMode) }
    }
    @Published var excaliburHotkey: String {
        didSet { write(excaliburHotkey, Keys.excaliburHotkey) }
    }
    @Published var customPasteHotkey: String {
        didSet { write(customPasteHotkey, Keys.customPasteHotkey) }
    }
    @Published var autoPasteAfterLoad: Bool {
        didSet { write(autoPasteAfterLoad, Keys.autoPasteAfterLoad) }
    }
    /// Empty = auto-detect any running com.adobe.PremierePro.* (see PasteDriver).
    /// Don't default this to a version — Adobe bumps the id each major release, and a
    /// hard-coded one is wrong for every user who isn't on that exact version.
    @Published var premiereBundleID: String {
        didSet { write(premiereBundleID, Keys.premiereBundleID) }
    }
    @Published var premiereOnlyHotkey: Bool {
        didSet { write(premiereOnlyHotkey, Keys.premiereOnlyHotkey) }
    }
    @Published var showInDock: Bool {
        didSet {
            write(showInDock, Keys.showInDock)
            applyActivationPolicy()
        }
    }
    @Published var onboardingComplete: Bool {
        didSet { write(onboardingComplete, Keys.onboardingComplete) }
    }

    /// Set by `AppDelegate.applyHotkey()`. Surfaced in Preferences so a combo that another
    /// app already owns fails visibly instead of leaving the panel unopenable with no
    /// explanation — the failure was previously log-only.
    @Published var hotkeyRegistrationFailed = false

    /// Mirrors the login item. Not stored in UserDefaults: `SMAppService` is the source of
    /// truth, and it can be changed from System Settings behind the app's back.
    @Published var launchAtLogin: Bool {
        didSet {
            guard isLoaded, launchAtLogin != Self.loginItemIsEnabled() else { return }
            applyLaunchAtLogin()
        }
    }

    /// Last error from toggling the login item, for display in Preferences.
    @Published var launchAtLoginError: String?

    static let defaultToggleHotkey = "ctrl+alt+cmd+p"

    private enum Keys {
        static let toggleHotkey = "toggleHotkey"
        static let adobeOnlySnapshot = "adobeOnlySnapshot"
        static let pasteMode = "pasteMode"
        static let excaliburHotkey = "excaliburHotkey"
        static let customPasteHotkey = "customPasteHotkey"
        static let autoPasteAfterLoad = "autoPasteAfterLoad"
        static let premiereBundleID = "premiereBundleID"
        static let premiereOnlyHotkey = "premiereOnlyHotkey"
        static let showInDock = "showInDock"
        static let onboardingComplete = "onboardingComplete"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        toggleHotkey = defaults.string(forKey: Keys.toggleHotkey) ?? Self.defaultToggleHotkey
        adobeOnlySnapshot = defaults.bool(forKey: Keys.adobeOnlySnapshot)
        pasteModeRaw = defaults.string(forKey: Keys.pasteMode) ?? PasteMode.native.rawValue
        excaliburHotkey = defaults.string(forKey: Keys.excaliburHotkey) ?? "alt+cmd+shift+;"
        customPasteHotkey = defaults.string(forKey: Keys.customPasteHotkey) ?? "cmd+shift+v"
        autoPasteAfterLoad = defaults.bool(forKey: Keys.autoPasteAfterLoad)
        premiereBundleID = defaults.string(forKey: Keys.premiereBundleID) ?? ""
        // `bool(forKey:)` returns false for a missing key, but this one defaults to ON.
        premiereOnlyHotkey = defaults.object(forKey: Keys.premiereOnlyHotkey) as? Bool ?? true
        showInDock = defaults.bool(forKey: Keys.showInDock)
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        launchAtLogin = Self.loginItemIsEnabled()

        isLoaded = true
    }

    var pasteMode: PasteMode {
        get { PasteMode(rawValue: pasteModeRaw) ?? .native }
        set { pasteModeRaw = newValue.rawValue }
    }

    private func write(_ value: Any, _ key: String) {
        guard isLoaded else { return }
        defaults.set(value, forKey: key)
    }

    // MARK: - Side effects

    /// `.regular` = Dock + menu bar. `.accessory` = menu bar only (Raycast style).
    ///
    /// Applied live. This used to say "Restart app to apply" in a tooltip, which is both a
    /// worse experience and easy to miss — the policy can be swapped at runtime.
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    private static func loginItemIsEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
            Log.line(" launch at login = \(launchAtLogin)")
        } catch {
            // Most common cause: the app is being run from somewhere macOS won't register,
            // e.g. straight out of the DMG or a Downloads folder quarantine.
            launchAtLoginError = "Move PowerBin to your Applications folder, then try again."
            launchAtLogin = Self.loginItemIsEnabled()
            Log.line(" launch at login failed — \(error)")
        }
    }

    /// Re-reads the login item from the system. System Settings can change it behind us.
    func refreshLaunchAtLogin() {
        let enabled = Self.loginItemIsEnabled()
        if launchAtLogin != enabled {
            isLoaded = false
            launchAtLogin = enabled
            isLoaded = true
        }
    }
}

/// Standalone preferences window controller — separate from the floating panel.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController(rootView: SettingsView(), title: "PowerBin Preferences",
                                                 size: NSSize(width: 500, height: 560))

    private static let frameName = "PowerBinPreferences"
    private var hasShownOnce = false

    init<Content: View>(rootView: Content, title: String, size: NSSize) {
        let host = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.setContentSize(size)
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        // Remember where the user put it instead of re-centering on every open, which is
        // what `center()`-on-every-show used to do.
        _ = window.setFrameAutosaveName(Self.frameName)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        AppSettings.shared.refreshLaunchAtLogin()
        NSApp.activate(ignoringOtherApps: true)
        if !hasShownOnce {
            hasShownOnce = true
            if window?.setFrameUsingName(Self.frameName) != true {
                window?.center()
            }
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Permissions onboarding window.
final class PermissionsWindowController: NSWindowController {
    static let shared = PermissionsWindowController()

    init() {
        let host = NSHostingController(rootView: PermissionsView(onDismiss: {
            AppSettings.shared.onboardingComplete = true
            AppDelegate.shared?.applyHotkey()
            PermissionsWindowController.shared.window?.close()
        }))
        let window = NSWindow(contentViewController: host)
        window.title = "PowerBin — Permissions"
        window.setContentSize(NSSize(width: 480, height: 400))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
