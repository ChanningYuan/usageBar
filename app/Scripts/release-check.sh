#!/bin/bash
# 发版自检：一条命令核对正式包能不能发。任何一项不过就返回失败，不准进入推送。
# 用法：./Scripts/release-check.sh 0.3.42        （在 build-app.sh 之后、git push 之前跑）
#
# 核对项：
#   1 版本号        源码 Info.plist 与正式包都是这个版本
#   2 干净构建      release 编译目录里没有早于本次构建开始时间的目标文件
#   3 单元测试      build-app.sh 记下的测试结果是「0 failures」
#   4 签名公证      正式包是 Notarized Developer ID，App 与 DMG 都已装订
#   5 自动更新清单  appcast 里这个版本只有一条，下载地址是版本化镜像，length 等于 zip 字节，带签名
#   6 账本核对      重启正式包跑完首轮刷新后，每个来源主列表合计 = 明细合计（已拍板接受的历史差异见放行清单）
#
# 放行清单：../_notes/ledger-allow.txt（每行一个「来源:日期」，# 开头为注释；本机数据相关，不进公开仓库）
set -u

VER="${1:-}"
[ -n "$VER" ] || { echo "用法：$0 <版本号>"; exit 2; }
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP="$DIST_DIR/usageBar.app"
FAILS=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ❌ $1"; FAILS=$((FAILS + 1)); }

echo "发版自检 v${VER}"

echo "[1] 版本号"
SRC_VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PROJECT_DIR/Sources/usageBar/Info.plist" 2>/dev/null)"
APP_VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"
[ "$SRC_VER" = "$VER" ] && pass "源码 Info.plist = ${SRC_VER}" || fail "源码 Info.plist 是 ${SRC_VER:-读不到}，不是 ${VER}"
[ "$APP_VER" = "$VER" ] && pass "正式包 = ${APP_VER}" || fail "正式包是 ${APP_VER:-读不到}，不是 ${VER}"

echo "[2] 干净构建"
INFO="$DIST_DIR/build-info.txt"
if [ -f "$INFO" ]; then
  STARTED="$(sed -n 's/^build_started_at=//p' "$INFO")"
  BIN_DIR="$(sed -n 's/^release_bin_dir=//p' "$INFO")"
  if [ -n "$STARTED" ] && [ -d "$BIN_DIR" ]; then
    TOTAL="$(find "$BIN_DIR" -name '*.o' | wc -l | tr -d ' ')"
    OLD="$(find "$BIN_DIR" -name '*.o' ! -newermt "$STARTED" | wc -l | tr -d ' ')"
    [ "$TOTAL" -gt 0 ] && [ "$OLD" = "0" ] && pass "${TOTAL} 个目标文件全部生成于 ${STARTED} 之后" \
      || fail "目标文件 ${TOTAL} 个，其中 ${OLD} 个早于构建开始（${STARTED}）"
  else
    fail "build-info.txt 缺构建开始时间或编译目录"
  fi
else
  fail "没有 dist/build-info.txt（不是用当前 build-app.sh 打的包？）"
fi

echo "[3] 单元测试"
TESTS="$(sed -n 's/^tests=//p' "$INFO" 2>/dev/null)"
echo "$TESTS" | grep -q "with .* 0 failures" && pass "$TESTS" || fail "测试结果不是全绿：${TESTS:-没有记录}"

echo "[4] 签名公证"
spctl -a -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" && pass "正式包是 Notarized Developer ID" || fail "正式包没通过公证校验"
xcrun stapler validate "$APP" >/dev/null 2>&1 && pass "App 已装订公证票据" || fail "App 没装订公证票据"
xcrun stapler validate "$DIST_DIR/usageBar.dmg" >/dev/null 2>&1 && pass "DMG 已装订公证票据" || fail "DMG 没装订公证票据"

echo "[5] 自动更新清单"
APPCAST="$REPO_DIR/appcast.xml"
ITEMS="$(grep -c "<sparkle:version>${VER}</sparkle:version>" "$APPCAST" 2>/dev/null)"; ITEMS="${ITEMS:-0}"
[ "$ITEMS" = "1" ] && pass "appcast 里 ${VER} 恰好一条" || fail "appcast 里 ${VER} 有 ${ITEMS} 条"
LEN="$(grep -o "dl/v${VER}/usageBar.zip\" length=\"[0-9]*\"" "$APPCAST" | grep -o '[0-9]*"$' | tr -d '"')"
ZIP_SIZE="$(stat -f%z "$DIST_DIR/usageBar.zip" 2>/dev/null)"
[ -n "$LEN" ] && [ "$LEN" = "$ZIP_SIZE" ] && pass "下载地址是版本化镜像，length ${LEN} = zip 字节" \
  || fail "length ${LEN:-找不到} 与 zip 字节 ${ZIP_SIZE:-读不到} 不一致"
grep -A0 "dl/v${VER}/usageBar.zip" "$APPCAST" | grep -q 'sparkle:edSignature="' && pass "带 EdDSA 签名" || fail "这一条没有 EdDSA 签名"

echo "[6] 账本核对（重启正式包，等首轮刷新落盘稳定）"
pkill -x usageBar 2>/dev/null; sleep 1
LAUNCH_TS="$(date +%s)"
open "$APP"
if python3 - "$LAUNCH_TS" <<'PY'
import datetime, json, os, sys, time
p = os.path.expanduser("~/Library/Application Support/usageBar/file-cache.json")
launch = int(sys.argv[1]); deadline = time.time() + 300; last = None; since = None
while time.time() < deadline:
    try:
        s = datetime.datetime.fromisoformat(json.load(open(p))["savedAt"].replace("Z", "+00:00")).timestamp()
    except Exception:
        s = 0
    if s >= launch:
        if s != last:
            last, since = s, time.time()
        elif time.time() - since >= 40:
            sys.exit(0)
    time.sleep(5)
sys.exit(1)
PY
then
  ALLOW_ARGS=()
  ALLOW_FILE="$REPO_DIR/_notes/ledger-allow.txt"
  if [ -f "$ALLOW_FILE" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
      [ -n "$line" ] && ALLOW_ARGS+=(--allow "$line")
    done < "$ALLOW_FILE"
  fi
  if python3 "$PROJECT_DIR/Scripts/check-ledger.py" "${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"}" | sed 's/^/    /'; [ "${PIPESTATUS[0]}" = "0" ]; then
    pass "每个来源主列表合计 = 明细合计"
  else
    fail "账本核对没过（见上表）"
  fi
else
  fail "正式包 5 分钟内没把首轮刷新落盘"
fi

echo
if [ "$FAILS" = "0" ]; then
  echo "✅ 发版自检全部通过，可以推送"
  exit 0
fi
echo "❌ ${FAILS} 项没过，停止发布"
exit 1
