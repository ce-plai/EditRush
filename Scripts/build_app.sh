#!/bin/zsh
# Builds EditRush.app into ./build (release by default).  Usage: Scripts/build_app.sh [debug|release]
set -e
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG" --product EditRush
BIN="$(swift build -c "$CONFIG" --show-bin-path)/EditRush"
APP=build/EditRush.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EditRush"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>EditRush</string>
  <key>CFBundleDisplayName</key><string>EditRush</string>
  <key>CFBundleIdentifier</key><string>local.editrush.EditRush</string>
  <key>CFBundleExecutable</key><string>EditRush</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>EditRush Project</string>
      <key>CFBundleTypeExtensions</key><array><string>editrush</string></array>
      <key>LSItemContentTypes</key><array><string>local.editrush.project</string></array>
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
      <key>UTTypeIdentifier</key><string>local.editrush.project</string>
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
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
