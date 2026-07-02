#!/usr/bin/env python3
"""把 CHANGELOG.md 里某版本的段落转 HTML，**内联**进 appcast.xml 的 <description>。
这样 Sparkle 更新弹窗直接显示更新说明，无需在任何地方托管 html。
同时删掉 generate_appcast 可能生成的 <sparkle:releaseNotesLink>（指向未托管的 url）。

用法: inject-release-notes.py <appcast.xml> <CHANGELOG.md> <版本号>
就地改写 appcast.xml。
"""
import sys
import re
import html

appcast_path, changelog_path, version = sys.argv[1], sys.argv[2], sys.argv[3]

# 1. 从 CHANGELOG 抽当前版本段落 → HTML
text = open(changelog_path, encoding="utf-8").read()
m = re.search(
    r"^##\s*\[?" + re.escape(version) + r"\]?.*?$(.*?)(?=^##\s|\Z)",
    text, re.M | re.S,
)
body = m.group(1).strip() if m else ""

out = ['<h3>usageBar ' + html.escape(version) + "</h3>"]
in_ul = False
for raw in body.splitlines():
    line = raw.rstrip()
    if not line:
        continue
    if line.startswith("### "):
        if in_ul:
            out.append("</ul>"); in_ul = False
        out.append("<p><b>" + html.escape(line[4:]) + "</b></p>")
    elif line.startswith("- "):
        if not in_ul:
            out.append("<ul>"); in_ul = True
        item = html.escape(line[2:])
        item = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", item)
        out.append("<li>" + item + "</li>")
    else:
        if in_ul:
            out.append("</ul>"); in_ul = False
        out.append("<p>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(line)) + "</p>")
if in_ul:
    out.append("</ul>")
# 末尾追加「完整更新历史」链接：弹窗只显示当前版 notes，想看全的点它跳托管的 changelog 页
# （Sparkle 的 release-notes WebView 会用系统浏览器打开外链）。页面由 usagebar-site/gen-changelog.py
# 从本 CHANGELOG.md 生成、发版后 scp 部署到 usagebar.cn/changelog.html。
out.append('<hr>')
out.append('<p><a href="https://usagebar.cn/changelog.html">查看完整更新历史 →</a></p>')
notes_html = "\n".join(out)

# 2. 改写 appcast：删掉 releaseNotesLink，在 <item> 里插入内联 <description>
xml = open(appcast_path, encoding="utf-8").read()
xml = re.sub(r"\s*<sparkle:releaseNotesLink>.*?</sparkle:releaseNotesLink>", "", xml, flags=re.S)
desc = "\n            <description><![CDATA[\n" + notes_html + "\n            ]]></description>"
# 插在 <item> 之后第一个换行处
xml = re.sub(r"(<item>)", r"\1" + desc, xml, count=1)

open(appcast_path, "w", encoding="utf-8").write(xml)
print("✓ 已内联 release notes 到 appcast <description>")
