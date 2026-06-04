#!/bin/bash
# 把 install-usagebar/ skill 打包成可分发的 install-usagebar.zip
# 依赖：先跑 build-app.sh 生成 dist/usageBar.zip
# 用法：./Scripts/build-skill.sh
#
# 产物：../install-usagebar.zip (~210KB,含 SKILL.md + README.md + usageBar.zip)
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"           # .../usageBar/app
USAGEBAR_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"            # .../usageBar
APP_ZIP="$PROJECT_DIR/dist/usageBar.zip"
SKILL_DIR="$USAGEBAR_ROOT/install-usagebar"
SKILL_ZIP="$USAGEBAR_ROOT/install-usagebar.zip"

# 1. 检查 app zip 是否存在
if [ ! -f "$APP_ZIP" ]; then
  echo "❌ 找不到 $APP_ZIP"
  echo "   请先跑 ./Scripts/build-app.sh 生成 .app 安装包"
  exit 1
fi

# 2. 检查 skill 目录是否存在
if [ ! -d "$SKILL_DIR" ]; then
  echo "❌ 找不到 skill 目录 $SKILL_DIR"
  echo "   该目录应包含 SKILL.md + README.md,如果丢失请从 git 恢复"
  exit 1
fi

if [ ! -f "$SKILL_DIR/SKILL.md" ]; then
  echo "❌ skill 目录内没有 SKILL.md,结构异常"
  exit 1
fi

# 3. 同步最新 usageBar.zip 到 skill 目录
echo "→ 同步 usageBar.zip 到 skill 目录..."
cp "$APP_ZIP" "$SKILL_DIR/usageBar.zip"

# 4. 打包 skill 目录
echo "→ 打包 install-usagebar.zip..."
rm -f "$SKILL_ZIP"
cd "$USAGEBAR_ROOT"
zip -r -q install-usagebar.zip install-usagebar \
  -x "install-usagebar/.DS_Store" \
  -x "install-usagebar/*/.DS_Store"

echo ""
echo "✅ 完成"
echo ""
echo "产物:"
echo "  $SKILL_ZIP"
ls -lh "$SKILL_ZIP" | awk '{print "  大小: "$5}'
echo ""
echo "skill 目录结构:"
ls -1 "$SKILL_DIR" | sed 's/^/    /'
echo ""
echo "发同事:"
echo "  把 $SKILL_ZIP 发给同事"
echo "  同事按 README.md 操作:"
echo "    1) 解压到对应 AI Agent 的 skills 目录"
echo "       (如 ~/.claude/skills/)"
echo "    2) 跟 AI Agent 说\"装一下 usageBar\""
