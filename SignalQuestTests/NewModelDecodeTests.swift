import XCTest
@testable import SignalQuest

final class NewModelDecodeTests: XCTestCase {
    /// Régression BUG-A : le backend (zod) exige la clé JSON `text`. Envoyer
    /// `content` renvoyait 400 INVALID_COMMENT et l'app croyait l'envoi échoué.
    func testCreateCommentRequestEncodesTextKey() throws {
        let data = try JSONEncoder.signalQuest.encode(CreateCommentRequest(text: "salut", parentId: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "salut")
        XCTAssertNil(json["content"], "Ne doit plus émettre la clé 'content'")
    }

    func testDecodeAntennaSite() throws {
        let json = """
        [{
            "id": "site-1",
            "siteId": "SFR123",
            "lat": 48.8,
            "lng": 2.35,
            "operators": ["SFR", "Orange"],
            "technologies": ["4G", "5G"],
            "address": "1 rue de Paris"
        }]
        """
        let sites = try JSONDecoder.signalQuest.decode([AntennaSite].self, from: Data(json.utf8))
        XCTAssertEqual(sites.first?.siteId, "SFR123")
        XCTAssertEqual(sites.first?.latitude, 48.8)
        XCTAssertEqual(sites.first?.operators.count, 2)
        XCTAssertTrue(sites.first?.technologies.contains("5G") ?? false)
    }

    func testDecodeSocialCommentsLenient() throws {
        let json = """
        {
            "items": [
                {"id": "c1", "author": {"id": "u1", "name": "Camille"}, "content": "Top !", "createdAt": "2026-05-11T10:00:00.000Z"},
                {"id": "c2", "author": {"id": "u2", "handle": "nora"}, "text": "👏", "likes": 4, "likedByMe": true}
            ],
            "cursor": "next"
        }
        """
        let response = try JSONDecoder.signalQuest.decode(SocialCommentsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.comments.count, 2)
        XCTAssertEqual(response.comments[0].text, "Top !")
        XCTAssertEqual(response.comments[1].likes, 4)
        XCTAssertEqual(response.nextCursor, "next")
    }

    func testDecodeFriendsList() throws {
        let json = """
        {
            "friends": [
                {
                    "friendshipId": "f1",
                    "userId": "u1",
                    "name": "Camille",
                    "email": "c@x.fr",
                    "avatarUrl": null,
                    "presence": {"status": "online", "isOnline": true, "lastSeenAt": "2026-05-11T10:00:00.000Z"}
                }
            ]
        }
        """
        struct Response: Codable { let friends: [Friend] }
        let response = try JSONDecoder.signalQuest.decode(Response.self, from: Data(json.utf8))
        XCTAssertEqual(response.friends.first?.displayName, "Camille")
        XCTAssertEqual(response.friends.first?.presence?.isOnline, true)
    }

    func testDecodeGamificationProfile() throws {
        let json = """
        {
            "level": 5,
            "points": 1240,
            "xpToNextLevel": 500,
            "consecutiveDays": 14,
            "badges": [
                {"id": "b1", "title": "Premier speedtest", "tier": "bronze"}
            ]
        }
        """
        let profile = try JSONDecoder.signalQuest.decode(GamificationProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.level, 5)
        XCTAssertEqual(profile.badges.count, 1)
        XCTAssertEqual(profile.badges.first?.tier, "bronze")
    }

    func testDecodeGamificationProfileWrappedBackendShape() throws {
        let json = """
        {
            "profile": {
                "points": 10099,
                "level": 32,
                "pointsToNextLevel": 141,
                "consecutiveDays": 4,
                "badges": [
                    {"id": "speedtester_bronze", "name": "Testeur Débutant", "icon": "📊", "tier": "bronze"}
                ]
            },
            "events": [
                {"id": "e1", "type": "speedtest", "points": 4, "createdAt": "2026-05-11T10:00:00.000Z"}
            ]
        }
        """
        let profile = try JSONDecoder.signalQuest.decode(GamificationProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.level, 32)
        XCTAssertEqual(profile.xpToNextLevel, 141)
        XCTAssertEqual(profile.badges.first?.title, "Testeur Débutant")
        XCTAssertEqual(profile.badges.first?.icon, "📊")
    }

    func testDecodeMessageConversationWithEmptyAvatarAndEncryptedLastMessage() throws {
        let json = """
        {
            "conversations": [{
                "id": "c1",
                "title": null,
                "isGroup": false,
                "e2eeEnabled": true,
                "groupPhotoUrl": "",
                "createdAt": "2026-04-05T17:46:25.492Z",
                "participants": [{
                    "userId": "u1",
                    "role": "member",
                    "user": {"id": "u1", "name": "Samuel", "email": "samuel@example.com", "avatarUrl": ""},
                    "presence": {"status": "online", "isOnline": false}
                }],
                "lastMessage": {
                    "id": "m1",
                    "kind": "TEXT",
                    "content": "",
                    "e2eeVersion": 1,
                    "e2eeIvB64": "ZIJBFR6bfacJYcIS",
                    "e2eeCiphertextB64": "n5rpro6IvodAv9ZyPQHF54By65g=",
                    "createdAt": "2026-04-25T20:14:00.050Z",
                    "sender": {"id": "u1", "name": "Samuel", "email": "samuel@example.com", "avatarUrl": ""}
                }
            }],
            "hasMore": false,
            "nextCursor": null
        }
        """
        let response = try JSONDecoder.signalQuest.decode(ConversationsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.conversations.count, 1)
        XCTAssertEqual(response.conversations.first?.participants.first?.user.avatarUrl, nil)
        XCTAssertEqual(response.conversations.first?.lastMessage?.isEncrypted, true)
    }

    func testDecodeUserStatsFromBackendShape() throws {
        let json = """
        {
            "profile": {
                "name": "SQ iOS Test",
                "bio": null,
                "avatarUrl": null,
                "createdAt": "2026-06-10T09:08:14.234Z",
                "level": 3,
                "gamificationPoints": 87,
                "consecutiveDays": 0
            },
            "validations": [],
            "speedtests": [
                {
                    "id": "cmq9b71mq0qcq2frtjy2naab4",
                    "downloadSpeed": 516.936296,
                    "uploadSpeed": 260.440072,
                    "averageSpeed": 434.1565232,
                    "ping": 15.712,
                    "connectionType": "WIFI"
                },
                {
                    "id": "cmq9b4df00qbi2frte32zs6rl",
                    "downloadSpeed": 508.342104,
                    "uploadSpeed": 270.663704,
                    "averageSpeed": 445.1554664,
                    "ping": 17.227,
                    "connectionType": "WIFI"
                }
            ],
            "signalRatings": [],
            "photos": [
                {
                    "id": "cmq9jp3eo0y1v2frtowfv331f",
                    "siteId": "2987654"
                }
            ]
        }
        """
        let stats = try JSONDecoder.signalQuest.decode(UserStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.level, 3)
        XCTAssertEqual(stats.totalPoints, 87)
        XCTAssertEqual(stats.totalSpeedtests, 2)
        XCTAssertEqual(stats.totalPhotos, 1)
        XCTAssertEqual(stats.totalValidations, 0)
        XCTAssertNil(stats.totalCoverageSessions)
    }

    func testDecodeUserStatsFlatLegacy() throws {
        let json = """
        {
            "totalSpeedtests": 12,
            "totalPhotos": 5,
            "totalValidations": 3,
            "totalCoverageSessions": 2,
            "totalPoints": 1500,
            "level": 4
        }
        """
        let stats = try JSONDecoder.signalQuest.decode(UserStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.level, 4)
        XCTAssertEqual(stats.totalPoints, 1500)
        XCTAssertEqual(stats.totalSpeedtests, 12)
        XCTAssertEqual(stats.totalPhotos, 5)
        XCTAssertEqual(stats.totalValidations, 3)
        XCTAssertEqual(stats.totalCoverageSessions, 2)
    }
}
