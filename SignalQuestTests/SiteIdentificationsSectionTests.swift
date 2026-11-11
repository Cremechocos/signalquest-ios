import XCTest
@testable import SignalQuest

/// « Tes identifications ici » sur la fiche d'un support : un bloc par nœud eNB/gNB du
/// membre sur CE support, jamais une ligne sans nœud ni un nœud d'un autre support.
final class SiteIdentificationsSectionTests: XCTestCase {
    private func item(_ json: String) throws -> MyIdentification {
        try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data(json.utf8))
    }

    func testOneTargetPerNodeOfThisSupportOnly() throws {
        let rows = [
            #"{"id":"a","siteId":"2877566","type":"enb","value":"626821","enb":"626821","gnb":null,"operator":"SFR","sectors":[]}"#,
            #"{"id":"b","siteId":"2877566","type":"cell","value":"626821-1","enb":"626821","gnb":null,"cellId":"1","pci":"120","operator":"SFR","sectors":[1]}"#,
            #"{"id":"c","siteId":"2877566","type":"gnb","value":"9001","enb":null,"gnb":"9001","operator":"SFR","sectors":[]}"#,
            #"{"id":"d","siteId":"1111111","type":"enb","value":"555","enb":"555","gnb":null,"operator":"SFR","sectors":[]}"#,
        ]
        let items = try rows.map(item)
        let targets = SiteIdentificationsModel.targets(siteId: "2877566", in: items)
        XCTAssertEqual(Set(targets.map(\.node)), ["626821", "9001"])
        XCTAssertEqual(targets.count, 2, "Une seule entrée par nœud, cellules comprises")
        XCTAssertTrue(targets.allSatisfy { $0.siteId == "2877566" })
        XCTAssertTrue(SiteIdentificationsModel.targets(siteId: "2877566", in: []).isEmpty)
    }

    /// La ligne du nœud qui porte un PCI se nomme par lui parmi les cellules, sans
    /// répéter « eNB 608665 » sous le titre du bloc (retour d'Alexandre du 11/11).
    func testNodeRowWithPciIsNamedByItsPciAmongCells() throws {
        let node = try item(#"{"id":"n","siteId":"1316142","type":"enb","value":"608665","enb":"608665","gnb":null,"pci":"181","operator":"BOUYGUES","sectors":[1]}"#)
        XCTAssertEqual(node.nodeLabel, "eNB 608665")
        XCTAssertEqual(node.cellLabel, "PCI 181")
        let bare = try item(#"{"id":"m","siteId":"1316142","type":"enb","value":"608665","enb":"608665","gnb":null,"operator":"BOUYGUES","sectors":[]}"#)
        XCTAssertEqual(bare.cellLabel, "eNB 608665")
        let cell = try item(#"{"id":"c","siteId":"1316142","type":"cell","value":"608665-10","enb":"608665","gnb":null,"cellId":"10","pci":"181","operator":"BOUYGUES","sectors":[2]}"#)
        XCTAssertEqual(cell.cellLabel, cell.nodeLabel)
    }
}
