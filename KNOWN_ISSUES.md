# Known issues

PowerBin was built and tested against **Premiere Pro 2025 (v25)** and has
not been maintained since. Adobe has shipped several Premiere releases after that. This page
lists what is known to break, what is likely to break, and how to tell which one you hit.

If you hit something not listed here, open an issue with the bug report template and attach
`~/Library/Logs/PowerBin.log` (check it for client names first).

## Premiere Pro compatibility

### Newer Premiere versions are untested

| Premiere Pro | Status |
|---|---|
| 2025 (v25) and earlier | Worked, last version tested |
| 2026 (v26) and later | **Untested.** Please report. |

PowerBin depends on behaviour Adobe does not document or promise to keep:

- **The clipboard format is private.** Premiere puts its data on the macOS pasteboard
  under `com.adobe.*` and dynamic `dyn.*` types. PowerBin stores those bytes and puts them
  back unchanged. If Adobe changes the format, saving still "works" (PowerBin stores
  whatever is there) but pasting does nothing, or Premiere pastes something partial.
- **Presets are tied to the Premiere version that made them.** A preset saved in v25 holds
  v25 clipboard data. A newer Premiere may refuse it. Pasting across major versions has
  never been tested. If an old preset fails, copy the same thing again in your current
  Premiere and save it as a new preset.
- **A session cookie is stripped on save.** `com.adobe.dvaui.ppro/mz/cookie` (also seen as
  a `dyn.*` type with that MIME type) identifies the copying session and is not written back
  on load. If a future Premiere starts requiring it, every paste will silently fail.
  The filter lives in `PasteboardService.isPremiereCookie`.
- **The bundle ID changes with every major release** (`com.adobe.PremierePro.24`,
  `.25`, ...). PowerBin matches the `com.adobe.premierepro` prefix, then falls back to an
  app whose name contains "Premiere Pro". If Adobe renames the bundle (for example a new
  Beta channel id), the Premiere-only hotkey and auto-paste stop finding Premiere.
  Workaround: Preferences → Premiere bundle ID, paste the exact ID from
  `osascript -e 'id of app "Adobe Premiere Pro 2026"'` (adjust the name).

### Symptom → likely cause

| Symptom | Likely cause |
|---|---|
| Hotkey does nothing anywhere | Accessibility / Input Monitoring not granted, or another app owns the combo (Preferences shows a red warning). |
| Hotkey works on the Desktop but not in Premiere | Bundle ID detection failed. Set it manually. |
| Hotkey does nothing on the Desktop | Expected. "Premiere-only hotkey" is on by default. |
| Preset loads, ⌘V in Premiere pastes nothing | Clipboard format changed in your Premiere version, or a cross-version preset. Re-copy and re-save. |
| Auto-paste brings Premiere forward but nothing pastes | Accessibility missing, or Premiere took longer than ~0.4 s to take focus (`PasteDriver`: 16 polls × 25 ms). Paste manually with ⌘V. |
| Excalibur mode opens Excalibur but does not run the command | Timing: `PasteDriver` waits 0.32 s before Return. Slow machines may need more. |
| Pasted clips show as offline media | The preset references media by path; that media is not on this machine or has moved. |

## macOS

- **Not notarized.** There are no signed release builds. A self-built app opens on the Mac
  that built it; copied to another Mac, Gatekeeper reports it as damaged. Notarizing needs a
  paid Apple Developer account.
- **Accessibility resets after rebuilding** when the app is ad-hoc signed, because the
  signature (and so the identity macOS granted access to) changes on every build. Use a
  stable self-signed certificate; see the README.
- **No Dock icon by default.** PowerBin is a menu-bar app (`LSUIElement`). If you can't
  find it, look for the tray icon in the menu bar, or enable "Show in Dock".
- **Newer macOS releases are untested.** Minimum is macOS 13. Carbon hotkeys and
  `CGEvent` keystroke injection still work on current releases as far as is known, but
  Apple tightens these permissions regularly.

## Build

- **Command Line Tools alone cannot build it on current SDKs.** Verified on macOS 27.2
  with Swift 6.4.2 (CLT only), `swift build` fails with:

  ```
  error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
  for macro 'State()'; plugin for module 'SwiftUIMacros' not found
  ```

  The SwiftUI macro plugins ship with Xcode, not with the Command Line Tools. Install
  Xcode and select it: `sudo xcode-select -s /Applications/Xcode.app`.
- **`swift test` needs Xcode.** XCTest is not part of the Command Line Tools.
- **Universal builds** use `swift build --triple` per architecture plus `lipo`. If one
  slice fails to build, `build-dmg.sh` aborts rather than shipping a single-arch app.

## Not supported

- **Windows.** This is the macOS app only.
- **Other Adobe apps** (After Effects, Audition, Premiere Rush). The pasteboard capture is
  generic, but paste targeting and the hotkey filter look for Premiere Pro only.
