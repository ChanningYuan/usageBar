#!/bin/bash
# usageBar 卸载脚本
# 由 install-usagebar skill 调用
#
# 用法：bash <skill_dir>/scripts/uninstall.sh [--purge-config]
#   不带参数：只删 .app（保留用户配置 ~/Library/Application Support/usageBar/）
#   --purge-config：同时删除用户配置

set -euo pipefail

PROCESS_PATTERN="usageBar.app/Contents/MacOS/usageBar"
APP_PATH="/Applications/usageBar.app"
CONFIG_DIR="$HOME/Library/Application Support/usageBar"

PURGE=0
for arg in "$@"; do
  if [ "$arg" = "--purge-config" ]; then
    PURGE=1
  fi
done

echo "→ usageBar 卸载开始"

# 杀进程
if pgrep -f "$PROCESS_PATTERN" > /dev/null; then
  echo "→ 停止进程..."
  pkill -f "$PROCESS_PATTERN" 2>/dev/null || true
  sleep 1
fi

# 删 .app
if [ -d "$APP_PATH" ]; then
  echo "→ 删除 $APP_PATH"
  rm -rf "$APP_PATH"
else
  echo "  $APP_PATH 不存在，跳过"
fi

# 用户配置
if [ -d "$CONFIG_DIR" ]; then
  if [ $PURGE -eq 1 ]; then
    echo "→ 清理用户配置 $CONFIG_DIR"
    rm -rf "$CONFIG_DIR"
  else
    echo "  保留用户配置 $CONFIG_DIR"
    echo "  如需一并清理，加 --purge-config 重跑此脚本"
  fi
fi

echo ""
echo "✅ 卸载完成"
