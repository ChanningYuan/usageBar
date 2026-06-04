---
name: install-usagebar
version: "1.0.0"
description: 安装/诊断/卸载 usageBar macOS 菜单栏工具。安装触发词：用户说"装一下 usageBar"、"安装 usageBar"、"帮我装个 usageBar"、"把 usageBar 装上"、"装下 usagebar"、"重装 usageBar"、"更新 usageBar"。诊断触发词：用户说"usageBar 装失败"、"usageBar 跑不起来"、"usageBar 菜单栏没图标"、"usageBar 报错"、"生成 usageBar 诊断报告"、"usageBar 不工作"。卸载触发词：用户说"卸载 usageBar"、"删了 usageBar"、"uninstall usageBar"。安装会解压 skill 自带 usageBar.tar.gz 到 /Applications、清 Gatekeeper、启动；诊断会生成结构化 md 报告含环境/进程/数据源/缓存/日志/crash；卸载默认保留用户配置。
---

## 这个 skill 干啥

usageBar 是一个 macOS 菜单栏小工具，实时显示 Claude Code / Codex / 钉钉悟空 等 AI 工具的 token 消耗。

本 skill 让你一句话完成 usageBar 的安装：解压自带的 `usageBar.tar.gz` → 清 Gatekeeper → 拷到 `/Applications` → 启动。全程零交互，约 30 秒。

未签名 .app 需要清 `com.apple.quarantine` 才能直接 `open` 不被拦截，这就是 skill 干的核心动作。

---

## 何时触发

- **安装**：用户说"装/安装/帮我装/装上/重装/更新 usageBar"
- **诊断**：用户说"装失败/跑不起来/没图标/报错/生成诊断报告/不工作"
- **卸载**：用户说"卸载 / 删了 / uninstall usageBar"

---

## 安装流程

整套安装逻辑封装在 `scripts/install.sh`，AI 只要做两件事：

### 1. 定位 skill 目录

skill 目录是本 `SKILL.md` 所在目录的绝对路径。常见位置：

- Claude Code：`~/.claude/skills/install-usagebar/`
- Cursor / 其他 IDE：去问用户 skill 目录

如果你（AI Agent）的 runtime 暴露了 skill 加载路径，直接用；否则按上面顺序探测，找到含 `usageBar.tar.gz` 的那个目录即为 `$SKILL_DIR`。

### 2. 跑 install.sh

```bash
bash "$SKILL_DIR/scripts/install.sh"
```

脚本会自检系统、解压、清 quarantine、覆盖安装、启动、报告结果。看脚本的 stdout 给用户复述结果即可。

### 看脚本退出码做后续判断

| exit code | 含义 | 你该怎么做 |
|---|---|---|
| 0 | 成功 | 复述脚本最后那段 "✅ 安装完成" 给用户，安装流程结束 |
| 10 | CPU 架构不对（Intel Mac） | 告知用户：Intel Mac 暂不支持，联系作者要 universal binary |
| 11 | macOS 版本太低 | 告知用户：需要 macOS 14+，先升级系统 |
| 20 | 找不到 usageBar.tar.gz | skill 安装包损坏，让用户重新获取 install-usagebar.zip 并解压到 skills 目录 |
| 21 | tar.gz 解压失败 | 同上，安装包损坏 |
| 30 | 拷贝到 /Applications 被拒 | 大概率企业 MDM 管控。建议用户跑 `sudo cp -R /tmp/usagebar-install/usageBar.app /Applications/` |
| 其他非 0 | 未预期错误 | 把脚本 stderr 完整发给用户，建议联系作者 |

---

## 诊断流程（用户报问题时）

当用户说"装失败 / 跑不起来 / 没图标 / 报错 / 不工作"等任何"出问题了"的话，**第一步生成诊断报告**，不要急着试错。

### 调用方式

**关键**：你（AI Agent）调 diagnose.sh 时，**必须用 `--context` 把对话上下文传进去**。同事懒得手填，你已经有上下文（用户原话、你的尝试、报错输出），直接打包给作者侧的 AI 排查。

```bash
bash "$SKILL_DIR/scripts/diagnose.sh" --context "$(cat <<'CTX'
**用户最初的请求**: <复述用户原话，例："帮我装下 usageBar 然后启动它">

**AI 已尝试的操作**:
- 跑了 `bash $SKILL_DIR/scripts/install.sh`
- 看到退出码 30，stderr 输出: cp 报 "Operation not permitted"
- 尝试了 sudo cp，仍失败

**当前观察**:
- /Applications/usageBar.app 不存在
- 同事说他公司的 Mac 装了「数字方舟 MDM」

**用户原话补充**:
- 用户说："我看到一个红色弹窗写 system policy blocked"
CTX
)"
```

`<<'CTX'` 用单引号防止 shell 误解析特殊字符。把你跟用户对话过程中收集到的所有相关信息写进去，**越具体越好** —— 作者侧的 AI 拿到这份报告只能靠你这部分的"叙事"理解前因后果，没办法回头问同事。

### 报告内容

脚本生成 9 个 section，写到 `~/Desktop/usageBar-诊断报告-<时间戳>.md`：

1. 环境（macOS / 架构 / 内存 / 时区）
2. usageBar 安装状态（.app 路径 / binary / Info.plist / quarantine / 签名）
3. 进程状态（pgrep / ps）
4. 本地数据源（Claude / Codex / 悟空 目录文件数）
5. usageBar 缓存（file-cache.json）
6. 最近 5 分钟系统日志（log show --process usageBar）
7. crash 报告（过去 7 天 `~/Library/Logs/DiagnosticReports/usageBar*`）
8. skill 包状态（SKILL.md / usageBar.tar.gz md5 / 各脚本）
9. **问题上下文**（你通过 --context 注入的对话总结）

### 报告生成后

- 报告会自动用 `open` 打开（macOS 默认应用）
- 告诉同事："诊断报告已生成到 `~/Desktop/usageBar-诊断报告-...md`，把这份文件拖给作者即可"
- 你自己也 `Read` 一下报告，根据下面"异常→修复对照表"先尝试一次自助修复（如果是常见问题）；修不了再让用户发作者

如果同事只想自己看（不要写文件）：

```bash
bash "$SKILL_DIR/scripts/diagnose.sh" --stdout
```

### 常见 section 异常 → 修复对照

| section 异常 | 含义 | 修复 |
|---|---|---|
| 1: 架构 = x86_64 | Intel Mac | 当前版本不支持，需要 universal binary |
| 1: macOS < 14 | 版本过低 | 升级 macOS |
| 2: ❌ .app 未安装 | 没装好 | 跑 install.sh |
| 2: ❌ quarantine 仍存在 | Gatekeeper 会拦 | `sudo xattr -d com.apple.quarantine /Applications/usageBar.app` |
| 3: ❌ 无进程 | 没启动 / 崩了 | 看 section 6 系统日志、section 7 crash 报告 |
| 4: 所有数据源都 ⚪ 不存在 | 同事还没用过任何 AI 工具 | 装一个再说，否则没数据可显示 |
| 5: 缓存目录不存在 | app 从未成功启动 | 先解决 section 3 |
| 6: 日志有 EXC_BAD_ACCESS / NSException | binary 崩 | 看 section 7 crash 详情 |
| 7: 有 crash 报告 | binary 崩过 | 把 crash 前 30 行发作者 |
| 8: usageBar.tar.gz md5 跟作者发的不一致 | 包损坏 | 重新获取 install-usagebar.zip |

## 卸载流程

当用户说"卸载 usageBar"时：

```bash
bash "$SKILL_DIR/scripts/uninstall.sh"
```

脚本默认**保留用户配置**（`~/Library/Application Support/usageBar/`），只删 `/Applications/usageBar.app`。

如果用户明确说"连配置一起删 / 完全干净 / 数据也清掉"，加参数：

```bash
bash "$SKILL_DIR/scripts/uninstall.sh" --purge-config
```

不要主动删用户配置 —— 重新安装时会失去历史 cache 和偏好设置。

---

## 故障排查

### 安装后菜单栏没图标

1. **看进程**：`pgrep -f "usageBar.app/Contents/MacOS/usageBar"` 有输出说明进程跑了
2. **首次冷启慢**：等 15-30 秒，usageBar 第一次启动要扫盘构建缓存
3. **菜单栏满了被挤掉**：用户 Cmd+拖动菜单栏图标整理，或装 Bartender
4. **app 启动崩溃**：查 `~/Library/Logs/DiagnosticReports/` 最新 crash 报告

### 第一次 open 仍弹 Gatekeeper 警告

quarantine 没清干净。验证 + 手动修复：

```bash
xattr -l /Applications/usageBar.app
# 输出里不应有 com.apple.quarantine

# 如果还有，手动清：
sudo xattr -d com.apple.quarantine /Applications/usageBar.app
open /Applications/usageBar.app
```

### 安装时 pkill 没杀掉旧版

旧进程可能被系统挂起。强杀：

```bash
sudo pkill -9 -f "usageBar.app/Contents/MacOS/usageBar"
```

然后重跑 install.sh。

### cp 报 Operation not permitted

`/Applications` 写入受限（SIP 或企业 MDM）。用 sudo：

```bash
sudo cp -R /tmp/usagebar-install/usageBar.app /Applications/
sudo xattr -d com.apple.quarantine /Applications/usageBar.app
open /Applications/usageBar.app
```

如果是企业管控机完全禁止非签名 app，这个 skill 走不通，需要作者出签名版。


## 约束

- 只动 `/Applications/usageBar.app`，不碰其他系统文件
- 不静默 sudo —— 需要时告诉用户为啥
- 不主动删用户配置（除非用户明确要求）
- 失败时给完整 stderr，不能只说"失败了"

---

## Changelog

### 1.0.0 — 2026-05-28

首个标注 version 的发布。Qoder 三件套（CLI / IDE / Work）全部接入"简单 + 精确"本地直读路径。

**新增 Provider**
- `Qoder (IDE)`：读 `~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db` 的 `chat_message.token_info`（OpenAI 兼容 3 列，全量历史从 2025-12-18 起）
- `Qoder (Work)`：读 `~/Library/Application Support/QoderWork/logs/<ts>/main.log` 的 SSE `message_delta` 事件，usageBar 自己做增量 mirror 到 `~/Library/Application Support/usageBar/qoderwork-mainlog-capture.jsonl` 防 rotation 清掉历史。**零配置**纯本地直读（精确 2 列：input + output）

**修复**
- Qoder (IDE) SQLite WAL 模式下主 db 文件 mtime 不刷新导致 FileMtimeCache 永远命中旧 records 的 bug —— 现在合并 (db.mtime, db-wal.mtime, db.size + db-wal.size) 三元组做 cache key

**前置版本（无 version 号）**
- Claude Code、Codex、悟空 Provider 基础实现
- skill 安装/诊断/卸载流程

更详细的开发日志见 `工具/usageBar/CHANGELOG.md`（Keep a Changelog 格式，开发视角）。
