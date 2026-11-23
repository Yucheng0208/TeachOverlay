#!/bin/bash
# 編譯 Apple Silicon (arm64) 版本並打包成 TeachOverlay.app
# 用自己的 Developer ID 簽章：SIGN_IDENTITY="Developer ID Application: XXX" ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/TeachOverlay"

APP=build/TeachOverlay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TeachOverlay"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 版權年份依編譯當年自動更新
YEAR=$(date +%Y)
if [ "$YEAR" -gt 2026 ]; then SPAN="2026–$YEAR"; else SPAN="2026"; fi
plutil -replace NSHumanReadableCopyright -string "© $SPAN Yu-Cheng Chang. GPL-3.0" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/AppIcon.png "$APP/Contents/Resources/"
cp Resources/Fonts/*.ttf Resources/Fonts/FontAwesome-LICENSE.txt "$APP/Contents/Resources/"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"

echo "完成：$APP（$(lipo -archs "$APP/Contents/MacOS/TeachOverlay")）"
echo "   執行：open $APP"
