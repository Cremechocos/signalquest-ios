import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 6a3 (E2EE-AUTO §4.2, révision 12) : libellé et dernière activité, lus à
/// clés exactes et joints au journal vérifié par `deviceId`, pour l'affichage seul.
final class E2EEAutoDeviceLabelsTests: XCTestCase {
    private let ownId = "ios_device_own_000000000"
    private let otherId = "web_device_other_00000000"

    private func json(_ devices: [[String: Any]], extra: [String: Any] = [:]) -> Data {
        var root: [String: Any] = ["devices": devices]
        root.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func device(_ id: String, label: Any = NSNull(), seen: Any = NSNull()) -> [String: Any] {
        ["deviceId": id, "label": label, "lastSeenAtMs": seen]
    }

    func testParsesTheExactShape() throws {
        let parsed = try XCTUnwrap(E2EEAutoDeviceLabels.parse(json([
            device(ownId, label: "iPhone 15 Pro", seen: "1793000040000"),
            device(otherId),
        ])))
        XCTAssertEqual(parsed[ownId], .init(label: "iPhone 15 Pro", lastSeenAtMs: 1_793_000_040_000))
        XCTAssertEqual(parsed[otherId], .init(label: nil, lastSeenAtMs: nil))
        XCTAssertEqual(E2EEAutoDeviceLabels.parse(json([])), [:])
    }

    /// Une seule faute écarte toute la réponse : libellés et activités restent inconnus.
    func testRefusesTheWholeResponseOnAnyFault() {
        let refused: [(String, Data)] = [
            ("ordre", json([device(otherId), device(ownId)])),
            ("doublon", json([device(ownId), device(ownId)])),
            ("clé en plus à la racine", json([device(ownId)], extra: ["next": NSNull()])),
            ("clé en plus", json([device(ownId).merging(["platform": "ios"]) { $1 }])),
            ("clé absente", json([["deviceId": ownId, "label": NSNull()]])),
            ("activité en nombre", json([device(ownId, seen: 1_793_000_040_000)])),
            ("activité non canonique", json([device(ownId, seen: "01793000040000")])),
            ("activité négative", json([device(ownId, seen: "-1")])),
            ("libellé vide", json([device(ownId, label: "")])),
            ("libellé avec saut de ligne", json([device(ownId, label: "iPhone\nPro")])),
            ("libellé avec tabulation", json([device(ownId, label: "iPhone\tPro")])),
            ("libellé avec U+2028", json([device(ownId, label: "iPhone\u{2028}Pro")])),
            ("libellé avec Cf", json([device(ownId, label: "iPhone\u{200B}")])),
            ("espace en tête", json([device(ownId, label: " iPhone")])),
            ("espace insécable en fin", json([device(ownId, label: "iPhone\u{00A0}")])),
            ("65 points de code", json([device(ownId, label: String(repeating: "é", count: 65))])),
            ("identifiant non opaque", json([device("ios device")])),
        ]
        for (name, data) in refused {
            XCTAssertNil(E2EEAutoDeviceLabels.parse(data), name)
        }
        XCTAssertNotNil(E2EEAutoDeviceLabels.parse(json([device(ownId, label: "Safari\u{00A0}sur macOS")])), "U+00A0 au milieu est admis")
        XCTAssertNotNil(E2EEAutoDeviceLabels.parse(json([device(ownId, label: String(repeating: "é", count: 64))])))
    }

    @MainActor
    func testScreenJoinsLabelsByDeviceIdAndKeepsThemOnAFailedRead() async {
        let day: Int64 = 24 * 3_600_000
        func state(_ id: String, _ platform: E2EEAutoLog.Platform) -> E2EEAutoLog.DeviceState {
            let key = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
            return E2EEAutoLog.DeviceState(
                deviceId: id, platform: platform, identityKeyB64: key, signingKeyB64: key, keyVersion: 1, status: .active,
                addedAtMs: day, activatedAtMs: day, addEntryHash: E2EEAutoLog.digest(id), identityKeys: []
            )
        }
        var account = E2EEAutoLog.AccountState(userId: "user_alice_00000000001", accountSaltB64: Data(count: 16).base64EncodedString())
        for device in [state(ownId, .ios), state(otherId, .web)] { account.devices[device.deviceId] = device }
        final class Labels: @unchecked Sendable { var read: [String: E2EEAutoDeviceLabels.Display]? }
        let labels = Labels()
        labels.read = [
            otherId: .init(label: "Safari sur macOS", lastSeenAtMs: 5 * day),
            "android_unknown_0000000000": .init(label: "Pixel 8", lastSeenAtMs: 5 * day),
        ]
        let ownId = ownId
        let model = E2EEAutoDevicesViewModel(dependencies: .init(
            ownDeviceId: { ownId }, readOwnAccount: { .verified(account) }, revoke: { _, _ in .retryLater },
            readLabels: { labels.read }, nowMs: { 10 * day }
        ))
        await model.load()
        XCTAssertEqual(model.rows.map(\.id), [ownId, otherId], "un appareil absent du journal n'apparaît pas")
        let other = model.rows[1]
        XCTAssertEqual(other.label, "Safari sur macOS")
        XCTAssertEqual(E2EEAutoDevicesView.deviceName(other), "Safari sur macOS")
        XCTAssertNil(model.rows[0].label, "absent de la réponse : libellé inconnu")
        XCTAssertEqual(E2EEAutoDevicesView.deviceName(model.rows[0]), E2EEAutoDevicesView.platformName(model.rows[0]))

        let now = Date(timeIntervalSince1970: TimeInterval(5 * day) / 1_000 + 7_200)
        XCTAssertNotNil(E2EEAutoDevicesView.activityText(other, now: now))
        XCTAssertNil(E2EEAutoDevicesView.activityText(model.rows[0], now: now), "pas pour cet appareil")

        labels.read = nil
        await model.load()
        XCTAssertEqual(model.rows[1].label, "Safari sur macOS", "une lecture en échec n'efface rien")
    }
}
