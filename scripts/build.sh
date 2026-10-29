#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
mkdir -p build/module-cache build/helper-src dist
UPSTREAM=52ba05dca4bdc590672c19d554701f4438e20338
[ "$(git -C upstream/AirCard rev-parse HEAD)" = "$UPSTREAM" ] || { echo 'Unexpected upstream revision' >&2; exit 1; }
git -C upstream/AirCard diff --quiet HEAD -- || { echo "Modified upstream source; refusing build" >&2; exit 1; }
# Security-reviewed constrained AirCard helpers generated from the pinned source.
/usr/bin/python3 scripts/prepare_helper.py
/usr/bin/python3 scripts/prepare_artwork.py
OUTPUT_APP="$PWD/dist/WalletSkin Studio.app"
BUILD_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/walletskin-build.XXXXXX")"
trap 'rm -rf "$BUILD_STAGING"; if [ -n "${STAGING:-}" ]; then rm -rf "$STAGING"; fi' EXIT
APP="$BUILD_STAGING/WalletSkin Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
  xcrun clang -fobjc-arc -O2 -Wall -Wextra -arch "$ARCH" -mmacosx-version-min=14.0 -framework Foundation -framework CoreFoundation /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice build/helper-src/device_helper.m -o "build/device_helper_$ARCH"
  xcrun clang -fobjc-arc -O2 -Wall -Wextra -arch "$ARCH" -mmacosx-version-min=14.0 -framework Foundation -framework CoreFoundation /System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost build/helper-src/airtraffic_host.m -o "build/airtraffic_host_$ARCH"
  xcrun swiftc -sdk "$SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" -O -parse-as-library -target "$ARCH-apple-macosx14.0" Sources/*.swift -o "build/WalletSkinStudio_$ARCH"
done
lipo -create build/device_helper_arm64 build/device_helper_x86_64 -output "$APP/Contents/Resources/bin/device_helper"
lipo -create build/airtraffic_host_arm64 build/airtraffic_host_x86_64 -output "$APP/Contents/Resources/bin/airtraffic_host"
lipo -create build/WalletSkinStudio_arm64 build/WalletSkinStudio_x86_64 -output "$APP/Contents/MacOS/WalletSkinStudio"
cp -R Resources/StarterDesigns "$APP/Contents/Resources/StarterDesigns"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp scripts/validate_stage.py "$APP/Contents/Resources/validate_stage.py"
cp Resources/aircard_artwork.py "$APP/Contents/Resources/aircard_artwork.py"
cp Resources/bridge.py "$APP/Contents/Resources/bridge.py"
cp upstream/AirCard/LICENSE "$APP/Contents/Resources/AirCard-LICENSE.txt"
cp docs/SECURITY.md "$APP/Contents/Resources/SECURITY.md"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WalletSkinStudio</string>
<key>CFBundleIdentifier</key><string>local.walletskin.studio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>WalletSkin Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleDevelopmentRegion</key><string>he</string>
<key>CFBundleLocalizations</key><array><string>he</string><string>en</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/bin/device_helper"
codesign --force --sign - "$APP/Contents/Resources/bin/airtraffic_host"
# File-provider folders may add FinderInfo to a locally generated bundle.
# Remove only this non-security metadata; never clear quarantine.
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
ditto --norsrc --noextattr "$APP" "$OUTPUT_APP"
if [ "${SKIP_DMG:-0}" != 1 ]; then
 STAGING="$(mktemp -d "${TMPDIR:-/tmp}/walletskin-dmg.XXXXXX")"
 ditto --norsrc --noextattr "$APP" "$STAGING/WalletSkin Studio.app"
 codesign --verify --strict "$STAGING/WalletSkin Studio.app"
 ln -s /Applications "$STAGING/Applications"
 cp README.md "$STAGING/README-he.md"
 mkdir -p "$STAGING/Resources"
 cp -R Resources/StarterDesigns "$STAGING/Resources/StarterDesigns"
 cat > "$STAGING/START-HERE.txt" <<'GUIDE'
WalletSkin Studio — התחלה מהירה

1. גררו את WalletSkin Studio אל Applications.
2. פתחו את האפליקציה מתוך Applications.
3. אם תופיע הכנה חד-פעמית, השתמשו בכפתור התקנת רכיב Apple.
4. עקבו אחרי שלבים 1–4 בראש האפליקציה.

מדריך מלא בעברית עם תמונות:
https://github.com/razmazlih/walletskin-studio#readme

החלה על iPhone היא ניסיונית: סיכון לנתוני Books, ללא שחזור מאומת לתמונת המקור.
GUIDE
 cp -R docs "$STAGING/docs"
 hdiutil create -volname 'WalletSkin Studio' -srcfolder "$STAGING" -ov -format UDZO "$PWD/dist/WalletSkin Studio.dmg"
 hdiutil verify "$PWD/dist/WalletSkin Studio.dmg"
fi
echo "Built: $OUTPUT_APP"
