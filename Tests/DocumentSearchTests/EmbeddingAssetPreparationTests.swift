import XCTest
@testable import DocumentSearch

private actor AssetDownload {
    private(set) var calls = 0
    private var completion: CheckedContinuation<Bool, Never>?
    private var finished: Bool?
    private var started: [CheckedContinuation<Void, Never>] = []

    func run() async -> Bool {
        calls += 1
        if let finished { return finished }
        return await withCheckedContinuation { continuation in
            completion = continuation
            started.forEach { $0.resume() }
            started = []
        }
    }

    func waitUntilStarted() async {
        if completion != nil { return }
        await withCheckedContinuation { started.append($0) }
    }

    func finish(_ available: Bool) {
        finished = available
        completion?.resume(returning: available)
        completion = nil
    }

    func reset() { finished = nil }
}

final class EmbeddingAssetPreparationTests: XCTestCase {
    func testConcurrentPreparationSharesOneDownload() async {
        let preparation = EmbeddingAssetPreparation()
        let download = AssetDownload()
        let tasks = (0..<8).map { _ in Task { await preparation.request { await download.run() } } }
        await download.waitUntilStarted()
        // Give every caller a chance to join the shared request before completing it.
        try? await Task.sleep(for: .milliseconds(20))
        await download.finish(true)
        for task in tasks { let result = await task.value; XCTAssertTrue(result) }
        let calls = await download.calls
        XCTAssertEqual(calls, 1)
    }

    func testFailedDownloadCanBeRetried() async {
        let preparation = EmbeddingAssetPreparation()
        let download = AssetDownload()
        let first = Task { await preparation.request { await download.run() } }
        await download.waitUntilStarted()
        await download.finish(false)
        let failed = await first.value
        XCTAssertFalse(failed)

        await download.reset()
        let retry = Task { await preparation.request { await download.run() } }
        await download.waitUntilStarted()
        await download.finish(true)
        let ready = await retry.value
        XCTAssertTrue(ready)
        let calls = await download.calls
        XCTAssertEqual(calls, 2)
    }

    func testCancelledCallerDoesNotCancelTheSharedDownload() async {
        let preparation = EmbeddingAssetPreparation()
        let download = AssetDownload()
        let first = Task { await preparation.request { await download.run() } }
        await download.waitUntilStarted()
        first.cancel()
        let nextSession = Task { await preparation.request { await download.run() } }
        try? await Task.sleep(for: .milliseconds(20))
        await download.finish(true)
        let nextReady = await nextSession.value
        XCTAssertTrue(nextReady)
        _ = await first.value
        let calls = await download.calls
        XCTAssertEqual(calls, 1)
    }
}
