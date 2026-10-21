#!/bin/bash
# Builds Clothespeg.app into ./build without needing Xcode.
# Usage: scripts/build-app.sh [debug|release|lite]
#   lite — the App Store build: sandbox entitlements, its own bundle id,
#          and the features the store forbids compiled out (APPSTORE_LITE).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
LITE=0
if [ "$CONFIG" = "lite" ]; then LITE=1; CONFIG=release; fi
if [ "$CONFIG" = "lite-debug" ]; then LITE=1; CONFIG=debug; fi
if [ "$LITE" = "1" ]; then
  APP="build/ClothespegLite.app"
  BUNDLE_ID="com.vizwise.clothespeg.lite"
  BUNDLE_NAME="Clothespeg 苹果专版"
else
  APP="build/Clothespeg.app"
  # A fresh identity on purpose. macOS 26 keeps a per-app "allow in the menu
  # bar" authorization keyed by bundle id, and the one held for the old id
  # (com.vizwise.clothespeg) went bad: AppKit built a valid, visible status
  # item and the WindowServer still refused to commit it, so the icon never
  # showed. The new id starts with a clean authorization — the same fix
  # Flyring shipped for the same symptom. Settings are carried over once by
  # migrateSettingsToNewIdentity in main.swift.
  BUNDLE_ID="com.vizwise.clothespeg.app"
  BUNDLE_NAME="Clothespeg"
fi
# 1.9.0 is a minor: notes can now carry a reminder — once, or every day,
# week or month — and the settings window took on the design tokens the
# cards already used. It also fixes the menu-bar icon that stopped showing
# on macOS 26: the system's per-app "allow in the menu bar" authorization
# for the old bundle id was poisoned, so the app moves to a fresh identity
# (com.vizwise.clothespeg.app) and carries the saved settings across once.
#
# 1.9.1 is a patch: the app now asks for Accessibility before it types a
# ⌘V into another process, so the Accessibility toggle in System Settings
# actually switches on (it would not for an app that never asked), and the
# build is notarized with the company Developer ID.
#
# 1.9.2 is a patch: reminders keep working after a relaunch (the in-app timer
# is rebuilt at launch, not only on save), a one-time reminder that has
# already rung no longer rings a second time when its time is moved around in
# the past, and the Permissions page gains a Notifications row — its status, a
# way to ask, and the System Settings door.
VERSION="1.9.2"

# Builds one architecture and prints the binary's path.
# The Command Line Tools for macOS 27 ship an SDK whose SwiftUI needs a macro
# plugin they do not include. If the default SDK fails, fall back to the
# newest macOS 26 SDK installed alongside it.
#
# SwiftPM's own sandbox needs its helper to be able to apply itself, which it
# cannot when this script runs inside another sandbox. Turning it off only
# affects the build; the app it produces is signed below like any other.
SWIFT_BUILD=(swift build --disable-sandbox)
if [ "$LITE" = "1" ]; then
  SWIFT_BUILD+=(-Xswiftc -DAPPSTORE_LITE)
fi
# DEBUG, so a debug build can be told apart from a release one in the source.
# Spelled out rather than left to the build system, because the one thing
# this flag is for — a second copy of the app being asked to quit — is
# something only a build you are about to test can benefit from, and a
# released app has no business quitting anybody.
if [ "$CONFIG" = "debug" ]; then
  SWIFT_BUILD+=(-Xswiftc -DDEBUG)
fi

build_arch() {
  local triple="$1-apple-macosx14.0"
  if [ -z "${SDKROOT:-}" ] && ! "${SWIFT_BUILD[@]}" -c "$CONFIG" --triple "$triple" >&2; then
    FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -z "$FALLBACK" ]; then exit 1; fi
    echo "Retrying with $FALLBACK" >&2
    export SDKROOT="$FALLBACK"
  fi
  if [ -n "${SDKROOT:-}" ]; then "${SWIFT_BUILD[@]}" -c "$CONFIG" --triple "$triple" >&2; fi
  cp "$("${SWIFT_BUILD[@]}" -c "$CONFIG" --triple "$triple" --show-bin-path)/Clothespeg" "$OUT/Clothespeg-$1"
}

# A universal binary, so it runs on Apple silicon and on Intel Macs, from
# macOS 14 Sonoma onwards.
OUT="$(mktemp -d)"
build_arch arm64
build_arch x86_64
lipo -create "$OUT/Clothespeg-arm64" "$OUT/Clothespeg-x86_64" -output "$OUT/Clothespeg"
BIN="$OUT/Clothespeg"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clothespeg"

# Icon: a static master at scripts/AppIcon.png (1024, transparent rounded
# corners), converted once from the designer's JPG. The old generator
# (make-icon.swift) drew it in code; a drawn icon lost to a real one.
WORK="$(mktemp -d)"
cp scripts/AppIcon.png "$WORK/icon.png"
ICONSET="$WORK/Clothespeg.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Clothespeg.icns"
rm -rf "$WORK"

# Translations: one folder per language, listed in Info.plist so macOS knows
# which languages the app speaks. The peg art rides along the same way, and
# so does the pushpin a pinned card wears in place of its clip.
cp Sources/Clothespeg/Resources/Peg.png "$APP/Contents/Resources/"
cp Sources/Clothespeg/Resources/Pushpin.png "$APP/Contents/Resources/"
LANGUAGES=""
for dir in Sources/Clothespeg/Resources/*.lproj; do
  cp -R "$dir" "$APP/Contents/Resources/"
  LANGUAGES="$LANGUAGES<string>$(basename "$dir" .lproj)</string>"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundleDisplayName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Clothespeg</string>
  <key>CFBundleIconFile</key><string>Clothespeg</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LANGUAGES}</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign the app.
#
# **Whatever this machine has.** The original took the first `Developer ID
# Application` the keychain listed and signed with that, which is only correct
# while there is exactly one — and this keychain also holds another app's
# self-signed development certificate. That one does not match the pattern
# today, so the build came out right, but "right because the other certificate
# happens not to look like this one" is not a thing to ship releases on.
#
# So: the certificate to release under is passed in, rather than guessed.
# A release build names it, and the signature is read back afterwards to
# confirm the team — a release signed by the wrong certificate opens on the
# machine that built it and nowhere else, and that is worth a hard stop. A
# debug build signs ad hoc when nothing is named, which is all it needs: it
# only ever has to open on the machine it was built on.
#
# The name is not a secret and is not hidden anywhere: every app signed with a
# Developer ID shows that company's name in Gatekeeper, and anyone can read
# it with `codesign -dv`. Only the private key stays on its own machine, and
# only the keychain holding it can produce a signature.
#
#   scripts/build-app.sh debug
#   SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
#     scripts/build-app.sh release
#
# With a name but no matching certificate in the keychain, a release stops and
# says so. Without a name, a release is signed with the first Developer ID
# found, and if there is none it falls back to ad hoc with that stated plainly
# rather than quietly.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
RELEASE_TEAM="${RELEASE_TEAM:-}"
IDENTITY="$SIGN_IDENTITY"

if [ -z "$IDENTITY" ]; then
  # Not named: take a Developer ID if there is one, else sign ad hoc below.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi

# A named certificate that is not there is a mistake worth stopping for — the
# build would otherwise fall back to the first certificate found, which is the
# exact mistake naming it was meant to prevent.
if [ -n "$SIGN_IDENTITY" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  echo "ERROR: ${SIGN_IDENTITY} is not in this keychain." >&2
  echo "Check the name, or drop SIGN_IDENTITY to sign with whatever is here." >&2
  exit 1
fi

if [ -n "$IDENTITY" ]; then
  # The Lite build signs with its entitlements, so the sandbox the store
  # expects is really on the binary; the entitlements themselves are the
  # sandbox and the folder access a watched folder needs.
  if [ "$LITE" = "1" ]; then
    codesign --force --options runtime --timestamp --entitlements scripts/ClothespegLite.entitlements --sign "$IDENTITY" "$APP"
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  fi
  # Ask the binary, not the script. An ad-hoc signature looks identical from
  # here and is the one that stops opening anywhere else.
  #
  # `Authority` is not printed by every codesign version; the team is the part
  # that is checked, and the identity is echoed from what the build was told
  # to use so the line is never blank.
  SIGNED_TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if [ -n "$RELEASE_TEAM" ] && [ "$SIGNED_TEAM" != "$RELEASE_TEAM" ]; then
    echo "ERROR: signed with team '${SIGNED_TEAM:-none}', expected '${RELEASE_TEAM}'." >&2
    exit 1
  fi
  echo "Signed with $IDENTITY (team ${SIGNED_TEAM:-none}, hardened runtime + secure timestamp)"
else
  if [ "$LITE" = "1" ]; then
    codesign --force --deep --entitlements scripts/ClothespegLite.entitlements --sign - "$APP" >/dev/null
  else
    codesign --force --deep --sign - "$APP" >/dev/null
  fi
  echo "Signed ad hoc (no Developer ID in this keychain)"
  # Said out loud, because a release that is ad hoc is not the thing to
  # publish and nothing else in the build will say so.
  if [ "$CONFIG" = "release" ] || [ "$LITE" = "1" ]; then
    echo "NOTE: this is a release build with no Developer ID, so it will only open on this machine."
    echo "      To publish one, export SIGN_IDENTITY with the certificate to release under."
  fi
fi
echo "Built $APP"
