import Foundation

/// 通过官方 CLI 查询 Codex 账号额度（0812 spec §三，取代 JSONL 扫描）。
///
/// 做法：拉起 `codex -s read-only -a untrusted app-server`（stdio 上的 JSON-RPC），
/// 依次发 `initialize` → `account/read` → `account/rateLimits/read`，拿到按池分好的
/// `rateLimitsByLimitId` + 重置券后立即结束进程。凭据刷新完全由 CLI 自己完成
/// （它管理 ~/.codex/auth.json 的 token 轮换），usageBar 零钥匙串、零自管凭据。
///
/// ⚠️ 二进制发现链（顺序即优先级）：PATH 常见安装位 → npm 全局 → Codex Desktop 内嵌
/// → VS Code/Cursor 扩展内嵌。每个候选都要 `--version` 验真——npm 装坏（原生二进制丢失、
/// shim 报 ENOENT）在本机实测出现过，光看文件存在会误判。验真结果进程内缓存，失败时重探。
enum CodexAppServerClient {

    enum RPCError: Error {
        case binaryNotFound
        case methodNotFound      // CLI 版本太老，无 account/rateLimits/read
        case notLoggedIn
        case timeout
        case processFailed
    }

    /// [String: Any] 不是编译期 Sendable，但本结构构造后只读、跨 Task 只传一次 → unchecked 安全
    struct Result: @unchecked Sendable {
        /// `account/rateLimits/read` 的 result 对象（原始 JSON）
        let rateLimits: [String: Any]
        /// `account/read` 给的套餐名（rateLimits 里也有，双保险）
        let accountPlan: String?
        /// 账号类型："chatgpt" / "apikey"（API Key 登录无额度池概念）
        let accountType: String?
    }

    // MARK: - 二进制发现

    /// 验真通过的二进制路径缓存（进程内；失败时清掉重探）
    nonisolated(unsafe) private static var cachedBinary: String?

    static func discoverBinary() -> String? {
        if let c = cachedBinary, FileManager.default.isExecutableFile(atPath: c) { return c }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
        // VS Code / Cursor 的 Codex 扩展内嵌二进制（浅层 glob，找不到就算了）
        for extRoot in ["\(home)/.vscode/extensions", "\(home)/.cursor/extensions"] {
            if let dirs = try? FileManager.default.contentsOfDirectory(atPath: extRoot) {
                for d in dirs where d.lowercased().contains("openai") || d.lowercased().contains("chatgpt") {
                    candidates.append("\(extRoot)/\(d)/bin/codex")
                    candidates.append("\(extRoot)/\(d)/out/codex")
                }
            }
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if validate(path) {
                cachedBinary = path
                return path
            }
        }
        return nil
    }

    /// `--version` 3 秒验真：能跑通且输出含 "codex" 才算数（npm 坏 shim 会退非零/报 ENOENT）。
    private static func validate(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return false }
        guard p.terminationStatus == 0 else { return false }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.lowercased().contains("codex")
    }

    // MARK: - RPC

    /// 完整一问：拉起 app-server，拿额度 + 账号信息。阻塞最多 `timeout` 秒（调用方放后台线程）。
    static func fetch(timeout: TimeInterval = 15) -> Swift.Result<Result, RPCError> {
        guard let bin = discoverBinary() else { return .failure(.binaryNotFound) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = Pipe()
        do { try p.run() } catch {
            cachedBinary = nil   // 起不来 → 缓存失效，下轮重探
            return .failure(.processFailed)
        }
        defer {
            if p.isRunning { p.terminate() }
        }

        func send(_ obj: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0A)
            stdin.fileHandleForWriting.write(data)
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "usageBar", "title": "usageBar", "version": "1"]]])
        send(["jsonrpc": "2.0", "id": 2, "method": "account/read",
              "params": ["refreshToken": false]])
        send(["jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read", "params": [:]])

        // 逐行读 stdout 直到拿到 id=3 的应答。readabilityHandler 后台收流 + 信号量限时等待——
        // ⚠️ 不能用 availableData 轮询：它是阻塞读，服务端悬死（有进程无输出）时超时永远不触发。
        final class Box: @unchecked Sendable {
            var buffer = Data()
            var accountPlan: String?
            var accountType: String?
            var loggedOut = false
            var outcome: Swift.Result<Result, RPCError>?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)

        stdout.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {   // EOF：进程退了还没给应答
                if box.outcome == nil { box.outcome = .failure(.processFailed); done.signal() }
                return
            }
            box.buffer.append(chunk)
            while let nl = box.buffer.firstIndex(of: 0x0A) {
                let line = box.buffer.subdata(in: box.buffer.startIndex..<nl)
                box.buffer.removeSubrange(box.buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = obj["id"] as? Int else { continue }
                if id == 2, let result = obj["result"] as? [String: Any] {
                    let account = result["account"] as? [String: Any]
                    box.accountPlan = account?["planType"] as? String
                    box.accountType = account?["type"] as? String
                    if account == nil { box.loggedOut = true }
                }
                if id == 3, box.outcome == nil {
                    if let err = obj["error"] as? [String: Any] {
                        let code = (err["code"] as? Int) ?? 0
                        if code == -32601 { box.outcome = .failure(.methodNotFound) }
                        else if box.loggedOut { box.outcome = .failure(.notLoggedIn) }
                        else { box.outcome = .failure(.processFailed) }
                    } else if let result = obj["result"] as? [String: Any] {
                        box.outcome = .success(Result(rateLimits: result, accountPlan: box.accountPlan,
                                                      accountType: box.accountType))
                    } else {
                        box.outcome = .failure(.processFailed)
                    }
                    done.signal()
                }
            }
        }
        defer { stdout.fileHandleForReading.readabilityHandler = nil }

        let waited = done.wait(timeout: .now() + timeout)
        // 信号量的内存屏障保证：signal 前对 box 的写在 wait 返回后可见；timeout 分支只读 nil。
        if waited == .timedOut { return .failure(.timeout) }
        return box.outcome ?? .failure(.processFailed)
    }
}
