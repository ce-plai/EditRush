#!/bin/zsh
# Builds, signs, notarizes and publishes a release to GitHub.  Usage: Scripts/release.sh <version> [notes.md]
#   e.g. Scripts/release.sh 1.0 notes.md      (DRAFT=1 to create the GitHub release as a draft)
#
# One-time setup:
#   - a "Developer ID Application" certificate in the login Keychain (IDENTITY=... to pick one)
#   - notary credentials:  xcrun notarytool store-credentials editrush-notary --apple-id <id> --team-id <team>
#     (NOTARY_PROFILE=... to use another profile name)
#   - the Sparkle update key in the Keychain (generate_keys --account ai.pl.editrush; back it up with -x)
#   - gh, logged in with push access to the repo
set -e
cd "$(dirname "$0")/.."
VERSION=${1:?usage: Scripts/release.sh <version> [notes.md]}
NOTES_FILE=$2
TAG=v$VERSION
REPO=ce-plai/EditRush
NOTARY_PROFILE=${NOTARY_PROFILE:-editrush-notary}
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"')}

[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the Keychain."; exit 1 }
[ -z "$(git status --porcelain)" ] || { echo "Working tree has uncommitted changes; commit them first."; exit 1 }
[ -n "$(git branch -r --contains HEAD)" ] || { echo "HEAD isn't pushed; push it first."; exit 1 }
! git ls-remote --exit-code --tags origin "$TAG" >/dev/null || { echo "Tag $TAG already exists on origin."; exit 1 }
if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE=build/notes.md
  mkdir -p build && echo "EditRush $VERSION" > "$NOTES_FILE"
fi

echo "==> Building EditRush $VERSION (universal)"
VERSION=$VERSION UNIVERSAL=1 Scripts/build_app.sh release
APP=build/EditRush.app
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")

echo "==> Signing with $IDENTITY"
# Inside-out: Sparkle's helpers, the framework, then the app. Hardened runtime + timestamp for notarization.
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@" }
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$APP"
codesign --verify --strict --deep "$APP"

echo "==> Making DMG"
DMG=build/EditRush.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/EditRush.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname EditRush -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing (usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "==> Writing appcast"
# Only the newest release is listed; that's all Sparkle needs to offer an update.
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account ai.pl.editrush "$DMG")  # sparkle:edSignature="…" length="…"
NOTES_HTML=$(gh api markdown -f text="$(cat "$NOTES_FILE")" -f mode=gfm -f context=$REPO)
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>EditRush</title>
    <item>
      <title>EditRush $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/EditRush.dmg" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML

echo "==> Publishing $TAG"
gh release create "$TAG" "$DMG" build/appcast.xml --repo $REPO --target "$(git rev-parse HEAD)" \
  --title "EditRush $VERSION" --notes-file "$NOTES_FILE" ${DRAFT:+--draft}
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
