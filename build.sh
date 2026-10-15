#!/bin/zsh
# Zippie.app 만들기: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Zippie

APP=Zippie.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Zippie "$APP/Contents/MacOS/Zippie"

# 아이콘: Icon Composer로 만든 Icon/AppIcon.icon을 컴파일한다.
# macOS 26은 Assets.car의 Liquid Glass 아이콘을, 그 이전 macOS는 AppIcon.icns를 쓴다.
xcrun actool Icon/AppIcon.icon --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Zippie</string>
  <key>CFBundleDisplayName</key><string>Zippie</string>
  <key>CFBundleIdentifier</key><string>com.mxvixxn.zippie</string>
  <key>CFBundleExecutable</key><string>Zippie</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Finder 우클릭 → 빠른 동작/서비스 메뉴. NSRequiredContext가 있어야 처음부터 켜진 상태로 나온다 -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Zippie로 압축</string></dict>
      <key>NSMessage</key><string>compressFiles</string>
      <key>NSPortName</key><string>Zippie</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.item</string><string>public.folder</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Zippie로 풀기</string></dict>
      <key>NSMessage</key><string>extractFiles</string>
      <key>NSPortName</key><string>Zippie</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.zip-archive</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>ZIP 압축 파일</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.zip-archive</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>파일 및 폴더</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.item</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "완료: $PWD/$APP"
