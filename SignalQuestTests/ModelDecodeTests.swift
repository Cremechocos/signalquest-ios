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

    // MARK: Partager vers SignalQuest (boîte de dépôt, destinations)

    private func makeInbox() throws -> ShareInbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareInboxTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ShareInbox(root: root)
    }

    /// Fichier source de `bytes` octets ; au-delà de 1 Mio il est creux (rapide à créer).
    private func makeSource(_ kind: ShareInbox.Kind, name: String, bytes: Int = 16, uti: String? = nil) throws -> ShareInbox.Source {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        if bytes > 1_048_576 {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        } else {
            try Data(repeating: 0x41, count: bytes).write(to: url)
        }
        let defaultUTI: String
        switch kind {
        case .image: defaultUTI = "public.jpeg"
        case .video: defaultUTI = "public.mpeg-4"
        case .file: defaultUTI = "com.adobe.pdf"
        }
        return ShareInbox.Source(kind: kind, fileName: name, uti: uti ?? defaultUTI, fileURL: url)
    }

    func testShareInboxWritesThenReadsTextLinkAndFiles() throws {
        let inbox = try makeInbox()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = try inbox.write(
            text: "  Voilà la mesure  ",
            url: URL(string: "https://example.com/page?x=1"),
            sources: [try makeSource(.image, name: "a.jpg", bytes: 40), try makeSource(.image, name: "b.jpg", bytes: 50)],
            now: now
        )
        XCTAssertEqual(manifest.text, "Voilà la mesure")
        XCTAssertEqual(manifest.url, "https://example.com/page?x=1")
        XCTAssertEqual(manifest.imageCount, 2)
        XCTAssertEqual(manifest.composedText, "Voilà la mesure\nhttps://example.com/page?x=1")

        let entry = try XCTUnwrap(inbox.pending(now: now.addingTimeInterval(60)))
        XCTAssertEqual(entry.manifest, manifest)
        XCTAssertEqual(entry.directory.lastPathComponent, manifest.id)
        let first = try XCTUnwrap(entry.manifest.items.first)
        XCTAssertEqual(try entry.data(for: first).count, 40)
        XCTAssertEqual(entry.manifest.items.map(\.byteCount), [40, 50])
        // Le dossier de travail a disparu : seul le dépôt complet reste.
        let names = try FileManager.default.contentsOfDirectory(atPath: inbox.root.path)
        XCTAssertEqual(names, [manifest.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.directory.appendingPathComponent("manifest.json").path))
    }

    func testShareInboxKeepsTheMostRecentAndRemovesById() throws {
        let inbox = try makeInbox()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = try inbox.write(text: "ancien", url: nil, sources: [], now: now)
        let newer = try inbox.write(text: "récent", url: nil, sources: [], now: now.addingTimeInterval(120))
        XCTAssertEqual(inbox.pending(now: now.addingTimeInterval(200))?.id, newer.id)
        inbox.remove(id: newer.id)
        XCTAssertEqual(inbox.pending(now: now.addingTimeInterval(200))?.id, older.id)
        // Un identifiant qui n'en est pas un ne touche à rien.
        inbox.remove(id: "../\(older.id)")
        inbox.remove(id: "")
        XCTAssertEqual(inbox.pending(now: now.addingTimeInterval(200))?.id, older.id)
    }

    func testShareInboxEnforcesItsLimits() throws {
        let inbox = try makeInbox()
        let tenMiB = ShareInbox.maxFileBytes
        // Dix images passent, onze non.
        let ten = try (0..<10).map { try makeSource(.image, name: "i\($0).jpg") }
        XCTAssertNoThrow(try inbox.write(text: nil, url: nil, sources: ten))
        let eleven = try (0..<11).map { try makeSource(.image, name: "i\($0).jpg") }
        XCTAssertThrowsError(try inbox.write(text: nil, url: nil, sources: eleven)) {
            XCTAssertEqual($0 as? ShareInbox.Failure, .tooManyImages)
        }
        // Vidéo ou fichier : 10 Mio exactement passe, un octet de plus non.
        XCTAssertNoThrow(try inbox.write(text: nil, url: nil, sources: [try makeSource(.file, name: "ok.pdf", bytes: tenMiB)]))
        XCTAssertThrowsError(try inbox.write(text: nil, url: nil, sources: [try makeSource(.video, name: "gros.mp4", bytes: tenMiB + 1)])) {
            XCTAssertEqual($0 as? ShareInbox.Failure, .fileTooLarge("gros.mp4"))
        }
        // Une image a sa propre borne, plus large.
        XCTAssertNoThrow(try inbox.write(text: nil, url: nil, sources: [try makeSource(.image, name: "photo.heic", bytes: tenMiB + 1)]))
        XCTAssertThrowsError(try inbox.write(text: nil, url: nil, sources: [try makeSource(.image, name: "enorme.heic", bytes: ShareInbox.maxImageBytes + 1)])) {
            XCTAssertEqual($0 as? ShareInbox.Failure, .fileTooLarge("enorme.heic"))
        }
        // Une seule vidéo ou un seul fichier, jamais mêlé à des images.
        XCTAssertThrowsError(try inbox.write(text: nil, url: nil, sources: [
            try makeSource(.file, name: "a.pdf"), try makeSource(.video, name: "b.mp4"),
        ])) { XCTAssertEqual($0 as? ShareInbox.Failure, .unsupportedCombination) }
        XCTAssertThrowsError(try inbox.write(text: nil, url: nil, sources: [
            try makeSource(.image, name: "a.jpg"), try makeSource(.file, name: "b.pdf"),
        ])) { XCTAssertEqual($0 as? ShareInbox.Failure, .unsupportedCombination) }
        // Texte : 4 000 caractères au plus (des caractères, pas des octets).
        XCTAssertNoThrow(try inbox.write(text: String(repeating: "é", count: 4_000), url: nil, sources: []))
        XCTAssertThrowsError(try inbox.write(text: String(repeating: "é", count: 4_001), url: nil, sources: [])) {
            XCTAssertEqual($0 as? ShareInbox.Failure, .textTooLong)
        }
        // Lien web seulement, et rien du tout ne se dépose pas.
        XCTAssertThrowsError(try inbox.write(text: nil, url: URL(string: "tel:0102030405"), sources: [])) {
            XCTAssertEqual($0 as? ShareInbox.Failure, .unsupportedURL)
        }
        XCTAssertThrowsError(try inbox.write(text: "   \n", url: nil, sources: [])) {
            XCTAssertEqual($0 as? ShareInbox.Failure, .empty)
        }
        // Un refus ne laisse aucun dossier de travail derrière lui.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: inbox.root.path).filter { $0.hasPrefix(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testShareInboxExpiresAfterTwentyFourHours() throws {
        let inbox = try makeInbox()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = try inbox.write(text: "frais", url: nil, sources: [try makeSource(.file, name: "f.pdf")], now: now.addingTimeInterval(-23 * 3_600))
        let stale = try inbox.write(text: "périmé", url: nil, sources: [], now: now.addingTimeInterval(-25 * 3_600))
        // Un dépôt daté trop loin dans le futur (horloge) ne vaut pas non plus.
        let future = try inbox.write(text: "futur", url: nil, sources: [], now: now.addingTimeInterval(3_600))
        XCTAssertEqual(inbox.pending(now: now)?.id, fresh.id)
        XCTAssertNil(try makeInbox().pending(now: now))

        inbox.purgeExpired(now: now)
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: inbox.root.path))
        XCTAssertEqual(remaining, [fresh.id])
        XCTAssertFalse(remaining.contains(stale.id) || remaining.contains(future.id))
        // Exactement 24 h : expiré.
        XCTAssertNil(inbox.pending(now: now.addingTimeInterval(3_600)))
    }

    func testShareInboxPurgeAllEmptiesTheInbox() throws {
        let inbox = try makeInbox()
        _ = try inbox.write(text: "a", url: nil, sources: [try makeSource(.image, name: "a.jpg")])
        _ = try inbox.write(text: "b", url: nil, sources: [])
        XCTAssertNotNil(inbox.pending())
        inbox.purgeAll()
        XCTAssertNil(inbox.pending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.root.path))
        // Purger une boîte absente ne plante pas, et elle se recrée à l'écriture suivante.
        inbox.purgeAll()
        inbox.purgeExpired()
        XCTAssertNoThrow(try inbox.write(text: "c", url: nil, sources: []))
    }

    func testShareInboxManifestIsTolerant() throws {
        let inbox = try makeInbox()
        let id = UUID().uuidString
        let directory = inbox.root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("0123456789".utf8).write(to: directory.appendingPathComponent("photo.jpg"))
        // Version future : clé inconnue, texte et lien absents, un élément d'un
        // genre inconnu, un élément dont le fichier a disparu, un nom piégé.
        let json = """
        {"id":"\(id)","createdAt":1800000000,"futureKey":{"a":1},
         "items":[
          {"kind":"image","fileName":"photo.jpg","uti":"public.jpeg","byteCount":10,"extra":true},
          {"kind":"hologram","fileName":"x.bin","uti":"public.data","byteCount":3},
          {"kind":"file","fileName":"disparu.pdf","uti":"com.adobe.pdf","byteCount":5},
          {"kind":"file","fileName":"../manifest.json","uti":"public.data","byteCount":5}
         ]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        let entry = try XCTUnwrap(inbox.pending(now: Date(timeIntervalSince1970: 1_800_000_100)))
        XCTAssertNil(entry.manifest.text)
        XCTAssertNil(entry.manifest.url)
        XCTAssertEqual(entry.manifest.items.map(\.fileName), ["photo.jpg"])

        // Un manifeste lisible mais incompréhensible est un débris : il part.
        let broken = inbox.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("pas du JSON".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        // Un dossier sans manifeste aussi, mais pas un nom étranger au dépôt.
        let headless = inbox.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: headless, withIntermediateDirectories: true)
        let stranger = inbox.root.appendingPathComponent("autre-chose", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        inbox.purgeExpired(now: Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: headless.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
        XCTAssertNotNil(inbox.pending(now: Date(timeIntervalSince1970: 1_800_000_100)))
    }

    func testShareInboxSanitizesAndDeduplicatesFileNames() throws {
        let inbox = try makeInbox()
        let manifest = try inbox.write(text: nil, url: nil, sources: [
            try makeSource(.image, name: "a.jpg"),
            try makeSource(.image, name: "a.jpg"),
            try makeSource(.image, name: "A.JPG"),
        ])
        XCTAssertEqual(manifest.items.map(\.fileName), ["a.jpg", "a (2).jpg", "A (3).JPG"])
        XCTAssertEqual(ShareInbox.sanitizedFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(ShareInbox.sanitizedFileName("..caché.png"), "caché.png")
        XCTAssertEqual(ShareInbox.sanitizedFileName("a:b\\c.txt"), "a_b_c.txt")
        XCTAssertEqual(ShareInbox.sanitizedFileName(""), "file")
        XCTAssertLessThanOrEqual(ShareInbox.sanitizedFileName(String(repeating: "x", count: 300) + ".pdf").count, 140)
        // Le manifeste n'est jamais écrasé par un fichier du même nom.
        let clash = try inbox.write(text: nil, url: nil, sources: [try makeSource(.file, name: "manifest.json")])
        XCTAssertEqual(clash.items.first?.fileName, "manifest (2).json")
        XCTAssertNotNil(inbox.pending())
    }

    func testShareInboxOnlySweepsStaleWorkFolders() throws {
        let inbox = try makeInbox()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(at: inbox.root, withIntermediateDirectories: true)
        let old = inbox.root.appendingPathComponent(".tmp-\(Int(now.timeIntervalSince1970) - 7_200)-\(UUID().uuidString)")
        let current = inbox.root.appendingPathComponent(".tmp-\(Int(now.timeIntervalSince1970) - 60)-\(UUID().uuidString)")
        for url in [old, current] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        inbox.purgeExpired(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testShareKindsAreClassifiedFromTheirTypeIdentifier() {
        XCTAssertEqual(ShareInbox.Kind.classify(typeIdentifier: "public.heic"), .image)
        XCTAssertEqual(ShareInbox.Kind.classify(typeIdentifier: "public.png"), .image)
        XCTAssertEqual(ShareInbox.Kind.classify(typeIdentifier: "com.apple.quicktime-movie"), .video)
        XCTAssertEqual(ShareInbox.Kind.classify(typeIdentifier: "com.adobe.pdf"), .file)
        XCTAssertEqual(ShareInbox.Kind.classify(typeIdentifier: "inconnu.type"), .file)
    }

    private func shareManifest(text: String? = nil, url: String? = nil, _ items: [ShareInbox.Kind] = []) -> ShareInbox.Manifest {
        ShareInbox.Manifest(
            id: UUID().uuidString, createdAt: Date(), text: text, url: url,
            items: items.enumerated().map { ShareInbox.Item(kind: $1, fileName: "f\($0)", uti: "public.data", byteCount: 1) }
        )
    }

    func testFeedIsGreyedOutForVideosFilesAndSeveralImages() {
        XCTAssertNil(ShareDestinationPolicy.feedBlocker(for: shareManifest(text: "salut")))
        XCTAssertNil(ShareDestinationPolicy.feedBlocker(for: shareManifest(url: "https://example.com")))
        XCTAssertNil(ShareDestinationPolicy.feedBlocker(for: shareManifest(text: "légende", [.image])))
        XCTAssertEqual(ShareDestinationPolicy.feedBlocker(for: shareManifest([.video])), .videoOrFile)
        XCTAssertEqual(ShareDestinationPolicy.feedBlocker(for: shareManifest(text: "doc", [.file])), .videoOrFile)
        XCTAssertEqual(ShareDestinationPolicy.feedBlocker(for: shareManifest([.image, .image])), .severalImages)
    }

    func testEncryptedConversationsOnlyAcceptText() {
        let text = shareManifest(text: "salut", url: "https://example.com")
        let photo = shareManifest(text: "légende", [.image])
        let file = shareManifest([.file])
        // Non chiffrée : tout passe.
        for manifest in [text, photo, file] {
            XCTAssertTrue(ShareDestinationPolicy.conversationAccepts(manifest, toEncrypted: false, route: .plain))
        }
        // Chiffrée (v1 ou v2) : le texte seulement.
        for route in [EncryptedConversationSurfaces.ForwardRoute.legacyEncrypted, .v2] {
            XCTAssertTrue(ShareDestinationPolicy.conversationAccepts(text, toEncrypted: true, route: route))
            XCTAssertFalse(ShareDestinationPolicy.conversationAccepts(photo, toEncrypted: true, route: route))
            XCTAssertFalse(ShareDestinationPolicy.conversationAccepts(file, toEncrypted: true, route: route))
        }
        // Chiffrée v2 fermée dans cette version : rien n'y part.
        XCTAssertFalse(ShareDestinationPolicy.conversationAccepts(text, toEncrypted: true, route: .unavailable))
    }

    func testSharedTextIsAppendedToAnExistingDraft() {
        XCTAssertEqual(ReceivedShareSheet.mergedDraft(existing: nil, shared: "https://a.fr"), "https://a.fr")
        XCTAssertEqual(ReceivedShareSheet.mergedDraft(existing: "  \n", shared: "https://a.fr"), "https://a.fr")
        XCTAssertEqual(ReceivedShareSheet.mergedDraft(existing: "Regarde", shared: "https://a.fr"), "Regarde\nhttps://a.fr")
        // Le même partage reçu deux fois ne double pas le brouillon.
        XCTAssertEqual(ReceivedShareSheet.mergedDraft(existing: "Regarde\nhttps://a.fr", shared: "https://a.fr"), "Regarde\nhttps://a.fr")
    }

    // MARK: - P2-47 — site partagé en texte (format commun web / iOS / Android)

    private static let siteBase = URL(string: "https://signalquest.fr")!

    private static let gerlandLines = [
        "Antenne Orange (eNB 812345)",
        "Opérateur: Orange",
        "Technologies: 4G, 5G",
        "eNB: 812345",
        "PCI: 211",
        "Support: 1234567",
        "ANFR: 0691234567",
        "Marché: FR",
        "Adresse: 45, rue de Gerland, 69007 Lyon",
        "Position: 45.72869, 4.83312",
        "Lien: https://signalquest.fr/carte?lat=45.72869&lng=4.83312&siteId=1234567&market=FR&operator=ORANGE&open=antenna",
    ]

    private static let gerland = SiteShareCard(
        operatorName: "Orange", technologies: ["5G", "4G"], enb: "812345", pci: "211",
        supportId: "1234567", anfr: "0691234567", market: "FR",
        address: "45, rue de Gerland, 69007 Lyon",
        coordinate: SiteShareCoordinate(latitude: 45.72869, longitude: 4.83312)
    )

    func testSiteShareWriterProducesTheCommonFormatLineByLine() {
        XCTAssertEqual(Self.gerland.shareText(baseURL: Self.siteBase), Self.gerlandLines.joined(separator: "\n"))
    }

    func testSiteShareRoundTripWriterToReader() throws {
        let text = Self.gerland.shareText(baseURL: Self.siteBase)
        let card = try XCTUnwrap(SiteShareCard.parse(text))
        XCTAssertEqual(card.operatorName, "Orange")
        XCTAssertEqual(card.technologies, ["4G", "5G"])
        XCTAssertEqual(card.enb, "812345")
        XCTAssertEqual(card.pci, "211")
        XCTAssertEqual(card.supportId, "1234567")
        XCTAssertEqual(card.anfr, "0691234567")
        XCTAssertEqual(card.market, "FR")
        XCTAssertEqual(card.address, "45, rue de Gerland, 69007 Lyon")
        XCTAssertEqual(card.coordinate, SiteShareCoordinate(latitude: 45.72869, longitude: 4.83312))
        XCTAssertEqual(card.link, Self.gerlandLines.last?.replacingOccurrences(of: "Lien: ", with: ""))
    }

    func testSiteShareReaderReadsTheTextTheWebWrites() throws {
        // Texte du test du web (`formatAntennaShareText`), origine absolue.
        let card = try XCTUnwrap(SiteShareCard.parse(Self.gerlandLines.filter { !$0.hasPrefix("PCI") }.joined(separator: "\n")))
        XCTAssertNil(card.pci)
        XCTAssertEqual(card.enb, "812345")
        XCTAssertEqual(card.coordinate?.latitude, 45.72869)
    }

    func testSiteShareHeaderCarriesENBThenANFRThenNothing() {
        var card = SiteShareCard(operatorName: "Orange", enb: "812345", anfr: "0691234567", market: "FR")
        XCTAssertEqual(card.shareText(baseURL: Self.siteBase).components(separatedBy: "\n").first, "Antenne Orange (eNB 812345)")
        card.enb = nil
        XCTAssertEqual(card.shareText(baseURL: Self.siteBase).components(separatedBy: "\n").first, "Antenne Orange (ANFR 0691234567)")
        card.anfr = nil
        XCTAssertEqual(card.shareText(baseURL: Self.siteBase).components(separatedBy: "\n").first, "Antenne Orange")
        card.operatorName = nil
        XCTAssertEqual(card.shareText(baseURL: Self.siteBase).components(separatedBy: "\n").first, "Antenne")
    }

    func testSiteShareWriterOmitsUnknownDataAndNeverWritesZeroZero() {
        let text = SiteShareCard(supportId: "1234567", market: "FR").shareText(baseURL: Self.siteBase)
        XCTAssertEqual(text, [
            "Antenne",
            "Support: 1234567",
            "Marché: FR",
            "Lien: https://signalquest.fr/carte?siteId=1234567&market=FR&open=antenna",
        ].joined(separator: "\n"))
        XCTAssertFalse(text.contains("Position"))
        XCTAssertFalse(text.lowercased().contains("inconnu"))
        // 0, 0 n'est pas une coordonnée : le lecteur comme l'écrivain la refusent.
        XCTAssertNil(SiteShareCoordinate(latitude: 0, longitude: 0))
        XCTAssertNil(SiteShareCoordinate(latitude: 91, longitude: 4))
        XCTAssertNil(SiteShareCoordinate(latitude: 45, longitude: .nan))
    }

    func testSiteShareWriterKeepsEachValueOnOneLine() throws {
        let card = SiteShareCard(supportId: "1", market: "FR", address: "12 rue X\nLyon")
        let text = card.shareText(baseURL: Self.siteBase)
        XCTAssertTrue(text.contains("\nAdresse: 12 rue X Lyon\n"))
        XCTAssertEqual(try XCTUnwrap(SiteShareCard.parse(text)).address, "12 rue X Lyon")
    }

    func testSiteShareSeveralOperatorsGiveABareHeaderAndNoOperatorKey() throws {
        let card = SiteShareCard(operatorName: "Orange, SFR", supportId: "1234567", market: "FR")
        let lines = card.shareText(baseURL: Self.siteBase).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Antenne")
        XCTAssertTrue(lines.contains("Opérateur: Orange, SFR"))
        XCTAssertFalse(lines.last?.contains("operator=") ?? true)
        XCTAssertTrue(try XCTUnwrap(SiteShareCard.parse(lines.joined(separator: "\n"))).hasSeveralOperators)
    }

    func testSiteShareOperatorNamesAndLinkKeys() {
        XCTAssertEqual(SiteShareCard.metropolitanOperatorName(forKey: "ORANGE"), "Orange")
        XCTAssertEqual(SiteShareCard.metropolitanOperatorName(forKey: "bouygues"), "Bouygues Telecom")
        XCTAssertEqual(SiteShareCard.metropolitanOperatorName(forKey: "BYTEL"), "Bouygues Telecom")
        XCTAssertEqual(SiteShareCard.metropolitanOperatorName(forKey: "FREE"), "Free Mobile")
        XCTAssertEqual(SiteShareCard.metropolitanOperatorName(forKey: "SFR"), "SFR")
        XCTAssertNil(SiteShareCard.metropolitanOperatorName(forKey: "ROGERS"), "hors métropole, le nom du site")
        XCTAssertEqual(SiteShareCard.linkOperatorKey("Bouygues Telecom"), "BOUYGUES")
        XCTAssertEqual(SiteShareCard.linkOperatorKey("Free Mobile"), "FREE")
        XCTAssertEqual(SiteShareCard.linkOperatorKey("Rogers Communications"), "ROGERS_COMMUNICATIONS")
        XCTAssertEqual(SiteShareCard.linkOperatorKey("Free-Caraïbes"), "FREE_CARAÏBES")
        XCTAssertNil(SiteShareCard.linkOperatorKey("ALL"))
        XCTAssertNil(SiteShareCard.linkOperatorKey("  "))
        let abroad = SiteShareCard(operatorName: "Rogers", supportId: "9", market: "CA").shareText(baseURL: Self.siteBase)
        XCTAssertTrue(abroad.hasPrefix("Antenne Rogers\nOpérateur: Rogers"))
        XCTAssertTrue(abroad.hasSuffix("siteId=9&market=CA&operator=ROGERS&open=antenna"))
    }

    func testSiteShareReaderToleratesCommasSemicolonsAndRejectsBadPositions() throws {
        func position(_ value: String) -> SiteShareCoordinate? {
            SiteShareCard.parse("Antenne Orange\nSupport: 1\nPosition: \(value)")?.coordinate
        }
        let expected = SiteShareCoordinate(latitude: 45.72869, longitude: 4.83312)
        XCTAssertEqual(position("45.72869, 4.83312"), expected)
        XCTAssertEqual(position("45,72869; 4,83312"), expected, "virgule décimale")
        XCTAssertEqual(position("45.72869;4.83312"), expected, "« ; » comme séparateur")
        XCTAssertEqual(position("45,72869, 4,83312"), expected)
        XCTAssertEqual(position(" -21.1151 ; 55.5364 "), SiteShareCoordinate(latitude: -21.1151, longitude: 55.5364))
        // Pas de coordonnée : pas de vignette, mais la carte reste.
        XCTAssertNil(position("0, 0"))
        XCTAssertNil(position("0.00000, 0.00000"))
        XCTAssertNil(position("91, 4.8"))
        XCTAssertNil(position("45.7, 181"))
        XCTAssertNil(position("quelque part"))
        let card = try XCTUnwrap(SiteShareCard.parse("Antenne Orange\nSupport: 1\nPosition: 0, 0"))
        XCTAssertEqual(card.supportId, "1")
        XCTAssertNil(card.coordinate)
    }

    func testSiteShareReaderIgnoresUnknownLabelsAndUnknownValues() throws {
        let card = try XCTUnwrap(SiteShareCard.parse("""
        Antenne Orange (eNB 812345)
        Humeur: joyeuse
        Opérateur: Orange
        Hauteur: 30 m
        PCI: inconnu
        """))
        XCTAssertEqual(card.operatorName, "Orange")
        XCTAssertNil(card.pci, "« inconnu » n'est pas une donnée")
        XCTAssertEqual(card.enb, "812345", "l'eNB de l'en-tête sert à défaut de ligne")
    }

    func testSiteShareFreeTextStartingWithAntenneIsNotACard() {
        XCTAssertNil(SiteShareCard.parse("Antenne cassée chez moi depuis hier, quelqu'un d'autre ?"))
        XCTAssertNil(SiteShareCard.parse("Antenne\nvoici ce que j'ai vu: rien du tout"))
        XCTAssertNil(SiteShareCard.parse("Antenne Orange (eNB 812345)"), "un en-tête seul ne suffit pas")
        XCTAssertNil(SiteShareCard.parse("Antenne\nLien: https://signalquest.fr/carte"), "un lien seul ne suffit pas")
        XCTAssertNil(SiteShareCard.parse("Antennes de Lyon\nOpérateur: Orange"), "« Antennes » n'est pas l'en-tête")
        XCTAssertNil(SiteShareCard.parse("Bonjour\nOpérateur: Orange\nSupport: 1"), "pas d'en-tête")
        XCTAssertNil(SiteShareCard.parse(""))
        XCTAssertNil(SiteShareCard.parse("Antenne\nSupport: " + String(repeating: "1", count: 2_000)), "trop long pour un partage")
        // Un en-tête décoré (emoji, casse) reste un en-tête.
        XCTAssertNotNil(SiteShareCard.parse("📡 ANTENNE Orange\nSupport: 1"))
    }

    func testSiteShareLinkOpensOnlyWhenHTTPSAndSignalQuest() throws {
        let card = try XCTUnwrap(SiteShareCard.parse(Self.gerlandLines.joined(separator: "\n")))
        let url = try XCTUnwrap(card.openURL)
        XCTAssertTrue(ShareCardData.isSignalQuestURL(url))
        // Lien d'un autre domaine : lisible, mais jamais ouvert sans confirmation.
        let foreign = try XCTUnwrap(SiteShareCard.parse("Antenne\nSupport: 1\nLien: https://exemple.test/carte"))
        XCTAssertNotNil(foreign.openURL)
        XCTAssertFalse(ShareCardData.isSignalQuestURL(try XCTUnwrap(foreign.openURL)))
        // http en clair : pas de lien du tout.
        XCTAssertNil(SiteShareCard.parse("Antenne\nSupport: 1\nLien: http://signalquest.fr/carte")?.openURL)
        XCTAssertNil(SiteShareCard.parse("Antenne\nSupport: 1")?.openURL)
    }

    func testSiteShareOldWebFormatKeepsTheENBAndNoOperator() throws {
        let card = try XCTUnwrap(SiteShareCard.parse(
            "Antenne SFR (eNB 812345)\nSupport: 1234567\nAdresse: 12 rue X, 69007 Lyon\nLien: https://signalquest.fr/?search=1234567"
        ))
        XCTAssertNil(card.operatorName, "l'ancien en-tête disait « SFR » quel que soit le site")
        XCTAssertEqual(card.enb, "812345")
        XCTAssertNil(card.coordinate)
        XCTAssertEqual(card.supportId, "1234567")
    }

    func testSiteShareTechnologiesAreCanonicalAndAscending() {
        XCTAssertEqual(SiteShareCard.generations(in: ["5G", "4G"]), ["4G", "5G"])
        XCTAssertEqual(SiteShareCard.generations(in: ["LTE 800", "5G NR 3500", "GSM 900", "UMTS 2100"]), ["2G", "3G", "4G", "5G"])
        XCTAssertEqual(SiteShareCard.generations(in: ["4G", "4G"]), ["4G"])
        XCTAssertEqual(SiteShareCard.generations(in: ["Wi-Fi", ""]), [])
        XCTAssertEqual(SiteShareCard.parse("Antenne\nTechnologies: 5G · 3G / 4G")?.technologies, ["3G", "4G", "5G"])
    }

    func testANFRSupportConversationTextNamesOneOperatorOrNone() throws {
        func antenna(_ id: String, _ op: String) -> ANFRMapAntenna {
            ANFRMapAntenna(id: id, supId: "0123456", operatorRaw: op, system: "LTE 1800", generationRaw: "4G", modTypeRaw: "added",
                           statut: "En service", dateMaj: "", latitude: nil, longitude: nil, city: nil, address: "12 RUE DES LILAS")
        }
        let one = ANFRMapSite(supId: "0123456", latitude: 45.72869, longitude: 4.83312, city: "LYON 07", antennas: [antenna("a", "ORANGE")])
        let oneText = ANFRSiteDetailSheet.conversationShareText(for: one, baseURL: Self.siteBase)
        XCTAssertTrue(oneText.hasPrefix("Antenne Orange\nOpérateur: Orange\nSupport: 0123456\nMarché: FR\n"))
        XCTAssertTrue(oneText.contains("Position: 45.72869, 4.83312"))
        XCTAssertTrue(oneText.contains("Adresse: 12 Rue des Lilas, Lyon 07"))
        XCTAssertFalse(oneText.contains("Technologies"), "le relevé ne liste que les antennes modifiées")
        let card = try XCTUnwrap(SiteShareCard.parse(oneText))
        XCTAssertEqual(card.supportId, "0123456")
        XCTAssertEqual(card.operatorName, "Orange")

        let two = ANFRMapSite(supId: "0123456", latitude: 45.72869, longitude: 4.83312, city: "LYON 07",
                              antennas: [antenna("a", "ORANGE"), antenna("b", "SFR")])
        let twoLines = ANFRSiteDetailSheet.conversationShareText(for: two, baseURL: Self.siteBase).components(separatedBy: "\n")
        XCTAssertEqual(twoLines.first, "Antenne")
        XCTAssertTrue(twoLines.contains("Opérateur: Orange, SFR"))
    }

    /// SITE-1a : la forme servie par `GET /api/site-threads/comments` (bdf14de61), et le corps
    /// strict de la publication (le serveur refuse toute clé inconnue).
    func testSiteFollowKeyNeedsAPreciseOperator() throws {
        XCTAssertNil(SiteFollowKey(market: "fr", operatorKey: "ALL", siteId: "0123456"))
        XCTAssertNil(SiteFollowKey(market: "fr", operatorKey: " ", siteId: "0123456"))
        XCTAssertNil(SiteFollowKey(market: "", operatorKey: "ORANGE", siteId: "0123456"))
        let key = try XCTUnwrap(SiteFollowKey(market: " drom ", operatorKey: "ORANGE", siteId: "DROM:97100001"))
        XCTAssertEqual(key.queryItems.map { "\($0.name)=\($0.value ?? "")" },
                       ["market=DROM", "operator=ORANGE", "siteId=DROM:97100001"])
        let status = try JSONDecoder().decode(SiteFollowStatus.self,
                                              from: Data(#"{"following":true,"followId":"f_1","notify":true}"#.utf8))
        XCTAssertEqual(status, SiteFollowStatus(following: true, followId: "f_1"))
        let none = try JSONDecoder().decode(SiteFollowStatus.self,
                                            from: Data(#"{"following":false,"followId":null,"notify":null}"#.utf8))
        XCTAssertNil(none.followId)
    }

    func testDecodesASiteThreadPageAndEncodesAStrictPost() throws {
        let json = """
        {"thread":{"market":"FR","operator":"ORANGE","siteKey":"0123456","commentCount":2,"following":false},
         "comments":[
          {"id":"c2","kind":"help","text":"Débit faible ce soir","createdAt":"2026-10-19T00:51:37.123Z",
           "radio":{"technology":"4G","band":"b3","pci":214,"rsrp":-98.4,"neighbors":[{"pci":12}]},
           "author":{"id":"u2","handle":"camille","name":"Camille","avatarUrl":null},"own":false,"canDelete":false},
          {"id":"c1","kind":"comment","text":"5G active","createdAt":"2026-10-17T08:00:00.000Z","radio":null,
           "author":{"id":"u1","handle":null,"name":null,"avatarUrl":null},"own":true,"canDelete":true}],
         "nextCursor":"2026-10-17T08:00:00.000Z::c1","requestId":"r1"}
        """
        let page = try JSONDecoder.signalQuest.decode(SiteCommentsPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.thread.commentCount, 2)
        XCTAssertEqual(page.nextCursor, "2026-10-17T08:00:00.000Z::c1")
        XCTAssertEqual(page.comments.map(\.kind), [.help, .comment])
        XCTAssertNotNil(page.comments[0].createdAt)
        XCTAssertEqual(page.comments[0].radio?.summary, "4G · B3 · PCI 214 · -98 dBm")
        XCTAssertEqual(page.comments[0].author.displayName, "Camille")
        XCTAssertTrue(page.comments[1].canDelete)
        XCTAssertNil(page.comments[1].radio)

        // iOS ne joint que la technologie, la 5G NSA et SA au même format que le serveur.
        XCTAssertEqual(SiteCommentRadio.coarse(.fiveGNSA)?.technology, "5G")
        XCTAssertNil(SiteCommentRadio.coarse(nil))
        let radio = try XCTUnwrap(SiteCommentRadio.coarse(.fourG))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(radio)) as? [String: Any]
        XCTAssertEqual(encoded?.keys.sorted(), ["technology"])

        XCTAssertEqual(ReportTarget.siteComment("c2").id, "c2")

        // Les refus propres aux comptes récents se disent par leur code, jamais par le texte serveur.
        let links = APIError.http(status: 422, code: "LINKS_NOT_ALLOWED_YET", message: "Les liens sont possibles après 7 jours",
                                  requestId: nil, retryAfter: nil)
        XCTAssertEqual(links.errorDescription, String(localized: "Les liens sont possibles une fois ton compte âgé de 7 jours. Retire le lien pour publier."))
        let daily = APIError.http(status: 429, code: "NEW_ACCOUNT_DAILY_LIMIT", message: "3 messages par jour", requestId: nil, retryAfter: nil)
        XCTAssertEqual(daily.errorDescription, String(localized: "Pendant les 7 premiers jours, un compte publie au plus 3 messages par jour. Réessaie demain."))
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
