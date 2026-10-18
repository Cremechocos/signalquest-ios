import XCTest
@testable import SignalQuest

final class ModelDecodeTests: XCTestCase {
    func testSocialFeedDecode() throws {
        let page = try JSONDecoder.signalQuest.decode(SocialFeedPage.self, from: Data(Self.feedJSON.utf8))
        XCTAssertEqual(page.items.first?.id, "post-1")
        XCTAssertEqual(page.items.first?.signal?.downloadMbps, 321)
        XCTAssertEqual(page.stories.count, 1)
    }

    private struct DateBox: Decodable { let d: Date }

    /// DEC-DATE-EPOCH-01 : le décodeur tolère une date en epoch numérique
    /// (secondes ou millisecondes) en plus des chaînes ISO — sinon un seul champ
    /// date en epoch ferait jeter tout l'objet/tableau parent.
    func testDateDecodingToleratesEpochAndISO() throws {
        let dec = JSONDecoder.signalQuest
        let ms = try dec.decode(DateBox.self, from: Data("{\"d\":1715421600000}".utf8))
        XCTAssertEqual(ms.d.timeIntervalSince1970, 1715421600, accuracy: 0.001)
        let s = try dec.decode(DateBox.self, from: Data("{\"d\":1715421600}".utf8))
        XCTAssertEqual(s.d.timeIntervalSince1970, 1715421600, accuracy: 0.001)
        let iso = try dec.decode(DateBox.self, from: Data("{\"d\":\"2024-05-11T10:00:00.000Z\"}".utf8))
        XCTAssertEqual(iso.d.timeIntervalSince1970, 1715421600, accuracy: 1)
    }

    func testMapSnapshotDecode() throws {
        let snapshot = try JSONDecoder.signalQuest.decode(SocialMapSnapshot.self, from: Data(Self.mapJSON.utf8))
        XCTAssertEqual(snapshot.speedtests.first?.averageSpeed, 210)
        XCTAssertEqual(snapshot.displayItems(include: [.speedtest]).count, 1)
    }

    func testPhotoAndMessageDecode() throws {
        let photo = try JSONDecoder.signalQuest.decode(Photo.self, from: Data(Self.photoJSON.utf8))
        XCTAssertEqual(photo.displayCaption, "Site photo")
        XCTAssertNil(photo.marketCode, "Les photos historiques restent décodables sans scope opérateur")

        let scopedPhoto = try JSONDecoder.signalQuest.decode(Photo.self, from: Data("""
        {"id":"p2","siteId":"site-2","description":"Support mutualisé","operator":"VODAFONE","marketCode":"DE","siteOperators":["VODAFONE","TELEKOM"]}
        """.utf8))
        XCTAssertEqual(scopedPhoto.marketCode, "DE")
        XCTAssertEqual(scopedPhoto.siteOperators, ["VODAFONE", "TELEKOM"])

        let messages = try JSONDecoder.signalQuest.decode(MessagesPageResponse.self, from: Data(Self.messagesJSON.utf8))
        XCTAssertEqual(messages.messages.first?.content, "Salut")
    }

    func testMyIdentificationDecodesPciStringAndGroupsByNode() throws {
        let response = try JSONDecoder.signalQuest.decode(MyIdentificationsResponse.self, from: Data("""
        {
          "identifications": [
            {"id":"n1","siteId":"site-1","type":"enb","enb":"12345","operator":"SFR","tech":"4G","validations":2,"sectors":[]},
            {"id":"p1","siteId":"site-1","type":"pci","enb":"12345","pci":"078","ci":"3160321","operator":"SFR","tech":"4G","validations":1,"sectors":[2]}
          ]
        }
        """.utf8))
        let pci = try XCTUnwrap(response.identifications.first { $0.id == "p1" })
        XCTAssertEqual(pci.pciValue, "078")
        XCTAssertEqual(pci.pci, 78)

        let groups = IdentifiedNodeGroup.group(response.identifications)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "eNB 12345")
        XCTAssertEqual(groups.first?.cells.first?.label, "PCI 078")
    }

    private static let feedJSON = """
    {"items":[{"id":"post-1","kind":"speedtest","createdAt":"2026-05-11T10:00:00.000Z","author":{"id":"u1","name":"Camille","handle":"camille","avatarUrl":null},"text":"Hello","attachments":[],"hashtags":["ios"],"reactions":[],"commentsCount":0,"repostsCount":0,"favoritesCount":0,"likedByMe":false,"favoritedByMe":false,"repostedByMe":false,"signal":{"downloadMbps":321,"detectedTechs":[]}}],"nextCursor":null,"stories":[{"id":"s1","author":{"id":"u1","name":"Camille","handle":"camille","avatarUrl":null},"text":"Story","mediaUrl":null,"thumbnailUrl":null,"mediaKind":"text","background":null,"metadata":null,"visibility":"public","status":"active","durationSeconds":5,"createdAt":"2026-05-11T10:00:00.000Z","expiresAt":null,"viewedByMe":false,"isMine":false}],"trendingHashtags":[],"suggestedUsers":[],"requestId":"req"}
    """

    // MARK: Accusés « distribué » / « lu »

    func testReceiptsDecodeIsLenient() throws {
        let dec = JSONDecoder.signalQuest
        let full = try dec.decode(ConversationReceipts.self, from: Data(#"""
        {"readReceipts":[{"userId":"u2","name":"Léa","lastReadAt":"2026-10-18T10:00:00.000Z"}],
         "deliveryReceipts":[{"userId":"u2","name":"Léa","lastDeliveredAt":"2026-10-18T10:00:05Z"},{"userId":"u3","name":null,"lastDeliveredAt":null}]}
        """#.utf8))
        XCTAssertEqual(full.readReceipts.count, 1)
        XCTAssertEqual(full.deliveryReceipts.map(\.userId), ["u2", "u3"])
        // Dates avec et sans fractions de seconde.
        XCTAssertEqual(try XCTUnwrap(full.readReceipts.first?.lastReadAt).timeIntervalSince1970, 1_792_317_600, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(full.deliveryReceipts.first?.lastDeliveredAt).timeIntervalSince1970, 1_792_317_605, accuracy: 1)
        XCTAssertNil(full.deliveryReceipts.last?.lastDeliveredAt)
        // Clés absentes ou de forme inattendue : listes vides, pas d'échec.
        XCTAssertEqual(try dec.decode(ConversationReceipts.self, from: Data("{}".utf8)), ConversationReceipts())
        let partial = try dec.decode(ConversationReceipts.self, from: Data(#"{"readReceipts":[{"userId":"u2"}],"deliveryReceipts":"x"}"#.utf8))
        XCTAssertEqual(partial.readReceipts.map(\.userId), ["u2"])
        XCTAssertTrue(partial.deliveryReceipts.isEmpty)
    }

    func testOwnMessageStatusInADirectConversation() {
        let sent = Date(timeIntervalSince1970: 1_000)
        func status(read: Date? = nil, delivered: Date? = nil, deliveryKnown: Bool = true) -> OwnMessageReceiptStatus {
            OwnMessageReceiptStatus.resolve(
                messageDate: sent, isGroup: false, currentUserId: "me", participantIds: ["me", "u2"],
                readReceipts: read.map { [ReadReceipt(userId: "u2", name: "Léa", lastReadAt: $0)] } ?? [],
                deliveryReceipts: deliveryKnown ? delivered.map { [DeliveryReceipt(userId: "u2", name: "Léa", lastDeliveredAt: $0)] } ?? [] : []
            )
        }
        XCTAssertEqual(status(), .sent)
        XCTAssertEqual(status(delivered: sent.addingTimeInterval(-1)), .sent, "Distribué avant l'envoi : ne couvre pas ce message")
        XCTAssertEqual(status(delivered: sent.addingTimeInterval(2)), .delivered)
        XCTAssertEqual(status(read: sent.addingTimeInterval(5), delivered: sent.addingTimeInterval(2)), .read)
        // Dates égales : l'accusé couvre le message.
        XCTAssertEqual(status(delivered: sent), .delivered)
        XCTAssertEqual(status(read: sent), .read)
        // Sans accusés de distribution (route absente) : le lu seul fait foi, comme avant.
        XCTAssertEqual(status(read: sent.addingTimeInterval(1), deliveryKnown: false), .read)
        XCTAssertEqual(status(deliveryKnown: false), .sent)
        // Un lu sans ligne « distribué » vaut distribué mais le lu l'emporte.
        XCTAssertEqual(status(read: sent.addingTimeInterval(1)), .read)
        // Ses propres accusés ne comptent jamais.
        let ownOnly = OwnMessageReceiptStatus.resolve(
            messageDate: sent, isGroup: false, currentUserId: "me", participantIds: ["me", "u2"],
            readReceipts: [ReadReceipt(userId: "me", name: nil, lastReadAt: sent.addingTimeInterval(9))],
            deliveryReceipts: [DeliveryReceipt(userId: "me", name: nil, lastDeliveredAt: sent.addingTimeInterval(9))]
        )
        XCTAssertEqual(ownOnly, .sent)
    }

    func testOwnMessageStatusInAGroupNeedsEveryoneForDeliveredAndRead() {
        let sent = Date(timeIntervalSince1970: 1_000)
        let members = ["me", "a", "b", "c"]
        func status(read: [String: Double] = [:], delivered: [String: Double] = [:], members: [String] = members) -> OwnMessageReceiptStatus {
            OwnMessageReceiptStatus.resolve(
                messageDate: sent, isGroup: true, currentUserId: "me", participantIds: members,
                readReceipts: read.sorted { $0.key < $1.key }.map { ReadReceipt(userId: $0.key, name: $0.key.uppercased(), lastReadAt: sent.addingTimeInterval($0.value)) },
                deliveryReceipts: delivered.sorted { $0.key < $1.key }.map { DeliveryReceipt(userId: $0.key, name: $0.key.uppercased(), lastDeliveredAt: sent.addingTimeInterval($0.value)) }
            )
        }
        XCTAssertEqual(status(), .sent)
        XCTAssertEqual(status(delivered: ["a": 1, "b": 1]), .sent, "Un membre n'a pas encore reçu")
        XCTAssertEqual(status(delivered: ["a": 1, "b": 1, "c": 0]), .delivered)
        // Lu partiel : l'existant « Vu par … ».
        XCTAssertEqual(status(read: ["a": 1], delivered: ["a": 1, "b": 1, "c": 1]), .seenBy(["A"]))
        XCTAssertEqual(status(read: ["a": 1, "c": 2]), .seenBy(["A", "C"]))
        XCTAssertEqual(status(read: ["a": 1, "b": 1, "c": 1]), .read)
        // Un lu compte aussi comme reçu : deux lus + un distribué = tous ont reçu, deux seulement ont lu.
        XCTAssertEqual(status(read: ["a": 1, "b": 1], delivered: ["c": 1]), .seenBy(["A", "B"]))
        // Membres inconnus : les autres se déduisent des accusés.
        XCTAssertEqual(status(delivered: ["a": 1, "b": 1], members: []), .delivered)
        // Un lu dont les noms manquent ne produit pas un « Vu par » vide.
        let anonymous = OwnMessageReceiptStatus.resolve(
            messageDate: sent, isGroup: true, currentUserId: "me", participantIds: members,
            readReceipts: [ReadReceipt(userId: "a", name: nil, lastReadAt: sent)], deliveryReceipts: []
        )
        XCTAssertEqual(anonymous, .sent)
    }

    private static let mapJSON = """
    {"timestamp":"2026-05-11T10:00:00.000Z","friends":[],"photos":[],"validations":[],"sessions":[],"coveragePoints":[],"speedtests":[{"id":"sp1","userId":"u1","latitude":48.85,"longitude":2.35,"averageSpeed":210,"uploadAvg":42,"pingAvg":18,"timestamp":"2026-05-11T10:00:00.000Z","networkType":"WIFI","mobileOperator":"SignalQuest"}],"photosCount":0,"validationsCount":0,"sessionsCount":0,"coveragePointsCount":0,"speedtestsCount":1,"rawCoveragePointsCount":0,"logicalCoveragePointsCount":0}
    """

    private static let photoJSON = """
    {"id":"p1","siteId":"site-1","imageUrl":null,"thumbnailUrl":null,"uploadedAt":"2026-05-11T10:00:00.000Z","description":"Site photo","likes":3,"operator":"SFR"}
    """

    private static let messagesJSON = """
    {"hasMore":false,"nextCursor":null,"messages":[{"id":"m1","conversationId":"c1","senderId":"u1","kind":"TEXT","content":"Salut","createdAt":"2026-05-11T10:00:00.000Z","attachments":[],"reactions":[]}],"readReceipts":[]}
    """
}
