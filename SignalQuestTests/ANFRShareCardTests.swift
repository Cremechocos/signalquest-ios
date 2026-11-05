import XCTest
@testable import SignalQuest

/// Image de partage des statistiques d'antennes, sur les références du web
/// (`~/Site/qa/anfr-share-reference`, captures de la prod du 05/11).
final class ANFRShareCardTests: XCTestCase {
    private func row(_ name: String, _ hex: UInt32, _ value: Int, _ delta: Int?) -> ANFRShareCardModel.Row {
        .init(name: name, color: UIColor(hex: hex), value: value, delta: delta)
    }

    private var franceN78: [ANFRShareCardModel.Row] {
        [row("Orange", 0xFF7900, 15_038, 48), row("Bouygues", 0x009DDC, 11_616, 32),
         row("Free", 0x6B7280, 11_554, 20), row("SFR", 0xE60012, 10_969, 20)]
    }

    func testImagesHaveTheWebSizesAtScaleTwo() {
        let landscape = ANFRShareCardRenderer.render(.init(
            square: false, title: "Antennes 5G 3,5 GHz en France", total: 49_177, totalDelta: 120,
            dateText: "05/11/2026", rows: franceN78
        ))
        XCTAssertEqual(landscape.size, CGSize(width: 2_400, height: 1_260))
        let square = ANFRShareCardRenderer.render(.init(
            square: true, title: "Antennes 5G 3,5 GHz en France", total: 49_177, totalDelta: 120,
            dateText: "05/11/2026", rows: franceN78
        ))
        XCTAssertEqual(square.size, CGSize(width: 2_160, height: 2_160))
        write(landscape, "fr-n78-paysage-avec-delta")
        write(square, "fr-n78-carre-avec-delta")

        let overseas = ANFRShareCardRenderer.render(.init(
            square: true, title: "Antennes 4G · Outre-mer", total: 3_467, totalDelta: 0, dateText: "05/11/2026",
            rows: [row("Orange", 0xFF7900, 1_014, 0), row("Outremer Telecom", 0x8B5CF6, 515, 0), row("SRR", 0x0EA5E9, 475, 0),
                   row("Digicel", 0xB91C1C, 423, 0), row("Free Caraïbes", 0x6B7280, 420, 0), row("Telco OI", 0x22C55E, 343, 0),
                   row("Zeop", 0xB7791F, 277, 0), row("Maore Mobile", 0x0891B2, 0, 0)]
        ))
        write(overseas, "drom-4g-carre-avec-delta")
        let undated = ANFRShareCardRenderer.render(.init(
            square: false, title: "Antennes 5G 3,5 GHz en France", total: 49_177, totalDelta: nil, dateText: nil,
            rows: franceN78.map { row($0.name, 0xFF7900, $0.value, nil) }
        ))
        write(undated, "fr-n78-paysage-sans-delta")
    }

    func testFileNameFollowsTheWeb() {
        let n78 = ANFRShareBand.all[1]
        XCTAssertEqual(ANFRShareCardBuilder.fileName(market: .fr, band: n78, latestDate: "2026-11-05", square: false),
                       "signalquest-antennes-n78-2026-11-05.png")
        XCTAssertEqual(ANFRShareCardBuilder.fileName(market: .fr, band: n78, latestDate: "2026-11-05", square: true),
                       "signalquest-antennes-n78-2026-11-05-carre.png")
        XCTAssertEqual(ANFRShareCardBuilder.fileName(market: .drom, band: n78, latestDate: nil, square: false),
                       "signalquest-antennes-n78-outre-mer-anfr.png")
        XCTAssertFalse(ANFRShareBand.available(in: .drom).contains { $0.key == "n1" })
    }

    /// Les PNG sont écrits pour une comparaison à l'œil quand `SQ_ANFR_SHARE_OUT` est donné.
    private func write(_ image: UIImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SQ_ANFR_SHARE_OUT"], let data = image.pngData() else { return }
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
