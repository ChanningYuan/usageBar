#!/bin/bash
# usageBar 安装脚本
# 由 install-usagebar skill 调用，把同目录的 usageBar.tar.gz 解压安装到 /Applications
#
# 用法：bash <skill_dir>/scripts/install.sh
# 退出码：0 = 成功，非 0 = 失败（错误信息已打到 stderr）

set -euo pipefail

# ---- 定位 skill 目录 + zip 包 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_PATH="$SKILL_DIR/usageBar.tar.gz"

# 固定临时目录（不用 $$ 避免 AI 跨 Bash 调用丢失）
TMP_DIR="/tmp/usagebar-install"

# 进程过滤模式（用 -f 匹配 binary 完整路径，-x 匹配不到 .app 里的 binary）
PROCESS_PATTERN="usageBar.app/Contents/MacOS/usageBar"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "→ usageBar 安装开始"
echo "  skill 目录: $SKILL_DIR"
echo "  安装包:     $PKG_PATH"
echo ""

# ---- Step 0：前置检查（架构 + macOS 版本）----
arch=$(uname -m)
if [ "$arch" != "arm64" ]; then
  echo "❌ 当前 CPU 架构是 $arch，usageBar 只支持 Apple Silicon (M1/M2/M3/M4)。" >&2
  echo "   Intel Mac 请联系作者编译 universal binary 版本。" >&2
  exit 10
fi

ver=$(sw_vers -productVersion | cut -d. -f1)
if [ "$ver" -lt 14 ]; then
  echo "❌ 当前 macOS 版本是 $(sw_vers -productVersion)，usageBar 需要 macOS 14 (Sonoma) 或更高。" >&2
  exit 11
fi

echo "✓ 系统检查通过 (macOS $(sw_vers -productVersion), $arch)"

# ---- Step 1：验证安装包存在 ----
if [ ! -f "$PKG_PATH" ]; then
  echo "❌ 找不到 $PKG_PATH" >&2
  echo "   skill 安装包损坏。重新获取并解压 install-usagebar.zip 到你的 AI Agent skills 目录。" >&2
  exit 20
fi

# ---- Step 2：解压到临时目录 ----
echo "→ 解压安装包..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
tar -xzf "$PKG_PATH" -C "$TMP_DIR/"

if [ ! -d "$TMP_DIR/usageBar.app" ]; then
  echo "❌ tar.gz 解压后未找到 usageBar.app，安装包可能损坏" >&2
  exit 21
fi

# ---- Step 3：清 Gatekeeper quarantine（只清一项属性，不破坏签名）----
echo "→ 清除 Gatekeeper quarantine 标记..."
xattr -d com.apple.quarantine "$TMP_DIR/usageBar.app" 2>/dev/null || true
# 验证（输出空白就是清干净了）
remaining=$(xattr -l "$TMP_DIR/usageBar.app" 2>/dev/null | grep -c "com.apple.quarantine" || true)
if [ "$remaining" -gt 0 ]; then
  echo "⚠️  quarantine 仍残留，第一次 open 可能弹警告" >&2
fi

# ---- Step 4：杀旧进程 + 覆盖安装 ----
echo "→ 停止旧版进程（如果在跑）..."
pkill -f "$PROCESS_PATTERN" 2>/dev/null || true
sleep 1

echo "→ 安装到 /Applications/..."
if [ -d /Applications/usageBar.app ]; then
  rm -rf /Applications/usageBar.app
fi
cp -R "$TMP_DIR/usageBar.app" /Applications/usageBar.app

if [ ! -d /Applications/usageBar.app ]; then
  echo "❌ 拷贝到 /Applications 失败" >&2
  echo "   可能是权限问题，让用户跑：sudo cp -R \"$TMP_DIR/usageBar.app\" /Applications/" >&2
  exit 30
fi

# ---- Step 5：启动 ----
echo "→ 启动 usageBar.app..."
open /Applications/usageBar.app
sleep 2

if pgrep -f "$PROCESS_PATTERN" > /dev/null; then
  pid=$(pgrep -f "$PROCESS_PATTERN" | head -1)
  echo "✓ usageBar 进程已启动 (PID: $pid)"
else
  echo "⚠️  open 已发出但未检测到进程，可能仍在冷启动中（首次 ~15 秒）"
fi

# ---- Step 6：报告结果 ----
echo ""
echo "✅ 安装完成"
echo ""
echo "  位置: /Applications/usageBar.app"
echo "  界面: 屏幕右上角菜单栏会出现 token 消耗数字"
echo "  冷启: 首次 ~15 秒，之后秒开"
echo ""
echo "  开机自启请到 系统设置 → 通用 → 登录项 添加 usageBar"
echo "  卸载: 跟 AI Agent 说\"卸载 usageBar\""
