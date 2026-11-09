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

    /// Un refus immédiat compte comme un aller-retour ; un silence reste perdu.
    func testRefusalCountsAsReplyButSilenceDoesNot() async {
        struct Probe: SpeedtestTCPProbing {
            let outcome: Result<Double, Error>
            func connectLatencyMs(host: String, port: UInt16, timeoutSeconds: TimeInterval) async throws -> Double {
                try outcome.get()
            }
        }
        let accepted = await iperfLoadedConnectRttMs(tcpProbe: Probe(outcome: .success(7.4)), host: "192.0.2.1", port: 9240)
        let refused = await iperfLoadedConnectRttMs(
            tcpProbe: Probe(outcome: .failure(SpeedtestTCPRefusal(elapsedMs: 7.6))), host: "192.0.2.1", port: 9240
        )
        let silent = await iperfLoadedConnectRttMs(
            tcpProbe: Probe(outcome: .failure(URLError(.timedOut))), host: "192.0.2.1", port: 9240
        )
        XCTAssertEqual(accepted, 7.4)
        XCTAssertEqual(refused, 7.6)
        XCTAssertNil(silent)
    }
}
