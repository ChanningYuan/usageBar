#!/bin/bash
# usageBar 诊断报告生成器
# 同事安装/使用出问题时，跑这个脚本生成一份 md 报告发作者。
#
# 用法：
#   bash <skill_dir>/scripts/diagnose.sh
#   # 默认把报告写到 ~/Desktop/usageBar-诊断报告-<时间戳>.md 并自动打开
#
#   bash <skill_dir>/scripts/diagnose.sh --stdout
#   # 输出到 stdout（便于管道或 AI Agent 直接读）

# 诊断脚本 NOT 用 set -u —— 鲁棒性比严格性重要：脚本自己崩了同事就拿不到任何诊断信息。
# pipefail 也不开，因为大量 `cmd 2>/dev/null || true` 路径不需要它。
# 唯一保留的：所有可能失败的命令都显式 `|| true` 兜底。
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROCESS_PATTERN="usageBar.app/Contents/MacOS/usageBar"
APP_PATH="/Applications/usageBar.app"
CONFIG_DIR="$HOME/Library/Application Support/usageBar"
SKILL_PKG="$SKILL_DIR/usageBar.tar.gz"

# 输出目标 + 上下文
TO_STDOUT=0
CONTEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stdout) TO_STDOUT=1; shift ;;
    --context)
      # 防御性：如果 --context 后没跟值（heredoc 解析失败 / AI 传错），不要 unbound 崩
      if [ $# -ge 2 ]; then
        CONTEXT="$2"
        shift 2
      else
        CONTEXT=""
        shift
      fi
      ;;
    --context=*) CONTEXT="${1#--context=}"; shift ;;
    *) shift ;;
  esac
done

if [ $TO_STDOUT -eq 0 ]; then
  TS=$(date +%Y%m%d-%H%M%S)
  OUT="$HOME/Desktop/usageBar-诊断报告-${TS}.md"
  exec > "$OUT"
fi

# ---- helpers ----
status_yes() { printf "✅ %s\n" "$1"; }
status_no()  { printf "❌ %s\n" "$1"; }
status_warn(){ printf "⚠️  %s\n" "$1"; }
safe_run()   { "$@" 2>/dev/null || true; }
bytes_human(){ # 字节 → 人类可读
  b=$1
  if   [ "$b" -lt 1024 ]; then echo "${b} B"
  elif [ "$b" -lt 1048576 ]; then echo "$((b/1024)) KB"
  else echo "$((b/1048576)) MB"; fi
}

# ============================================================
# 报告开始
# ============================================================
cat <<EOF
# usageBar 诊断报告

**生成时间**: $(date "+%Y-%m-%d %H:%M:%S")
**报告版本**: v1.0

> 这份报告由同事侧诊断脚本自动生成。
> 同事：把整份发给作者，作者会发 AI 排查。
> AI：按 \`## n.\` 顺序逐条 read，定位问题在哪一步。

---

## 1. 环境

| 项目 | 值 |
|---|---|
| macOS | $(sw_vers -productVersion) ($(sw_vers -buildVersion)) |
| 架构 | $(uname -m) |
| CPU 型号 | $(sysctl -n machdep.cpu.brand_string 2>/dev/null) |
| 内存 | $(echo "$(sysctl -n hw.memsize) / 1073741824" | bc) GB |
| 时区 | $(date "+%Z (%z)") |
| Shell | $SHELL |
| Hostname | $(hostname) |

EOF

# ============================================================
# 2. usageBar 安装状态
# ============================================================
cat <<EOF
## 2. usageBar 安装状态

EOF

if [ -d "$APP_PATH" ]; then
  status_yes ".app 路径: $APP_PATH"

  BIN="$APP_PATH/Contents/MacOS/usageBar"
  if [ -f "$BIN" ]; then
    size=$(stat -f "%z" "$BIN" 2>/dev/null)
    mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$BIN" 2>/dev/null)
    echo "- binary 大小: $(bytes_human "$size")"
    echo "- binary 修改时间: $mtime"
  else
    status_no "binary 文件不存在！.app 结构损坏"
  fi

  # Info.plist
  INFO="$APP_PATH/Contents/Info.plist"
  if [ -f "$INFO" ]; then
    LSUI=$(defaults read "$INFO" LSUIElement 2>/dev/null || echo "未设置")
    echo "- LSUIElement: $LSUI（应该是 1/true，否则会有 Dock 图标）"
    BUNDLE_VER=$(defaults read "$INFO" CFBundleShortVersionString 2>/dev/null || echo "未设置")
    echo "- 版本: $BUNDLE_VER"
  fi

  # xattr
  XATTR=$(xattr -l "$APP_PATH" 2>/dev/null)
  if echo "$XATTR" | grep -q "com.apple.quarantine"; then
    status_no "com.apple.quarantine **仍存在** — 这会导致第一次打开弹 Gatekeeper 警告"
    echo "  完整 xattr 输出:"
    echo "$XATTR" | sed 's/^/    /'
    echo "  修复命令: \`sudo xattr -d com.apple.quarantine /Applications/usageBar.app\`"
  else
    status_yes "com.apple.quarantine 已清除"
  fi

  # 签名
  CS=$(codesign -dvv "$APP_PATH" 2>&1 | head -5 || true)
  echo ""
  echo "**代码签名**:"
  echo '```'
  echo "$CS"
  echo '```'
else
  status_no ".app 未安装（找不到 $APP_PATH）"
  echo "  → 让同事先跑 install.sh 装一次"
fi

# ============================================================
# 3. 进程状态
# ============================================================
cat <<EOF

## 3. 进程状态

EOF

PIDS=$(pgrep -f "$PROCESS_PATTERN" 2>/dev/null || true)
if [ -n "$PIDS" ]; then
  for pid in $PIDS; do
    status_yes "进程在跑: PID $pid"
    PSLINE=$(ps -p "$pid" -o pid,stat,%cpu,%mem,etime,command 2>/dev/null | tail -1)
    echo "  详情: \`$PSLINE\`"
  done
else
  status_no "无 usageBar 进程"
  echo "  → 可能没启动，或者进程崩了"
fi

# ============================================================
# 4. 数据源
# ============================================================
cat <<EOF

## 4. 本地数据源

usageBar 读这些目录的 jsonl 文件统计 token，不联网。

EOF

check_dir() {
  local label=$1
  local path=$2
  local pattern=${3:-"*"}
  if [ -d "$path" ]; then
    cnt=$(find "$path" -name "$pattern" -type f 2>/dev/null | wc -l | tr -d ' ')
    size=$(du -sh "$path" 2>/dev/null | cut -f1)
    echo "- ✅ **$label**: $path"
    echo "  - 文件数: $cnt"
    echo "  - 总大小: $size"
  else
    echo "- ⚪ **$label**: $path（不存在，该工具未使用 → 正常）"
  fi
}


check_dir "Claude Code" "$HOME/.claude/projects" "*.jsonl"
check_dir "Codex" "$HOME/.codex/sessions" "rollout-*.jsonl"
check_dir "钉钉悟空 / Rewind" "$HOME/Library/Application Support/dingtalk-rewind-server/users"

# ============================================================
# 5. usageBar 缓存
# ============================================================
cat <<EOF

## 5. usageBar 缓存（mtime 增量缓存）

EOF

if [ -d "$CONFIG_DIR" ]; then
  status_yes "缓存目录: $CONFIG_DIR"
  CACHE="$CONFIG_DIR/file-cache.json"
  if [ -f "$CACHE" ]; then
    size=$(stat -f "%z" "$CACHE" 2>/dev/null)
    mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$CACHE" 2>/dev/null)
    echo "- file-cache.json 大小: $(bytes_human "$size")"
    echo "- 最后写入: $mtime"
    # 用 grep 替代 jq（同事可能没装 jq）
    if command -v jq >/dev/null 2>&1; then
      entries=$(jq '.entries | length' "$CACHE" 2>/dev/null || echo "?")
      schema=$(jq -r '.schemaVersion // "?"' "$CACHE" 2>/dev/null)
      echo "- 缓存条目数: $entries"
      echo "- schemaVersion: $schema"
    fi
  else
    status_warn "file-cache.json 不存在（首次启动还没写或被清掉过）"
  fi
else
  status_no "缓存目录不存在 → app 从未成功启动过，或被卸载干净"
fi

# ============================================================
# 6. 系统日志（最近 5 分钟）
# ============================================================
cat <<EOF

## 6. 最近 5 分钟系统日志（usageBar 相关）

EOF

echo '```'
LOG_OUT=$(log show --process usageBar --last 5m --style compact 2>&1 | head -50 || true)
if [ -z "$LOG_OUT" ] || echo "$LOG_OUT" | grep -q "No log messages found"; then
  echo "（无相关日志 — 进程没在跑或没产生日志）"
else
  echo "$LOG_OUT"
fi
echo '```'

# ============================================================
# 7. crash 报告
# ============================================================
cat <<EOF

## 7. 最近的 crash 报告（如有）

EOF

CRASHES=$(find "$HOME/Library/Logs/DiagnosticReports" -name "usageBar*" -mtime -7 2>/dev/null | head -3)
if [ -n "$CRASHES" ]; then
  status_warn "**有 crash 报告**（最近 7 天）"
  for c in $CRASHES; do
    echo "- $c"
    echo "  - 时间: $(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$c" 2>/dev/null)"
  done
  echo ""
  echo "**最新 crash 前 30 行**:"
  echo '```'
  head -30 "$(echo "$CRASHES" | head -1)" 2>/dev/null
  echo '```'
else
  status_yes "无 crash 报告（过去 7 天）"
fi

# ============================================================
# 8. skill 包状态
# ============================================================
cat <<EOF

## 8. skill 包状态

EOF

echo "- SKILL_DIR: \`$SKILL_DIR\`"
if [ -f "$SKILL_DIR/SKILL.md" ]; then
  echo "- SKILL.md: ✅ 存在"
else
  status_no "SKILL.md 不存在！"
fi
if [ -f "$SKILL_PKG" ]; then
  size=$(stat -f "%z" "$SKILL_PKG" 2>/dev/null)
  md5=$(md5 -q "$SKILL_PKG" 2>/dev/null)
  echo "- usageBar.tar.gz: $(bytes_human "$size"), md5=\`$md5\`"
else
  status_no "usageBar.tar.gz 不存在！skill 包损坏"
fi
for s in install.sh uninstall.sh diagnose.sh; do
  if [ -f "$SCRIPT_DIR/$s" ]; then
    echo "- scripts/$s: ✅"
  else
    status_warn "scripts/$s 缺失"
  fi
done

# ============================================================
# 9. 问题上下文（AI 通过 --context 注入，或同事手填）
# ============================================================
cat <<EOF

## 9. 问题上下文

EOF

if [ -n "$CONTEXT" ]; then
  echo "_（由 AI Agent 根据对话上下文自动填写）_"
  echo ""
  echo "$CONTEXT"
  echo ""
else
  cat <<'EOF'
_（无 AI 上下文输入。如果是同事自己跑的诊断脚本，请补充下面 4 项）_

**做了什么操作**:
（例：跟 AI 说"装一下 usageBar"，AI 跑了 install.sh，报错……）

**期望看到什么**:
（例：菜单栏右上角出现 token 数字）

**实际看到什么**:
（例：跑完没看到图标 / AI 报红字 / 弹了 Gatekeeper 警告 / 等等）

**报错信息 / 截图**:
（如有，贴在这里。或者另发截图给作者）
EOF
fi

cat <<'EOF'

---

**发送方式**:
- 把这份 md 整份复制粘贴发给作者
- 或者把文件 (`~/Desktop/usageBar-诊断报告-*.md`) 拖给作者
- 作者会发给 AI Agent，AI 按 section 1-8 排查 + 看 section 9 的上下文
EOF

# ============================================================
# 提示用户
# ============================================================
if [ $TO_STDOUT -eq 0 ]; then
  # 报告写在文件里，给用户提示
  echo ""
  echo "✅ 诊断报告已生成: $OUT" >&2
  echo "" >&2
  echo "下一步：" >&2
  echo "  1. 打开文件，填一下「9. 描述问题」那段" >&2
  echo "  2. 整份复制粘贴发给作者，或直接拖文件给作者" >&2
  open "$OUT" 2>/dev/null || true
fi
