import XCTest
@testable import SignalQuest

/// Passage d'un résultat de speedtest au modèle de la carte de partage.
///
/// Le rendu est vérifié ailleurs (`SQShareCardRenderTests`, par pièces jointes à
/// regarder) ; ici on vérifie ce qu'aucun coup d'œil ne rattrape : les nombres
/// affichés, les échelles, et les replis quand une donnée manque.
final class SQShareCardBuilderTests: XCTestCase {

    /// Locale figée : le séparateur décimal fait partie de ce qu'on vérifie.
    private let locale = Locale(identifier: "fr_FR")

    private func result(
        downloadSeries: [Double]? = Array(repeating: 700, count: 20),
        uploadSeries: [Double]? = Array(repeating: 120, count: 20),
        pingMin: Double? = 14,
        pingMedian: Double? = 18,
        pingAverage: Double? = 24,
        loadedPings: Bool = true,
        pingDl: Double? = 42,
        pingUl: Double? = 57,
        connection: NetworkConnectionKind = .cellular,
        ssid: String? = nil,
        /// En Wi-Fi, ce champ porte le FAI résolu par IP/ASN — pas l'opérateur SIM.
        operatorName: String? = nil,
        technology: CellularRadioTechnology? = .fiveGSA,
        city: String? = "Lyon",
        address: String? = nil,
        pingHost: String? = "paris.bbr.test"
    ) -> SpeedtestRunResult {
        SpeedtestRunResult(
            id: UUID(),
            label: "test",
            downloadMbps: 770.24,
            downloadAverageMbps: 770.24,
            downloadMaxMbps: 812.4,
            uploadMbps: 126.44,
            uploadAverageMbps: 126.44,
            uploadMaxMbps: 131.0,
            pingMs: pingAverage,
            pingMedianMs: pingMedian,
            pingMinMs: pingMin,
            pingMaxMs: 30,
            jitterMs: 1.44,
            pingDlMs: loadedPings ? pingDl : nil,
            jitterDlMs: loadedPings ? 6.2 : nil,
            pingUlMs: loadedPings ? pingUl : nil,
            jitterUlMs: loadedPings ? 9.4 : nil,
            pingProtocol: "ICMP",
            durationSeconds: 14,
            connectionType: connection,
            cellularTechnology: connection == .wifi || connection == .wired ? nil : technology,
            networkOperatorName: operatorName ?? (connection == .cellular ? "Orange" : nil),
            wifiSSID: ssid,
            city: city,
            address: address,
            serverName: "Paris BBR (Bouygues)",
            downloadServerName: "Paris BBR (Bouygues)",
            downloadServerHost: "paris.bbr.test",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: downloadSeries,
            uploadSeriesMbps: uploadSeries,
            deviceModel: "iPhone 17 Pro (iPhone18,1)",
            osVersion: "iOS 27",
            pingServerHost: pingHost
        )
    }

    private func model(
        _ result: SpeedtestRunResult,
        options: SpeedtestShareOptions = .init()
    ) -> SQShareCardModel {
        SQShareCardBuilder.model(
            for: result,
            theme: .dark,
            locale: locale,
            options: options
        )
    }

    /// Couleur en hexadécimal : une `Color` SwiftUI convertie n'est pas `==` à
    /// la même teinte construite en `UIColor`.
    private func hex(_ color: UIColor?) -> UInt32? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let color, color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    // MARK: Nombres

    func testDisplayedNumbersMatchTheResult() {
        let card = model(result())
        XCTAssertEqual(card.download, .init(number: "770", unit: "Mb/s"))
        XCTAssertEqual(card.downloadPeakText, "Pic à 812 Mb/s")
        XCTAssertEqual(card.upload, .init(number: "126", unit: "Mb/s"))
        XCTAssertEqual(card.uploadPeakText, "Pic à 131 Mb/s")
        XCTAssertEqual(card.latencyLabel, "Latence min.")
        XCTAssertEqual(card.latency, .init(number: "14", unit: "ms"))
        XCTAssertEqual(card.latencyAverageText, "Moyenne 24 ms")
    }

    /// Un pic qui s'écrit comme le débit n'apporte rien : pas de ligne.
    func testPeakEqualToTheAverageIsOmitted() {
        let sample = SpeedtestRunResult(label: "flat", downloadMbps: 84.21, downloadAverageMbps: 84.21,
            downloadMaxMbps: 84.24, uploadAverageMbps: 20, uploadMaxMbps: 20, durationSeconds: 10, connectionType: .wifi)
        let card = model(sample)
        XCTAssertNil(card.downloadPeakText)
        XCTAssertNil(card.uploadPeakText)
    }

    /// Règle du 20/10 : une décimale sous 10, entier de 10 à 999, Gb/s à trois
    /// décimales dès 1 000 — les bascules jugées sur la valeur arrondie.
    func testThroughputFollowsTheSharedNumberRule() {
        func text(_ mbps: Double) -> String? {
            SQShareCardBuilder.throughput(mbps, locale: locale).map { "\($0.number) \($0.unit)" }
        }
        XCTAssertEqual(text(7.54), "7,5 Mb/s")
        XCTAssertEqual(text(9.96), "10 Mb/s")
        XCTAssertEqual(text(84.24), "84 Mb/s")
        XCTAssertEqual(text(214.4), "214 Mb/s")
        XCTAssertEqual(text(999.6), "1,000 Gb/s")
        XCTAssertEqual(text(1_722), "1,722 Gb/s")
        XCTAssertEqual(text(12_408.6), "12,409 Gb/s")
        XCTAssertNil(text(0), "Jamais de zéro : la ligne disparaît")
        XCTAssertNil(text(.nan))
    }

    /// Une valeur absente retire sa ligne : jamais de zéro ni de tiret.
    func testMissingValuesRemoveTheirLine() {
        XCTAssertNil(model(result(pingMin: nil, pingMedian: nil, pingAverage: nil)).latency)
        let noLoad = model(result(loadedPings: false))
        XCTAssertEqual(noLoad.rows.map(\.label), ["Gigue", "Serveur"])
        XCTAssertNil(model(result(downloadSeries: nil)).downloadGraph)
    }

    /// Sans minimum : la médiane puis la moyenne, sous « Latence », sans ligne Moyenne.
    func testLatencyFallsBackToMedianThenAverage() {
        let median = model(result(pingMin: nil))
        XCTAssertEqual(median.latencyLabel, "Latence")
        XCTAssertEqual(median.latency?.number, "18")
        XCTAssertNil(median.latencyAverageText)
        XCTAssertEqual(model(result(pingMin: nil, pingMedian: nil)).latency?.number, "24")
    }

    /// Note sous charge : pire latence chargée moins la latence affichée, barème
    /// Cloudflare du serveur et d'Android (57 − 14 = 43 ms → C).
    func testUnderLoadRowCarriesTheGradeThenTheDelta() {
        let rows = model(result()).rows
        XCTAssertEqual(rows.map(\.label), ["Sous charge", "Gigue", "Serveur"])
        XCTAssertEqual(rows[0].value, "+43 ms")
        XCTAssertEqual(rows[0].grade?.letter, "C")
        XCTAssertEqual(rows[1].value, "1,4 ms")
        XCTAssertEqual(rows[2].value, "Paris BBR (Bouygues)")
    }

    func testLoadedLatencyGradeThresholds() {
        func grade(_ loaded: Double) -> String? {
            SQShareCardBuilder.loadedLatency(for: result(pingMin: 20, loadedPings: true, pingDl: loaded, pingUl: nil))?.grade.letter
        }
        XCTAssertEqual(grade(25), "A")
        XCTAssertEqual(grade(50), "B")
        XCTAssertEqual(grade(80), "C")
        XCTAssertEqual(grade(220), "D")
        XCTAssertEqual(grade(221), "F")
        XCTAssertEqual(grade(10), "A", "Une latence chargée plus basse n'est pas une hausse négative")
    }

    /// Latence au repos mesurée ailleurs que sur le serveur du test (ou inconnue) :
    /// l'écart ne mesure pas la charge, la ligne disparaît.
    func testUnderLoadNeedsTheIdleLatencyOnTheTestServer() {
        XCTAssertNil(SQShareCardBuilder.loadedLatency(for: result(pingHost: "1.1.1.1")))
        XCTAssertNil(SQShareCardBuilder.loadedLatency(for: result(pingHost: nil)))
        XCTAssertNotNil(SQShareCardBuilder.loadedLatency(for: result(pingHost: "PARIS.bbr.test")))
    }

    // MARK: Séries

    func testLongSeriesIsDownsampled() {
        let series = (0..<200).map { Double($0) }
        let graph = model(result(downloadSeries: series)).downloadGraph
        XCTAssertEqual(graph?.points.count, 32)
        XCTAssertGreaterThan(graph?.points.first ?? 0, 0)
        XCTAssertLessThan(graph?.points.last ?? 0, 200)
    }

    /// Le haut du tracé est le maximum mesuré : la marge vient du gabarit (4 pt).
    func testGraphScaleIsTheMeasuredMaximum() {
        let graph = model(result(downloadSeries: [100, 200, 300])).downloadGraph
        XCTAssertEqual(graph?.localMax ?? 0, 300, accuracy: 0.001)
    }

    /// Un échantillon aberrant est un artefact de mesure : il est borné, sinon il
    /// écrase l'échelle et aplatit toute la courbe.
    func testAbsurdSamplesAreClamped() {
        let graph = model(result(downloadSeries: [100, 999_999, 200])).downloadGraph
        XCTAssertEqual(graph?.points.max() ?? 0, 20_000, accuracy: 0.001)
    }

    func testNonFiniteSamplesAreDropped() {
        let graph = model(result(downloadSeries: [100, .nan, .infinity, -5, 300])).downloadGraph
        XCTAssertEqual(graph?.points, [100, 300])
    }

    func testCurvesUseInkForDownloadAndBrandForUpload() {
        let card = model(result())
        XCTAssertEqual(card.downloadGraph?.accentColor, UIColor(hex: 0x1C201E))
        XCTAssertEqual(card.uploadGraph?.accentColor, UIColor(hex: 0xA8123A))
    }

    // MARK: En-tête et pied

    func testHeaderCarriesOperatorThenGeneration() {
        let network = model(result()).network
        XCTAssertEqual(network?.name, "Orange")
        XCTAssertEqual(network?.detail, "5G")
        XCTAssertEqual(hex(network?.barColor), 0xFF7900)
    }

    /// Le SSID identifie un foyer et l'image est faite pour être publiée : il n'y
    /// figure jamais, sur aucune plateforme.
    func testSsidNeverReachesTheCard() {
        let card = model(result(connection: .wifi, ssid: "Maison-Germain", operatorName: "Free"))
        let rendered = [card.network?.name ?? "", card.network?.detail ?? "", card.deviceCityText]
            + card.rows.map(\.value)
        XCTAssertFalse(rendered.contains { $0.contains("Maison") })
    }

    /// C'est le FAI — résolu par IP/ASN, donc muet sur le réseau local — qui
    /// prend la place du SSID : « Free · Wi-Fi », barre à sa couleur.
    func testWifiHeaderCarriesTheIspInsteadOfTheSsid() {
        let network = model(result(connection: .wifi, ssid: "Maison-Germain", operatorName: "Free")).network
        XCTAssertEqual(network?.name, "Free")
        XCTAssertEqual(network?.detail, "Wi-Fi")
        XCTAssertEqual(hex(network?.barColor), 0x6B7280)
    }

    /// FAI inconnu : « Wi-Fi » seul et sans barre plutôt qu'un opérateur inventé.
    func testWifiHeaderFallsBackToWifiAlone() {
        let network = model(result(connection: .wifi, ssid: "Maison-Germain")).network
        XCTAssertEqual(network?.name, "Wi-Fi")
        XCTAssertNil(network?.detail)
        XCTAssertNil(network?.barColor)
    }

    /// FAI hors palette : son nom sans barre — le gris de repli se lirait « Free ».
    func testUnknownIspKeepsItsNameWithoutABar() {
        let network = model(result(connection: .wifi, operatorName: "OVHcloud")).network
        XCTAssertEqual(network?.name, "OVHcloud")
        XCTAssertEqual(network?.detail, "Wi-Fi")
        XCTAssertNil(network?.barColor)
    }

    /// Sous VPN, l'adresse vue est celle du tunnel : la techno seule, sans barre.
    func testVpnHeaderKeepsTheTechnologyAlone() {
        let network = model(result(connection: .other, operatorName: "M247", technology: .fourG)).network
        XCTAssertEqual(network?.name, "4G")
        XCTAssertNil(network?.detail)
        XCTAssertNil(network?.barColor)
        XCTAssertNil(model(result(connection: .other, technology: nil)).network)
    }

    func testDateReadsAsASentence() {
        XCTAssertTrue(model(result()).dateText?.contains("mai 2026 à") == true, model(result()).dateText ?? "nil")
    }

    /// L'identifiant machine relève du diagnostic : la carte n'affiche que le nom
    /// commercial de l'appareil.
    func testFooterKeepsTheMarketingNameOnly() {
        let card = model(result())
        XCTAssertEqual(card.deviceCityText, "iPhone 17 Pro · Lyon")
    }

    func testCityFallsBackToTheAddress() {
        let card = model(result(city: nil, address: "12 rue des Lilas, 69003 Lyon"))
        XCTAssertTrue(card.deviceCityText.hasSuffix("· Lyon"), card.deviceCityText)
    }

    /// Rien plutôt qu'un « France » par défaut : une localisation fausse vaut
    /// moins qu'une absence.
    func testMissingLocationLeavesOnlyTheDevice() {
        let card = model(result(city: nil, address: nil))
        XCTAssertEqual(card.deviceCityText, "iPhone 17 Pro")
    }

    func testPrivacyOptionsHideOnlyContextualMetadata() {
        let sample = result()
        let full = model(sample)
        let privateCard = model(
            sample,
            options: SpeedtestShareOptions(
                includeNetworkContext: false,
                includeApproximateLocation: false,
                includeDevice: false,
                includeRadioDetails: false,
                includeServerDetails: false,
                includeTimestamp: false
            )
        )

        XCTAssertNil(privateCard.network)
        XCTAssertNil(privateCard.dateText)
        XCTAssertFalse(privateCard.rows.contains { $0.label == "Serveur" })
        XCTAssertEqual(privateCard.deviceCityText, "")

        // Le résultat lui-même reste partageable et ne change jamais avec les
        // options de confidentialité.
        XCTAssertEqual(privateCard.download, full.download)
        XCTAssertEqual(privateCard.upload, full.upload)
        XCTAssertEqual(privateCard.latency, full.latency)
        XCTAssertEqual(privateCard.downloadGraph?.points, full.downloadGraph?.points)
        XCTAssertEqual(privateCard.uploadGraph?.points, full.uploadGraph?.points)
    }

    func testDeviceAndApproximateLocationCanBeHiddenIndependently() {
        let sample = result()
        XCTAssertEqual(
            model(sample, options: .init(includeApproximateLocation: false)).deviceCityText,
            "iPhone 17 Pro"
        )
        XCTAssertEqual(
            model(sample, options: .init(includeDevice: false)).deviceCityText,
            "Lyon"
        )
    }

    func testShareTextHonorsPrivacyOptionsAndKeepsCoreResult() {
        let sample = result()
        let text = SpeedtestShareImageRenderer.shareText(
            for: sample,
            options: SpeedtestShareOptions(
                includeNetworkContext: false,
                includeApproximateLocation: false,
                includeDevice: false,
                includeRadioDetails: false,
                includeServerDetails: false,
                includeTimestamp: false
            )
        )

        XCTAssertTrue(text.contains("770 \(SQUnits.throughputUnit(mbps: 770))"))
        XCTAssertTrue(text.contains("ping 24 ms"))
        XCTAssertTrue(text.contains("#SignalQuest"))
        XCTAssertFalse(text.contains("Orange"))
        XCTAssertFalse(text.contains("Lyon"))
        XCTAssertFalse(text.contains("Paris BBR"))
    }

    func testExportFilenameDoesNotExposeInternalResultIdentifier() throws {
        let sample = result()
        let url = try SQShareCardBuilder.renderPNG(for: sample, theme: .dark)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(url.lastPathComponent.contains(sample.id.uuidString))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("sq_speedtest_share_"))
        XCTAssertEqual(url.pathExtension, "png")
    }

    // MARK: Couleurs

    /// L'échelle de qualité (Drive Test, cadran) reste saturée au-delà de 1 —
    /// l'image A ne l'emploie plus, mais le thème est partagé.
    func testQualityScaleSaturatesAboveOne() {
        let theme = SQShareCardTheme.dark
        XCTAssertEqual(theme.qualityColor(ratio: 2), theme.speedPalette.last, "saturé au-delà de 1")
    }

    /// Échelle de latence INVERSÉE : une latence basse doit tomber sur le vert.
    func testLowLatencyIsGreenAndHighLatencyIsRed() {
        let theme = SQShareCardTheme.dark
        XCTAssertEqual(theme.latencyColor(ms: 5), theme.speedPalette.last)
        XCTAssertEqual(theme.latencyColor(ms: 400), theme.speedPalette.first)
    }

    // MARK: Bout en bout

    /// L'image telle qu'un partage la produit, en pièces jointes à REGARDER à côté
    /// des références A-ios.png et A-sans-courbe-ni-radio.png.
    func testRendersFromAnActualResult() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded, "Polices absentes — carte en Helvetica")
        let sample = result(
            downloadSeries: (0..<40).map { 120 + Double($0) * 18 },
            uploadSeries: (0..<40).map { 20 + Double($0) * 2.6 }
        )
        let image = SQShareCardRenderer.render(SQShareCardBuilder.model(for: sample, theme: .dark, locale: locale))
        XCTAssertEqual(image.size.width, 2_400, accuracy: 1)
        XCTAssertEqual(image.size.height, 1_260, accuracy: 1)
        let attachment = XCTAttachment(image: image)
        attachment.name = "partage-a-cellulaire"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRendersAWifiCardCarryingTheIspNotTheSsid() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded, "Polices absentes — carte en Helvetica")
        let sample = result(
            downloadSeries: (0..<40).map { 300 + Double($0) * 9 },
            uploadSeries: (0..<40).map { 40 + Double($0) * 1.5 },
            connection: .wifi,
            ssid: "Maison-Germain",
            operatorName: "Free"
        )
        let attachment = XCTAttachment(image: SQShareCardBuilder.renderImage(for: sample, theme: .light))
        attachment.name = "partage-a-wifi"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRendersPrivacyReducedPreview() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded, "Polices absentes — carte en Helvetica")
        let options = SpeedtestShareOptions(
            includeNetworkContext: false,
            includeApproximateLocation: false,
            includeDevice: false,
            includeRadioDetails: false,
            includeServerDetails: false,
            includeTimestamp: false
        )
        let image = SQShareCardBuilder.renderImage(for: result(downloadSeries: nil, uploadSeries: nil), theme: .light, options: options)
        let attachment = XCTAttachment(image: image)
        attachment.name = "partage-a-confidentialite-maximale"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(image.size.width, 2_400, accuracy: 1)
        XCTAssertEqual(image.size.height, 1_260, accuracy: 1)
    }
}
