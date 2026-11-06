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
# 1.10.0 is a minor: a picture that holds a QR code now says what the code
# says — right-click to copy the contents or to follow a link, the space bar
# to read it under the picture. Nothing else about a picture changes: it is
# still a picture, and copies and drags as itself. The reading happens once,
# in the background, a tenth of a second after the card hangs.
#
# It also carries one fix that was written as 1.9.3 and never released: a
# repeated reminder that rings while the Mac is asleep or the app is shut now
# shows its 知道了 when the person comes back. The lit card used to be a memory
# of having heard the ring, and a sleeping machine hears nothing — the banner
# arrived on its own and the card could only say 下次. The light is now worked
# out from the reminder's last turn and the turn that was answered, so waking
# up (or opening the app) is enough to see it.
#
# 1.11.0 is a minor: the search field now finds a picture by the words on it.
# A screenshot of a report used to be findable only by the name it was saved
# under — `SCR-20261029-0912.png`, which is not what anybody remembers about
# it. Each picture is now read once, in the background, and what it says joins
# everything else a card is searched by: its words, its file's path, the app it
# came from, and the code in it. Nothing on the card changes, the reading
# happens once in a picture's life rather than once per launch, and no model is
# bundled — the reader ships with macOS, so the download stays under 4 MB.
#
# Two more, gathered while that was being built. Editing a picture by
# long-press now opens it in Preview rather than the system Markup sheet: that
# sheet is a fixed-size overlay drawn by another process, with no title bar to
# drag and no size to change, and a picture nobody can zoom is a picture nobody
# edits comfortably. And a line that has to be flipped to reach a ringing note
# now flips there by itself and centres it — the bell was easy to miss on the
# second page.
#
# Reminders also catch up after sleep. A turn that passed while the Mac was
# asleep used to be skipped for being late; it is now delivered once, on waking,
# and a duplicate that the system already showed is not shown twice.
#
# 2.0.0 is a major: taking a screenshot is a capture of its own now, and the
# biggest thing in it is a change of rule — everything only *selects*. A drag,
# a click on a window and the space bar used to fire, and a frame that fired
# was a frame nobody could adjust; now they choose, and Return (or a double
# click on the frame) takes the picture, so the same gesture can be corrected
# before it counts.
#
# The bar under the frame follows from that. It lost its words and became six
# icons with their keys in the corner — `R` shape, `L` long, `W` words, `T`
# translate, `A` again, `E` edit — and two of them are new: 编辑 takes the
# picture and opens it in the editor in one move, and 重截 puts the last frame
# back where it was and waits, lit, until you press Return, instead of
# photographing a rectangle you cannot see.
#
# The bar also dresses the way the rest of the app does now: light where the app
# is light, dark where it is dark, with the same surface as the editor's own
# floating bar. Every capture used to wear one hardcoded dark surface, which in
# a light-mode app was the one thing on screen that came from a different one.
#
# And a capture can photograph this app now. The clipboard line, the editor and
# a pinned picture were all left out of every picture — including their pixels
# in a selection, which is a hole nobody asked for. The line has the same
# standing as anything else on the screen, which is the rule macOS itself
# follows.
#
# One fix in the editor: a colour is the pen's, not the mark's. Choosing black
# from the well while a mark was still selected recoloured that mark and left
# the pen red, so the same colour had to be chosen again for every annotation.
# 2.1.0 is the icon, and three things behind it. The plate used to hold one
# card and a wooden peg — the picture of a clipboard, which this stopped being
# a while ago: it takes pictures, keeps them clipped, and hangs notes beside
# them. It now holds two cards, one a picture and one a page of words, with a
# camera's corner marks around them, so the three things it does are visible
# before anything is opened.
#
# The translate button gained a language. It used to mean one fixed answer; it
# now carries a shortlist of ten, kept as language codes, and which one it uses
# is chosen from the button's own menu — the settings page only says what the
# menu offers. The button shows an arrow for it and no language name, because a
# name at that size was a word nobody could read.
#
# Two things stopped happening twice. A capture is written into the folder the
# screenshot inbox watches, so it arrived twice: one card, since the line keeps
# one card per thing, but two pegs going in and two sounds. And a maximised
# window whose first row sits a point inside the menu bar's strip answered for
# the menu bar, so clicking it put the line away; the strip is now only the
# cheap test and the window server is asked what the click reached.
VERSION="2.2.0"

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
  <key>CFBundleVersion</key><string>15</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LANGUAGES}</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Clothespeg uses the microphone to record a voice memo on a note.</string>
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

# Both builds are hardened, so both need Audio Input on the *binary*. An
# entitlements file sitting in scripts/ proves nothing; the microphone
# request is refused before TCC can ask if the signature has no such key.
# Lite has its own (sandbox + file access) and the regular build has only
# this one.
if [ "$LITE" = "1" ]; then
  ENTITLEMENTS="scripts/ClothespegLite.entitlements"
else
  ENTITLEMENTS="scripts/Clothespeg.entitlements"
fi

if [ -n "$IDENTITY" ]; then
  # The Lite build signs with its entitlements, so the sandbox the store
  # expects is really on the binary; the entitlements themselves are the
  # sandbox and the folder access a watched folder needs.
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
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
  codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP" >/dev/null
  echo "Signed ad hoc (no Developer ID in this keychain)"
  # Said out loud, because a release that is ad hoc is not the thing to
  # publish and nothing else in the build will say so.
  if [ "$CONFIG" = "release" ] || [ "$LITE" = "1" ]; then
    echo "NOTE: this is a release build with no Developer ID, so it will only open on this machine."
    echo "      To publish one, export SIGN_IDENTITY with the certificate to release under."
  fi
fi
# An entitlements file in scripts/ is not proof that the *binary* carries it.
# Ask the signature, and stop the build rather than shipping another app that
# silently loses its microphone request.
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
case "$SIGNED_ENTITLEMENTS" in
  *com.apple.security.device.audio-input*) ;;
  *) echo "ERROR: $APP has no audio-input entitlement on its signature." >&2
     exit 1 ;;
esac
echo "Built $APP"
