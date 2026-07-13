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

echo "→ 刷新内置价目快照 (pricing-snapshot.json)..."
# 每次构建从线上表拉一份塞进 app 资源：用户机器拉不到 usagebar.cn 时（公司安全软件拦 app 进程、
# 离线首启…）靠它兜底，不至于全员 $0。新鲜度 = 发版日；装上后 app 仍会照常拉线上表更新。
# 校验通过才覆盖——拉挂了 / 拉到残表就沿用仓库里那份旧快照，绝不把好快照冲坏。
SNAPSHOT="$PROJECT_DIR/Sources/usageBar/pricing-snapshot.json"
SNAPSHOT_TMP="$(mktemp -t pricing-snapshot)"
if curl -sf --max-time 30 https://usagebar.cn/pricing.json -o "$SNAPSHOT_TMP" \
   && python3 -c "
import json, sys
d = json.load(open('$SNAPSHOT_TMP'))
n = len(d.get('providers', {}))
assert n >= 30, f'厂商数只有 {n}，疑似残表'
print(f'   厂商数 {n} ✓')
"; then
  mv "$SNAPSHOT_TMP" "$SNAPSHOT"
  echo "   快照已更新: $(du -h "$SNAPSHOT" | cut -f1)"
else
  rm -f "$SNAPSHOT_TMP"
  echo "   ⚠️ 拉取/校验失败，沿用仓库里的旧快照（app 仍会在用户机器上拉线上表）"
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

echo "→ 建本地化 .lproj（让 Sparkle 等框架按系统语言显示中文/英文 UI）..."
for loc in zh-Hans en; do
  mkdir -p "$APP_DIR/Contents/Resources/$loc.lproj"
  # 放个最小占位文件，确保 .lproj 被 NSBundle 识别 + 被 codesign 正确封装
  : > "$APP_DIR/Contents/Resources/$loc.lproj/Localizable.strings"
done

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
# 背景图（虚线弧形箭头 + 底部双语拖拽提示）。best-effort：生成失败就退化成无背景裸图标，不挡发版。
# 多分辨率 TIFF（1x+2x）保证 Retina 下箭头/文字清晰。
BG_STMT=""
mkdir -p "$DMG_STAGE/.background"
if swift "$PROJECT_DIR/Scripts/make-dmg-background.swift" "$DMG_STAGE/.background" >/dev/null 2>&1 \
   && tiffutil -cathidpicheck "$DMG_STAGE/.background/background.png" "$DMG_STAGE/.background/background@2x.png" \
        -out "$DMG_STAGE/.background/background.tiff" >/dev/null 2>&1; then
  rm -f "$DMG_STAGE/.background/background.png" "$DMG_STAGE/.background/background@2x.png"
  BG_STMT='set background picture of theVO to file ".background:background.tiff"'
else
  echo "  ⚠️ DMG 背景图生成失败，退化为无背景裸图标（不影响安装功能）"
  rm -rf "$DMG_STAGE/.background"
fi
rm -f "$DIST_DIR/usageBar.dmg" "$DIST_DIR/usageBar-rw.dmg"
# 1) 先建可读写 DMG(留余量给 .DS_Store)
hdiutil create -volname "usageBar" -srcfolder "$DMG_STAGE" -ov -format UDRW -size 40m "$DIST_DIR/usageBar-rw.dmg" >/dev/null
# 2) 挂载 + AppleScript 摆窗口/图标(best-effort;失败只是不美化,不影响安装功能)
hdiutil attach "$DIST_DIR/usageBar-rw.dmg" -readwrite -noverify -noautoopen >/dev/null
# ⚠️ 非引号 heredoc：要插值 $BG_STMT；AppleScript 正文里没有 $ / 反引号，安全。
osascript <<APPLESCRIPT 2>/dev/null || echo "  ⚠️ DMG 美化未生效(可能需在 系统设置→隐私与安全性→自动化 给终端授权控制 Finder);DMG 功能正常"
tell application "Finder"
  tell disk "usageBar"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, 800, 580}
    set theVO to the icon view options of container window
    set arrangement of theVO to not arranged
    set icon size of theVO to 104
    set text size of theVO to 12
    $BG_STMT
    set position of item "usageBar.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
hdiutil detach "/Volumes/usageBar" >/dev/null 2>&1 || hdiutil detach "/Volumes/usageBar" -force >/dev/null 2>&1
# 3) 转成压缩只读
hdiutil convert "$DIST_DIR/usageBar-rw.dmg" -format UDZO -o "$DIST_DIR/usageBar.dmg" >/dev/null
rm -f "$DIST_DIR/usageBar-rw.dmg"
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
    # 下载地址钉死本版 release。⚠️ 别改回 latest/download——两版连发时「旧 appcast(缓存) +
    # latest 已指新包」会错位,用户下到新 zip 验旧签名 → Sparkle 报"此更新未正确签名"
    # (2026-07-09 v0.3.16/17 同晚连发实锤踩过);版本化 URL 让每份 appcast 钉死自己的资产,根治该族竞态
    "$GEN_APPCAST" \
      --download-url-prefix "https://github.com/ChanningYuan/usageBar/releases/download/v${APP_VER}/" \
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

# 「给 AI 装」自 2026-06-30 起改为**远程 skill.md**（https://usagebar.cn/skill.md）+
# **火山镜像**（https://usagebar.cn/dl/usageBar.zip，服务器 cron 每天自动从 GitHub release
# 同步 usageBar.zip）。skill 让 agent 现拉 usageBar.zip 安装，不再随包分发。
# 故本脚本**不再生成** usageBar.tar.gz / install-usagebar.zip（旧本地 zip 安装方式已废弃，
# 该方式 8 个版本累计 0 下载）。需要镜像更新时由服务器 cron 自动完成，无需 build 侧介入。

echo ""
echo "✅ 完成"
echo ""
echo "产物："
echo "  $APP_DIR"
echo "  $DIST_DIR/usageBar.dmg                ← DMG 拖拽安装包（给人类，推荐）"
echo "  $DIST_DIR/usageBar.zip                ← 单独 .app zip（Sparkle 更新包 + 镜像/skill 用）"
echo ""
echo "测试本机能跑："
echo "  open $APP_DIR"
echo ""
echo "发版只需上传 release：usageBar.dmg + usageBar.zip（install-usagebar.zip 已停产）。"
echo "「给 AI 装」走 https://usagebar.cn/skill.md + 镜像 /dl/usageBar.zip（服务器 cron 自动同步）。"
