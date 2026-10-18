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

    // MARK: Comparateur de zone (CMP-1)

    private static let zoneJSON = """
    {"market":"FR","unit":"site","activeDefinition":"Sites au statut En service.",
     "snapshot":{"date":"2026-09-24","source":"ANFR"},"center":{"lat":45.76,"lon":4.84},"radiusKm":50,
     "total":{"active":540,"planned":78},"totalByGeneration":{"2G":230,"3G":310,"4G":530,"5G":300},
     "operators":[
      {"key":"ORANGE","active":402,"planned":36,"generations":{"2G":211,"3G":190,"4G":396,"5G":172}},
      {"key":"FREE","active":0,"planned":0,"generations":{}},
      {"active":5},
      {"key":"SFR","active":296}
     ],"requestId":"req-1"}
    """

    func testZoneCompareDecodesTheFullContractInRegistryOrder() throws {
        let zone = try JSONDecoder.signalQuest.decode(ANFRZoneCompare.self, from: Data(Self.zoneJSON.utf8))
        XCTAssertEqual(zone.market, "FR")
        XCTAssertEqual(zone.unit, "site")
        XCTAssertEqual(zone.snapshotDate, "2026-09-24")
        XCTAssertEqual(zone.snapshotSource, "ANFR")
        XCTAssertEqual(zone.activeDefinition, "Sites au statut En service.")
        XCTAssertEqual(zone.radiusKm, 50)
        XCTAssertEqual(zone.totalActive, 540)
        XCTAssertEqual(zone.totalPlanned, 78)
        XCTAssertEqual(zone.totalByGeneration, ANFRZoneGenerations(g2: 230, g3: 310, g4: 530, g5: 300))
        XCTAssertEqual(zone.requestId, "req-1")
        XCTAssertEqual(zone.operators.map(\.key), ["ORANGE", "FREE", "SFR"], "Ordre du serveur, ligne sans clé ignorée")
        XCTAssertEqual(zone.operators[0].generations.g5, 172)
        XCTAssertFalse(zone.hasBands)
    }

    func testZoneCompareMissingKeysFallBackToZeroNeverAnError() throws {
        let zone = try JSONDecoder.signalQuest.decode(ANFRZoneCompare.self, from: Data(Self.zoneJSON.utf8))
        let free = try XCTUnwrap(zone.operators.first { $0.key == "FREE" })
        XCTAssertEqual(free.active, 0)
        XCTAssertEqual(free.generations, .zero, "Un opérateur à 0 reste dans la liste")
        let sfr = try XCTUnwrap(zone.operators.first { $0.key == "SFR" })
        XCTAssertEqual(sfr.planned, 0)
        XCTAssertEqual(sfr.generations, .zero)
        XCTAssertNil(sfr.bands)

        let empty = try JSONDecoder.signalQuest.decode(ANFRZoneCompare.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.totalActive, 0)
        XCTAssertEqual(empty.totalPlanned, 0)
        XCTAssertEqual(empty.totalByGeneration, .zero)
        XCTAssertTrue(empty.operators.isEmpty)
        XCTAssertNil(empty.snapshotDate)

        let partial = try JSONDecoder.signalQuest.decode(
            ANFRZoneCompare.self, from: Data(#"{"totalByGeneration":{"4G":12},"total":{"active":3}}"#.utf8))
        XCTAssertEqual(partial.totalByGeneration, ANFRZoneGenerations(g2: 0, g3: 0, g4: 12, g5: 0), "Générations absentes = 0")
        XCTAssertEqual(partial.totalActive, 3)
        XCTAssertEqual(partial.totalPlanned, 0)
    }

    func testZoneCompareBandsDecodeGroupedByGenerationAndSortByGeneration() throws {
        func decode(_ bands: String) throws -> [ANFRZoneBandCount]? {
            let json = #"{"operators":[{"key":"ORANGE","active":1,"bands":"# + bands + "}]}"
            return try JSONDecoder.signalQuest.decode(ANFRZoneCompare.self, from: Data(json.utf8)).operators.first?.bands
        }
        let grouped = try XCTUnwrap(decode(
            #"{"2G":{"GSM900":211},"3G":{"U900":37,"U1":120},"4G":{"B20":390,"B3":392,"B28":12},"5G":{"n78":150}}"#))
        XCTAssertEqual(ANFRZoneBandCount.sorted(grouped).map(\.band), ["GSM900", "U900", "U1", "B28", "B20", "B3", "n78"],
                       "Par génération puis fréquence : U1 est l'UMTS 2100, B28 le 700 MHz")
        XCTAssertEqual(grouped.first { $0.band == "U1" }?.displayName, "3G 2100")
        XCTAssertEqual(grouped.first { $0.band == "U1" }?.spokenName, "3G 2100 MHz")
        XCTAssertEqual(ANFRZoneBandCount(band: "X9", count: 1).displayName, "X9")
        XCTAssertEqual(grouped.first { $0.band == "B20" }?.count, 390)
        XCTAssertEqual(ANFRZoneBandCount.sorted(grouped).compactMap(\.generation), ["2G", "3G", "3G", "4G", "4G", "4G", "5G"])

        XCTAssertEqual(try decode(#"{"5G":{"n78":4}}"#), [ANFRZoneBandCount(band: "n78", count: 4)], "Génération absente = omise")
        XCTAssertEqual(try decode("{}"), [], "Aucune bande active")
        XCTAssertNil(try decode(#"{"B20":7}"#), "Forme inattendue : pas de détail, pas d'erreur")
        XCTAssertNil(try decode(#""n/a""#), "Forme inconnue : pas de détail, pas d'erreur")
        XCTAssertNil(ANFRZoneBandCount.generation(ofBand: "X7"))
    }

    /// Tableau bandes × opérateurs : une ligne par bande vue chez au moins un opérateur,
    /// groupée par génération puis par fréquence ; une bande absente d'un opérateur = aucun site.
    func testZoneBandGroupsBuildOneRowPerBandAcrossOperators() throws {
        let json = #"""
        {"operators":[
          {"key":"ORANGE","bands":{"4G":{"B20":38,"B3":38},"5G":{"n78":15}}},
          {"key":"FREE","bands":{"3G":{"U1":12},"4G":{"B28":21,"B3":33}}},
          {"key":"SFR"}
        ]}
        """#
        let zone = try JSONDecoder.signalQuest.decode(ANFRZoneCompare.self, from: Data(json.utf8))
        let groups = zone.bandGroups
        XCTAssertEqual(groups.map(\.generation), ["3G", "4G", "5G"])
        XCTAssertEqual(groups[1].rows.map(\.band.band), ["B28", "B20", "B3"])
        XCTAssertEqual(groups[1].rows[2].counts, ["ORANGE": 38, "FREE": 33])
        XCTAssertNil(groups[1].rows[0].counts["ORANGE"], "Bande absente chez Orange : aucun site")
        XCTAssertEqual(groups[1].rows[1].band.frequencyLabel, "800 MHz")
        XCTAssertEqual(zone.bandCellMax, 38)
    }

    func testZoneBarSegmentsAreProportionalToTheLargestOperatorSum() throws {
        let big = ANFRZoneOperator(key: "A", active: 10, planned: 0, generations: ANFRZoneGenerations(g2: 0, g3: 20, g4: 60, g5: 20))
        let small = ANFRZoneOperator(key: "B", active: 5, planned: 0, generations: ANFRZoneGenerations(g2: 0, g3: 0, g4: 25, g5: 25))
        let empty = ANFRZoneOperator(key: "C", active: 0, planned: 0, generations: .zero)
        let zone = ANFRZoneCompare(market: "FR", activeDefinition: "", snapshotDate: nil, snapshotSource: nil, radiusKm: 50,
                                   totalActive: 12, totalPlanned: 0, totalByGeneration: .zero, operators: [big, small, empty])
        XCTAssertEqual(zone.barSegments(for: big).map(\.fraction), [0, 0.2, 0.6, 0.2])
        XCTAssertEqual(zone.barSegments(for: big).map(\.generation), ["2G", "3G", "4G", "5G"])
        XCTAssertEqual(zone.barSegments(for: small).map(\.fraction), [0, 0, 0.25, 0.25])
        XCTAssertEqual(zone.barSegments(for: small).map(\.count), [0, 0, 25, 25])
        XCTAssertEqual(zone.barSegments(for: empty).map(\.fraction), [0, 0, 0, 0])
        XCTAssertLessThanOrEqual(zone.barSegments(for: big).map(\.fraction).reduce(0, +), 1.000_001)

        let none = ANFRZoneCompare(market: "FR", activeDefinition: "", snapshotDate: nil, snapshotSource: nil, radiusKm: 20,
                                   totalActive: 0, totalPlanned: 0, totalByGeneration: .zero, operators: [empty])
        XCTAssertEqual(none.barSegments(for: empty).map(\.fraction), [0, 0, 0, 0], "Zone vide : pas de division par zéro")
    }

    // MARK: - Lot 2 messagerie

    /// Archivage sans quitter : seule la présence de `shelvedSummary` dit que le serveur sait archiver.
    func testShelvedSummaryIsOptionalAndTolerant() throws {
        func decode(_ json: String) throws -> ConversationsResponse {
            try JSONDecoder.signalQuest.decode(ConversationsResponse.self, from: Data(json.utf8))
        }
        XCTAssertNil(try decode(#"{"conversations":[]}"#).shelvedSummary)
        XCTAssertEqual(try decode(#"{"conversations":[],"shelvedSummary":{"count":3,"unreadCount":1}}"#).shelvedSummary,
                       ShelvedSummary(count: 3, unreadCount: 1))
        XCTAssertEqual(try decode(#"{"conversations":[],"shelvedSummary":{}}"#).shelvedSummary,
                       ShelvedSummary(count: 0, unreadCount: 0), "Une valeur manquante vaut 0, la clé reste présente")
        XCTAssertEqual(try decode(#"{"conversations":[],"shelvedSummary":{"count":-4,"unreadCount":"x"}}"#).shelvedSummary,
                       ShelvedSummary(count: 0, unreadCount: 0))
    }

    func testConversationCarriesShelvedFlagAndDate() throws {
        func decode(_ extra: String) throws -> MessageConversation {
            try JSONDecoder.signalQuest.decode(MessageConversation.self, from: Data(#"{"id":"c1","participants":[]\#(extra)}"#.utf8))
        }
        XCTAssertFalse(try decode("").shelved)
        XCTAssertTrue(try decode(#","shelved":true"#).shelved)
        let dated = try decode(#","shelvedAt":"2026-10-01T10:00:00.000Z""#)
        XCTAssertTrue(dated.shelved, "Une date d’archivage suffit quand le drapeau manque")
        XCTAssertNotNil(dated.shelvedAt)
        XCTAssertFalse(try decode(#","shelved":false"#).shelved)
    }

    /// Les liens dossier ↔ conversation ne viennent que de la liste des dossiers.
    func testConversationFoldersDecodeLinksAndSkipBrokenEntries() throws {
        let json = """
        {"categories":[
          {"id":"f1","name":"Terrain","links":[{"conversationId":"c1"},{"conversationId":"c2"},{"x":1}]},
          {"id":"f2","name":42},
          {"name":"sans identifiant"}
        ]}
        """
        let response = try JSONDecoder.signalQuest.decode(ConversationFoldersResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.categories.map(\.id), ["f1", "f2"])
        XCTAssertEqual(response.categories[0].conversationIds, ["c1", "c2"])
        XCTAssertEqual(response.categories[1].conversationIds, [])
    }

    func testFocusSessionRunningDependsOnEndAndActiveFlag() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(MessageFocusSession(conversationIds: ["c1"], endsAt: nil).isRunning(at: now))
        XCTAssertTrue(MessageFocusSession(conversationIds: ["c1"], endsAt: now.addingTimeInterval(60)).isRunning(at: now))
        XCTAssertFalse(MessageFocusSession(conversationIds: ["c1"], endsAt: now.addingTimeInterval(-1)).isRunning(at: now),
                       "Une session échue reste marquée active côté serveur")
        XCTAssertFalse(MessageFocusSession(conversationIds: ["c1"], endsAt: nil, active: false).isRunning(at: now))
        let none = try JSONDecoder.signalQuest.decode(MessageFocusResponse.self, from: Data(#"{"focusSession":null}"#.utf8))
        XCTAssertNil(none.focusSession)
        let some = try JSONDecoder.signalQuest.decode(MessageFocusResponse.self, from: Data(
            #"{"focusSession":{"id":"s1","conversationIds":["c1","c2"],"endsAt":"2030-01-01T00:00:00.000Z"}}"#.utf8))
        XCTAssertEqual(some.focusSession?.conversationIds, ["c1", "c2"])
        XCTAssertTrue(some.focusSession?.active ?? false, "Un champ absent prend la valeur par défaut")
    }

    func testSecretPolicyDecodesWithDefaultsAndEncodesItsFields() throws {
        let empty = try JSONDecoder.signalQuest.decode(ConversationSecretPolicyResponse.self, from: Data(#"{"policy":null}"#.utf8))
        XCTAssertNil(empty.policy)
        let policy = try JSONDecoder.signalQuest.decode(ConversationSecretPolicyResponse.self, from: Data(
            #"{"policy":{"requireBiometric":true,"autoDeleteSeconds":3600}}"#.utf8)).policy
        XCTAssertEqual(policy, ConversationSecretPolicy(requireBiometric: true, blockScreenshots: false, autoDeleteSeconds: 3600))
        XCTAssertEqual(policy?.outgoingTTLSeconds, 3600)
        XCTAssertFalse(policy?.isInactive ?? true)
        XCTAssertTrue(ConversationSecretPolicy().isInactive)
        // Le PUT remplace l'ensemble des champs ; un délai absent se lit « sans limite » côté serveur.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversationSecretPolicy(autoDeleteSeconds: 60))) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["requireBiometric", "blockScreenshots", "autoDeleteSeconds", "ephemeralDefault"])
    }

    private static let callEventJSON = """
    {"callId":"k1","mode":"video","outcome":"missed","startedAt":"2026-10-18T10:00:00.000Z","durationSec":null,"callerId":"other"}
    """

    func testCallThreadEventDecodingIsTolerant() throws {
        let event = try JSONDecoder.signalQuest.decode(CallThreadEvent.self, from: Data(Self.callEventJSON.utf8))
        XCTAssertEqual(event.callId, "k1")
        XCTAssertEqual(event.mode, .video)
        XCTAssertEqual(event.outcome, .missed)
        XCTAssertNil(event.durationSec)
        // Un mode inconnu se lit comme un appel vocal ; une issue inconnue écarte l'entrée sans casser la page.
        let page = try JSONDecoder.signalQuest.decode(CallThreadHistoryPage.self, from: Data("""
        {"events":[
          {"callId":"a","mode":"hologram","outcome":"completed","startedAt":"2026-10-18T10:00:00.000Z","durationSec":240},
          {"callId":"b","mode":"audio","outcome":"exploded","startedAt":"2026-10-18T10:05:00.000Z"},
          {"callId":"c","mode":"audio","outcome":"declined","startedAt":"2026-10-18T10:06:00.000Z"}
        ],"nextBefore":"2026-10-18T09:00:00.000Z"}
        """.utf8))
        XCTAssertEqual(page.events.map(\.callId), ["a", "c"])
        XCTAssertEqual(page.events.first?.mode, .audio)
        XCTAssertEqual(page.nextBefore, "2026-10-18T09:00:00.000Z")
        let last = try JSONDecoder.signalQuest.decode(CallThreadHistoryPage.self, from: Data(#"{"events":[],"nextBefore":null}"#.utf8))
        XCTAssertNil(last.nextBefore)
    }

    /// L'issue se lit selon `callerId` : un « annulé » est « manqué » chez l'appelé, « annulé » chez l'appelant.
    func testCallThreadWordingFollowsTheCaller() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func event(_ outcome: CallThreadEvent.Outcome, mode: CallThreadEvent.Mode = .audio, duration: Int? = nil) -> CallThreadEvent {
            CallThreadEvent(callId: "k", mode: mode, outcome: outcome, startedAt: at, durationSec: duration, callerId: "me")
        }
        let cancelled = event(.cancelled)
        XCTAssertEqual(cancelled.summary(currentUserId: "me"), String(localized: "Appel vocal annulé"))
        XCTAssertEqual(cancelled.summary(currentUserId: "other"), String(localized: "Appel vocal manqué"))
        XCTAssertTrue(cancelled.isMissedForReader(currentUserId: "other"))
        XCTAssertFalse(cancelled.isMissedForReader(currentUserId: "me"))
        XCTAssertEqual(event(.missed).summary(currentUserId: "me"), String(localized: "Appel vocal sans réponse"))
        XCTAssertEqual(event(.missed, mode: .video).summary(currentUserId: "other"), String(localized: "Appel vidéo manqué"))
        XCTAssertEqual(event(.declined).summary(currentUserId: "me"), String(localized: "Appel vocal refusé"))
        XCTAssertFalse(event(.declined).isMissedForReader(currentUserId: "other"))
        XCTAssertEqual(event(.completed).summary(currentUserId: "me"), String(localized: "Appel vocal"))
        XCTAssertEqual(CallThreadEvent.durationLabel(240), CallThreadEvent.durationLabel(240))
        XCTAssertNotEqual(event(.completed, duration: 240).summary(currentUserId: "me"), String(localized: "Appel vocal"),
                          "Une durée connue se lit dans la phrase")
        XCTAssertEqual(event(.completed, mode: .video).systemImage, "video.fill")
    }

    func testCallThreadPlacementInsertsByDateAndDeduplicatesByCallId() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func message(_ id: String, _ seconds: TimeInterval) -> MessageItem {
            MessageItem(
                id: id, conversationId: "c1", senderId: "other", kind: "TEXT", content: "x",
                e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil,
                createdAt: base.addingTimeInterval(seconds), editedAt: nil, deletedAt: nil, replyToId: nil, threadReplyCount: 0,
                sender: nil, attachments: [], reactions: []
            )
        }
        func call(_ id: String, _ seconds: TimeInterval, _ outcome: CallThreadEvent.Outcome = .completed) -> CallThreadEvent {
            CallThreadEvent(callId: id, mode: .audio, outcome: outcome, startedAt: base.addingTimeInterval(seconds))
        }
        let messages = [message("m1", 10), message("m2", 20), message("m3", 30)]
        let placement = CallThreadPlacement.make(messages: messages, events: [call("late", 99), call("b", 25), call("a", 15), call("a2", 15)])
        XCTAssertEqual(placement.before["m2"]?.map(\.callId), ["a", "a2"])
        XCTAssertEqual(placement.before["m3"]?.map(\.callId), ["b"])
        XCTAssertEqual(placement.trailing.map(\.callId), ["late"])
        XCTAssertEqual(CallThreadPlacement.make(messages: messages, events: []), .empty)

        // Historique puis temps réel : le même callId remplace, il ne s'ajoute pas.
        let merged = CallThreadPlacement.merge([call("a", 15, .missed), call("b", 25)], with: [call("a", 15, .completed), call("c", 5)])
        XCTAssertEqual(merged.map(\.callId), ["b", "a", "c"], "Du plus récent au plus ancien")
        XCTAssertEqual(merged.first { $0.callId == "a" }?.outcome, .completed)
    }

    func testCallEventStreamPayloadBecomesATrigger() {
        let data = #"{"type":"call_event","conversationId":"c1","at":"2026-10-18T10:00:00.000Z","call":\#(Self.callEventJSON)}"#
        guard case .callEvent(let event) = SyncTrigger.from(event: "call_event", data: data) else {
            return XCTFail("L’événement call_event doit produire un déclencheur dédié")
        }
        XCTAssertEqual(event?.callId, "k1")
        guard case .callEvent(let broken) = SyncTrigger.from(event: "call_event", data: "pas du JSON") else {
            return XCTFail("Un corps illisible reste un call_event, sans appel")
        }
        XCTAssertNil(broken)
    }

    /// Siri : la recherche ne touche que le nom ; l'entité ne porte ni contenu ni autre champ.
    func testConversationIntentDirectoryMatchesByNameOnly() {
        typealias Item = SQConversationIntentDirectory.Item
        let items = [Item(id: "1", name: "Équipe terrain", isEncrypted: false), Item(id: "2", name: "Camille", isEncrypted: true)]
        XCTAssertEqual(SQConversationIntentDirectory.matching(items, name: "equipe").map(\.id), ["1"])
        XCTAssertEqual(SQConversationIntentDirectory.matching(items, name: "  ").count, 2)
        XCTAssertTrue(SQConversationIntentDirectory.matching(items, name: "zzz").isEmpty)
        XCTAssertEqual(Set(Mirror(reflecting: ConversationEntity(items[0])).children.compactMap(\.label)), ["id", "name"])
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
