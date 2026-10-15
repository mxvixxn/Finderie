#!/bin/zsh
# Finderie.app 만들기: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Finderie

APP=Finderie.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Finderie "$APP/Contents/MacOS/Finderie"

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
  <key>CFBundleName</key><string>Finderie</string>
  <key>CFBundleDisplayName</key><string>Finderie</string>
  <key>CFBundleIdentifier</key><string>com.mxvixxn.finderie</string>
  <key>CFBundleExecutable</key><string>Finderie</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Finder 확장(FinderieExtension.appex)이 앱을 부르는 주소 -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.mxvixxn.finderie.finder-link</string>
      <key>CFBundleURLSchemes</key><array><string>finderie</string></array>
    </dict>
  </array>
  <!-- Finder 우클릭 → 빠른 동작/서비스 메뉴. NSRequiredContext가 있어야 처음부터 켜진 상태로 나온다 -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Finderie로 압축</string></dict>
      <key>NSMessage</key><string>compressFiles</string>
      <key>NSPortName</key><string>Finderie</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.item</string><string>public.folder</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Finderie로 풀기</string></dict>
      <key>NSMessage</key><string>extractFiles</string>
      <key>NSPortName</key><string>Finderie</string>
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

# Finder 확장: 우클릭 메뉴 맨 위의 "Finderie로 압축 / 풀기"
APPEX="$APP/Contents/PlugIns/FinderieExtension.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp Extension/Info.plist "$APPEX/Contents/Info.plist"
xcrun swiftc -O -module-name FinderieExtension -parse-as-library -application-extension \
  -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path)" \
  Extension/FinderSync.swift -framework FinderSync -framework Cocoa \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$APPEX/Contents/MacOS/FinderieExtension"
codesign --force --sign - --entitlements Extension/FinderieExtension.entitlements "$APPEX"

# 앱 서명 (확장을 먼저 서명했으니 --deep은 쓰지 않는다)
codesign --force --sign - "$APP"
echo "완료: $PWD/$APP"
