#!/bin/zsh
# Builds EditRush.app into ./build (release by default).  Usage: Scripts/build_app.sh [debug|release]
#   VERSION=1.2   marketing version (default 1.0)
#   BUILD=57      bundle version Sparkle compares; must increase every release (default: commit count)
#   UNIVERSAL=1   build for Apple Silicon and Intel
set -e
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
VERSION=${VERSION:-1.0}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
ARCH_FLAGS=()
[ -n "$UNIVERSAL" ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product EditRush $ARCH_FLAGS
BIN_DIR="$(swift build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)"
APP=build/EditRush.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/EditRush" "$APP/Contents/MacOS/EditRush"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>EditRush</string>
  <key>CFBundleDisplayName</key><string>EditRush</string>
  <key>CFBundleIdentifier</key><string>ai.pl.editrush</string>
  <key>CFBundleExecutable</key><string>EditRush</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>EditRush uses the microphone to record voiceovers onto your timeline.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>EditRush Project</string>
      <key>CFBundleTypeExtensions</key><array><string>editrush</string></array>
      <key>LSItemContentTypes</key><array><string>ai.pl.editrush.project</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Media</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.audio</string>
        <string>public.image</string>
      </array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>ai.pl.editrush.project</string>
      <key>UTTypeDescription</key><string>EditRush Project</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeIconFile</key><string>AppIcon</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>editrush</string></array>
      </dict>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>EditRush — a fast, simple video editor.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>SUFeedURL</key><string>https://github.com/ce-plai/EditRush/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>cfmGFt3NZ2a7g3d8JqM8VcvPrvkC/AmBXSnRvxVRNXg=</string>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements Resources/EditRush.entitlements "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
