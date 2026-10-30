import AppKit
import Combine
import SwiftUI
import Foundation

// MARK: - Logger (writes to ~/Library/Logs/PowerBin.log)
//
// Support asks customers for this file, so it has to survive an unattended editing
// session: bounded on disk, safe to write from several threads, and cheap enough that
// logging a paste doesn't show up as a hitch.
//
// The previous version created an ISO8601DateFormatter and opened/seeked/closed a
// FileHandle on *every* line, from whatever thread happened to call it — main actor,
// detached Keychain task, and the CGEvent tap callback all reach this. Interleaved
// writes and an unbounded file were both live problems.
enum Log {
    /// Rotate at 1 MB, keeping one previous file. A month of heavy use is well under this.
    private static let maxBytes: Int = 1 * 1024 * 1024

    static let url: URL = {
        let d = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("PowerBin.log")
    }()

    private static let rotatedURL = url.appendingPathExtension("1")

    /// Serialises every write. Everything below this line runs on it and nowhere else.
    private static let queue = DispatchQueue(label: "com.adityavishwakarma.powerbin.log")

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var handle: FileHandle?
    private static var bytesWritten: Int = 0

    static func line(_ s: String) {
        let stamped = "[\(formatter.string(from: Date()))] \(s)\n"
        FileHandle.standardError.write(Data(stamped.utf8))
        let payload = Data(stamped.utf8)
        queue.async {
            write(payload)
        }
    }

    /// Queue-confined. Never call from anywhere but `queue`.
    private static func write(_ payload: Data) {
        if handle == nil { open() }
        guard let handle else { return }

        if bytesWritten + payload.count > maxBytes {
            rotate()
            guard let rotated = self.handle else { return }
            rotated.write(payload)
            bytesWritten = payload.count
            return
        }

        handle.write(payload)
        bytesWritten += payload.count
    }

    private static func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // 0600: the log names presets and workspaces, which are client names for a
            // freelance editor. No reason for other accounts on the Mac to read it.
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        bytesWritten = Int((try? h.seekToEnd()) ?? 0)
        handle = h
    }

    private static func rotate() {
        let fm = FileManager.default
        try? handle?.close()
        handle = nil
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: url, to: rotatedURL)
        open()
    }
}

/// Bundle version, in one place. Support tickets start with "which build are you on?", and
/// before this the answer was nowhere in the UI.
enum AppInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    static var versionDisplay: String { "Version \(shortVersion) (\(buildNumber))" }
}

@main
struct PowerBinApp {
    static func main() {
        Log.line("PowerBin main() entered")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .regular = Dock + menu bar. .accessory = menu bar only (Raycast / Asset Hub style).
        app.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var floatingPanel: FloatingPanel?
    private var hotkeyService: HotkeyService?
    private var statusItem: NSStatusItem?

    private let presetStore = PresetStore()
    private let pasteboard = PasteboardService()
    private let settings = AppSettings.shared

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// Re-register the global hotkey. Called from SettingsView after the user
    /// records a new combo.
    ///
    /// Publishes the result. Registration fails whenever another app already owns the
    /// combo, and that used to be log-only: the customer set a hotkey, nothing happened,
    /// and there was nothing on screen saying why.
    @discardableResult
    func applyHotkey() -> Bool {
        guard let svc = hotkeyService else { return false }
        let combo = settings.toggleHotkey.trimmingCharacters(in: .whitespaces)
        let ok = combo.isEmpty ? false : svc.apply(combo)
        settings.hotkeyRegistrationFailed = !ok
        Log.line(" hotkey re-applied=\(ok) combo=\(combo.isEmpty ? "(none)" : combo)")
        return ok
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.line(" launch — bundleID=\(Bundle.main.bundleIdentifier ?? "nil")")
        Log.line(" → setupMainMenu")
        setupMainMenu()
        Log.line(" → setupStatusItem")
        setupStatusItem()
        Log.line(" → setupFloatingPanel")
        setupFloatingPanel()
        Log.line(" → setupHotkey")
        setupHotkey()
        Log.line(" ready — hotkey=\(settings.toggleHotkey)")

        // First-run onboarding: prompt for permissions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.maybeShowOnboarding()
        }
    }

    private func maybeShowOnboarding() {
        let missing = PermissionsService.anyMissing()
        if !settings.onboardingComplete {
            Log.line(" onboarding — missing=\(missing.map { $0.rawValue })")
            PermissionsWindowController.shared.show()
        } else if !missing.isEmpty {
            Log.line(" permissions still reported missing after onboarding dismissed: \(missing.map { $0.rawValue })")
        }
    }

    // MARK: - Menu bar

    /// Install a main menu so ⌘X / ⌘C / ⌘V / ⌘A work in text fields.
    ///
    /// AppKit dispatches those key equivalents through `NSApp.mainMenu`. An LSUIElement
    /// agent gets no main menu for free and never displays one, so without this every
    /// text field in the app silently ignores paste (preset names, workspace names).
    ///
    /// The items use nil targets on purpose: they travel the responder chain to whatever
    /// text field is first responder. The menu is never rendered; only its key
    /// equivalents matter.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PowerBin", action: #selector(quit), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
        Log.line("   mainMenu installed — editItems=\(edit.items.count) hasPaste=\(edit.items.contains { $0.keyEquivalent == "v" })")
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.imagePosition = .imageLeft
        button.target = self
        button.action = #selector(onStatusClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        button.image = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: "PowerBin")
        button.toolTip = "PowerBin — \(AppInfo.versionDisplay)"
    }

    @objc private func onStatusClick(_ sender: Any?) {
        let evt = NSApp.currentEvent
        if evt?.type == .rightMouseUp || (evt?.modifierFlags.contains(.control) ?? false) {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Show PowerBin",
                                action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let log = NSMenuItem(title: "Reveal Log in Finder", action: #selector(revealLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let version = NSMenuItem(title: AppInfo.versionDisplay, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit PowerBin", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil // detach so left-click stays bound to onStatusClick
    }

    // MARK: - Floating panel

    private func setupFloatingPanel() {
        Log.line("   floatingPanel: making RootView")
        let view = RootView(
            store: presetStore,
            pasteboard: pasteboard,
            dismiss: { [weak self] in self?.hidePanel() },
            reveal: { [weak self] in self?.showPanelAtMouse() }
        )
        Log.line("   floatingPanel: NSHostingView")
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1080, height: 640)
        host.autoresizingMask = [.width, .height]
        Log.line("   floatingPanel: FloatingPanel init")
        let panel = FloatingPanel(contentRect: host.frame)
        panel.minSize = NSSize(width: 920, height: 500)
        panel.contentView = host
        panel.onResignKey = { [weak self] in self?.hidePanel() }
        floatingPanel = panel
        Log.line("   floatingPanel: done")
    }

    private func setupHotkey() {
        hotkeyService = HotkeyService { [weak self] in
            self?.handleGlobalHotkey()
        }
        applyHotkey()
    }

    private func handleGlobalHotkey() {
        guard shouldHandleGlobalHotkey() else {
            let app = NSWorkspace.shared.frontmostApplication
            Log.line(" hotkey ignored — frontmost=\(app?.bundleIdentifier ?? app?.localizedName ?? "nil")")
            return
        }

        Log.line(" hotkey fired")
        togglePanel()
    }

    private func shouldHandleGlobalHotkey() -> Bool {
        guard settings.premiereOnlyHotkey else { return true }
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }

        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        let configured = settings.premiereBundleID.lowercased()
        if !configured.isEmpty && bundleID == configured {
            return true
        }
        if bundleID.hasPrefix("com.adobe.premierepro") {
            return true
        }

        return (app.localizedName ?? "").lowercased().contains("premiere")
    }

    @objc private func togglePanel() {
        guard let panel = floatingPanel else { return }
        Log.line(" togglePanel — visible=\(panel.isVisible)")
        if panel.isVisible {
            hidePanel()
        } else {
            showPanelAtMouse()
        }
    }

    private func showPanelAtMouse() {
        guard let panel = floatingPanel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let size = panel.frame.size

        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height + 20)
        if let s = screen {
            let vis = s.visibleFrame
            origin.x = max(vis.minX + 8, min(origin.x, vis.maxX - size.width - 8))
            origin.y = max(vis.minY + 8, min(origin.y, vis.maxY - size.height - 8))
        }
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        floatingPanel?.orderOut(nil)
    }

    @objc private func openPreferences() {
        SettingsWindowController.shared.show()
    }

    /// Support asks for this file first. Make it one click instead of a Finder path.
    @objc private func revealLog() {
        Log.line(" log revealed from menu")
        let target = FileManager.default.fileExists(atPath: Log.url.path)
            ? Log.url
            : Log.url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
