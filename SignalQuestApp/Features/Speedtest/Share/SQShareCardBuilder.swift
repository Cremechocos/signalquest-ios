import UIKit

/// Groupes de métadonnées que l'utilisateur peut retirer avant publication.
///
/// Les mesures essentielles (débits, graphes et latence) ne sont jamais
/// masquées : elles constituent le résultat partagé. Les détails restent inclus
/// par défaut, conformément au contrat produit, sans rendre aucun d'eux
/// obligatoire.
struct SpeedtestShareOptions: Equatable, Hashable, Sendable {
    var includeNetworkContext = true
    var includeApproximateLocation = true
    var includeDevice = true
    var includeRadioDetails = true
    var includeServerDetails = true
    var includeTimestamp = true
}

/// Passage d'un résultat de speedtest à la carte de partage — pendant iOS de
/// `buildShareCardModel` (Android, `SpeedtestShareCardModel.kt`).
///
/// Tout ce qui se CALCULE vit ici : nettoyage des séries, downsampling, échelles,
/// couleurs, formatage. `SQShareCardRenderer` ne fait que DESSINER le modèle et
/// ne décide de rien — c'est ce partage des rôles qui rend la carte vérifiable
/// sans produire d'image, et qui garantit qu'iOS et Android affichent les mêmes
/// nombres au même endroit.
///
/// Les constantes ci-dessous sont celles d'Android : les diverger suffirait à
/// désaligner deux cartes pourtant issues du même test.
enum SQShareCardBuilder {

    /// Au-delà, un échantillon est un artefact de mesure, pas un débit.
    private static let seriesClampMbps: Double = 20_000

    /// Au-delà, les points sont moyennés par buckets.
    private static let maxPoints = 32

    /// L'échelle Y vaut le max de la série × 4/3 : le pic culmine ainsi à 75 % de
    /// la hauteur. Sans cette marge, une série quasi constante (upload lissé par
    /// l'edge) dessine une ligne COLLÉE au bord supérieur du graphe.
    private static let graphHeadroomFactor: Double = 4.0 / 3.0

    // MARK: - Rendu

    /// Écrit la carte en PNG dans le dossier temporaire et renvoie son URL.
    ///
    /// Non isolée, là où `ImageRenderer` contraignait l'ancienne carte SwiftUI au
    /// main actor : le dessin Core Graphics ne traverse aucune hiérarchie de vues,
    /// ce qui laisse les tests produire l'image hors du main actor. Appelée depuis
    /// la vue elle s'exécute tout de même dessus, comme avant — l'en affranchir
    /// supposerait de rendre le résultat ET le thème `Sendable` (`UIColor` ne
    /// l'est pas), pour un rendu déjà bien plus rapide que le précédent.
    static func renderImage(
        for result: SpeedtestRunResult,
        theme: SQShareCardTheme,
        options: SpeedtestShareOptions = .init()
    ) -> UIImage {
        SQShareCardRenderer.render(model(for: result, theme: theme, options: options))
    }

    static func renderPNG(
        for result: SpeedtestRunResult,
        theme: SQShareCardTheme,
        options: SpeedtestShareOptions = .init()
    ) throws -> URL {
        try writePNG(renderImage(for: result, theme: theme, options: options))
    }

    /// Écrit exactement l'image affichée dans l'aperçu. Le nom ne contient ni
    /// l'identifiant interne du test, ni opérateur, lieu ou horodatage métier.
    static func writePNG(_ image: UIImage) throws -> URL {
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sq_speedtest_share_\(UUID().uuidString).png")
        try data.write(to: url, options: [.atomic])
        return url
    }

    // MARK: - Modèle

    static func model(
        for result: SpeedtestRunResult,
        theme: SQShareCardTheme,
        locale: Locale = .autoupdatingCurrent,
        options: SpeedtestShareOptions = .init()
    ) -> SQShareCardModel {
        let downloadGraph = graph(
            samples: result.downloadSeriesMbps ?? [],
            average: result.downloadAverageMbps,
            peak: result.downloadMaxMbps,
            gaugeMax: SpeedtestGaugeScale.maxSpeed(for: result, upload: false),
            theme: theme,
            trace: result.measurementTrace?.phases.first { $0.phase == "download" }
        )
        let uploadAverage = result.uploadAverageMbps ?? 0
        let uploadGraph = graph(
            samples: result.uploadSeriesMbps ?? [],
            average: uploadAverage,
            peak: result.uploadMaxMbps ?? uploadAverage,
            gaugeMax: SpeedtestGaugeScale.maxSpeed(for: result, upload: true),
            theme: theme,
            trace: result.measurementTrace?.phases.first { $0.phase == "upload" }
        )

        // v6 uses the measured minimum; archives preserve their historical value.
        let latency = result.primaryPingMs ?? 0

        return SQShareCardModel(
            theme: theme,
            brand: "SIGNALQUEST",
            headerNetworkText: options.includeNetworkContext ? headerNetworkText(for: result) : "",
            dateTimeText: options.includeTimestamp ? dateText(result.createdAt, locale: locale) : nil,
            download: .init(
                label: String(localized: "Download"),
                value: formatMbps(result.downloadAverageMbps, locale: locale),
                unit: result.downloadAverageMbps >= 1000 ? "Gbps" : "Mbps",
                maxValue: formatMbps(result.downloadMaxMbps, locale: locale),
                labelColor: downloadGraph.accentColor,
                graph: downloadGraph,
                maxUnit: result.downloadMaxMbps >= 1000 ? "Gbps" : "Mbps"
            ),
            upload: .init(
                label: String(localized: "Upload"),
                value: result.uploadAverageMbps.map { formatMbps($0, locale: locale) } ?? "—",
                unit: uploadAverage >= 1000 ? "Gbps" : "Mbps",
                maxValue: result.uploadMaxMbps.map { formatMbps($0, locale: locale) } ?? "—",
                labelColor: uploadGraph.accentColor,
                graph: uploadGraph,
                maxUnit: (result.uploadMaxMbps ?? uploadAverage) >= 1000 ? "Gbps" : "Mbps"
            ),
            latencyLabel: String(localized: "Latence"),
            latencyValueText: result.primaryPingMs.map { "\(Int($0.rounded()))" } ?? "—",
            latencyUnit: "ms",
            latencySubText: latencySubText(for: result, locale: locale),
            latencyColor: result.primaryPingMs == nil ? theme.textSecondary : theme.latencyColor(ms: latency),
            underLoadLabel: String(localized: "Sous charge"),
            underLoadRows: underLoadRows(
                for: result, download: downloadGraph, upload: uploadGraph, locale: locale
            ),
            serverLabel: String(localized: "Serveur"),
            serverText: options.includeServerDetails
                ? (result.serverName ?? result.downloadServerName)?.shareTrimmed
                : nil,
            deviceCityText: deviceCityText(
                for: result,
                includeDevice: options.includeDevice,
                includeLocation: options.includeApproximateLocation
            ),
            // VIDE, et ce n'est pas un trou à combler : ces lignes portent
            // l'identité radio (porteuses agrégées, MCC/MNC, bande) qu'Android lit
            // sur son modem et qu'iOS n'expose pas. Le pied se replie tout seul.
            // Le flag reste dans le contrat commun Android/iOS, mais iOS ne
            // fournit aucune preuve RF du réseau servant à rendre ici.
            radioLines: []
        )
    }

    // MARK: - Graphes

    private static func graph(
        samples: [Double], average: Double, peak: Double,
        gaugeMax: Double, theme: SQShareCardTheme, trace: SpeedtestPhaseTrace? = nil
    ) -> SQShareCardModel.Graph {
        let timed = trace?.recentSeries
        let points = timed?.map(\.mbps) ?? downsample(prepareSeries(samples, average: average, peak: peak))
        return .init(
            points: points,
            localMax: Swift.max(points.max() ?? 1, 1) * graphHeadroomFactor,
            // La teinte suit le débit MOYEN rapporté au maximum atteignable sur ce
            // réseau : 300 Mb/s est excellent en 4G et médiocre en 5G.
            accentColor: theme.qualityColor(ratio: average / Swift.max(gaugeMax, 1)),
            normalizedTimes: trace.map { phase in
                (timed ?? []).map { Double($0.elapsedMs - phase.warmupEndOffsetMs) / Double(max(1, phase.usefulDurationMs)) }
            },
            durationSeconds: trace.map { Double($0.usefulDurationMs) / 1000 }
        )
    }

    /// Historical samples keep their existing scale; missing samples stay missing.
    private static func prepareSeries(_ samples: [Double], average: Double, peak: Double) -> [Double] {
        let clean = samples
            .filter { $0.isFinite && $0 >= 0 }
            .map { Swift.min($0, seriesClampMbps) }
        guard clean.count >= 2 else { return [] }
        return clean
    }

    /// Moyennage par buckets — port verbatim du downsampling d'Android.
    private static func downsample(_ source: [Double]) -> [Double] {
        guard source.count > maxPoints else { return source }
        return (0..<maxPoints).map { bucket in
            let start = (bucket * source.count) / maxPoints
            let end = Swift.min(
                Swift.max(((bucket + 1) * source.count) / maxPoints, start + 1),
                source.count
            )
            let slice = source[start..<end]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    // MARK: - Textes

    /// « 5G SA · Orange », « Wi-Fi · Free » — le lien puis qui le fournit.
    ///
    /// Le SSID n'y figure JAMAIS : le nom d'un réseau domestique identifie un
    /// foyer, et cette carte est faite pour être publiée. C'est le FAI qui prend
    /// sa place — `networkOperatorName` le porte en Wi-Fi, résolu par IP/ASN,
    /// donc sans rien révéler du réseau local. Même arbitrage que
    /// `networkShareDisplayName`, et Android suit la même règle.
    private static func headerNetworkText(for result: SpeedtestRunResult) -> String {
        var parts: [String] = []
        switch result.connectionType {
        case .wifi:
            parts.append("Wi-Fi")
        case .wired:
            parts.append("Ethernet")
        case .cellular:
            parts.append(result.cellularTechnology?.displayName ?? String(localized: "Cellulaire"))
        case .other:
            // VPN ou lien inconnu : on ne revendique aucune génération.
            break
        }
        if let operatorName = result.networkOperatorName?.shareTrimmed {
            parts.append(operatorName)
        }
        if parts.isEmpty, let fallback = result.networkShareDisplayName.shareTrimmed {
            parts.append(fallback)
        }
        return parts.joined(separator: " · ")
    }

    /// « moy. 24 ms · gigue 3,2 ms » — la gigue est omise si elle n'est pas
    /// exploitable, jamais rendue en « NaN ».
    private static func latencySubText(for result: SpeedtestRunResult, locale: Locale) -> String {
        var pieces: [String] = []
        if let average = result.pingMs, average.isFinite, average >= 0 {
            pieces.append("\(String(localized: "moy.")) \(Int(average.rounded())) ms")
        }
        if let jitter = result.jitterMs, jitter.isFinite, jitter >= 0 {
            pieces.append("\(String(localized: "gigue")) \(decimal(jitter, locale: locale)) ms")
        }
        return pieces.joined(separator: " · ")
    }

    private static func underLoadRows(
        for result: SpeedtestRunResult,
        download: SQShareCardModel.Graph,
        upload: SQShareCardModel.Graph,
        locale: Locale
    ) -> [SQShareCardModel.UnderLoadRow] {
        func row(
            _ prefix: String, ping: Double?, jitter: Double?, dotColor: UIColor
        ) -> SQShareCardModel.UnderLoadRow? {
            guard let ping, ping.isFinite, ping >= 0 else { return nil }
            let usableJitter = jitter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return .init(
                prefix: prefix,
                valueText: "\(Int(ping.rounded())) ms",
                jitText: usableJitter.map { "· jit \(decimal($0, locale: locale))" },
                dotColor: dotColor
            )
        }
        // Codes universels, non traduits — comme sur Android.
        return [
            row("↓ DL", ping: result.pingDlMs, jitter: result.jitterDlMs, dotColor: download.accentColor),
            row("↑ UL", ping: result.pingUlMs, jitter: result.jitterUlMs, dotColor: upload.accentColor)
        ].compactMap { $0 }
    }

    private static func deviceCityText(
        for result: SpeedtestRunResult,
        includeDevice: Bool,
        includeLocation: Bool
    ) -> String {
        // `deviceModel` est stocké au format « iPhone 17 Pro (iPhone18,1) » : la
        // carte n'en garde que le nom commercial, l'identifiant machine relevant
        // du diagnostic et non de ce qu'on publie.
        let stored = result.deviceModel?.shareTrimmed ?? AppleDeviceDescriptor.currentShareModelName
        let device = stored.components(separatedBy: " (").first?
            .trimmingCharacters(in: .whitespaces) ?? stored
        return [
            includeDevice ? device : "",
            includeLocation ? city(for: result) : "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    /// La commune du point de mesure : `city` quand le géocodage l'a fournie,
    /// sinon extraite de l'adresse comme Android. Rien plutôt qu'un « France »
    /// par défaut : une localisation fausse vaut moins qu'une absence.
    private static func city(for result: SpeedtestRunResult) -> String {
        if let city = result.city?.shareTrimmed { return city }
        guard let address = result.address?.shareTrimmed else { return "" }
        let parts = address
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Un segment « 69003 Lyon » porte la commune après le code postal.
        for part in parts {
            guard let zip = part.range(of: #"^\d{5}\s+"#, options: .regularExpression) else { continue }
            let city = part[zip.upperBound...].trimmingCharacters(in: .whitespaces)
            if !city.isEmpty { return city }
        }
        // Sinon le premier segment qui ne soit pas une voie numérotée.
        if parts.count > 1, parts[0].contains(where: \.isNumber) { return parts[1] }
        return parts.first ?? ""
    }

    // MARK: - Formats

    /// Localized Mbps below 1000, Gbps above; persisted measurements remain Mbps.
    private static func formatMbps(_ value: Double, locale: Locale) -> String {
        let safe = value.isFinite && value >= 0 ? value : 0
        return safe >= 1000 ? String(format: "%.2f", locale: locale, safe / 1000) : decimal(safe, locale: locale)
    }

    private static func decimal(_ value: Double, locale: Locale) -> String {
        String(format: "%.1f", locale: locale, value)
    }

    private static func dateText(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        return formatter.string(from: date)
    }
}

private extension String {
    var shareTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
