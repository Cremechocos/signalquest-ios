import XCTest
@testable import SignalQuest

final class SSEFrameParserTests: XCTestCase {
    private func parse(_ text: String) throws -> [SSEFrameParser.Frame] {
        var parser = SSEFrameParser()
        return try text.utf8.compactMap { try parser.append($0) }
    }

    func testLFFramesDispatchAtEmptyLinesAndIgnoreHeartbeats() throws {
        XCTAssertEqual(try parse(": heartbeat\n\nevent: snapshot\ndata: {\"items\":[]}\n\n"),
                       [.init(event: "snapshot", data: "{\"items\":[]}")])
    }

    func testCRLFCRAndUTF8FragmentsPreservePayload() throws {
        XCTAssertEqual(try parse("\u{FEFF}event: snapshot\r\ndata: é😊\r\ndata: deuxième ligne\r\n\r\n"),
                       [.init(event: "snapshot", data: "é😊\ndeuxième ligne")])
        XCTAssertEqual(try parse("data: one\r\rdata: two\r\r"),
                       [.init(event: "message", data: "one"), .init(event: "message", data: "two")])
    }

    func testEventOrderingEmptyDataAndWhitespaceFollowFraming() throws {
        XCTAssertEqual(try parse("data:  value  \nevent: update\n\ndata:\n\n"),
                       [.init(event: "update", data: " value  "), .init(event: "message", data: "")])
    }

    func testUnterminatedEventDoesNotLeakIntoAnotherConnection() throws {
        XCTAssertTrue(try parse("event: old\ndata: partial").isEmpty)
        XCTAssertEqual(try parse("data: current\n\n"), [.init(event: "message", data: "current")])
    }

    func testOversizedLineOrFrameIsRejected() {
        for input in [String(repeating: "x", count: 40), String(repeating: "data:\n", count: 8)] {
            var parser = SSEFrameParser(limit: 32)
            XCTAssertThrowsError(try input.utf8.forEach { _ = try parser.append($0) })
        }
    }
}
