#!/usr/bin/env bash
# 组装「未签名 .app 壳」（dev-app）：用 debug 产物拼一个真正的 .app，供签名公证**之前**验收
# 「只认 .app 的功能」——登录项 SMAppService、系统通知、Dock/LaunchServices 行为等。
# 这类功能 debug 裸可执行文件测不出（v0.3.28 开机自启踩过：公证烧完才第一次真实验证）。
#
# ⚠️ 只许本机验收用：ad-hoc 临时签名、未公证，严禁分发、严禁当 dist 产物上传。
# ⚠️ 与正式 app 同 bundle id、共享 UserDefaults——验完记得退出，并把验收期间登记的登录项
#    （指向 .build/dev-app 路径）在 系统设置→登录项 或 app 设置页里关掉，别留开发残留。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

swift build
BIN="$PROJECT_DIR/.build/debug/usageBar"
APP="$PROJECT_DIR/.build/dev-app/usageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/usageBar"
cp "$PROJECT_DIR/Sources/usageBar/Info.plist" "$APP/Contents/Info.plist"
# SPM 资源 bundle（图标等）要跟着可执行文件走，否则 Bundle.module 找不到资源
cp -R "$PROJECT_DIR/.build/debug/"*.bundle "$APP/Contents/MacOS/" 2>/dev/null || true
# Sparkle 走 SPM artifacts 的绝对路径 rpath，本机运行无需拷贝 framework

# ad-hoc 签名（SMAppService 等系统接口要求 app 有有效签名，临时签名即可）
codesign --force -s - "$APP/Contents/MacOS/usageBar"
codesign --force -s - "$APP"

echo "✓ dev-app 壳已组装: $APP"
echo "  open \"$APP\"   # 验「只认 .app」的功能；验完退出并清掉登录项登记"
