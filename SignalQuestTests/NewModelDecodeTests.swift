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

    // MARK: - Pannes communautaires

    /// Une panne telle que la route de DÉTAIL la rend : adresse dénormalisée, droit de fermeture
    /// arbitré par le serveur, chronologie chargée.
    private func outageJSON(timeline: String) -> Data {
        Data("""
        {
            "id": "o1",
            "targetKind": "anfr",
            "targetId": "3079254",
            "marketCode": "FR",
            "operatorKey": "SFR",
            "latitude": 45.18,
            "longitude": 5.72,
            "siteName": "Site 3079254",
            "address": "12 rue des Alpes, 38000 Grenoble",
            "state": "confirmed",
            "severity": "degraded",
            "affectsData": true,
            "affectsVoice": false,
            "affectsSms": false,
            "confirmCount": 3,
            "disputeCount": 0,
            "confirmationsRemaining": 0,
            "confirmThreshold": 3,
            "operatorConfirmed": false,
            "startedAt": "2026-08-11T09:12:00.000Z",
            "myVote": "report",
            "canVote": false,
            "canClose": true,
            "timeline": \(timeline)
        }
        """.utf8)
    }

    func testDecodeCommunityOutageAddressAndCanClose() throws {
        let outage = try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: outageJSON(timeline: "null"))
        XCTAssertEqual(outage.address, "12 rue des Alpes, 38000 Grenoble")
        XCTAssertTrue(outage.canClose)
    }

    /// « Non chargée » et « aucun événement » ne sont pas la même chose : la liste paginée rend
    /// `timeline: null`, et une panne porte toujours au moins sa création. Confondre les deux
    /// ferait monter un bloc « Chronologie » vide sur la feuille.
    func testCommunityOutageDistinguishesUnloadedTimelineFromEmptyOne() throws {
        let unloaded = try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: outageJSON(timeline: "null"))
        XCTAssertNil(unloaded.timeline)
        let empty = try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: outageJSON(timeline: "[]"))
        XCTAssertEqual(empty.timeline, [])
    }

    /// Le contrat impose d'IGNORER en silence un genre inconnu : la liste s'allongera côté
    /// serveur, et les trois clients ne se mettent pas à jour le même jour. Une ligne perdue vaut
    /// mieux qu'une chronologie entière perdue — ou qu'un `kind` brut affiché à l'écran.
    func testCommunityOutageTimelineDropsUnknownKindsAndKeepsTheRest() throws {
        let timeline = """
        [
            {"id": "e1", "at": "2026-08-11T09:12:00.000Z", "kind": "reported", "isSelf": true, "services": ["data", "voice"]},
            {"id": "e2", "at": "2026-08-11T09:20:00.000Z", "kind": "points_awarded", "isSelf": false},
            {"id": "e3", "at": "2026-08-11T09:40:00.000Z", "kind": "state_confirmed", "isSelf": false}
        ]
        """
        let outage = try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: outageJSON(timeline: timeline))
        let entries = try XCTUnwrap(outage.timeline)
        XCTAssertEqual(entries.map(\.kind), [.reported, .stateConfirmed])
        XCTAssertTrue(entries[0].isSelf)
        XCTAssertEqual(entries[0].services, ["data", "voice"])
        // Clé absente et non tableau vide : le contrat la retire quand l'événement ne porte sur
        // aucun service en particulier.
        XCTAssertEqual(entries[1].services, [])
    }

    /// L'échelon « Confirmée par l'opérateur » n'existe pas partout : c'est le serveur qui tient
    /// la liste des 5 flux (tous français), et le client doit MASQUER l'échelon ailleurs plutôt
    /// que de l'afficher « en attente ». Le défaut retenu est `false` — un serveur plus ancien
    /// qui ne rend pas le champ fait donc taire l'échelon, ce qui est la bonne moitié de l'erreur.
    func testOperatorConfirmationPossibleDefaultsToSilence() throws {
        let absent = try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: outageJSON(timeline: "null"))
        XCTAssertFalse(absent.operatorConfirmationPossible)
        let json = String(decoding: outageJSON(timeline: "null"), as: UTF8.self)
            .replacingOccurrences(
                of: "\"operatorConfirmed\": false",
                with: "\"operatorConfirmed\": false, \"operatorConfirmationPossible\": true"
            )
        let present = try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: Data(json.utf8))
        XCTAssertTrue(present.operatorConfirmationPossible)
    }

    // MARK: - Incidents opérateurs par site

    /// `supported` et `available` ne disent PAS la même chose, et les confondre ferait afficher
    /// « aucun incident » là où l'on ne sait rien : `supported: false` = ce marché n'a aucun flux
    /// d'opérateur, `available: false` = le flux existe mais n'a pas pu être lu.
    func testDecodeSiteOperatorIncidents() throws {
        let data = Data("""
        {
            "supported": true,
            "available": true,
            "market": "FR",
            "count": 1,
            "incidents": [
                {
                    "incidentKey": "sfr-fr:XY1234",
                    "sourceId": "sfr-fr",
                    "market": "FR",
                    "operator": "SFR",
                    "codeSiteOp": "XY1234",
                    "issueType": "degraded",
                    "latitude": 45.18,
                    "longitude": 5.72,
                    "raison": "INT",
                    "detail": "Coupure d'alimentation",
                    "startedAt": "2026-08-10",
                    "expectedEndAt": "2026-08-12",
                    "commune": "GRENOBLE",
                    "services": {},
                    "affectsVoice": false,
                    "affectsData": true,
                    "matchMethod": "geo_120m",
                    "matchDistanceMeters": 47
                }
            ]
        }
        """.utf8)
        let response = try JSONDecoder.signalQuest.decode(SiteOperatorIncidentsResponse.self, from: data)
        XCTAssertTrue(response.supported)
        XCTAssertTrue(response.available)
        let incident = try XCTUnwrap(response.incidents.first)
        XCTAssertEqual(incident.operator, "SFR")
        XCTAssertEqual(incident.issueType, "degraded")
        XCTAssertTrue(incident.affectsData)
        XCTAssertFalse(incident.affectsVoice)
        // Rapproché par la DISTANCE seule : la fiche doit pouvoir le dire, parce que le code de
        // site d'un opérateur n'est pas le `sup_id` de l'ANFR et qu'en ville le rapprochement
        // désigne parfois le pylône voisin.
        XCTAssertTrue(incident.isGeoMatch)
        XCTAssertEqual(incident.matchDistanceMeters, 47)
    }

    /// Les 47 marchés sans flux : le serveur répond `supported: false` sans réveiller le moindre
    /// chargeur de source. Le client doit lire cette réponse sans la confondre avec un échec.
    func testDecodeUnsupportedMarketIncidents() throws {
        let data = Data(#"{"supported": false, "available": false, "market": "CH", "incidents": []}"#.utf8)
        let response = try JSONDecoder.signalQuest.decode(SiteOperatorIncidentsResponse.self, from: data)
        XCTAssertFalse(response.supported)
        XCTAssertTrue(response.incidents.isEmpty)
    }
}
