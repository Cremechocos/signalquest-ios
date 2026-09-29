import Foundation
import XCTest
@testable import SignalQuest

/// Correctifs de fiabilité du plan 2 (Lot 1) qui ne relèvent d'aucune suite existante.
final class Lot1ReliabilityTests: XCTestCase {

    // MARK: SOC-05 — événements de conversation

    func testStateEventsAreReadFromThePayloadTypeOfTheGenericUpdate() {
        // Le serveur double un vote : `poll_voted`, puis un `update` qui porte le même type.
        XCTAssertEqual(SyncTrigger.from(event: "poll_voted", data: "{}"), .stateEvent)
        XCTAssertEqual(SyncTrigger.from(event: "update", data: #"{"type":"message_reaction","messageId":"m1"}"#), .stateEvent)
        XCTAssertEqual(SyncTrigger.from(event: "update", data: #"{"type":"read_state"}"#), .stateEvent)
        XCTAssertEqual(SyncTrigger.from(event: "update", data: #"{"type":"message_created"}"#), .serverEvent)
        XCTAssertEqual(SyncTrigger.from(event: "message", data: "not json"), .serverEvent)
        XCTAssertEqual(SyncTrigger.from(event: "typing", data: "{}"), .typingEvent)
        XCTAssertEqual(SyncTrigger.from(event: "viewing", data: "{}"), .viewingEvent)
    }

    // MARK: SOC-02 / SOC-04 — refus définitifs

    func testOnlyDefinitiveClientErrorsAreTreatedAsPermanent() {
        func http(_ status: Int) -> APIError {
            .http(status: status, code: nil, message: "", requestId: nil, retryAfter: nil)
        }
        for status in [400, 403, 404, 409, 410, 413, 422] {
            XCTAssertTrue(http(status).isPermanentRequestFailure, "\(status)")
        }
        for status in [401, 408, 425, 429, 500, 502, 503] {
            XCTAssertFalse(http(status).isPermanentRequestFailure, "\(status)")
        }
        XCTAssertFalse(URLError(.notConnectedToInternet).isPermanentRequestFailure)
        XCTAssertFalse(APIError.transport("offline").isPermanentRequestFailure)
        XCTAssertFalse(CancellationError().isPermanentRequestFailure)
    }

    // MARK: OBS-01 — non-fatals sans contenu

    func testDiagnosticsKeepIdentifiersButNeverTheServerMessage() {
        let error = APIError.http(status: 422, code: "INVALID_POLL", message: "Texte privé de l’utilisateur",
                                  requestId: "req-123", retryAfter: nil)
        let report = SQDiagnostics.sanitized(error, area: .postOutbox)
        XCTAssertEqual(report.domain, "SQ.post_outbox.http")
        XCTAssertEqual(report.code, 422)
        XCTAssertEqual(report.userInfo["apiCode"] as? String, "INVALID_POLL")
        XCTAssertEqual(report.userInfo["requestId"] as? String, "req-123")
        let dump = report.userInfo.values.map { "\($0)" }.joined(separator: " ")
        XCTAssertFalse(dump.contains("privé"), "Le message du serveur ne doit jamais partir")
        XCTAssertNil(report.userInfo[NSLocalizedDescriptionKey])
    }

    func testOfflineAndCancelledFailuresAreNotReported() {
        XCTAssertFalse(SQDiagnostics.shouldReport(CancellationError()))
        XCTAssertFalse(SQDiagnostics.shouldReport(APIError.cancelled))
        XCTAssertFalse(SQDiagnostics.shouldReport(APIError.transport("offline")))
        XCTAssertFalse(SQDiagnostics.shouldReport(URLError(.timedOut)))
        XCTAssertTrue(SQDiagnostics.shouldReport(APIError.decoding("shape")))
        XCTAssertTrue(SQDiagnostics.shouldReport(
            APIError.http(status: 500, code: nil, message: "", requestId: nil, retryAfter: nil)))
    }

    func testDecodingContextNamesTheFieldPathWithoutAnyValue() throws {
        struct Probe: Decodable { struct Item: Decodable { let count: Int }; let items: [Item] }
        let json = Data(#"{"items":[{"count":1},{"count":"secret-value"}]}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Probe.self, from: json)
            XCTFail("Le type attendu est un entier")
        } catch {
            let context = SQDiagnostics.decodingContext(error, type: Probe.self)
            XCTAssertEqual(context["type"], "Probe")
            XCTAssertEqual(context["codingPath"], "items.[1].count")
            XCTAssertFalse(context.values.contains { $0.contains("secret-value") })
        }
    }

    // MARK: SOC-09 — e-mails des membres

    func testMemberSearchShowsTheHandleAndNeverTheEmail() throws {
        let json = Data(#"{"id":"u1","name":null,"handle":"alex","email":"alex@example.com"}"#.utf8)
        let user = try JSONDecoder().decode(MessageSearchUser.self, from: json)
        XCTAssertEqual(user.displayName, "alex")
        XCTAssertEqual(user.publicSubtitle, "@alex")
        let anonymous = try JSONDecoder().decode(MessageSearchUser.self,
            from: Data(#"{"id":"u2","email":"hidden@example.com"}"#.utf8))
        XCTAssertFalse(anonymous.displayName.contains("hidden"))
        XCTAssertNil(anonymous.publicSubtitle)
    }

    // MARK: SOC-32 — transcription réservée aux notes vocales

    func testTranscriptionIsOfferedOnlyForVoiceNotes() throws {
        func message(_ attachments: String) throws -> MessageItem {
            let json = #"{"id":"m","kind":"TEXT","content":"bonjour","attachments":\#(attachments),"reactions":[]}"#
            return try JSONDecoder.signalQuest.decode(MessageItem.self, from: Data(json.utf8))
        }
        XCTAssertFalse(try message("[]").hasVoiceNote)
        XCTAssertFalse(try message(#"[{"kind":"IMAGE","contentType":"image/jpeg"}]"#).hasVoiceNote)
        XCTAssertTrue(try message(#"[{"kind":"AUDIO"}]"#).hasVoiceNote)
        XCTAssertTrue(try message(#"[{"kind":"FILE","contentType":"audio/m4a"}]"#).hasVoiceNote)
    }
}
