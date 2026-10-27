import XCTest
@testable import SignalQuest

/// Marqueur de conversation (E2EE-AUTO §7.2, révision 13) : lecture tolérante de
/// `e2eeAuto` et `firstAutoEpochNumber`, numéro retenu jamais remonté, puis
/// décision par époque, rejoués sur `contracts/e2ee-auto/epoch-markers-v1.json`.
final class E2EEAutoConversationMarkersTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/epoch-markers-v1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// La liste et le détail se lisent de façon tolérante : la colonne `tolerant`.
    func testConversationMarkersReadTolerantly() throws {
        let markers = try XCTUnwrap(try vector()["markers"] as? [[String: Any]])
        XCTAssertEqual(markers.count, 13)
        for marker in markers {
            let name = try XCTUnwrap(marker["name"] as? String)
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(marker["conversation"]))
            let conversation = try JSONDecoder().decode(MessageConversation.self, from: data)
            let tolerant = try XCTUnwrap(marker["tolerant"] as? [String: Any])
            let expected = (tolerant["firstAutoEpochNumber"] as? NSNumber)?.intValue
            XCTAssertEqual(conversation.firstAutoEpochNumber, expected, name)
            XCTAssertEqual(conversation.firstAutoEpochNumber != nil, tolerant["e2eeAuto"] as? Bool, name)
        }
    }

    func testScenariosRetainTheSmallestNumberAndDecide() throws {
        let scenarios = try XCTUnwrap(try vector()["scenarios"] as? [[String: Any]])
        XCTAssertEqual(scenarios.count, 7)
        for scenario in scenarios {
            let name = try XCTUnwrap(scenario["name"] as? String)
            let served = try XCTUnwrap(scenario["served"] as? [String: Any])
            let servedNumber = (served["firstAutoEpochNumber"] as? NSNumber)?.intValue
            let local = (scenario["localRetained"] as? NSNumber)?.intValue
            let marked = try XCTUnwrap(scenario["markedEpochsRead"] as? [Int])

            // Le numéro servi passe par la mémoire de l'app, avec le numéro gardé localement.
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "e2ee-auto-markers-\(UUID().uuidString)"))
            let store = E2EEAutoConversationMarkers(defaults: defaults)
            var conversation = MessageConversation(
                id: "conv_a", title: nil, isGroup: false, e2eeEnabled: true, groupPhotoUrl: nil, createdAt: nil,
                updatedAt: nil, lastMessageAt: nil, lastReadAt: nil, pinnedAt: nil, participants: [], lastMessage: nil
            )
            conversation.firstAutoEpochNumber = servedNumber
            store.record([conversation], ownerScopeId: "user:alice")
            let localWithMarked = ([local].compactMap { $0 } + marked).min()
            let retained = store.guardNumber(local: localWithMarked, conversationId: "conv_a", ownerScopeId: "user:alice")
            XCTAssertEqual(retained, (scenario["retained"] as? NSNumber)?.intValue, name)

            for read in try XCTUnwrap(scenario["reads"] as? [[String: Any]]) {
                let decision = E2EEAutoConversationMarkers.decide(
                    epochNumber: try XCTUnwrap(read["epochNumber"] as? Int), marked: try XCTUnwrap(read["marked"] as? Bool),
                    retained: retained, servedAuto: try XCTUnwrap(served["e2eeAuto"] as? Bool)
                )
                XCTAssertEqual(decision.rawValue, read["expect"] as? String, "\(name) : \(read)")
            }
        }
    }

    /// Un numéro servi plus grand ne remonte jamais la garde, d'une lecture à l'autre.
    func testRecordedNumberNeverRises() throws {
        let store = E2EEAutoConversationMarkers(defaults: try XCTUnwrap(UserDefaults(suiteName: "e2ee-auto-markers-\(UUID().uuidString)")))
        func served(_ number: Int?) -> MessageConversation {
            var conversation = MessageConversation(
                id: "conv_a", title: nil, isGroup: false, e2eeEnabled: true, groupPhotoUrl: nil, createdAt: nil,
                updatedAt: nil, lastMessageAt: nil, lastReadAt: nil, pinnedAt: nil, participants: [], lastMessage: nil
            )
            conversation.firstAutoEpochNumber = number
            return conversation
        }
        store.record([served(6)], ownerScopeId: "user:alice")
        store.record([served(9)], ownerScopeId: "user:alice")
        store.record([served(nil)], ownerScopeId: "user:alice")
        XCTAssertEqual(store.firstAutoEpochNumber(conversationId: "conv_a", ownerScopeId: "user:alice"), 6)
        store.record([served(3)], ownerScopeId: "user:alice")
        XCTAssertEqual(store.firstAutoEpochNumber(conversationId: "conv_a", ownerScopeId: "user:alice"), 3)
        XCTAssertNil(store.firstAutoEpochNumber(conversationId: "conv_a", ownerScopeId: "user:bob"), "par compte")
    }
}
