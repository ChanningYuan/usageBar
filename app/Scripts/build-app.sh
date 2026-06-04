#!/bin/bash
# 把 SwiftPM 产物打包成 macOS .app bundle + zip 给同事
# 用法：./Scripts/build-app.sh
#
# 产物：./dist/usageBar.app + ./dist/usageBar.zip
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/usageBar.app"
BUILD_DIR="$PROJECT_DIR/.build/release"

echo "→ 编译 release 模式..."
cd "$PROJECT_DIR"
swift build -c release

echo "→ 清理旧 dist..."
rm -rf "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "→ 复制 binary..."
cp "$BUILD_DIR/usageBar" "$APP_DIR/Contents/MacOS/usageBar"

echo "→ 复制资源 bundle (SVG/PNG 图标)..."
cp -R "$BUILD_DIR/usageBar_usageBar.bundle" "$APP_DIR/Contents/Resources/"

echo "→ 复制 Info.plist..."
cp "$PROJECT_DIR/Sources/usageBar/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "→ 复制 AppIcon.icns..."
cp "$PROJECT_DIR/../icon/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "→ 写 PkgInfo..."
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "→ 打 zip..."
cd "$DIST_DIR"
zip -r -q usageBar.zip usageBar.app

# 自动同步到 install-usagebar skill（如果存在）
SKILL_ZIP="$PROJECT_DIR/../install-usagebar/usageBar.zip"
if [ -d "$PROJECT_DIR/../install-usagebar" ]; then
  cp usageBar.zip "$SKILL_ZIP"
  echo "→ 同步到 skill 包: $(cd "$(dirname "$SKILL_ZIP")" && pwd)/usageBar.zip"

  # 顺手重新打 install-usagebar.zip（顶层分发包）
  SKILL_PARENT="$PROJECT_DIR/.."
  cd "$SKILL_PARENT"
  rm -f install-usagebar.zip
  zip -r -q install-usagebar.zip install-usagebar -x "*.DS_Store"
  echo "→ 重新打 install-usagebar.zip: $(pwd)/install-usagebar.zip"
fi

echo ""
echo "✅ 完成"
echo ""
echo "产物："
echo "  $APP_DIR"
echo "  $DIST_DIR/usageBar.zip                ← 单独 .app zip"
if [ -d "$PROJECT_DIR/../install-usagebar" ]; then
  echo "  $(cd "$PROJECT_DIR/.." && pwd)/install-usagebar.zip   ← skill 完整包（发同事用）"
fi
echo ""
echo "测试本机能跑："
echo "  open $APP_DIR"
echo ""
echo "发同事 skill 包："
echo "  $(cd "$PROJECT_DIR/.." && pwd)/install-usagebar.zip"
