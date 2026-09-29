import XCTest
@testable import SignalQuest

/// Récapitulatif du dernier trajet (MES-14) : conservé sur l'appareil, par
/// compte, en valeurs brutes pour que le texte suive la langue du moment.
@MainActor
final class DriveTestSessionRecapTests: XCTestCase {
    private let suiteName = "DriveTestSessionRecapTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeRecap(dataCap: Bool = false, vpn: Bool = false) -> DriveTestViewModel.SessionRecap {
        DriveTestViewModel.SessionRecap(
            endedAt: Date(timeIntervalSince1970: 1_790_000_000), distanceMeters: 12_345, testCount: 7,
            bytes: 1_250_000_000, stoppedByDataCap: dataCap, vpnActive: vpn
        )
    }

    func testRecapSurvivesARelaunch() {
        let recap = makeRecap()
        recap.save(defaults: defaults)
        XCTAssertEqual(DriveTestViewModel.SessionRecap.load(defaults: defaults), recap)
    }

    /// Un autre compte sur le même téléphone ne voit pas le trajet du premier.
    func testEachAccountKeepsItsOwnTrip() {
        let previousUser = LocalAccountScope.currentUserId
        defer {
            if let previousUser { LocalAccountScope.activate(userId: previousUser) } else { LocalAccountScope.deactivate() }
        }
        LocalAccountScope.activate(userId: "recap-owner-a")
        makeRecap().save(defaults: defaults)
        LocalAccountScope.activate(userId: "recap-owner-b")
        XCTAssertNil(DriveTestViewModel.SessionRecap.load(defaults: defaults))
        LocalAccountScope.activate(userId: "recap-owner-a")
        XCTAssertEqual(DriveTestViewModel.SessionRecap.load(defaults: defaults), makeRecap())
    }

    func testSummaryUsesSharedFormatters() {
        let line = makeRecap().summaryLine
        XCTAssertTrue(line.contains(SQUnits.distance(meters: 12_345)), line)
        XCTAssertTrue(line.contains(DriveTestViewModel.formattedBytes(1_250_000_000)), line)
        XCTAssertTrue(line.contains("7"), line)
    }

    /// Un arrêt aussitôt après le départ n'efface pas le dernier vrai trajet.
    func testEmptyTripIsNotKept() {
        let empty = DriveTestViewModel.SessionRecap(endedAt: Date(), distanceMeters: 12, testCount: 0, bytes: 0,
                                                    stoppedByDataCap: false, vpnActive: false)
        XCTAssertFalse(empty.isWorthKeeping)
        XCTAssertTrue(makeRecap().isWorthKeeping)
        XCTAssertEqual(DriveTestViewModel.formattedBytes(0).first, "0", "« Zéro ko » au lieu d'un nombre")
    }

    /// Le plafond atteint explique l'arrêt : il prime sur la mention du VPN.
    func testDataCapCaveatWinsOverVPN() {
        XCTAssertNil(makeRecap().caveat)
        XCTAssertEqual(makeRecap(dataCap: true, vpn: true).caveat,
                       String(localized: "Arrêt automatique : plafond de données atteint."))
        XCTAssertEqual(makeRecap(vpn: true).caveat,
                       String(localized: "VPN actif : rien n'a été publié sur la carte."))
    }
}
