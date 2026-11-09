import CryptoKit
import XCTest
@testable import SignalQuest

/// share-text v1.2 : le vecteur `contracts/share-text/v1.json` (copie à l'octet de
/// map-nextjs 499dea289, #1057 servie le 09/11), rejoué contre `ShareTextV1.read`.
final class ShareTextV1ContractTests: XCTestCase {

    private struct Vector: Decodable {
        struct Valid: Decodable {
            let `case`: String
            let type: String
            let fields: [String: String]
            let text: String
        }
        struct Expected: Decodable {
            let type: String
            let fields: [String: String]
            let safeLink: String?
        }
        struct Read: Decodable {
            let `case`: String
            let text: String
            let expected: Expected?
        }
        let fixtureVersion: String
        let valid: [Valid]
        let read: [Read]
    }

    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/share-text")
    }

    private func vector() throws -> Vector {
        try JSONDecoder().decode(Vector.self, from: Data(contentsOf: directory.appendingPathComponent("v1.json")))
    }

    func testTheVectorIsTheServedCopy() throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("v1.json"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sums = try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        XCTAssertEqual(sums, "\(digest)  v1.json\n")
    }

    func testEveryWrittenCaseReadsBackItsFields() throws {
        let vector = try vector()
        XCTAssertEqual(vector.valid.count, 13)
        for item in vector.valid {
            let parsed = try XCTUnwrap(ShareTextV1.read(item.text), item.case)
            XCTAssertEqual(parsed.kind.rawValue, item.type, item.case)
            XCTAssertEqual(parsed.fields, item.fields, item.case)
            XCTAssertEqual(parsed.safeLink, item.fields["link"], item.case)
        }
    }

    func testEveryReadCaseMatches() throws {
        let vector = try vector()
        XCTAssertEqual(vector.read.count, 36)
        for item in vector.read {
            let parsed = ShareTextV1.read(item.text)
            guard let expected = item.expected else {
                XCTAssertNil(parsed, item.case)
                continue
            }
            let value = try XCTUnwrap(parsed, item.case)
            XCTAssertEqual(value.kind.rawValue, expected.type, item.case)
            XCTAssertEqual(value.fields, expected.fields, item.case)
            XCTAssertEqual(value.safeLink, expected.safeLink, item.case)
        }
    }

    /// La forme comparable du §3 : portable, jamais une table de casse de langue.
    func testBrandComparableName() {
        XCTAssertEqual(ShareTextV1.comparableName("Bouygues-Télécom"), "bouyguestelecom")
        XCTAssertEqual(ShareTextV1.comparableName("Bouygues Telecom"), "bouyguestelecom")
        XCTAssertEqual(ShareTextV1.comparableName("ORANGE"), "orange")
        // « İ » (I point en chef) : NFD donne I + U+0307, retiré ; jamais « i̇ ».
        XCTAssertEqual(ShareTextV1.comparableName("İLIAD"), "iliad")
        XCTAssertEqual(ShareTextV1.comparableName("ß"), "")
    }

    func testThePreviewNeverShowsTheRawHeader() {
        let text = "SQ speedtest 1\ndownload_mbps: 412.0\nlink: https://signalquest.fr/speedtest/st_1"
        XCTAssertEqual(ShareTextV1.preview(text, locale: Locale(identifier: "fr_FR")), "Speedtest 412,0 Mb/s")
        XCTAssertNil(ShareTextV1.preview("Bonjour"))
        XCTAssertNil(ShareTextV1.preview("SQ site 2\noperator: ORANGE"))
    }

    /// v1.2 : « Opérateur : <marque> » puis « Réseau : <réseau> » ; une marque sans réseau
    /// seule ; sans marque, l'opérateur seul.
    func testSpeedtestCardOperatorRows() throws {
        func card(_ lines: String) throws -> SpeedtestShareTextCard {
            try XCTUnwrap(ShareTextV1.read("SQ speedtest 1\n" + lines + "link: https://signalquest.fr/speedtest/st_1").flatMap(SpeedtestShareTextCard.init))
        }
        let mvno = try card("download_mbps: 85.4\noperator: BOUYGUES\noperator_name: Bouygues Telecom\nbrand: La Poste Mobile\nmarket: FR\n")
        XCTAssertEqual(mvno.operatorRows(registry: nil).map(\.value), ["La Poste Mobile", "Bouygues Telecom"])
        XCTAssertEqual(mvno.operatorRows(registry: nil).map(\.label), ["Opérateur", "Réseau"])
        XCTAssertEqual(mvno.downloadMbps, 85.4)
        XCTAssertNotNil(mvno.safeURL)
        let alone = try card("brand: La Poste Mobile\n")
        XCTAssertEqual(alone.operatorRows(registry: nil).map(\.label), ["Opérateur"])
        let plain = try card("operator: ORANGE\noperator_name: Orange\nbrand: orange\nmarket: FR\n")
        XCTAssertNil(plain.brand, "Une marque qui répète le réseau est ignorée")
        XCTAssertEqual(plain.operatorRows(registry: nil).map(\.value), ["Orange"])
        // Clé inconnue de l'app : le nom porté par le texte.
        let unknown = try card("operator: UNMAPPED_MNO\noperator_name: Opérateur X\nmarket: ZZ\n")
        XCTAssertEqual(unknown.operatorRows(registry: nil).map(\.value), ["Opérateur X"])
        XCTAssertNil(ShareTextV1.read("SQ site 1\nlink: https://signalquest.fr/carte").flatMap(SpeedtestShareTextCard.init))
    }

    func testAnUnsafeLinkStaysReadableButNotOpenable() throws {
        let parsed = try XCTUnwrap(ShareTextV1.read("SQ speedtest 1\ndownload_mbps: 1.0\nlink: https://phishing.example/speedtest/st_1"))
        let card = try XCTUnwrap(SpeedtestShareTextCard(parsed))
        XCTAssertNil(card.safeURL)
        XCTAssertEqual(card.link, "https://phishing.example/speedtest/st_1")
    }

    /// Notification chiffrée locale et aperçu de la liste v2 : jamais l'en-tête brut.
    func testEncryptedNotificationAndListPreviewUseTheSharePreview() throws {
        let text = "SQ speedtest 1\ndownload_mbps: 412.0\nlink: https://signalquest.fr/speedtest/st_1"
        let payload = try E2EEV2ContentPayloadV2(sentAtMs: 1_760_000_000_000, counter: 1, replyToRef: nil, mentions: [], body: .text(text))
        let shown = E2EEV2NotificationPresentationPolicy.present(payload, ephemeral: false, privacy: .full)
        XCTAssertFalse(shown.body.contains("SQ speedtest"))
        XCTAssertTrue(shown.body.hasPrefix("Speedtest "))
        let plain = try E2EEV2ContentPayloadV2(sentAtMs: 1_760_000_000_000, counter: 2, replyToRef: nil, mentions: [], body: .text("Salut"))
        XCTAssertEqual(E2EEV2NotificationPresentationPolicy.present(plain, ephemeral: false, privacy: .full).body, "Salut")
    }
}
