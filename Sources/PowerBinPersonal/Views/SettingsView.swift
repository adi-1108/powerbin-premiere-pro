import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Toggle floating panel") {
                    HotkeyRecorder(combo: $settings.toggleHotkey) { _ in
                        AppDelegate.shared?.applyHotkey()
                    }
                }
                // Registration fails whenever another app already owns the combo. This was
                // log-only, so the user set a shortcut, nothing happened, and there was
                // nothing on screen explaining why.
                if settings.hotkeyRegistrationFailed {
                    Label(settings.toggleHotkey.isEmpty
                          ? "No shortcut set. Open PowerBin from the menu-bar icon, or record a combo above."
                          : "macOS wouldn't register this shortcut — another app is probably using it. Try a different combination.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Click the field, press your combo. Applies instantly — no restart.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("For Karabiner-Elements mouse buttons, map the button to F13-F20, then record that bare F-key here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset to \(HotkeyRecorder.prettyCombo(AppSettings.defaultToggleHotkey))") {
                    settings.toggleHotkey = AppSettings.defaultToggleHotkey
                    AppDelegate.shared?.applyHotkey()
                }
                .disabled(settings.toggleHotkey == AppSettings.defaultToggleHotkey)
            }

            Section("General") {
                Toggle("Open PowerBin at login", isOn: $settings.launchAtLogin)
                    .help("Registers PowerBin as a macOS login item.")
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Show in Dock (in addition to menu bar)",
                       isOn: $settings.showInDock)
                    .help("Off = menu-bar only, like Raycast. Applies immediately.")
                Toggle("Only respond to the hotkey while Premiere Pro is frontmost",
                       isOn: $settings.premiereOnlyHotkey)
                    .help("Off = the panel opens from any app.")
            }

            Section("Permissions") {
                Button("Open Permissions Panel…") {
                    PermissionsWindowController.shared.show()
                }
            }

            Section("Clipboard snapshot") {
                Toggle("Save only Adobe / Premiere pasteboard types",
                       isOn: $settings.adobeOnlySnapshot)
                    .help("Smaller presets, but drops any plain text or image copied alongside them.")
            }

            Section("Paste behavior") {
                Picker("Paste mode", selection: Binding(
                    get: { settings.pasteMode },
                    set: { settings.pasteMode = $0 }
                )) {
                    ForEach(PasteMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if settings.pasteMode == .excalibur {
                    LabeledContent("Excalibur shortcut") {
                        HotkeyRecorder(combo: $settings.excaliburHotkey, allowBareSpecialKeys: true)
                    }
                    Text("Click the field, then press the Excalibur paste shortcut you use in Premiere.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Double-clicking a preset will activate Premiere, press this shortcut, press Down, then press Return.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.pasteMode == .custom {
                    LabeledContent("Custom paste shortcut") {
                        HotkeyRecorder(combo: $settings.customPasteHotkey, allowBareSpecialKeys: true)
                    }
                }
                Toggle("Auto-paste after loading preset", isOn: $settings.autoPasteAfterLoad)
                    .help("After Load, activates Premiere and sends the paste hotkey.")
                TextField("Premiere bundle ID (optional)", text: $settings.premiereBundleID,
                          prompt: Text("Auto-detect"))
                    .help("Leave empty and PowerBin finds any running version of Premiere Pro. "
                          + "Only set this to pin a specific install, e.g. com.adobe.PremierePro.25")
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(AppInfo.versionDisplay).textSelection(.enabled)
                }
                HStack {
                    Button("Reveal Log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Log.url])
                    }
                    .help("Support will ask for this file.")
                    Button("Reveal Presets in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([presetsRoot])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { settings.refreshLaunchAtLogin() }
    }

    private var presetsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerBin", isDirectory: true)
    }
}
