#!/usr/bin/env bash
# Build PowerBin.app and package it into a DMG.
#
# Works with Command Line Tools alone (no Xcode): assembles the .app bundle by hand around
# the SwiftPM binary, then signs and wraps it in a DMG under dist/.
#
# SIGNING, in preference order: a "Developer ID Application" cert (distributable once
# notarised), then a local self-signed cert named by $POWERBIN_LOCAL_SIGNING_ID (stable
# identity, so macOS keeps the Accessibility grant across rebuilds), then ad-hoc.
# Ad-hoc and self-signed builds only open on the Mac that built them.
set -euo pipefail

cd "$(dirname "$0")/.."

# The SPM product / executable name. Not the .app name — see BUNDLE_NAME below.
PRODUCT="PowerBin"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"

# CONFIG=debug builds a native-arch test bundle that installs beside the release one.
CONFIG="${CONFIG:-release}"
case "$CONFIG" in
  release) SUFFIX="";       BUNDLE_NAME="PowerBin";          BUNDLE_ID="com.adityavishwakarma.powerbin" ;;
  debug)   SUFFIX="-debug"; BUNDLE_NAME="PowerBin Mac Test"; BUNDLE_ID="com.adityavishwakarma.powerbin.test" ;;
  *) echo "CONFIG must be 'release' or 'debug', got '$CONFIG'" >&2; exit 2 ;;
esac

DIST="dist"
APP="$DIST/$BUNDLE_NAME.app"
DMG="$DIST/$PRODUCT-$VERSION$SUFFIX.dmg"

echo "==> building $CONFIG binary"
# A release build is universal (Apple Silicon + Intel). `swift build --arch arm64 --arch x86_64` needs Xcode's xcbuild, which this
# machine (Command Line Tools only) does not have — so build each slice with --triple and
# lipo them together, which needs nothing but the toolchain.
#
# Debug stays native: it never ships, and cross-building doubles the build time.
if [ "$CONFIG" = "release" ]; then
  for triple in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
    echo "    slice $triple"
    swift build -c "$CONFIG" --triple "$triple" --product "$PRODUCT"
  done
  ARM_BIN="$(swift build -c "$CONFIG" --triple arm64-apple-macosx13.0 --product "$PRODUCT" --show-bin-path | tail -1)/$PRODUCT"
  X86_BIN="$(swift build -c "$CONFIG" --triple x86_64-apple-macosx13.0 --product "$PRODUCT" --show-bin-path | tail -1)/$PRODUCT"
  for slice in "$ARM_BIN" "$X86_BIN"; do
    [ -f "$slice" ] || { echo "no binary at $slice" >&2; exit 1; }
  done
  BIN="$(mktemp -d)/$PRODUCT"
  lipo -create -output "$BIN" "$ARM_BIN" "$X86_BIN"
else
  swift build -c "$CONFIG" --product "$PRODUCT"
  BIN="$(swift build -c "$CONFIG" --product "$PRODUCT" --show-bin-path | tail -1)/$PRODUCT"
  [ -f "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }
fi

echo "==> assembling $APP"
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# CFBundleExecutable must match the binary name, which stays $PRODUCT even when the
# bundle is named something else.
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"

# A release DMG with only one slice cannot launch on half of all Macs; fail here.
if [ "$CONFIG" = "release" ]; then
  ARCHS="$(lipo -archs "$APP/Contents/MacOS/$PRODUCT")"
  case "$ARCHS" in
    *arm64*) ;; *) echo "ABORT: release binary has no arm64 slice (got: $ARCHS)" >&2; exit 1 ;;
  esac
  case "$ARCHS" in
    *x86_64*) ;; *) echo "ABORT: release binary has no x86_64 slice (got: $ARCHS)." >&2
                    exit 1 ;;
  esac
  echo "    architectures: $ARCHS"
fi

# The .icns is generated from assets/branding/PowerBinIcon.svg — regenerate with
# Scripts/make-icon.sh, don't hand-edit. CFBundleIconFile in Info.plist names it
# without the extension, so the file must stay PowerBin.icns.
if [ -f Resources/PowerBin.icns ]; then
  cp Resources/PowerBin.icns "$APP/Contents/Resources/PowerBin.icns"
else
  echo "    WARNING: Resources/PowerBin.icns missing — app will show the generic icon" >&2
fi

# Resources/Info.plist carries $(VAR) placeholders that only xcodebuild expands.
# Expand the ones that matter, since nothing else will.
sed -e "s|\$(DEVELOPMENT_LANGUAGE)|en|g" \
    -e "s|\$(EXECUTABLE_NAME)|$PRODUCT|g" \
    -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
    -e "s|\$(PRODUCT_NAME)|$BUNDLE_NAME|g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $BUNDLE_NAME" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $BUNDLE_NAME" "$APP/Contents/Info.plist" 2>/dev/null || true

# Fail loudly rather than shipping a bundle with an unexpanded $(VAR) in it.
if grep -q '\$(' "$APP/Contents/Info.plist"; then
  echo "Info.plist still has unexpanded variables:" >&2
  grep '\$(' "$APP/Contents/Info.plist" >&2
  exit 1
fi

echo "==> signing"
# Preference order:
#   1. Developer ID Application — the only thing that can be notarised.
#   2. The self-signed "PowerBin Personal Developer ID" — useless for distribution, but it
#      gives a STABLE code identity, so macOS keeps the Accessibility/Apple Events grants
#      across rebuilds. Ad-hoc doesn't: its identity is the binary hash, so every rebuild
#      looks like a brand-new app and TCC re-prompts (and silently drops the hotkey).
#   3. Ad-hoc — last resort.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)"
LOCAL_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "${POWERBIN_LOCAL_SIGNING_ID:-PowerBin Personal Developer ID}" | head -1 | awk '{print $2}' || true)"

if [ -n "$DEV_ID" ]; then
  echo "    Developer ID: $DEV_ID"
  codesign --force --deep --options runtime --timestamp --sign "$DEV_ID" "$APP"
  SIGNED_FOR_RELEASE=yes
elif [ -n "$LOCAL_ID" ]; then
  echo "    self-signed local identity: $LOCAL_ID (stable TCC grants)"
  codesign --force --deep --options runtime --sign "$LOCAL_ID" "$APP"
  SIGNED_FOR_RELEASE=no
else
  echo "    ad-hoc — Accessibility will be re-prompted on every rebuild"
  codesign --force --deep --options runtime --sign - "$APP"
  SIGNED_FOR_RELEASE=no
fi
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> packaging $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$BUNDLE_NAME $VERSION" -srcfolder "$STAGE" \
               -ov -format UDZO "$DMG" >/dev/null

echo
echo "built:   $DMG  ($(du -h "$DMG" | cut -f1))"
echo "version: $VERSION ($BUILD_NUM)  config: $CONFIG"
if [ "$SIGNED_FOR_RELEASE" = "no" ]; then
  echo
  echo "LOCAL TESTING ONLY — not signed with a Developer ID, not notarised."
  echo "Fine on this Mac. On anyone else's: \"PowerBin is damaged and can't be opened\"."
  echo "First launch still needs a right-click -> Open, and Accessibility must be granted"
  echo "in System Settings -> Privacy & Security -> Accessibility, or the hotkey won't fire."
fi
