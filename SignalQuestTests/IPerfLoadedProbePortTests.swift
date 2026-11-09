import XCTest
@testable import SignalQuest

/// Latence sous charge iPerf3 sans ICMP (choix d'Alexandre du 09/11, méthode
/// d'Android) : jamais le port actif, le haut de la plage d'abord.
final class IPerfLoadedProbePortTests: XCTestCase {
    func testTopOfRangeUnlessItIsTheActivePort() {
        XCTAssertEqual(iperfLoadedProbePort(active: 9210, min: 9200, max: 9240), 9240)
        XCTAssertEqual(iperfLoadedProbePort(active: 9240, min: 9200, max: 9240), 9239)
        XCTAssertEqual(iperfLoadedProbePort(active: nil, min: 9200, max: 9240), 9240)
    }

    func testSinglePortRangeSkipsTheSample() {
        XCTAssertNil(iperfLoadedProbePort(active: 5201, min: 5201, max: 5201))
    }

    func testTwoPortRangeNeverHitsTheActivePort() {
        XCTAssertEqual(iperfLoadedProbePort(active: 5202, min: 5201, max: 5202), 5201)
        XCTAssertEqual(iperfLoadedProbePort(active: 5201, min: 5201, max: 5202), 5202)
    }
}
