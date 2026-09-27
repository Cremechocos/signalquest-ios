import XCTest
import CoreTelephony
@testable import SignalQuest

@MainActor
final class ActiveCellularServiceTests: XCTestCase {
    func testExplicitDataServiceWinsOverDictionaryOrder() {
        let result = NetworkPathMonitor.activeServiceValue(
            in: ["a": CTRadioAccessTechnologyLTE, "z": CTRadioAccessTechnologyNR],
            dataServiceIdentifier: "z", transform: CellularRadioTechnology.map)
        XCTAssertEqual(result, .fiveGSA)
    }

    func testMissingActiveServiceDoesNotBorrowAnotherSIM() {
        let result = NetworkPathMonitor.activeServiceValue(
            in: ["other": "20801"], dataServiceIdentifier: "active") { $0 }
        XCTAssertNil(result)
    }

    func testUnexposedActiveTechnologyDoesNotBorrowAnotherSIM() {
        let result = NetworkPathMonitor.activeServiceValue(
            in: ["active": "unexposed", "other": CTRadioAccessTechnologyLTE],
            dataServiceIdentifier: "active", transform: CellularRadioTechnology.map)
        XCTAssertNil(result)
    }

    func testUnknownDataServiceWithTwoSIMsStaysUnknown() {
        let result = NetworkPathMonitor.activeServiceValue(
            in: ["a": "20801", "b": "23415"], dataServiceIdentifier: nil) { $0 }
        XCTAssertNil(result)
    }

    func testSingleServiceFallbackAndNoSIM() {
        XCTAssertEqual(NetworkPathMonitor.activeServiceValue(
            in: ["only": "20801"], dataServiceIdentifier: nil) { $0 }, "20801")
        XCTAssertNil(NetworkPathMonitor.activeServiceValue(
            in: [String: String](), dataServiceIdentifier: nil) { $0 })
    }

    func testActiveCellularPathWithUnknownRATRemainsCellular() {
        let status = NetworkPathStatus.map(.init(usesWiFi: false, usesCellular: true,
            usesWired: false, isExpensive: true, isConstrained: false), cellularTechnology: nil)
        XCTAssertEqual(status.connection, .cellular)
        XCTAssertEqual(status.displayName, "Cellulaire")
        XCTAssertNil(status.cellularTechnology)
    }
}
