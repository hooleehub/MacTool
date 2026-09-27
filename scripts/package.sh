#!/bin/bash
# 打包 MacTool 为 DMG:./scripts/package.sh
# 产物:build/MacTool-<版本>.dmg(通用二进制,Apple 芯片 + Intel,ad-hoc 签名)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
STAGE="$BUILD/dmg-stage"

echo "==> 编译 Release(arm64 + x86_64)"
xcodebuild -project MacTool.xcodeproj -scheme MacTool -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  clean build -quiet

APP="$DERIVED/Build/Products/Release/MacTool.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD/MacTool-$VERSION.dmg"

echo "==> 签名(ad-hoc)并校验"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/MacTool"

echo "==> 生成 DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'EOF'
MacTool 安装说明

1. 把 MacTool 拖到右侧的「Applications」(应用程序)文件夹。
2. 第一次打开时,macOS 会提示"无法验证开发者"(本应用未经 Apple 公证):
   - 打开「系统设置 > 隐私与安全性」,滚动到底部,点击 MacTool 旁的「仍要打开」;
   - 或在终端执行:xattr -dr com.apple.quarantine /Applications/MacTool.app
3. 打开后 MacTool 显示在屏幕顶部菜单栏(没有程序坞图标),点击即可展开面板。

系统要求:macOS 15 或更高版本,Apple 芯片或 Intel 均可。
EOF
hdiutil create -volname "MacTool $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

echo "==> 完成:$DMG ($(du -h "$DMG" | cut -f1))"
