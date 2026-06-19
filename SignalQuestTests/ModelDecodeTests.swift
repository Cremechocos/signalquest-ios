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
