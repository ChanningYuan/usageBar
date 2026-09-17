#!/usr/bin/env python3
"""发版自检：核对本机 usageBar 账本，每个来源「主列表合计 = 明细合计」。

用法：
  python3 app/Scripts/check-ledger.py                       # 全部来源
  python3 app/Scripts/check-ledger.py --allow qwen-work:2026-08-14   # 放行已知、已拍板接受的历史差异

退出码：0 = 全部一致（或只剩 --allow 放行的差异）；1 = 有未放行的差异；2 = 账本读不到。

为什么要有它：`LedgerDetailTests` 只手工往账本塞记录再读，从没跑过任何来源的刷新，
测不出「刷新时两套算法不一致」「整份重算覆盖掉旧明细」这类问题。2026-09-17 对真实账本逐来源核对，
才发现 Codex、千问办公、Claude Code 三处主列表与详情页对不上。
用在发版第 4 步：正式包启动、跑完首轮刷新之后执行。
"""
import argparse
import collections
import datetime
import json
import os
import sys

LEDGER = os.path.expanduser("~/Library/Application Support/usageBar/file-cache.json")


def main() -> int:
    ap = argparse.ArgumentParser(description="核对 usageBar 账本：主列表合计 = 明细合计")
    ap.add_argument("--allow", action="append", default=[], metavar="来源:日期",
                    help="放行已知的历史差异，可重复传")
    ap.add_argument("--ledger", default=LEDGER, help="账本路径（默认本机 usageBar 账本）")
    args = ap.parse_args()

    try:
        data = json.load(open(args.ledger))
    except (OSError, ValueError) as e:
        print(f"❌ 读不到账本 {args.ledger}：{e}")
        return 2

    list_by = collections.defaultdict(collections.Counter)
    detail_by = collections.defaultdict(collections.Counter)
    for entry in data.get("entries", []):
        for r in entry.get("records", []):
            list_by[r["provider"]][r["date"]] += r["token"]
        for d in entry.get("details", []):
            detail_by[d["provider"]][d["date"]] += (d["input"] + d["output"] + d["cacheRead"]
                                                    + d["cacheCreate5m"] + d["cacheCreate1h"])

    allowed = set(args.allow)
    saved = data.get("savedAt", "?")
    print(f"账本 {args.ledger}（最后落盘 {saved}，schema {data.get('schemaVersion')}）")
    print(f"{'来源':<12} {'主列表合计':>16} {'明细合计':>16}  对不上的日期")
    blocking = []
    for provider in sorted(set(list_by) | set(detail_by)):
        lst, det = list_by[provider], detail_by[provider]
        dates = sorted(k for k in set(lst) | set(det) if lst[k] != det[k])
        marks = []
        for day in dates:
            tag = f"{day}（差 {lst[day] - det[day]:+,}）"
            if f"{provider}:{day}" in allowed:
                tag += " 已放行"
            else:
                blocking.append((provider, day))
            marks.append(tag)
        print(f"{provider:<12} {sum(lst.values()):>16,} {sum(det.values()):>16,}  {'、'.join(marks) or '无'}")

    if blocking:
        print(f"\n❌ {len(blocking)} 处未放行的差异：" + "、".join(f"{p}:{d}" for p, d in blocking))
        return 1
    print("\n✓ 每个来源主列表合计 = 明细合计" + ("（含已放行的历史差异）" if allowed else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
