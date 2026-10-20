import SwiftUI
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

    /// `theme` reste accepté pour ne pas toucher aux appelants, mais l'image A
    /// n'a qu'une palette claire (décision du 19/10) : une image publiée ne suit
    /// pas le thème de l'app de celui qui la partage.
    static func model(
        for result: SpeedtestRunResult,
        theme: SQShareCardTheme,
        locale: Locale = .autoupdatingCurrent,
        options: SpeedtestShareOptions = .init()
    ) -> SQShareCardModel {
        let downloadPeak = peakText(result.downloadMaxMbps, average: result.downloadAverageMbps, locale: locale)
        let uploadPeak = result.uploadAverageMbps.flatMap { average in
            result.uploadMaxMbps.flatMap { peakText($0, average: average, locale: locale) }
        }
        let downloadGraph = graph(
            samples: result.downloadSeriesMbps ?? [],
            accentColor: UIColor(hex: 0x1C201E),
            trace: result.measurementTrace?.phases.first { $0.phase == "download" },
            max: result.downloadMaxMbps, maxText: downloadPeak
        )
        let uploadGraph = graph(
            samples: result.uploadSeriesMbps ?? [],
            accentColor: UIColor(hex: 0xA8123A),
            trace: result.measurementTrace?.phases.first { $0.phase == "upload" },
            max: result.uploadMaxMbps, maxText: uploadPeak
        )

        let latency = displayedLatency(for: result)
        return SQShareCardModel(
            dateText: options.includeTimestamp ? dateText(result.createdAt, locale: locale) : nil,
            network: options.includeNetworkContext ? networkLine(for: result) : nil,
            download: throughput(result.downloadAverageMbps, locale: locale)
                ?? .init(number: "0", unit: "Mb/s"),
            // Avec sa courbe, le MAX s'écrit sur elle et n'est pas redit sous le chiffre.
            downloadPeakText: downloadGraph == nil ? downloadPeak : nil,
            downloadGraph: downloadGraph,
            upload: result.uploadAverageMbps.flatMap { throughput($0, locale: locale) },
            uploadPeakText: uploadGraph == nil ? uploadPeak : nil,
            uploadGraph: uploadGraph,
            latencyLabel: latency.isMinimum ? String(localized: "Latence min.") : String(localized: "Latence"),
            latency: latency.value.map { .init(number: Int($0.rounded()).formatted(.number.locale(locale)), unit: "ms") },
            latencyAverageText: latency.average.map {
                String(localized: "Moyenne \(Int($0.rounded()).formatted(.number.locale(locale))) ms")
            },
            rows: detailRows(for: result, locale: locale, includeServer: options.includeServerDetails),
            deviceCityText: deviceCityText(
                for: result,
                includeDevice: options.includeDevice,
                includeLocation: options.includeApproximateLocation
            )
        )
    }

    /// « MAX 96,8 Mb/s » — absent si le pic manque ou s'écrit comme le débit.
    /// « MAX » ne se traduit pas, comme dans l'app.
    private static func peakText(_ peak: Double, average: Double, locale: Locale) -> String? {
        guard let value = throughput(peak, locale: locale), value != throughput(average, locale: locale) else { return nil }
        return "MAX \(value.number) \(value.unit)"
    }

    /// Le minimum en grand, la moyenne dessous ; sans minimum, la médiane puis la
    /// moyenne, seules (spécification v11).
    static func displayedLatency(for result: SpeedtestRunResult) -> (value: Double?, isMinimum: Bool, average: Double?) {
        func usable(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        if let minimum = usable(result.pingMinMs) {
            return (minimum, true, usable(result.pingMs))
        }
        return (usable(result.pingMedianMs) ?? usable(result.pingMs), false, nil)
    }

    // MARK: - Graphes

    /// `nil` sous deux points : pas de courbe plutôt qu'une ligne inventée.
    /// Le MAX entre dans l'échelle : quand il dépasse les fenêtres tracées, c'est
    /// lui qui touche le haut, et son pointillé ne sort jamais du tracé.
    private static func graph(
        samples: [Double], accentColor: UIColor, trace: SpeedtestPhaseTrace? = nil,
        max peak: Double? = nil, maxText: String? = nil
    ) -> SQShareCardModel.Graph? {
        let timed = trace?.recentSeries
        let points = timed?.map(\.mbps) ?? downsample(prepareSeries(samples))
        guard points.count >= 2 else { return nil }
        let usablePeak = peak.flatMap { $0.isFinite && $0 > 0 ? Swift.min($0, seriesClampMbps) : nil }
        return .init(
            points: points,
            localMax: Swift.max(points.max() ?? 1, usablePeak ?? 0, 1),
            accentColor: accentColor,
            normalizedTimes: trace.map { phase in
                (timed ?? []).map { Double($0.elapsedMs - phase.sampleStartMs) / Double(max(1, phase.sampleDurationMs)) }
            },
            durationSeconds: trace.map { Double($0.sampleDurationMs) / 1000 },
            maxText: maxText,
            maxValue: maxText == nil ? nil : usablePeak
        )
    }

    /// Historical samples keep their existing scale; missing samples stay missing.
    private static func prepareSeries(_ samples: [Double]) -> [Double] {
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

    /// « SFR · 5G », « Free · Wi-Fi » : qui fournit, puis le lien.
    ///
    /// Le SSID n'y figure JAMAIS : le nom d'un réseau domestique identifie un
    /// foyer, et cette image est faite pour être publiée. C'est le FAI qui prend
    /// sa place — `networkOperatorName` le porte en Wi-Fi, résolu par IP/ASN,
    /// donc sans rien révéler du réseau local.
    ///
    /// Opérateur hors palette : son nom, sans barre. Opérateur inconnu, ou lien
    /// `.other` (VPN : l'adresse vue est celle du tunnel) : la techno seule, sans
    /// barre — on n'attribue pas un réseau qu'on ne connaît pas.
    static func networkLine(for result: SpeedtestRunResult) -> SQShareCardModel.NetworkLine? {
        let link: String?
        switch result.connectionType {
        case .wifi: link = "Wi-Fi"
        case .wired: link = "Ethernet"
        case .cellular, .other: link = result.cellularTechnology.map(generation)
        }
        let operatorName = result.connectionType == .other ? nil : result.networkOperatorName?.shareTrimmed
        if let operatorName {
            // Barre seulement pour un opérateur de la palette : le gris ardoise du
            // repli se lirait « Free » (#6B7280). Hors palette, son nom seul.
            let colors = SQBrand.operatorColors(operatorName)
            let isKnown = colors.name != SQBrand.defaultOperator.name
            return .init(name: operatorName, detail: link, barColor: isKnown ? UIColor(colors.solid) : nil)
        }
        return link.map { .init(name: $0, detail: nil, barColor: nil) }
    }

    /// « 5G SA » ou « 5G NSA » quand iOS les distingue, comme l'image d'Android
    /// (planche commune validée le 20/10).
    private static func generation(_ technology: CellularRadioTechnology) -> String {
        switch technology {
        case .twoG: "2G"
        case .threeG: "3G"
        case .fourG: "4G"
        case .fiveGNSA: "5G NSA"
        case .fiveGSA: "5G SA"
        }
    }

    /// Sous charge ↓ et ↑ (latence · gigue), gigue au repos, serveur — chaque
    /// ligne disparaît avec sa valeur (règle commune web, iOS et Android du 20/10).
    /// La note A–F se pose sur le pire des deux sens.
    private static func detailRows(
        for result: SpeedtestRunResult, locale: Locale, includeServer: Bool
    ) -> [SQShareCardModel.Row] {
        var rows: [SQShareCardModel.Row] = []
        let grade = loadedLatency(for: result)?.grade
        let receiving = validMs(result.pingDlMs), sending = validMs(result.pingUlMs)
        let worstIsReceiving = (receiving ?? -1) >= (sending ?? -1)
        if let receiving {
            rows.append(.init(label: String(localized: "Sous charge"),
                              value: loadedValue(receiving, jitter: result.jitterDlMs, locale: locale),
                              grade: worstIsReceiving ? grade : nil, arrow: .down))
        }
        if let sending {
            rows.append(.init(label: String(localized: "Sous charge"),
                              value: loadedValue(sending, jitter: result.jitterUlMs, locale: locale),
                              grade: worstIsReceiving ? nil : grade, arrow: .up))
        }
        if let jitter = result.jitterMs, jitter.isFinite, jitter >= 0 {
            rows.append(.init(label: String(localized: "Gigue au repos"), value: SQUnits.jitter(jitter, locale: locale)))
        }
        if includeServer, let server = serverText(for: result) {
            rows.append(.init(label: String(localized: "Serveur"), value: server))
        }
        return rows
    }

    /// « Roubaix · hébergé par OVH » pour un POP iPerf3 du catalogue, comme
    /// Android ; sinon le nom enregistré (« Cloudflare · Paris » le dit déjà).
    static func serverText(
        for result: SpeedtestRunResult,
        catalog: [IPerfPublicServer] = activeIPerfServers
    ) -> String? {
        let stored = (result.serverName ?? result.downloadServerName)?.shareTrimmed
        guard let id = result.downloadServerId?.shareTrimmed,
              let server = catalog.first(where: { $0.id == id }),
              let host = server.provider.label else { return stored }
        // Le nom porte la ville en tête : « Roubaix (OVH RBX) », « Paris BBR
        // (Bouygues) », « Paris Scaleway ». On retire la parenthèse, puis le
        // fournisseur et la variante de congestion, qui n'apprennent rien au lecteur.
        let variants: Set<String> = ["BBR", "CUBIC", "IPv6", host.lowercased()]
        var words = (server.name.components(separatedBy: " (").first ?? server.name)
            .split(separator: " ").map(String.init)
        if let plus = words.firstIndex(where: { $0.hasPrefix("+") }) { words.removeSubrange(plus...) }
        while let last = words.last, variants.contains(last) || variants.contains(last.lowercased()) {
            words.removeLast()
        }
        let city = words.joined(separator: " ")
        guard !city.isEmpty else { return stored }
        return String(localized: "\(city) · hébergé par \(host)")
    }

    /// « 48 ms · gigue 6,2 ms », ou la latence seule sans gigue mesurée.
    private static func loadedValue(_ ms: Double, jitter: Double?, locale: Locale) -> String {
        // Milliers séparés comme dans la langue (« 2 876 ms » en français, U+202F).
        let latency = "\(Int(ms.rounded()).formatted(.number.locale(locale))) ms"
        guard let jitter = validMs(jitter, allowsZero: true) else { return latency }
        return "\(latency) · " + String(localized: "gigue \(SQUnits.jitterValue(jitter, locale: locale)) ms")
    }

    private static func validMs(_ value: Double?, allowsZero: Bool = false) -> Double? {
        guard let value, value.isFinite, allowsZero ? value >= 0 : value > 0 else { return nil }
        return value
    }

    /// Hausse de latence sous charge et sa note — même dérivation que le serveur
    /// (`deriveBufferbloat`) et même barème que le client Android (seuils
    /// Cloudflare : A ≤ 5, B ≤ 30, C ≤ 60, D ≤ 200 ms, F au-delà). La référence
    /// au repos est la latence affichée en grand, pour que les deux nombres se
    /// lisent ensemble. Sans preuve qu'elle a visé le serveur du test, pas de ligne :
    /// l'écart entre deux machines différentes ne dit rien de la charge.
    static func loadedLatency(for result: SpeedtestRunResult) -> (deltaMs: Int, grade: SQShareCardModel.Grade)? {
        guard let pingHost = result.pingServerHost?.shareTrimmed,
              result.downloadServerHost.map({ $0.caseInsensitiveCompare(pingHost) == .orderedSame }) ?? true,
              let idle = displayedLatency(for: result).value else { return nil }
        let loaded = [result.pingDlMs, result.pingUlMs].compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        guard let worst = loaded.max() else { return nil }
        let delta = Int(Swift.max(0, worst - idle).rounded())
        // Texte en teinte -700, fond en teinte vive translucide (spécification v10).
        let (letter, color, background): (String, UInt32, UIColor) = switch delta {
        case ...5: ("A", 0x187B38, UIColor(hex: 0x1B8A3F, alpha: 0.12))
        case ...30: ("B", 0x477818, UIColor(hex: 0x7DB834, alpha: 0.16))
        case ...60: ("C", 0x8C6313, UIColor(hex: 0xD08F1D, alpha: 0.16))
        case ...200: ("D", 0xAC4F17, UIColor(hex: 0xE66A1F, alpha: 0.14))
        default: ("F", 0xAC4F17, UIColor(hex: 0xE66A1F, alpha: 0.14))
        }
        return (delta, .init(letter: letter, color: UIColor(hex: color), background: background))
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

    /// Règle commune du 20/10 : sous 10 Mb/s une décimale (« 7,5 »), de 10 à 999
    /// un entier (« 214 »), dès 1 000 des Gb/s à trois décimales (« 1,722 »). Les
    /// bascules se font sur la valeur ARRONDIE : 9,96 s'écrit « 10 », jamais
    /// « 10,0 ». `nil` pour une valeur nulle ou non finie : la ligne disparaît.
    static func throughput(_ mbps: Double, locale: Locale) -> SQShareCardModel.Value? {
        guard mbps.isFinite, mbps > 0 else { return nil }
        if mbps >= 999.5 {
            return .init(number: number(mbps / 1000, fractionDigits: 3, locale: locale), unit: "Gb/s")
        }
        if mbps >= 9.95 {
            return .init(number: number(mbps, fractionDigits: 0, locale: locale), unit: "Mb/s")
        }
        return .init(number: number(mbps, fractionDigits: 1, locale: locale), unit: "Mb/s")
    }

    private static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never).locale(locale))
    }

    /// « 19 octobre 2026 à 14:32 », « October 19, 2026 at 2:32 PM » — heure locale.
    private static func dateText(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private extension String {
    var shareTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
