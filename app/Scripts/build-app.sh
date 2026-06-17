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

echo "→ 嵌入 Sparkle.framework (自动更新)..."
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto "$BUILD_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
# 让主程序运行时能在 .app/Contents/Frameworks 找到 Sparkle（rpath 必须在签名前改好）
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/usageBar" 2>/dev/null || true

echo "→ 写 PkgInfo..."
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

if [ "$DO_SIGN" = "1" ]; then
  echo "→ 代码签名 (Developer ID + Hardened Runtime)..."
  # 先签 Sparkle.framework 内部嵌套代码(inside-out)：XPC → Updater.app → Autoupdate → framework
  SPK="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
  for nested in \
    "$SPK/XPCServices/Downloader.xpc" \
    "$SPK/XPCServices/Installer.xpc" \
    "$SPK/Updater.app" \
    "$SPK/Autoupdate"; do
    codesign --force --options runtime --timestamp --sign "$DEV_ID" "$nested"
  done
  codesign --force --options runtime --timestamp \
    --sign "$DEV_ID" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  # 再签内层资源 bundle，最后签外层 app（公证要求所有嵌套 bundle 都签）
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
# ⚠️ 必须用 ditto,不能用 `zip -r`——zip 会把 Sparkle.framework 的符号链接(Versions/Current 等)
# 展开成真实目录,导致框架结构损坏、解压后 app "已损坏"无法打开(Sparkle 更新和人类 zip 下载都会中招)。
# ditto 保留符号链接。
rm -f usageBar.zip
ditto -c -k --keepParent usageBar.app usageBar.zip

echo "→ 打 DMG (拖拽安装界面)..."
DMG_STAGE="$DIST_DIR/dmg-stage"
rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
cp -R "$APP_DIR" "$DMG_STAGE/usageBar.app"
ln -s /Applications "$DMG_STAGE/Applications"   # 拖进去就装
rm -f "$DIST_DIR/usageBar.dmg"
hdiutil create -volname "usageBar" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DIST_DIR/usageBar.dmg" >/dev/null
rm -rf "$DMG_STAGE"
if [ "$DO_SIGN" = "1" ]; then
  echo "→ 签名 + 公证 DMG..."
  codesign --force --timestamp --sign "$DEV_ID" "$DIST_DIR/usageBar.dmg"
  xcrun notarytool submit "$DIST_DIR/usageBar.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DIST_DIR/usageBar.dmg"
  echo "✓ DMG 已签名 + 公证 + 装订"
fi

# 生成 appcast.xml（Sparkle 自动更新源：用 EdDSA 私钥给 usageBar.zip 签名 + 写版本/下载地址）
if [ "$DO_SIGN" = "1" ]; then
  echo "→ 生成 appcast.xml..."
  GEN_APPCAST=$(find "$PROJECT_DIR/.build" -name generate_appcast -path '*artifacts*' 2>/dev/null | head -1)
  if [ -n "$GEN_APPCAST" ] && [ -x "$GEN_APPCAST" ]; then
    APPCAST_STAGE="$DIST_DIR/appcast-stage"
    rm -rf "$APPCAST_STAGE"; mkdir -p "$APPCAST_STAGE"
    cp "$DIST_DIR/usageBar.zip" "$APPCAST_STAGE/"
    APP_VER=$(defaults read "$APP_DIR/Contents/Info" CFBundleShortVersionString)
    # 下载地址用 latest/download —— GitHub 永远重定向到最新 release 的同名资产,免得每版改 URL
    "$GEN_APPCAST" \
      --download-url-prefix "https://github.com/ChanningYuan/usageBar/releases/latest/download/" \
      "$APPCAST_STAGE"
    # 把 CHANGELOG 当前版本段落**内联**进 appcast 的 <description>（更新弹窗直接显示，无需托管 html）
    python3 "$PROJECT_DIR/Scripts/inject-release-notes.py" "$APPCAST_STAGE/appcast.xml" "$PROJECT_DIR/../CHANGELOG.md" "$APP_VER" || true
    cp "$APPCAST_STAGE/appcast.xml" "$PROJECT_DIR/../appcast.xml"
    rm -rf "$APPCAST_STAGE"
    echo "✓ appcast.xml 已生成: $(cd "$PROJECT_DIR/.." && pwd)/appcast.xml"
  else
    echo "⚠️  找不到 generate_appcast,跳过 appcast 生成"
  fi
fi

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
echo "  $DIST_DIR/usageBar.dmg                ← DMG 拖拽安装包（给人类，推荐）"
echo "  $DIST_DIR/usageBar.zip                ← 单独 .app zip（备选）"
if [ -d "$PROJECT_DIR/../install-usagebar" ]; then
  echo "  $(cd "$PROJECT_DIR/.." && pwd)/install-usagebar.zip   ← skill 完整包（发同事用）"
fi
echo ""
echo "测试本机能跑："
echo "  open $APP_DIR"
echo ""
echo "发同事 skill 包："
echo "  $(cd "$PROJECT_DIR/.." && pwd)/install-usagebar.zip"
