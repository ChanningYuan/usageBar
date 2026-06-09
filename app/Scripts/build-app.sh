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

# ── 签名 / 公证配置（可用环境变量覆盖）──
# 只有当本机存在对应 Developer ID 证书、且未显式 SIGN=0 时才签名+公证；
# 否则自动跳过，产出未签名版本（方便没有证书的人 clone 后也能 build）。
DEV_ID="${DEV_ID:-Developer ID Application: Channing Yuan (9RCMA8NVFX)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-usagebar-notary}"
DO_SIGN=0
if [ "${SIGN:-1}" != "0" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEV_ID"; then
  DO_SIGN=1
fi

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

if [ "$DO_SIGN" = "1" ]; then
  echo "→ 代码签名 (Developer ID + Hardened Runtime)..."
  # 先签内层资源 bundle，再签外层 app（inside-out，公证要求所有嵌套 bundle 都签）
  codesign --force --options runtime --timestamp \
    --sign "$DEV_ID" "$APP_DIR/Contents/Resources/usageBar_usageBar.bundle"
  codesign --force --options runtime --timestamp \
    --sign "$DEV_ID" "$APP_DIR"
  codesign --verify --strict --verbose=1 "$APP_DIR"

  echo "→ 提交公证 (notarytool，通常几分钟)..."
  ditto -c -k --keepParent "$APP_DIR" "$DIST_DIR/usageBar-notarize.zip"
  xcrun notarytool submit "$DIST_DIR/usageBar-notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$DIST_DIR/usageBar-notarize.zip"

  echo "→ 装订公证票据 (stapler)..."
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  echo "✓ 已签名 + 公证 + 装订"
else
  echo "⚠️  跳过签名+公证（无对应 Developer ID 证书 或 SIGN=0），产出未签名版本"
fi

echo "→ 打 zip..."
cd "$DIST_DIR"
zip -r -q usageBar.zip usageBar.app

# 自动同步到 install-usagebar skill（如果存在）
SKILL_DIR_PATH="$PROJECT_DIR/../install-usagebar"
if [ -d "$SKILL_DIR_PATH" ]; then
  # ⚠️ skill 的 install.sh 解压的是 usageBar.tar.gz（不是 .zip）——必须从最新 .app
  # 重新生成它，否则 AI 安装会装到旧版（曾出现 .zip 刷新了但 .tar.gz 没刷新的脱节 bug）
  echo "→ 生成 skill 安装包 usageBar.tar.gz..."
  tar -czf "$SKILL_DIR_PATH/usageBar.tar.gz" -C "$DIST_DIR" usageBar.app
  # 清掉历史遗留的冗余 usageBar.zip（skill 不用它，留着会造成版本错乱）
  rm -f "$SKILL_DIR_PATH/usageBar.zip"

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
