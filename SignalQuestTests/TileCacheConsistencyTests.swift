import XCTest
@testable import SignalQuest

@MainActor
final class TileCacheConsistencyTests: XCTestCase {
    private func makeDisk() -> DiskCache {
        let name = "SQTileConsistency-\(UUID().uuidString)"
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return DiskCache(folderName: name)
    }

    func testDiskPromotionDoesNotRenewTheOriginDate() async throws {
        let disk = makeDisk()
        let clock = TileTestClock(Date(timeIntervalSince1970: 100))
        try await disk.write(Data("old".utf8), for: TileCache.storagePrefix + "a", createdAt: Date(timeIntervalSince1970: 90))
        let cache = TileCache(disk: disk, memoryTTL: 20, diskTTL: 20, now: { clock.value })
        let first = try await cache.data(for: "a") { Data("unexpected".utf8) }
        XCTAssertEqual(first, Data("old".utf8))
        clock.advance(15)
        let second = try await cache.data(for: "a") { Data("fresh".utf8) }
        XCTAssertEqual(second, Data("fresh".utf8))
        let stored = try await disk.readEntry(Data.self, for: TileCache.storagePrefix + "a")
        XCTAssertEqual(stored?.createdAt, clock.value)
    }

    func testForcedRefreshDoesNotJoinAnOlderNormalRequest() async throws {
        let disk = makeDisk()
        let cache = TileCache(disk: disk)
        let gate = TileFetchGate()
        let old = Task { try await cache.data(for: "a") { await gate.fetch() } }
        await gate.waitUntilStarted()
        let current = try await cache.data(for: "a", maxAge: 0) { Data("new".utf8) }
        XCTAssertEqual(current, Data("new".utf8))
        await gate.finish(Data("old".utf8))
        do { _ = try await old.value; XCTFail("A superseded response was returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        let relaunched = TileCache(disk: disk)
        let persisted = try await relaunched.data(for: "a") { Data("unexpected".utf8) }
        XCTAssertEqual(persisted, Data("new".utf8))
    }

    func testNormalRequestsCoalesceTheirNetworkWork() async throws {
        let cache = TileCache(disk: makeDisk())
        let gate = TileFetchGate()
        let first = Task { try await cache.data(for: "a") { await gate.fetch() } }
        await gate.waitUntilStarted()
        let second = Task { try await cache.data(for: "a") { await gate.fetch() } }
        await gate.finish(Data("one".utf8))
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [Data("one".utf8), Data("one".utf8)])
        let count = await gate.calls
        XCTAssertEqual(count, 1)
    }

    func testInvalidResponseIsNotPersistedAndCanBeRetried() async throws {
        let disk = makeDisk()
        let cache = TileCache(disk: disk)
        do {
            _ = try await cache.data(for: "a", validate: Self.validateJSON) { Data("invalid".utf8) }
            XCTFail("Invalid JSON entered the cache")
        } catch { XCTAssertTrue(error is DecodingError) }
        let rejected = try await disk.read(Data.self, for: TileCache.storagePrefix + "a")
        XCTAssertNil(rejected)
        let valid = Data(#"{"value":2}"#.utf8)
        let result = try await cache.data(for: "a", validate: Self.validateJSON) { valid }
        XCTAssertEqual(result, valid)
    }

    func testInvalidDiskEntryFallsBackToTheNetwork() async throws {
        let disk = makeDisk()
        try await disk.write(Data("invalid".utf8), for: TileCache.storagePrefix + "a")
        let cache = TileCache(disk: disk)
        let valid = Data(#"{"value":3}"#.utf8)
        let result = try await cache.data(for: "a", validate: Self.validateJSON) { valid }
        XCTAssertEqual(result, valid)
    }

    func testInvalidationDrainsWritesAndRejectsLateResponses() async throws {
        let disk = makeDisk()
        let cache = TileCache(disk: disk)
        try await disk.write("keep", for: "unrelated-owner-data")
        _ = try await cache.data(for: "a") { Data("visible".utf8) }
        let gate = TileFetchGate()
        let late = Task { try await cache.data(for: "a", maxAge: 0) { await gate.fetch() } }
        await gate.waitUntilStarted()
        await cache.removeAll()
        await gate.finish(Data("visible-again".utf8))
        do { _ = try await late.value; XCTFail("Invalidated response repopulated the cache") }
        catch { XCTAssertTrue(error is CancellationError) }
        let stored = try await disk.read(Data.self, for: TileCache.storagePrefix + "a")
        XCTAssertNil(stored)
        let neighbour = try await disk.read(String.self, for: "unrelated-owner-data")
        XCTAssertEqual(neighbour, "keep")
        let relaunched = TileCache(disk: disk)
        let result = try await relaunched.data(for: "a") { Data("hidden".utf8) }
        XCTAssertEqual(result, Data("hidden".utf8))
    }

    func testDisabledCacheDoesNotFetchTwiceForOneRequest() async throws {
        let cache = TileCache(disk: makeDisk(), memoryTTL: 0, diskTTL: 0)
        let counter = TileFetchCounter()
        let result = try await cache.data(for: "a") { await counter.next() }
        XCTAssertEqual(result, Data("1".utf8))
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testFailedForcedRefreshKeepsThePreviousValidEntry() async throws {
        let cache = TileCache(disk: makeDisk())
        let valid = Data(#"{"value":1}"#.utf8)
        _ = try await cache.data(for: "a", validate: Self.validateJSON) { valid }
        do {
            _ = try await cache.data(for: "a", maxAge: 0, validate: Self.validateJSON) { Data("invalid".utf8) }
            XCTFail("Malformed refresh succeeded")
        } catch { XCTAssertTrue(error is DecodingError) }
        let retained = try await cache.data(for: "a", validate: Self.validateJSON) { Data("unexpected".utf8) }
        XCTAssertEqual(retained, valid)
    }

    private nonisolated static func validateJSON(_ data: Data) throws {
        struct Payload: Decodable { let value: Int }
        _ = try JSONDecoder().decode(Payload.self, from: data)
    }
}

private final class TileTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor TileFetchGate {
    private var waiter: CheckedContinuation<Data, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    func fetch() async -> Data {
        calls += 1
        return await withCheckedContinuation { continuation in
            waiter = continuation
            for pending in startWaiters { pending.resume() }
            startWaiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func finish(_ data: Data) { waiter?.resume(returning: data); waiter = nil }
}

private actor TileFetchCounter {
    private(set) var count = 0
    func next() -> Data { count += 1; return Data(String(count).utf8) }
}
