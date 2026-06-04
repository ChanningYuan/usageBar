# install-usagebar

让你跟 AI Agent 说一句"装一下 usageBar"，AI 自动把 usageBar.app 装到 `/Applications` 并启动，全程零交互。

## usageBar 是什么

一个 macOS 菜单栏小工具，实时显示多个 AI 编程工具（Claude Code 订阅 / cc-api、Qoder、Codex、钉钉悟空）的 token 消耗。

菜单栏会显示 `📊 XXX.XM token`，点开看各 provider 分布，支持今日 / 7天 / 30天 / 累计 四个时间窗口。

## 系统要求

| 项目 | 要求 |
|---|---|
| macOS | 14 (Sonoma) 或更高 |
| CPU | Apple Silicon (M1/M2/M3/M4)。Intel Mac 不支持 |

skill 会自检，不满足直接报错退出。

## 怎么用

skill 装好后，跟 AI Agent 说下面任一句话：

- "装一下 usageBar"
- "帮我把 usageBar 装上"
- "安装 usageBar"
- "重装 usageBar"

AI 会自动跑 `scripts/install.sh` —— 解压、清 Gatekeeper quarantine、拷到 /Applications、启动，约 30 秒搞定。

## 包内结构

```
install-usagebar/
├── SKILL.md              # AI Agent 读的指令（触发词、流程、故障排查）
├── README.md             # 本文件
├── usageBar.tar.gz       # usageBar.app 的安装包（~330KB）
└── scripts/
    ├── install.sh                          # 安装脚本（被 SKILL.md 调用）
    ├── uninstall.sh                        # 卸载脚本
    └── diagnose.sh                         # 诊断脚本（出问题时跑）
```

## 安装后

- **位置**：`/Applications/usageBar.app`
- **菜单栏**：屏幕右上角出现 token 数字（首次冷启 ~15 秒）
- **开机自启**：系统设置 → 通用 → 登录项 → 添加 usageBar
- **数据更新**：后台 10 分钟自动刷新一次，或右键菜单点"立即刷新"

## 卸载

跟 AI Agent 说"卸载 usageBar"。

默认**保留用户配置**（`~/Library/Application Support/usageBar/`），下次重装能复用 cache。如果要彻底清掉，说"连配置一起删"。

## 出问题

### 第一步：跟 AI Agent 说"生成 usageBar 诊断报告"

AI 会自动跑 `scripts/diagnose.sh`，在你桌面生成一份 md 报告（约 1KB），含环境、安装状态、进程、数据源、缓存、系统日志、crash 报告等 8 个维度的信息。

文件名类似：`~/Desktop/usageBar-诊断报告-20260521-093635.md`

### 第二步：补充"我做了什么"

打开诊断报告，文件末尾「9. 描述问题」是空的，填一下：

- 你做了什么操作
- 期望看到什么
- 实际看到什么
- 报错信息 / 截图

### 第三步：整份发作者

把这份 md 完整复制粘贴发给作者，或者把文件直接拖给作者。

作者会发给 AI 排查，AI 按报告里 8 个 section 逐项分析，给具体修复指令。

### 也可以自己看

如果你想先自己看一下，跟 AI 说"用 stdout 模式诊断"或直接终端跑：

```bash
bash <你的 skill 目录>/install-usagebar/scripts/diagnose.sh --stdout
```

报告里 ✅/❌/⚠️ 直观能看出哪一步出问题。

### 常见问题（自助）

| 现象 | 修复 |
|---|---|
| 菜单栏没图标 | 等 15 秒（首次冷启），或菜单栏被挤满 |
| 装完弹 Gatekeeper | `sudo xattr -d com.apple.quarantine /Applications/usageBar.app` |
| cp 报 Operation not permitted | 企业管控机，需要作者出签名版 |
| 数据全是 — | 你机器还没装任何 AI 工具，装个 Claude Code 再说 |

## 升级新版本

作者会重新发 `install-usagebar.zip`，覆盖原 skill 目录即可。再让 AI 跑一遍触发词，覆盖式安装。
