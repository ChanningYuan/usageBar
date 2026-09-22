import XCTest
@testable import usageBarCore
@testable import usageBarProviders

final class QoderCreditsTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func response(_ request: String?, session: String = "session-A", model: String = "dfmodel",
                          credits: Any? = 1.25, original: Any? = 1.25, billable: Any? = true,
                          at: String = "2026-09-22T06:32:30.132Z", tokens: Int = 0,
                          stop: Any = "end_turn", messageId: String? = nil, uuid: String? = nil) -> [String: Any] {
        var usage: [String: Any] = ["input_tokens": tokens, "output_tokens": 0]
        usage["credits"] = credits; usage["original_credits"] = original
        usage["billable"] = billable; usage["request_id"] = request
        var message: [String: Any] = ["model": model, "usage": usage, "stop_reason": stop]
        message["id"] = messageId ?? request.map { "message-\($0)" }
        var obj: [String: Any] = ["type": "assistant", "sessionId": session, "timestamp": at, "message": message]
        obj["uuid"] = uuid ?? request.map { "record-\($0)" }
        return obj
    }

    @discardableResult
    private func write(_ records: [[String: Any]], to path: String, under root: URL) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try records.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try data.write(to: file)
        return file
    }

    private func detail(_ cache: FileMtimeCache, window: TimeWindow = .all,
                        now: Date = ISODateParser.parse("2026-09-22T08:00:00Z")!) async -> ProviderDetail {
        QoderCreditsAggregator.aggregate(entries: await cache.allEntries(), window: window, now: now)
    }

    private func assertConsistent(_ d: ProviderDetail, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(d.credits?.amount, d.models.reduce(Decimal(0)) { $0 + ($1.credits?.amount ?? 0) }, file: file, line: line)
        XCTAssertEqual(d.credits?.amount, d.sessions.reduce(Decimal(0)) { $0 + ($1.credits?.amount ?? 0) }, file: file, line: line)
        for session in d.sessions {
            XCTAssertEqual(session.credits?.amount, session.models.reduce(Decimal(0)) { $0 + ($1.credits?.amount ?? 0) }, file: file, line: line)
        }
    }

    func testIssueSampleCreditsAreIndependentOfTokensAndMessageID() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        try write([response("request-R", credits: 0.24520387862857143, original: 0.24520387862857143,
                            tokens: 0, messageId: "message-M")], to: "project/session-A.jsonl", under: root)
        let provider = QoderCliProvider(projectsDir: root, segmentsRoot: root.appendingPathComponent("absent"), cache: cache)
        _ = try await provider.fetchDailyRecords()
        let d = await detail(cache)
        XCTAssertEqual(d.tokens.total, 0)
        XCTAssertEqual(d.cost, 0.24520387862857143, accuracy: 0.000000000001)
        XCTAssertEqual(d.credits?.recordedRequests, 1)
        XCTAssertEqual(d.models.first?.modelId, "dfmodel")
        XCTAssertEqual(d.sessions.first?.sessionId, "session-A")
        XCTAssertTrue(d.credits!.hasActivity)
        assertConsistent(d)
    }

    func testCrossFileDuplicatesSubagentsAndSessionModelBreakdown() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        let shared = response("shared", model: "second", credits: 2.5, stop: "tool_use")
        try write([response("main"), shared,
                   ["type":"custom-title", "sessionId":"session-A", "customTitle":"Explicit title"]],
                  to: "project/session-A.jsonl", under: root)
        try write([shared, response("child", credits: 0.25)], to: "project/session-A/subagents/agent-a.jsonl", under: root)
        try write([shared], to: "project/session-A/subagents/agent-b.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let d = await detail(cache)
        XCTAssertEqual(d.credits?.amount, 4)
        XCTAssertEqual(d.credits?.recordedRequests, 3)
        XCTAssertEqual(d.credits?.subagentRequests, 2)
        XCTAssertEqual(d.sessions.count, 1)
        XCTAssertEqual(d.sessions[0].title, "Explicit title")
        XCTAssertEqual(d.sessions[0].models.count, 2)
        assertConsistent(d)
    }

    func testPersistenceRefreshAppendRotationAndDeletionDoNotLoseOrDuplicateCredits() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        let path = "project/session-A.jsonl"
        let file = try write([response("one")], to: path, under: root)
        let old = FileCacheEntry(filePath: "deleted-token-history", mtime: Date(), size: 1,
                                records: [FileDailyRecord(provider: "qoder-cli", date: "2026-07-01", token: 123)],
                                details: [FileDetailRecord(provider: "qoder-cli", date: "2026-07-01", sessionId: "old",
                                                           title: "Old", model: "old-model", lastActivity: Date(), tokens: TokenBreakdown(input: 123))])
        await cache.store(old)
        let provider = QoderCliProvider(projectsDir: root, segmentsRoot: root.appendingPathComponent("absent"), cache: cache)
        _ = try await provider.fetchDailyRecords()
        _ = try await provider.fetchDailyRecords()
        try write([response("one"), response("two", credits: 0.75)], to: path, under: root)
        _ = try await provider.fetchDailyRecords()
        // 真正经过 Codable 往返模拟重启；不触碰用户账本。
        let encoded = try JSONEncoder().encode(PersistedCache(entries: await cache.allEntries()))
        let restored = try JSONDecoder().decode(PersistedCache.self, from: encoded)
        let second = FileMtimeCache()
        for entry in restored.entries { await second.store(entry) }
        try FileManager.default.removeItem(at: file)
        try write([response("one"), response("two", credits: 0.75)], to: "rotated/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: second)
        let d = await detail(second)
        XCTAssertEqual(d.credits?.amount, 2)
        XCTAssertEqual(d.credits?.recordedRequests, 2)
        XCTAssertEqual(d.tokens.total, 123)
        XCTAssertTrue(d.credits!.uncoveredHistory)
        let history = await second.entry(forPath: old.filePath)
        XCTAssertEqual(history, old)
        assertConsistent(d)
    }

    func testMissingInvalidAndZeroRemainDistinct() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        var records = [response("missing", credits: nil), response("null", credits: NSNull()),
                       response("string", credits: "2"), response("bool", credits: true),
                       response("negative", credits: -1), response("zero", credits: 0)]
        var decoy = response("decoy", credits: 999); decoy["type"] = "user"; records.append(decoy)
        try write(records, to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let d = await detail(cache)
        XCTAssertEqual(d.credits?.recordedRequests, 1)
        XCTAssertEqual(d.credits?.missingRequests, 5)
        XCTAssertEqual(d.credits?.label, "0.00 积分*")
        let empty = CreditUsage()
        XCTAssertEqual(empty.label, "积分未知")
        assertConsistent(d)
    }

    func testBillingFlagsAndOriginalCreditsDoNotInventCharges() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        try write([response("free", credits: 3, original: 9, billable: false),
                   response("unknown", credits: 2, original: 4, billable: nil),
                   response("bad-flag", credits: 1, original: nil, billable: "true")],
                  to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let d = await detail(cache)
        XCTAssertEqual(d.credits?.amount, 6) // credits 原值，既不加 original，也不把未计费改成 0。
        XCTAssertEqual(d.credits?.nonBillableRequests, 1)
        XCTAssertEqual(d.credits?.billingUnknownRequests, 2)
        let observations = await cache.allEntries().compactMap(\.qoderCredits).flatMap(\.observations)
        XCTAssertEqual(observations.first(where: { $0.requestKey == "request:free" })?.originalCredits, 9)
        XCTAssertEqual(observations.first(where: { $0.requestKey == "request:bad-flag" })?.invalidFields, ["billable"])
        XCTAssertTrue(d.credits!.explanation.contains("不代表实际扣款"))
    }

    func testConflictingRequestValuesAndAttributionAreExcludedExplicitly() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        try write([response("amount", credits: 1), response("owner", credits: 2)], to: "project/session-A.jsonl", under: root)
        try write([response("amount", credits: 3)], to: "copy/session-A.jsonl", under: root)
        try write([response("owner", session: "session-B", credits: 2)], to: "project/session-B.jsonl", under: root)
        try write([response("path", session: "session-C")], to: "project/session-A/subagents/agent-c.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let d = await detail(cache)
        XCTAssertEqual(d.credits?.amount, 0)
        XCTAssertEqual(d.credits?.conflictRequests, 3)
        XCTAssertFalse(d.credits!.hasValue)
        XCTAssertTrue(d.sessions.contains { $0.sessionId == "usagebar:unresolved-credits" })
        assertConsistent(d)
    }

    func testFallbackIdentifiersAreMarkedAndAnonymousHistorySurvivesTruncation() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        let anonymous = response(nil, credits: 0.5, uuid: nil)
        try write([response(nil, messageId: "fallback-M"), response(nil, uuid: "fallback-U"), anonymous],
                  to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        try write([response(nil, credits: 0.25, at: "2026-09-22T07:00:00Z")], to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let d = await detail(cache)
        XCTAssertEqual(d.credits?.amount, 3.25)
        XCTAssertEqual(d.credits?.weakIdentityRequests, 4)
        assertConsistent(d)
    }

    func testStreamingSnapshotsOnlyCountCompletedRequestOnce() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        try write([response("one", credits: 99, stop: NSNull()), response("one", credits: 1.25, stop: "tool_use"),
                   response("one", credits: 1.25, stop: "tool_use"), response("two", credits: 0.75)],
                  to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let d = await detail(cache)
        XCTAssertEqual(d.credits?.amount, 2)
        XCTAssertEqual(d.credits?.recordedRequests, 2)
    }

    func testDateWindowsAcrossMidnightAndModelsUseExistingLocalBoundary() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        let now = ISODateParser.parse("2026-09-22T08:00:00Z")!
        let day = DailyAggregator.dateString(for: now)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = .current
        let midnight = formatter.date(from: day)!
        let iso = ISO8601DateFormatter()
        try write([response("before", credits: 0.1, at: iso.string(from: midnight.addingTimeInterval(-1))),
                   response("after", model: "second", credits: 0.2, at: iso.string(from: midnight.addingTimeInterval(1)))],
                  to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let today = await detail(cache, window: .today, now: now)
        let yesterday = await detail(cache, window: .yesterday, now: now)
        let all = await detail(cache)
        XCTAssertEqual(today.credits?.amount, Decimal(string: "0.2"))
        XCTAssertEqual(yesterday.credits?.amount, Decimal(string: "0.1"))
        XCTAssertEqual(all.credits?.amount, Decimal(string: "0.3"))
        XCTAssertEqual(all.sessions[0].models.count, 2)
        assertConsistent(all)
    }

    func testUnreadableAndMalformedFilesPreservePriorCreditsAndReportCoverage() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        let file = try write([response("one")], to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        try FileManager.default.removeItem(at: file)
        // 同名目录模拟真实读取失败，避免权限测试因运行身份而假通过。
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        var d = await detail(cache)
        XCTAssertEqual(d.credits?.amount, 1.25)
        XCTAssertTrue(d.credits!.sourceIssues)
        try FileManager.default.removeItem(at: file)
        try Data("not-json\n".utf8).write(to: file)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        d = await detail(cache)
        XCTAssertEqual(d.credits?.amount, 1.25)
        XCTAssertTrue(d.credits!.sourceIssues)
    }

    func testExistingTokenHistoryIsUnchangedAndOldCacheDecodesWithoutNewField() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        let file = try write([response("one", tokens: 10), response("two", credits: nil, tokens: 20)],
                             to: "project/session-A.jsonl", under: root)
        // 与旧版 provider 相同的扫描入口，避免 macOS /var 与 /private/var 临时路径别名。
        let scannedFile = try XCTUnwrap(JSONLReader.findFiles(under: root) { $0.pathExtension == "jsonl" }.first)
        let metadata = try XCTUnwrap(FileMetadata.read(at: scannedFile.path))
        let legacy = FileCacheEntry(filePath: scannedFile.path, mtime: metadata.mtime, size: metadata.size,
                                   records: [FileDailyRecord(provider: "qoder-cli", date: "2026-09-22", token: 30)],
                                   details: ClaudeDetailScanner.detailRecords(url: file, providerId: "qoder-cli", attachSource: false))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "qoderCredits")
        let decoded = try JSONDecoder().decode(FileCacheEntry.self, from: JSONSerialization.data(withJSONObject: object))
        await cache.store(decoded)
        _ = try await QoderCliProvider(projectsDir: root, segmentsRoot: root.appendingPathComponent("absent"), cache: cache).fetchDailyRecords()
        let stored = await cache.entry(forPath: scannedFile.path)
        XCTAssertEqual(stored, decoded)
        let d = await detail(cache)
        let tokenEntries = await cache.allEntries().filter { !$0.details.isEmpty }
        XCTAssertEqual(d.tokens.total, 30, "\(tokenEntries.map { ($0.filePath, $0.details.map { $0.tokens.total }) })")
        XCTAssertEqual(d.credits?.amount, 1.25)
        XCTAssertTrue(d.credits!.isPartial)
        assertConsistent(d)
    }

    func testConfirmedModelAliasesOnlyAndUnknownNamesRetainRawIdentity() throws {
        let root = try workspace(), catalog = root.appendingPathComponent("models")
        let rows = [["key":"dfmodel", "display_name":"DeepSeek-V4-Flash"],
                    ["key":"auto", "display_name":"Imagined underlying model"]]
        try JSONSerialization.data(withJSONObject: ["models":rows]).write(to: catalog)
        let names = QoderCreditsReader.modelNames(at: catalog)
        XCTAssertEqual(names["dfmodel"], "DeepSeek-V4-Flash")
        XCTAssertNil(names["auto"])
        XCTAssertNil(names["unknown"])
    }

    func testRewrittenMessageCannotSilentlyReplaceConflictingHistoricalCredits() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        let file = try write([response("one", credits: 1)], to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let originalMetadata = try XCTUnwrap(FileMetadata.read(at: file.path))
        try write([response("one", credits: 2)], to: "project/session-A.jsonl", under: root)
        try FileManager.default.setAttributes([.modificationDate: originalMetadata.mtime.addingTimeInterval(0.25)],
                                              ofItemAtPath: file.path)
        XCTAssertEqual(FileMetadata.read(at: file.path)?.size, originalMetadata.size)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let rewritten = await detail(cache)
        XCTAssertEqual(rewritten.credits?.conflictRequests, 1)
        try write([response("one", credits: 2), response("valid", credits: 0.5)],
                  to: "project/session-A.jsonl", under: root)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        try FileManager.default.removeItem(at: file)
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let d = await detail(cache)
        XCTAssertEqual(d.credits?.amount, 0.5)
        XCTAssertEqual(d.credits?.conflictRequests, 1)
        let files = await cache.allEntries().compactMap(\.qoderCredits).filter { !$0.observations.isEmpty }
        XCTAssertTrue(files.allSatisfy(\.sourceMissing))
        XCTAssertFalse(d.credits!.sourceIssues)
        assertConsistent(d)
    }

    func testCurrentCreditsDoNotClaimCoverageForOlderLogsInSameGroup() async throws {
        let root = try workspace(), cache = FileMtimeCache()
        let file = try write([response("one", credits: 1, tokens: 10)], to: "project/session-A.jsonl", under: root)
        let details = ClaudeDetailScanner.detailRecords(url: file, providerId: "qoder-cli", attachSource: false)
        await cache.store(FileCacheEntry(filePath: "/deleted/old-transcript.jsonl", mtime: .distantPast,
                                         size: 0, records: [], details: details))
        await cache.store(FileCacheEntry(filePath: "/logs/.usagebar-request-ledger/session-A/old-request", mtime: .distantPast,
                                         size: 0, records: [], details: details))
        await QoderCreditsReader.refresh(root: root, ledger: cache)
        let d = await detail(cache)
        XCTAssertEqual(d.tokens.total, 20)
        XCTAssertEqual(d.credits?.amount, 1)
        XCTAssertTrue(d.credits!.uncoveredHistory)
        XCTAssertTrue(d.models[0].credits!.isPartial)
        XCTAssertTrue(d.sessions[0].credits!.isPartial)
        assertConsistent(d)
    }
}
