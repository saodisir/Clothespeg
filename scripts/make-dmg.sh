#!/bin/bash
# Builds Clothespeg.app and packs it into a disk image for releases.
# Usage: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Clothespeg.app/Contents/Info.plist)"
DMG="build/Clothespeg-$VERSION.dmg"
NAME="Clothespeg"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R build/Clothespeg.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-dmg-background.swift "$WORK/bg1x.png" 1
swift scripts/make-dmg-background.swift "$WORK/bg2x.png" 2
# One TIFF holding both resolutions, so the window is sharp on Retina.
tiffutil -cathidpicheck "$WORK/bg1x.png" "$WORK/bg2x.png" -out "$STAGE/.background/background.tiff" >/dev/null

RW="$WORK/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -size 60m "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"

# Tiling window managers resize the window, and Finder would save that size
# into the image. Pause AeroSpace while laying it out, if it is running.
if command -v aerospace >/dev/null && pgrep -qx AeroSpace; then
  aerospace enable off
  trap 'aerospace enable on' EXIT
fi

# Lay out the window. Needs permission to control Finder; without it the
# image still works, just with Finder's default layout.
osascript <<OSA || echo "Finder layout skipped"
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 528}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Clothespeg.app" of container window to {160, 178}
    set position of item "Applications" of container window to {440, 178}
    -- Size last: Finder can resize the window while it applies the options.
    set the bounds of container window to {200, 120, 800, 528}
    update without registering applications
    delay 1
    set the bounds of container window to {200, 120, 800, 528}
    delay 1
    close
  end tell
end tell
OSA

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach -quiet "$MOUNT"
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$WORK"
echo "Built $DMG"

# Sign the disk image, send it to Apple for notarization and staple the
# ticket, so it opens without warnings even offline. Needs a Developer ID and
# notary credentials stored with:
#   xcrun notarytool store-credentials clothespeg-notary --apple-id ... --team-id ...
#
# **The image must be signed by the same certificate as the app inside it.**
# An image signed by a different one means the signature on the image says
# nothing about the app within, which is the state this repository was
# briefly in: `build-app.sh` named one certificate and this took the first
# Developer ID the keychain listed, so a fork could produce an image whose
# signature belonged to nobody in particular.
#
# So the certificate is passed in, the same way `build-app.sh` takes it:
#   SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/make-dmg.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
RELEASE_TEAM="${RELEASE_TEAM:-}"
IDENTITY="$SIGN_IDENTITY"

if [ -z "$IDENTITY" ]; then
  # Not named: take the first Developer ID, which is also what `build-app.sh`
  # fell back to, so the two agree when neither was given anything.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi

PROFILE="${NOTARY_PROFILE:-clothespeg-notary}"
if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  SIGNED_TEAM="$(codesign -dv "$DMG" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if [ -n "$RELEASE_TEAM" ] && [ "$SIGNED_TEAM" != "$RELEASE_TEAM" ]; then
    echo "ERROR: image signed with team '${SIGNED_TEAM:-none}', expected '${RELEASE_TEAM}'." >&2
    exit 1
  fi
  echo "Image signed with $IDENTITY (team ${SIGNED_TEAM:-none})"
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Notarizing, this usually takes a few minutes..."
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  else
    echo "No notary credentials in profile $PROFILE: the image is signed but not notarized."
  fi
else
  echo "NOTE: no Developer ID in this keychain, so the image is not signed." >&2
  echo "      It will only open on this machine. Export SIGN_IDENTITY to sign it." >&2
fi

# Keep the Homebrew cask in step: new version and the checksum of this image.
# Set TAP_DIR to the tap checkout; nothing is committed or pushed here, so the
# cask never points at a release that is not on GitHub yet.
TAP_DIR="${TAP_DIR:-$HOME/homebrew-tap}"
CASK="$TAP_DIR/Casks/clothespeg.rb"
if [ -f "$CASK" ]; then
  SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  echo "Updated $CASK to $VERSION ($SHA)"
  echo "After publishing the release: commit and push the tap."
else
  echo "No Homebrew cask at $CASK, skipped."
fi
