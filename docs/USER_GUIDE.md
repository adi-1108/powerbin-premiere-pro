# PowerBin user guide

How to set up and use PowerBin with Premiere Pro, with the caveats for each part.
Every section ends with a **Caveats** list. The project-wide list (Premiere versions, macOS,
building) is in [KNOWN_ISSUES.md](../KNOWN_ISSUES.md).

> PowerBin is unmaintained and was last tested on Premiere Pro 2025 (v25). Treat everything
> below as "how it worked then". On newer Premiere versions, test with a throwaway project
> before trusting it with real work.

- [1. Install](#1-install)
- [2. Permissions](#2-permissions)
- [3. The shortcut that opens PowerBin](#3-the-shortcut-that-opens-powerbin)
- [4. Saving a preset](#4-saving-a-preset)
- [5. Pasting a preset](#5-pasting-a-preset)
- [6. Paste modes: Native, Excalibur, Custom](#6-paste-modes-native-excalibur-custom)
- [7. Workspaces, favorites, previews](#7-workspaces-favorites-previews)
- [8. Keys inside the panel](#8-keys-inside-the-panel)
- [9. Preferences reference](#9-preferences-reference)
- [10. Moving, backing up and sharing presets](#10-moving-backing-up-and-sharing-presets)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Uninstalling](#12-uninstalling)

---

## 1. Install

1. Build the app (see the [README](../README.md#build)). You get `dist/PowerBin.app`.
2. Drag `PowerBin.app` to `/Applications` and open it.
3. PowerBin has **no Dock icon**. It lives in the menu bar (tray icon, top right). Click it
   to open the panel; right-click it for Preferences, the log and Quit.

**Caveats**
- There are no prebuilt or notarized downloads. A build only opens on the Mac that built it
  (or on any Mac if you sign it with your own Developer ID and notarize it).
- If you copy a self-built app to another Mac, macOS will say it is "damaged". It isn't;
  it is unsigned for that Mac. Build it there instead.
- Turn on **Preferences → General → Show in Dock** if you lose track of a menu-bar app.

---

## 2. Permissions

PowerBin asks for two macOS permissions on first launch (a Permissions window appears):

| Permission | Why | Without it |
|---|---|---|
| **Accessibility** | Sends the paste keystroke into Premiere | Auto-paste and double-click paste do nothing; you paste with ⌘V yourself |
| **Input Monitoring** | Hears bare F-keys (mouse buttons via Karabiner) | Normal modifier shortcuts still work; bare `F13`-`F19` may not |

Grant them in **System Settings → Privacy & Security**. You can reopen the window from
**Preferences → Permissions → Open Permissions Panel**.

**Caveats**
- After granting, **quit and reopen PowerBin**. macOS often doesn't re-check a grant for a
  running app, so it can still show as missing.
- macOS ties the grant to the app's code signature. An ad-hoc signed build gets a new
  signature every rebuild, so the grant silently stops applying and you must remove and
  re-add PowerBin in the list. Sign with a stable certificate (README → Signing).
- PowerBin never asks for Automation / Apple Events. If something asks for that, it isn't
  PowerBin.

---

## 3. The shortcut that opens PowerBin

Default: **⌃⌥⌘P** (Control-Option-Command-P), and only while Premiere Pro is frontmost.

To change it: **Preferences → Hotkey**, click the field, press the new combination. It
applies at once. **Esc** cancels, **✕** clears it, **Reset** restores the default.

### Opening it from a mouse button

1. In Karabiner-Elements, map the mouse button to `f13` (or `f14`-`f19`).
2. In PowerBin Preferences, click the hotkey field and press the mouse button once. It
   records as `F13`.
3. That button now toggles the panel under the pointer.

**Caveats**
- **The shortcut does nothing outside Premiere by default.** That's the "Only respond to
  the hotkey while Premiere Pro is frontmost" setting, and it is the number one "it's
  broken" report. Turn it off to use the shortcut anywhere.
- Use at least one modifier (⌘ ⌥ ⌃ ⇧). A bare letter is rejected. Only `F13`-`F19` work
  without a modifier.
- **Don't reuse a Premiere shortcut.** The PowerBin hotkey is live while Premiere is in
  front, so a clash breaks one of them. Check **Premiere Pro → Keyboard Shortcuts…**.
- If another app already owns the combo system-wide, macOS refuses it and Preferences shows
  a warning under the field. Pick another one.
- If Premiere isn't detected (new version with a new bundle ID), the Premiere-only hotkey
  never fires. Set **Premiere bundle ID** in Preferences, or turn the Premiere-only setting
  off. See [KNOWN_ISSUES.md](../KNOWN_ISSUES.md#premiere-pro-compatibility).
- The menu-bar icon always opens the panel, whatever the shortcut is doing.

---

## 4. Saving a preset

1. In Premiere, select what you want to keep: clips, titles, graphics, adjustment layers,
   audio, a group of items across tracks.
2. Press **⌘C** in Premiere.
3. Open PowerBin (hotkey).
4. Press **⌘S** (or click **Save**), type a name, press **↩**.

The preset is saved in the active workspace.

**Caveats**
- **PowerBin saves whatever is on the clipboard right now.** If you copied something in
  another app after Premiere, that's what gets saved. Copy in Premiere, then save straight
  away.
- **A preset is a snapshot of Premiere's clipboard, not of your media.** It stores the
  timeline items, effects and settings, and *references* to the media files by path. It
  does not copy the video, audio or image files. If those files move, get renamed or don't
  exist on this Mac, the pasted clips come in offline.
- Graphics and titles made with Essential Graphics usually paste fine. Fonts are not
  stored; a missing font is substituted by Premiere.
- **Presets are tied to the Premiere version that made them.** A preset saved in v25 may
  not paste in a newer Premiere. Re-copy and re-save after a Premiere upgrade.
- **Clipboard snapshot → "Save only Adobe / Premiere pasteboard types"** makes presets
  smaller but throws away plain text or images copied along with them. Leave it off unless
  presets get large.
- Big selections make big presets. A copied nested sequence with many items can be several
  MB, all of which is written to disk and loaded back each time.

---

## 5. Pasting a preset

1. In Premiere, click into the **timeline panel** and put the playhead (and the target
   track, if you use track targeting) where the preset should go.
2. Open PowerBin (hotkey). Start typing to filter.
3. **Double-click** the preset, or select it and press **↩**.

PowerBin hides itself, brings Premiere to the front, writes the preset to the clipboard and
sends the paste keystroke for your paste mode (section 6).

**Paste it yourself instead:** single-click to select a preset, then use **Load** (button or
right-click menu). With auto-paste off, Load only puts it on the clipboard, and the status
line says "Loaded '…'. Cmd-V in Premiere." Click exactly where you want it in Premiere and
press ⌘V.

**Caveats**
- **Your clipboard gets replaced.** Loading or pasting a preset overwrites whatever you had
  copied. PowerBin does not put your old clipboard back.
- **Paste follows Premiere's panel focus**, not PowerBin. If the Project panel or Effect
  Controls has focus, the paste goes there or does nothing. Click the timeline first.
- Pasting needs **Accessibility** (section 2). Without it, Load + manual ⌘V still works.
- PowerBin waits about 0.4 s for Premiere to come to the front. On a slow or busy machine
  (rendering, a big project still loading) the keystroke can arrive before Premiere is
  ready. Press ⌘V yourself if nothing landed.
- Premiere must already be running. PowerBin won't launch it.
- Normal Premiere paste rules apply: overwrite vs insert (⌘V vs ⇧⌘V), track targeting, and
  sync lock all behave exactly as if you had copied the item yourself.

---

## 6. Paste modes: Native, Excalibur, Custom

Set in **Preferences → Paste behavior → Paste mode**.

| Mode | Keys PowerBin sends after bringing Premiere forward | Setup |
|---|---|---|
| **Native ⌘V** (default) | `⌘V` | None |
| **Excalibur** | your Excalibur combo → 0.32 s → `↓` → ~0.09 s → `↩` | Record the same combo Excalibur uses |
| **Custom** | the combo you record | Bind the same combo to a command in Premiere |

### Native ⌘V
Start here. Works with no setup.

### Excalibur
For editors who paste through [Excalibur](https://knightsoftheeditingtable.com). PowerBin
doesn't talk to Excalibur; it only presses the keys.

1. Find the shortcut Excalibur uses to open its command palette and note it exactly.
2. **Preferences → Paste mode → Excalibur**, then record that same combo in the
   **Excalibur shortcut** field.
3. Double-click a preset to test.

### Custom
For any one Premiere command you want instead of plain paste (Paste Insert, Paste
Attributes, a remapped paste).

1. **Premiere Pro → Keyboard Shortcuts…**, bind the command to an unused combo.
2. **Preferences → Paste mode → Custom**, record the same combo.

### Auto-paste after loading
**Preferences → Paste behavior → Auto-paste after loading preset** (off by default). With it
on, **Load** also pastes, not only double-click. Leave it off while you're testing a new
setup.

**Caveats**
- **The combo in PowerBin must match the one in Premiere/Excalibur exactly.** If they
  differ, nothing happens and nothing tells you why. Check the log: it records every key
  PowerBin sends.
- **Excalibur timings are fixed in code** (`PasteDriver.swift`: 0.32 s before ↓, ~0.09 s
  before ↩). If Excalibur's palette opens slower than that, the ↓ and ↩ go nowhere. Use
  Custom mode with one Premiere shortcut instead, or change the constants and rebuild.
- Excalibur is a third-party paid extension and may itself have changed since this was
  tested.
- Custom mode starts with a placeholder combo. Replace it before use.

---

## 7. Workspaces, favorites, previews

- **Workspaces:** one preset library per client, channel or project. Left sidebar, **+**
  to add; rename or delete from the **⋯** menu on the active workspace.
- **Favorites** (⭐) and **Most Used** (📊): the right-hand rail. Both show presets from
  *all* workspaces. Most Used fills in as you paste.
- **Previews:** select a preset and attach a screenshot with **Upload Screenshot**,
  **Capture Screenshot** (opens the macOS screenshot tool and picks up the result), or **Use
  Copied Screenshot**.
- **Sorting:** by date created, time created, name, size, or number of clipboard types.

**Caveats**
- **Deleting a workspace deletes its presets and preview images from disk.** There is no
  undo and no Trash. Back up first (section 10).
- Previews are your screenshots, not real thumbnails. Premiere puts no usable image on the
  clipboard, so a preset without one shows a placeholder.
- **Capture Screenshot** relies on the screenshot landing on the clipboard or in your
  screenshot folder. If you changed where macOS saves screenshots, or cancel the capture,
  it may not find it; use Upload instead.
- Most Used counts are local to this Mac and reset if you delete the library folder.

---

## 8. Keys inside the panel

| Key | Action |
|---|---|
| *(type)* | Filter presets (the search field is focused when the panel opens) |
| ↑ / ↓ | Move the selection, even while typing |
| ↩ | Paste the selected preset |
| ⌘S | Save the clipboard as a new preset |
| ⌘, | Preferences |
| Esc | Close the panel |

Mouse: click selects, **double-click pastes**, right-click opens Paste / Load / Favorite /
Tag / Delete.

**Caveats**
- These keys are fixed, not configurable.
- The panel closes when you click outside it. That's on purpose; reopen with the hotkey.

---

## 9. Preferences reference

| Setting | Default | Notes |
|---|---|---|
| Hotkey | ⌃⌥⌘P | Section 3 |
| Open PowerBin at login | Off | Uses macOS Login Items; may need approval in System Settings → General → Login Items |
| Show in Dock | Off | Applies at once |
| Only respond to the hotkey while Premiere Pro is frontmost | On | Section 3 |
| Premiere bundle ID | Empty (auto) | Set only if auto-detect fails |
| Save only Adobe / Premiere pasteboard types | Off | Section 4 |
| Paste mode | Native ⌘V | Section 6 |
| Excalibur / Custom shortcut | — | Shown for those modes |
| Auto-paste after loading preset | Off | Section 6 |

---

## 10. Moving, backing up and sharing presets

Everything lives in one folder:

```
~/Library/Application Support/PowerBin/
  workspaces/<workspace>/presets/*.clp     the presets
  ...                                      preview images and metadata
```

- **Back up:** quit PowerBin and copy the whole `PowerBin` folder.
- **Move to another Mac:** copy the folder to the same place on the new Mac, then open
  PowerBin.
- A `.clp` file is JSON with the clipboard data base64-encoded inside.

**Caveats**
- **Sharing presets with other editors is hit and miss.** The media paths inside point to
  *your* drives. On their Mac the clips come in offline unless the media sits at the same
  paths. Graphics/titles with no external media travel best.
- Their Premiere version must be close to yours (section 4).
- Presets can contain client names and file paths. Check before sharing.

---

## 11. Troubleshooting

Start with the log: right-click the menu-bar icon → **Reveal Log in Finder**
(`~/Library/Logs/PowerBin.log`). It records every hotkey press, every preset save/load, and
every key PowerBin sends. It contains preset and workspace names; redact client names
before posting it in an issue.

| Problem | Try |
|---|---|
| Hotkey does nothing | Is Premiere frontmost? Warning under the hotkey field? Permissions granted, then app relaunched? |
| Mouse button does nothing | Input Monitoring; check the field recorded `F13` and not something else |
| Panel opens, nothing pastes | Accessibility; click the Premiere timeline first; try Native ⌘V mode; try Load + manual ⌘V |
| ⌘V in Premiere pastes nothing | Preset from an older Premiere: re-copy and re-save. If fresh presets also fail, your Premiere version changed the clipboard format: please open an issue |
| Wrong thing pastes | Something else was on the clipboard when you saved. Re-copy in Premiere, save again |
| Clips paste offline | Media moved or isn't on this Mac. Relink in Premiere |
| Excalibur mode does nothing | Combos must match exactly; timing may be too short; use Custom mode |
| Permissions keep resetting | Ad-hoc signed build. Sign with a stable certificate |
| Status line says "Clipboard restore failed" | The preset file is damaged or empty. Details in the log |

Still stuck: open an issue with the bug report template.

---

## 12. Uninstalling

1. Quit PowerBin (right-click the menu-bar icon → Quit).
2. Delete `/Applications/PowerBin.app`.
3. Optional: delete `~/Library/Application Support/PowerBin` (all your presets) and
   `~/Library/Logs/PowerBin.log`.
4. Optional: remove PowerBin from System Settings → Privacy & Security → Accessibility and
   Input Monitoring, and from Login Items.
