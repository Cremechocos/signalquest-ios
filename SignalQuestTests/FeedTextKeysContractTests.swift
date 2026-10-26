import XCTest
@testable import SignalQuest

/// Textes traduisibles du fil : les vecteurs du contrat `feed-text-keys` v1
/// (copie à l'octet de `contracts/feed-text-keys/v1.json`, 32995cd9e), rejoués
/// contre `FeedTextKey` et le décodage des posts (lot F, F8).
final class FeedTextKeysContractTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Key: Decodable {
            let key: String
            let args: [String: String]
        }
        struct Case: Decodable {
            struct Input: Decodable {
                let sourceType: String?
                let text: String
            }
            struct Expect: Decodable {
                let textKey: String?
                let textArgs: [String: JSONValue]?
            }
            let name: String
            let input: Input
            let expect: Expect
        }
        let version: Int
        let keys: [Key]
        let cases: [Case]
    }

    private func vectors() throws -> Vectors {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/feed-text-keys/v1.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    func testCatalogMatchesTheContract() throws {
        let vectors = try vectors()
        XCTAssertEqual(vectors.version, 1)
        XCTAssertEqual(vectors.keys.count, 36)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: vectors.keys.map { ($0.key, $0.args) }), FeedTextKey.contractArgs)
        // Règle 8 : une clé n'est jamais le préfixe d'une autre.
        let keys = vectors.keys.map(\.key)
        for key in keys {
            XCTAssertFalse(keys.contains { $0 != key && $0.hasPrefix(key + ".") }, key)
        }
    }

    /// Chaque sortie servie se traduit ; une sortie nulle laisse `text`. Les noms
    /// et le libellé de l'identifiant passent tels quels dans la phrase.
    func testEveryCaseRendersOrFallsBack() throws {
        let vectors = try vectors()
        XCTAssertEqual(vectors.cases.count, 87)
        let labels = ["cellid": "Cell ID", "pci": "PCI", "enb": "eNB", "gnb": "gNB"]
        for vector in vectors.cases {
            let item = try decodeItem(text: vector.input.text, textKey: vector.expect.textKey, textArgs: vector.expect.textArgs)
            guard vector.expect.textKey != nil else {
                XCTAssertNil(item.feedText, vector.name)
                XCTAssertEqual(item.displayText, vector.input.text, vector.name)
                continue
            }
            let text = try XCTUnwrap(item.feedText, vector.name)
            XCTAssertFalse(text.isEmpty, vector.name)
            XCTAssertEqual(item.displayText, text, vector.name)
            for name in ["place", "siteName", "badgeName", "questTitle", "departmentCode"] {
                if case .string(let value)? = vector.expect.textArgs?[name] {
                    XCTAssertTrue(text.contains(value), "\(vector.name) : \(name)")
                }
            }
            if case .string(let type)? = vector.expect.textArgs?["identifierType"] {
                XCTAssertTrue(text.contains(try XCTUnwrap(labels[type])), vector.name)
            }
            if case .number(let value)? = vector.expect.textArgs?["identifierValue"] {
                XCTAssertTrue(text.contains(String(Int64(value))), "\(vector.name) : sans séparateur de milliers")
            }
        }
    }

    /// Ce que l'app refuse d'elle-même (règle 2) : la carte garde `text`.
    func testAppRefusesWhatItCannotSay() {
        func key(_ key: String?, _ args: [String: JSONValue]?) -> FeedTextKey? { FeedTextKey(key: key, args: args) }
        XCTAssertNil(key("feed.future.key", [:]), "clé inconnue")
        XCTAssertNil(key(nil, nil))
        XCTAssertNil(key("feed.validation.submitted", ["identifierType": .string("nci")]), "énumération inconnue")
        XCTAssertNil(key("feed.validation.submitted", ["identifierType": .string("PCI")]), "énumération en minuscules")
        XCTAssertNil(key("feed.level.reached", ["level": .string("12")]), "nombre en chaîne")
        XCTAssertNil(key("feed.level.reached", ["level": .number(-1)]), "entier négatif")
        XCTAssertNil(key("feed.level.reached", ["level": .number(12.5)]), "décimal pour un entier")
        XCTAssertNil(key("feed.level.reached", nil), "argument manquant")
        XCTAssertNil(key("feed.speedtest.done", ["downloadMbps": .number(0)]), "débit nul")
        XCTAssertNil(key("feed.rating.signal", ["stars": .number(6)]))
        XCTAssertNil(key("feed.rating.signal", ["stars": .number(0)]))
        XCTAssertNil(key("feed.photo.site_with_place", ["place": .string("  ")]), "chaîne vide")
        XCTAssertNil(key("feed.netmonster.daily", [
            "created": .number(1), "updated": .number(2), "addressesUpdated": .number(3), "countryCode": .string("ZZ"),
        ]), "pays que l'app ne sait pas dire")
        XCTAssertNotNil(key("feed.validation.direct", ["identifierType": .string("gnb"), "identifierValue": .number(68_719_476_735)]),
                        "gNB au-delà de 2³¹ − 1")
        XCTAssertNotNil(key("feed.level.reached", ["level": .number(12), "extra": .string("x")]), "un argument en plus ne gêne pas")
    }

    /// Le décodage d'une clé mal formée ne coûte que la traduction.
    func testMalformedKeyKeepsThePost() throws {
        let data = Data("""
        {"id":"p1","kind":"badge","author":{"id":"u1"},"text":"Niveau 12 atteint !","generated":true,
         "textKey":12,"textArgs":"level","commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false}
        """.utf8)
        let item = try JSONDecoder().decode(UnifiedSocialFeedItem.self, from: data)
        XCTAssertNil(item.textKey)
        XCTAssertEqual(item.displayText, "Niveau 12 atteint !")
    }

    /// L'anglais lu dans `en.lproj` : pluriels, ordre des arguments, prépositions.
    func testEnglishTranslations() throws {
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let locale = Locale(identifier: "en")
        func en(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: english, locale: locale) }
        let label = "PCI", place = "Grenoble"
        XCTAssertEqual(en("Validation \(label) soumise · \(place)"), "PCI identification submitted · Grenoble")
        XCTAssertEqual(en("Nouvelle validation \(label) créée"), "New PCI identification")
        let value = "123456"
        XCTAssertEqual(en("Identification hors-ligne : \(label) \(value)"), "Offline identification: PCI 123456")
        XCTAssertEqual(en("\(1) nouvelles antennes"), "1 new site")
        XCTAssertEqual(en("\(4) nouvelles antennes"), "4 new sites")
        XCTAssertEqual(en("\(1) adresses mises à jour"), "1 address updated")
        XCTAssertEqual(en("\(1) mesures"), "1 measurement")
        let days = 7
        XCTAssertEqual(en("Série de \(days) jours consécutifs !"), "7-day streak!")
        XCTAssertEqual(en("au Luxembourg"), "in Luxembourg")
        let name = "Château d'eau"
        XCTAssertEqual(en("a ajouté \(name) sur la carte"), "added Château d'eau to the map")
        let stars = 4
        XCTAssertEqual(en("A évalué ce signal · \(stars)/5"), "Rated this signal · 4/5")
    }

    func testFrenchPluralsReadAtZeroAndOne() {
        // Le français met 0 et 1 au singulier ; la langue de dev des tests est le français.
        guard Bundle.main.preferredLocalizations.first == "fr" else { return }
        let session = FeedTextKey(key: "feed.session.completed", args: ["distanceMeters": .number(800), "measureCount": .number(0)])
        XCTAssertTrue(session?.text.hasSuffix("0 mesure") == true, session?.text ?? "")
        let streak = FeedTextKey(key: "feed.streak.bonus", args: ["days": .number(1)])
        XCTAssertEqual(streak?.text, "Série de 1 jour consécutif !")
    }

    private func decodeItem(text: String, textKey: String?, textArgs: [String: JSONValue]?) throws -> UnifiedSocialFeedItem {
        var object: [String: Any] = [
            "id": "p1", "kind": "badge", "author": ["id": "u1"], "text": text, "generated": true,
            "commentsCount": 0, "repostsCount": 0, "favoritesCount": 0,
            "likedByMe": false, "favoritedByMe": false, "repostedByMe": false,
        ]
        object["textKey"] = textKey ?? NSNull()
        object["textArgs"] = try textArgs.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
        return try JSONDecoder().decode(UnifiedSocialFeedItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
