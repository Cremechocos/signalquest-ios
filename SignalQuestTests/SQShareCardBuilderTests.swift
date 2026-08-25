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
        connection: NetworkConnectionKind = .cellular,
        ssid: String? = nil,
        /// En Wi-Fi, ce champ porte le FAI résolu par IP/ASN — pas l'opérateur SIM.
        operatorName: String? = nil,
        city: String? = "Lyon",
        address: String? = nil
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
            pingDlMs: loadedPings ? 42 : nil,
            jitterDlMs: loadedPings ? 6.2 : nil,
            pingUlMs: loadedPings ? 57 : nil,
            jitterUlMs: loadedPings ? 9.4 : nil,
            pingProtocol: "ICMP",
            durationSeconds: 14,
            connectionType: connection,
            cellularTechnology: connection == .cellular ? .fiveGSA : nil,
            networkOperatorName: operatorName ?? (connection == .cellular ? "Orange" : nil),
            wifiSSID: ssid,
            city: city,
            address: address,
            serverName: "Paris BBR (Bouygues)",
            downloadServerName: "Paris BBR (Bouygues)",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: downloadSeries,
            uploadSeriesMbps: uploadSeries,
            deviceModel: "iPhone 17 Pro (iPhone18,1)",
            osVersion: "iOS 27"
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

    // MARK: Nombres

    func testDisplayedNumbersMatchTheResult() {
        let card = model(result())
        XCTAssertEqual(card.download.value, "770,2")
        XCTAssertEqual(card.download.maxValue, "812,4")
        XCTAssertEqual(card.upload.value, "126,4")
        XCTAssertEqual(card.upload.maxValue, "131,0")
        XCTAssertEqual(card.download.unit, "Mbps")
    }

    /// Latence héros : min ?: médiane ?: moyenne — convention partagée avec
    /// Android. Un affichage qui glisserait vers la moyenne gonflerait la valeur
    /// mise en avant sur toutes les cartes.
    func testLatencyHeroPrefersMinThenMedianThenAverage() {
        XCTAssertEqual(model(result()).latencyValueText, "14")
        XCTAssertEqual(model(result(pingMin: nil)).latencyValueText, "18")
        XCTAssertEqual(model(result(pingMin: nil, pingMedian: nil)).latencyValueText, "24")
        XCTAssertEqual(
            model(result(pingMin: nil, pingMedian: nil, pingAverage: nil)).latencyValueText, "0"
        )
    }

    func testUnderLoadRowsAreOmittedWithoutLoadedLatency() {
        XCTAssertEqual(model(result()).underLoadRows.count, 2)
        // Bloc entièrement masqué par le renderer quand la liste est vide.
        XCTAssertTrue(model(result(loadedPings: false)).underLoadRows.isEmpty)
    }

    // MARK: Séries

    /// Sous deux points mesurés, la carte trace une ligne PLATE plutôt qu'un
    /// graphe inventé : le trait dit « pas de détail », pas « débit instable ».
    func testEmptySeriesFallsBackToAFlatLine() {
        let graph = model(result(downloadSeries: nil)).download.graph
        XCTAssertEqual(graph.points.count, 12)
        XCTAssertEqual(Set(graph.points).count, 1, "la ligne de repli doit être plate")
        XCTAssertEqual(graph.points.first ?? 0, 770.24, accuracy: 0.01)
    }

    func testLongSeriesIsDownsampled() {
        let series = (0..<200).map { Double($0) }
        let graph = model(result(downloadSeries: series)).download.graph
        XCTAssertEqual(graph.points.count, 32)
        // Moyennage par buckets : les extrêmes restent encadrés par la série.
        XCTAssertGreaterThan(graph.points.first ?? 0, 0)
        XCTAssertLessThan(graph.points.last ?? 0, 200)
    }

    /// Sans marge de tête, une série quasi constante colle au bord supérieur du
    /// graphe — le pic doit culminer à 75 % de la hauteur.
    func testGraphScaleLeavesHeadroom() {
        let graph = model(result(downloadSeries: [100, 200, 300])).download.graph
        XCTAssertEqual(graph.localMax, 300 * 4 / 3, accuracy: 0.001)
    }

    /// Un échantillon aberrant est un artefact de mesure : il est borné, sinon il
    /// écrase l'échelle et aplatit toute la courbe.
    func testAbsurdSamplesAreClamped() {
        let graph = model(result(downloadSeries: [100, 999_999, 200])).download.graph
        XCTAssertEqual(graph.points.max() ?? 0, 20_000, accuracy: 0.001)
    }

    func testNonFiniteSamplesAreDropped() {
        let graph = model(result(downloadSeries: [100, .nan, .infinity, -5, 300])).download.graph
        XCTAssertEqual(graph.points, [100, 300])
    }

    // MARK: En-tête et pied

    func testHeaderCarriesGenerationThenOperator() {
        XCTAssertEqual(model(result()).headerNetworkText, "5G SA · Orange")
    }

    /// Le SSID identifie un foyer et la carte est faite pour être publiée : il n'y
    /// figure jamais, sur aucune des deux plateformes.
    func testSsidNeverReachesTheCard() {
        let card = model(result(connection: .wifi, ssid: "Maison-Germain", operatorName: "Free"))
        let rendered = [card.headerNetworkText, card.deviceCityText, card.serverText ?? ""]
        XCTAssertFalse(rendered.contains { $0.contains("Maison") })
    }

    /// C'est le FAI — résolu par IP/ASN, donc muet sur le réseau local — qui
    /// prend la place du SSID.
    func testWifiHeaderCarriesTheIspInsteadOfTheSsid() {
        let card = model(result(connection: .wifi, ssid: "Maison-Germain", operatorName: "Free"))
        XCTAssertEqual(card.headerNetworkText, "Wi-Fi · Free")
    }

    /// FAI inconnu : « Wi-Fi » tout court plutôt qu'un opérateur inventé.
    func testWifiHeaderFallsBackToWifiAlone() {
        XCTAssertEqual(
            model(result(connection: .wifi, ssid: "Maison-Germain")).headerNetworkText, "Wi-Fi"
        )
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

    /// L'identité radio est vide sur iOS — limite de plateforme assumée, le pied
    /// doit se replier au lieu d'afficher un espace réservé.
    func testRadioLinesStayEmptyOnIOS() {
        XCTAssertTrue(model(result()).radioLines.isEmpty)
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

        XCTAssertEqual(privateCard.headerNetworkText, "")
        XCTAssertNil(privateCard.dateTimeText)
        XCTAssertNil(privateCard.serverText)
        XCTAssertEqual(privateCard.deviceCityText, "")
        XCTAssertTrue(privateCard.radioLines.isEmpty)

        // Le résultat lui-même reste partageable et ne change jamais avec les
        // options de confidentialité.
        XCTAssertEqual(privateCard.download.value, full.download.value)
        XCTAssertEqual(privateCard.upload.value, full.upload.value)
        XCTAssertEqual(privateCard.latencyValueText, full.latencyValueText)
        XCTAssertEqual(privateCard.download.graph.points, full.download.graph.points)
        XCTAssertEqual(privateCard.upload.graph.points, full.upload.graph.points)
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

        XCTAssertTrue(text.contains("770 Mbps"))
        XCTAssertTrue(text.contains("ping 14 ms"))
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

    /// La teinte suit le débit rapporté au maximum ATTEIGNABLE sur ce réseau :
    /// 300 Mb/s est excellent en 4G et médiocre en 5G. Deux réseaux différents ne
    /// peuvent donc pas produire la même couleur pour le même débit.
    func testAccentFollowsTheNetworkCeiling() {
        let fiveG = model(result()).download.graph.accentColor
        let theme = SQShareCardTheme.dark
        XCTAssertNotEqual(fiveG, theme.qualityColor(ratio: 1))
        XCTAssertEqual(theme.qualityColor(ratio: 2), theme.speedPalette.last, "saturé au-delà de 1")
    }

    /// Échelle de latence INVERSÉE : une latence basse doit tomber sur le vert.
    func testLowLatencyIsGreenAndHighLatencyIsRed() {
        let theme = SQShareCardTheme.dark
        XCTAssertEqual(theme.latencyColor(ms: 5), theme.speedPalette.last)
        XCTAssertEqual(theme.latencyColor(ms: 400), theme.speedPalette.first)
    }

    // MARK: Bout en bout

    /// La carte telle qu'un partage la produit — depuis un résultat, et non
    /// depuis un modèle écrit à la main comme dans `SQShareCardRenderTests`. Les
    /// pièces jointes sont à REGARDER : c'est la comparaison avec la carte
    /// Android qui valide le port, pas une assertion.
    func testRendersFromAnActualResult() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded, "Polices absentes — carte en Helvetica")
        let sample = result(
            downloadSeries: (0..<40).map { 120 + Double($0) * 18 },
            uploadSeries: (0..<40).map { 20 + Double($0) * 2.6 }
        )
        for (theme, name) in [(SQShareCardTheme.light, "clair"),
                              (SQShareCardTheme.dark, "sombre"),
                              (SQShareCardTheme.oled, "oled")] {
            let image = SQShareCardRenderer.render(
                SQShareCardBuilder.model(for: sample, theme: theme, locale: locale)
            )
            XCTAssertEqual(image.size.width, 2_160, accuracy: 1)
            let attachment = XCTAttachment(image: image)
            attachment.name = "carte-partage-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// La même carte en Wi-Fi : l'en-tête doit porter le FAI, et le SSID rester
    /// invisible. À regarder autant qu'à asserter.
    func testRendersAWifiCardCarryingTheIspNotTheSsid() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded, "Polices absentes — carte en Helvetica")
        let sample = result(
            downloadSeries: (0..<40).map { 300 + Double($0) * 9 },
            uploadSeries: (0..<40).map { 40 + Double($0) * 1.5 },
            connection: .wifi,
            ssid: "Maison-Germain",
            operatorName: "Free"
        )
        let card = SQShareCardBuilder.model(for: sample, theme: .light, locale: locale)
        XCTAssertEqual(card.headerNetworkText, "Wi-Fi · Free")
        let attachment = XCTAttachment(image: SQShareCardRenderer.render(card))
        attachment.name = "carte-partage-wifi"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRendersPrivacyReducedPreview() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded, "Polices absentes — carte en Helvetica")
        let sample = result(
            downloadSeries: (0..<40).map { 120 + Double($0) * 18 },
            uploadSeries: (0..<40).map { 20 + Double($0) * 2.6 }
        )
        let options = SpeedtestShareOptions(
            includeNetworkContext: false,
            includeApproximateLocation: false,
            includeDevice: false,
            includeRadioDetails: false,
            includeServerDetails: false,
            includeTimestamp: false
        )
        let image = SQShareCardBuilder.renderImage(
            for: sample,
            theme: .light,
            options: options
        )
        let attachment = XCTAttachment(image: image)
        attachment.name = "carte-partage-confidentialite-maximale"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(image.size.width, 2_160, accuracy: 1)
        XCTAssertEqual(image.size.height, 1_300, accuracy: 1)
    }
}
