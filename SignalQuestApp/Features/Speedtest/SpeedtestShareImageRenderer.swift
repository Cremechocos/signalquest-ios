import UIKit
import SwiftUI

/// Carte de partage d'un speedtest — paysage 1080×664, DA « Crème & Terre
/// cuite » : en-tête logo + génération/opérateur/commune en texte, deux cartes
/// Download (olive) / Upload (ambre) avec gros chiffres Bricolage, Max et
/// **graphes réels du test entier** (fenêtres fines du moteur, montée en
/// charge comprise — segment de grâce en pointillé, interpolation monotone
/// sans point inventé), grille des 4 latences (ping, jitter, chargé ↓/↑),
/// pied appareil + serveur + signalquest.fr. Rendu via `ImageRenderer`.
///
/// ⚠️ Rendu HORS hiérarchie de vues : les tokens dynamiques (`SQColor`) ne se
/// résolvent pas de façon déterministe dans `ImageRenderer` — les hex de la DA
/// sont donc codés en dur ici (exception admise par le contrat de design).
enum SpeedtestShareImageRenderer {
    /// Hauteur calée sur le contenu (footer affleurant, aucun vide résiduel).
    static let cardSize = CGSize(width: 1080, height: 664)
    // 2× → 2160×1328 px : reste parfaitement net pour une image partagée
    // (récepteurs sociaux ≤ 1080 px de large) tout en divisant par ~2,25 le
    // coût de rastérisation `ImageRenderer` (obligatoirement sur le main actor,
    // contrainte SwiftUI). L'ancien 3× produisait un 3240×1992 surdimensionné
    // qui pouvait provoquer un à-coup à l'apparition du résultat (PERF-SHARE-01).
    private static let exportScale: CGFloat = 2

    static func shareText(for result: SpeedtestRunResult) -> String {
        let download = Int(result.downloadAverageMbps.rounded())
        let upload = result.uploadAverageMbps.map { "\(Int($0.rounded())) Mbps up" } ?? "-- Mbps up"
        let ping = (result.pingMinMs ?? result.pingMs).map { "\(Int($0.rounded())) ms" } ?? "--"
        let net = result.networkShareDisplayName.trimmedNonEmpty ?? "réseau mobile"
        let place = result.city?.trimmedNonEmpty
        let placePart = place.map { " à \($0)" } ?? ""
        let server = (result.serverName ?? result.downloadServerName)?.trimmedNonEmpty
        let serverPart = server.map { " via \($0)" } ?? ""
        return """
        \(download) Mbps en download sur \(net)\(placePart)\(serverPart), ping \(ping), \(upload) — mesuré avec SignalQuest.
        #SignalQuest · signalquest.fr
        """
    }

    @MainActor
    static func renderImage(_ result: SpeedtestRunResult, theme: SpeedtestShareTheme = .dark) -> UIImage? {
        // Image de partage déterministe : on fige la taille Dynamic Type pour que
        // le rendu ne varie pas avec le réglage d'accessibilité de l'appareil
        // (les helpers SQFont suivent désormais Dynamic Type — cf. UI-02).
        let content = SpeedtestShareCard(result: result, theme: theme)
            .environment(\.displayScale, exportScale)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: content)
        renderer.scale = exportScale
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(cardSize)
        return renderer.uiImage
    }

    static func render(_ result: SpeedtestRunResult, theme: SpeedtestShareTheme = .dark) async throws -> URL {
        let image = await MainActor.run {
            renderImage(result, theme: theme)
        }
        guard let image, let data = image.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("signalquest-speedtest-\(result.id.uuidString).png")
        try data.write(to: url, options: [.atomic])
        return url
    }

    // Conservé pour la dérivation de localisation (tests).
    static func location(for result: SpeedtestRunResult) -> String {
        result.city?.trimmedNonEmpty ?? "France"
    }
}

// MARK: - Thème de l'image (suit le thème iOS clair/sombre)

struct SpeedtestShareTheme {
    let isDark: Bool
    let background: Color
    let surface: Color
    /// Tuiles internes / fond de graphe (crème secondaire, façon `surfaceMuted`).
    let surfaceMuted: Color
    /// Lignes de grille du graphe uniquement (pas de bordures de cartes).
    let separator: Color
    /// Brique — marque et petits accents éditoriaux.
    let accent: Color
    let downloadAccent: Color
    let uploadAccent: Color
    let textPrimary: Color
    let textSecondary: Color
    /// Palette qualité worst→best (couleur du trait selon la vitesse).
    let qualityStops: [Color]

    /// Sombre — nuit brun chaud de la DA « Crème & Terre cuite ».
    static let dark = SpeedtestShareTheme(
        isDark: true,
        background: Color(hex: 0x191410),
        surface: Color(hex: 0x262019),
        surfaceMuted: Color(hex: 0x332B20),
        separator: Color(hex: 0x3A3226),
        accent: Color(hex: 0xD97A66),
        downloadAccent: Color(hex: 0xA3B37A),
        uploadAccent: Color(hex: 0xDCA95E),
        textPrimary: Color(hex: 0xF2EAD9),
        textSecondary: Color(hex: 0xA8987E),
        qualityStops: [
            Color(hex: 0xE37E6B), Color(hex: 0xDF9364), Color(hex: 0xDCA95E),
            Color(hex: 0xBFAE6C), Color(hex: 0xA3B37A),
        ]
    )

    /// Clair — papier crème de la DA, accents olive (download) / ambre (upload).
    static let light = SpeedtestShareTheme(
        isDark: false,
        background: Color(hex: 0xF3EDE2),
        surface: Color(hex: 0xFBF7EF),
        surfaceMuted: Color(hex: 0xEDE5D5),
        separator: Color(hex: 0xE5DCC9),
        accent: Color(hex: 0xB04A3C),
        downloadAccent: Color(hex: 0x7E8C5C),
        uploadAccent: Color(hex: 0xC08A3E),
        textPrimary: Color(hex: 0x332818),
        textSecondary: Color(hex: 0x8D7C64),
        qualityStops: [
            Color(hex: 0xC13B2C), Color(hex: 0xC06235), Color(hex: 0xC08A3E),
            Color(hex: 0x9F8B4D), Color(hex: 0x7E8C5C),
        ]
    )

    static func resolve(_ scheme: ColorScheme) -> SpeedtestShareTheme {
        scheme == .dark ? .dark : .light
    }
}

// MARK: - Palette qualité (port de SpeedtestGaugeColors.colorForFillRatio)
// Rampe DA : danger (brique vive) → ambre → olive, au lieu du rouge→vert data-viz.

enum SpeedtestQualityPalette {
    private static let positions: [Double] = [0.075, 0.25, 0.45, 0.675, 0.90]

    static func color(forRatio ratio: Double, stops: [Color]) -> Color {
        let v = min(1, max(0, ratio))
        guard stops.count == positions.count else { return stops.first ?? .gray }
        if v <= positions.first! { return stops.first! }
        if v >= positions.last! { return stops.last! }
        for i in 0..<(positions.count - 1) {
            let lo = positions[i], hi = positions[i + 1]
            if v >= lo && v <= hi {
                let t = (v - lo) / (hi - lo)
                return lerp(stops[i], stops[i + 1], t)
            }
        }
        return stops.last!
    }

    static func color(forValue value: Double, gaugeMax: Double, stops: [Color]) -> Color {
        color(forRatio: gaugeMax > 0 ? value / gaugeMax : 0, stops: stops)
    }

    /// Conservé pour les tests (palette sombre par défaut).
    static func color(forRatio ratio: Double) -> Color {
        color(forRatio: ratio, stops: SpeedtestShareTheme.dark.qualityStops)
    }

    private static func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = UIColor(a).rgba, cb = UIColor(b).rgba
        return Color(
            .sRGB,
            red: ca.r + (cb.r - ca.r) * t,
            green: ca.g + (cb.g - ca.g) * t,
            blue: ca.b + (cb.b - ca.b) * t,
            opacity: 1
        )
    }
}

/// Échelle de jauge par réseau — port compact de `SpeedtestGaugeScale`.
enum SpeedtestGaugeScale {
    static func maxSpeed(for result: SpeedtestRunResult, upload: Bool) -> Double {
        let token = [result.networkDisplayName, result.cellularTechnology?.displayName]
            .compactMap { $0 }.joined(separator: " ").uppercased()
        if result.connectionType == .wifi { return upload ? 150 : 1_000 }
        if token.contains("5G") || token.contains("NR") { return upload ? 80 : 2_000 }
        if token.contains("4G") || token.contains("LTE") { return upload ? 50 : 0_600 }
        if token.contains("3G") || token.contains("HSPA") || token.contains("UMTS") { return upload ? 6 : 25 }
        if token.contains("2G") || token.contains("EDGE") || token.contains("GPRS") || token.contains("GSM") { return upload ? 0.3 : 1 }
        return upload ? 80 : 1_000
    }
}

private extension UIColor {
    var rgba: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }
}

// MARK: - Carte de partage (vue rendue en image)

private struct SpeedtestShareCard: View {
    let result: SpeedtestRunResult
    let theme: SpeedtestShareTheme

    private var bg: Color { theme.background }
    private var surface: Color { theme.surface }
    private var surfaceMuted: Color { theme.surfaceMuted }
    private var separator: Color { theme.separator }
    private var accent: Color { theme.accent }
    private var downloadAccent: Color { theme.downloadAccent }
    private var uploadAccent: Color { theme.uploadAccent }
    private var textPrimary: Color { theme.textPrimary }
    private var textSecondary: Color { theme.textSecondary }

    /// Séries fines mesurées du test ENTIER (grâce incluse) — jamais inventées.
    private var dlSeries: [Double] { cleaned(result.downloadSeriesMbps) }
    private var ulSeries: [Double] { cleaned(result.uploadSeriesMbps) }
    private var dlGraceCount: Int { max(0, result.downloadGraceWindowCount ?? 0) }
    private var ulGraceCount: Int { max(0, result.uploadGraceWindowCount ?? 0) }

    private var city: String { SpeedtestShareImageRenderer.location(for: result) }
    private var serverLabel: String? {
        (result.serverName ?? result.downloadServerName)?.trimmedNonEmpty
    }

    /// Génération mise en avant (5G NSA, 4G, WiFi…). `.other` (VPN, filaire
    /// inconnu) → nil : on ne revendique jamais une génération inconnue.
    private var generationLabel: String? {
        switch result.connectionType {
        case .wifi: return "WiFi"
        case .cellular: return result.cellularTechnology?.displayName ?? "Cellulaire"
        case .wired: return "Ethernet"
        case .other: return nil
        }
    }

    /// « Opérateur · Commune » sous la génération — jamais le SSID (vie privée).
    private var contextLine: String {
        let opName = result.networkOperatorName?.trimmedNonEmpty
            ?? (generationLabel == nil ? result.networkShareDisplayName.trimmedNonEmpty : nil)
        return [opName, city].compactMap { $0 }.joined(separator: " · ")
    }

    private var device: String {
        let model = result.deviceModel?.trimmedNonEmpty ?? AppleDeviceDescriptor.currentShareModelName
        let os = result.osVersion?.trimmedNonEmpty ?? AppleDeviceDescriptor.currentOSVersionLabel
        return "\(model) • \(os)"
    }

    private var dateLabel: String { Self.dateFormatter.string(from: result.createdAt) }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "d MMM yyyy · HH:mm"
        return formatter
    }()

    /// Formats français (virgule décimale) — l'app est monolangue FR.
    private static let frNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 24) {
                statCard(
                    label: "Download",
                    accentColor: downloadAccent,
                    avg: result.downloadAverageMbps,
                    maxValue: result.downloadMaxMbps,
                    series: dlSeries,
                    graceCount: dlGraceCount
                )
                statCard(
                    label: "Upload",
                    accentColor: uploadAccent,
                    avg: result.uploadAverageMbps,
                    maxValue: result.uploadMaxMbps,
                    series: ulSeries,
                    graceCount: ulGraceCount
                )
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 16)

            latencyGrid
                .padding(.top, 14)

            footer
                .padding(.top, 12)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(
            width: SpeedtestShareImageRenderer.cardSize.width,
            height: SpeedtestShareImageRenderer.cardSize.height
        )
        .background(
            ZStack {
                bg
                // Halo discret brique en haut à droite (profondeur sans bruit).
                RadialGradient(
                    colors: [accent.opacity(theme.isDark ? 0.12 : 0.08), .clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 520
                )
            }
        )
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    // MARK: En-tête — logo + génération/opérateur/commune en texte (sans capsules)

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 12) {
                Image("SQLogoMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(separator.opacity(0.6), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signal Quest")
                        .font(SQFont.displayFixed(24, .bold))
                        .foregroundStyle(textPrimary)
                    Text("Speedtest")
                        .font(SQFont.bodyFixed(13, .medium))
                        .foregroundStyle(textSecondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                if let generationLabel {
                    Text(generationLabel)
                        .font(SQFont.displayFixed(24, .bold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                Text(contextLine)
                    .font(SQFont.bodyFixed(15, .medium))
                    .foregroundStyle(textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    // MARK: Cartes Download / Upload

    private func statCard(
        label: String,
        accentColor: Color,
        avg: Double?,
        maxValue: Double?,
        series: [Double],
        graceCount: Int
    ) -> some View {
        let avgParts = formatSpeedParts(avg)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(SQFont.bodyFixed(15, .semibold))
                    .foregroundStyle(accentColor)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(avgParts.value)
                    .font(SQFont.displayFixed(72, .bold))
                    .foregroundStyle(textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(avgParts.unit)
                    .font(SQFont.bodyFixed(18, .medium))
                    .foregroundStyle(textSecondary)
            }
            .padding(.top, 4)

            HStack(spacing: 6) {
                if let maxValue, maxValue.isFinite, maxValue > 0 {
                    let maxParts = formatSpeedParts(maxValue)
                    Text("Max")
                        .font(SQFont.bodyFixed(13, .semibold))
                        .foregroundStyle(textSecondary)
                    Text(maxParts.value)
                        .font(SQFont.displayFixed(16, .bold))
                        .foregroundStyle(textPrimary)
                    Text(maxParts.unit)
                        .font(SQFont.bodyFixed(11, .semibold))
                        .foregroundStyle(textSecondary)
                } else {
                    Text("Mesure indisponible")
                        .font(SQFont.bodyFixed(13, .medium))
                        .foregroundStyle(textSecondary)
                }
            }
            .padding(.top, 4)

            SpeedtestShareGraph(
                series: series,
                averageMbps: avg ?? 0,
                graceCount: graceCount,
                accent: accentColor,
                plotBackground: surfaceMuted,
                gridColor: separator,
                labelColor: textSecondary
            )
            .overlay {
                if series.isEmpty, (avg ?? 0) <= 0 {
                    Text("Aucune donnée")
                        .font(SQFont.bodyFixed(13, .medium))
                        .foregroundStyle(textSecondary)
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .padding(.top, 12)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(separator.opacity(theme.isDark ? 0.55 : 0.9), lineWidth: 1)
        )
    }

    // MARK: Grille des 4 latences

    private var latencyGrid: some View {
        HStack(spacing: 0) {
            latencyCell(
                label: "Ping",
                tint: textSecondary,
                value: msText(result.pingMinMs ?? result.pingMs),
                subline: pingSubline
            )
            gridDivider
            latencyCell(
                label: "Jitter",
                tint: textSecondary,
                value: jitterText(result.jitterMs),
                subline: "au repos"
            )
            gridDivider
            latencyCell(
                label: "Ping chargé ↓",
                tint: downloadAccent,
                value: msText(result.pingDlMs),
                subline: gigueSubline(result.jitterDlMs)
            )
            gridDivider
            latencyCell(
                label: "Ping chargé ↑",
                tint: uploadAccent,
                value: msText(result.pingUlMs),
                subline: gigueSubline(result.jitterUlMs)
            )
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(separator.opacity(theme.isDark ? 0.55 : 0.9), lineWidth: 1)
        )
    }

    private var gridDivider: some View {
        Rectangle()
            .fill(separator.opacity(0.6))
            .frame(width: 1, height: 56)
    }

    private var pingSubline: String {
        guard let minMs = result.pingMinMs, let maxMs = result.pingMaxMs else { return " " }
        return "min \(Int(minMs.rounded())) · max \(Int(maxMs.rounded()))"
    }

    private func gigueSubline(_ jitter: Double?) -> String {
        guard let jitter, jitter.isFinite else { return "gigue —" }
        return "gigue ±\(formatNumber(jitter, fractionDigits: 1))"
    }

    private func msText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded()))"
    }

    private func jitterText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return formatNumber(value, fractionDigits: 1)
    }

    private func latencyCell(label: String, tint: Color, value: String, subline: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(SQFont.bodyFixed(12, .semibold))
                .kerning(0.6)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(SQFont.displayFixed(30, .bold))
                    .foregroundStyle(textPrimary)
                    .monospacedDigit()
                Text("ms")
                    .font(SQFont.bodyFixed(13, .semibold))
                    .foregroundStyle(textSecondary)
            }
            // Sous-ligne TOUJOURS rendue (hauteur fixe → cellules alignées).
            Text(subline)
                .font(SQFont.bodyFixed(12, .medium))
                .foregroundStyle(textSecondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Pied — appareil, serveur, marque + date

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Capsule(style: .continuous)
                    .fill(accent)
                    .frame(width: 72, height: 5)
                Text(device)
                    .font(SQFont.bodyFixed(13))
                    .foregroundStyle(textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let serverLabel {
                HStack(spacing: 7) {
                    Circle()
                        .fill(downloadAccent)
                        .frame(width: 8, height: 8)
                    Text(serverLabel)
                        .font(SQFont.bodyFixed(14, .semibold))
                        .foregroundStyle(textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: 380)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text("signalquest.fr")
                    .font(SQFont.displayFixed(16, .semibold))
                    .foregroundStyle(textPrimary)
                Text(dateLabel)
                    .font(SQFont.bodyFixed(12))
                    .foregroundStyle(textSecondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Formats

    /// « 487 Mbps », « 45,3 Mbps », « 1,42 Gbps » — virgule française.
    private func formatSpeedParts(_ mbps: Double?) -> (value: String, unit: String) {
        guard let mbps, mbps.isFinite, mbps > 0 else { return ("—", "Mbps") }
        if mbps >= 1_000 {
            return (formatNumber(mbps / 1_000, fractionDigits: 2), "Gbps")
        }
        if mbps >= 100 {
            return (formatNumber(mbps, fractionDigits: 0), "Mbps")
        }
        return (formatNumber(mbps, fractionDigits: 1), "Mbps")
    }

    private func formatNumber(_ value: Double, fractionDigits: Int) -> String {
        let formatter = Self.frNumberFormatter
        // Pas de zéro décimal de remplissage : « 45 » plutôt que « 45,0 »,
        // mais « 45,3 » et « 1,42 » gardent leurs décimales significatives.
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
    }

    private func cleaned(_ source: [Double]?) -> [Double] {
        (source ?? []).filter { $0.isFinite && $0 >= 0 }.map { min($0, 20_000) }
    }
}

/// Graphe d'une série speedtest RÉELLE (fenêtres fines du moteur, test entier).
/// - Pas de points inventés : seules les mesures du moteur (ou un plat à la
///   moyenne mesurée s'il n'y a qu'un seul point / moyenne sans série).
/// - Les `graceCount` premières fenêtres (montée en charge / omit iPerf3) se
///   tracent en pointillé atténué — le régime établi en trait plein.
/// - Échelle Y depuis 0 jusqu'au max réel.
/// - Interpolation cubique monotone (Fritsch–Carlson).
struct SpeedtestShareGraph: View {
    let series: [Double]
    /// Moyenne mesurée — ancre honnête si la série fine est absente.
    let averageMbps: Double
    /// Fenêtres de grâce en tête de série (0 = pas de segment de grâce).
    var graceCount: Int = 0
    let accent: Color
    let plotBackground: Color
    let gridColor: Color
    let labelColor: Color

    /// Série affichée : mesures du moteur si ≥ 2 points ; sinon moyenne réelle
    /// plate (toujours une donnée mesurée, jamais une courbe fantaisie).
    private var displaySeries: [Double] {
        if series.count >= 2 {
            return series
        }
        if let only = series.first, only > 0 {
            return [only, only]
        }
        if averageMbps.isFinite, averageMbps > 0 {
            return [averageMbps, averageMbps]
        }
        return [0, 0]
    }

    private var isSparse: Bool { series.count < 2 }
    private var hasData: Bool { displaySeries.contains(where: { $0 > 0 }) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                chart(in: proxy.size)
            }
            if hasData {
                axisLabels
            }
        }
        .background(plotBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(gridColor.opacity(0.45), lineWidth: 1)
        )
    }

    private var axisLabels: some View {
        let maxV = displaySeries.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Text(axisLabel(maxV))
            Spacer(minLength: 0)
            Text("0")
        }
        .font(SQFont.bodyFixed(10, .medium))
        .foregroundStyle(labelColor.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func axisLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Série effective + frontière de grâce après sous-échantillonnage : seule
    /// la partie utile est bucketisée, la grâce reste intacte (frontière stable).
    private func effectiveSeries(maxPoints: Int = 44) -> (values: [Double], grace: Int) {
        let base = displaySeries
        let grace = isSparse ? 0 : min(max(0, graceCount), base.count)
        guard base.count > maxPoints else { return (base, grace) }
        let useful = Array(base[grace...])
        let bucketed = simplified(useful, maxPoints: max(8, maxPoints - grace))
        return (Array(base[..<grace]) + bucketed, grace)
    }

    private func chart(in size: CGSize) -> some View {
        let effective = effectiveSeries()
        let pts = effective.values
        let grace = effective.grace
        let w = size.width, h = size.height
        let axisMax = max(pts.max() ?? 0, 0.001)
        let topInset: CGFloat = 14
        let bottomInset: CGFloat = 6
        let leftInset: CGFloat = 2
        let rightInset: CGFloat = 6
        let plotHeight = max(1, h - topInset - bottomInset)
        let plotWidth = max(1, w - leftInset - rightInset)
        let step = plotWidth / CGFloat(max(pts.count - 1, 1))
        let x: (Int) -> CGFloat = { leftInset + CGFloat($0) * step }
        let y: (Double) -> CGFloat = {
            h - bottomInset - CGFloat(min(1, max(0, $0 / axisMax))) * plotHeight
        }

        var points: [CGPoint] = []
        for i in 0..<pts.count {
            points.append(CGPoint(x: x(i), y: y(pts[i])))
        }

        let tangents = monotoneTangents(points)
        // Frontière : le point d'indice `grace` est le 1er point utile ; les
        // segments 0..<grace forment la montée en charge (pointillé atténué).
        let boundary = min(max(0, grace), max(0, points.count - 1))
        let graceLine = hermitePath(points: points, tangents: tangents, height: h, closed: false, segments: 0..<boundary)
        let mainLine = hermitePath(points: points, tangents: tangents, height: h, closed: false, segments: boundary..<max(boundary, points.count - 1))
        let fill = hermitePath(points: points, tangents: tangents, height: h, closed: true, segments: 0..<max(0, points.count - 1))

        let grid = Path { p in
            for i in 1...3 {
                let gy = topInset + plotHeight * CGFloat(i) / 4
                p.move(to: CGPoint(x: leftInset, y: gy))
                p.addLine(to: CGPoint(x: w - rightInset, y: gy))
            }
        }

        return ZStack {
            grid.stroke(gridColor.opacity(0.5), lineWidth: 1)
            if hasData {
                fill.fill(
                    LinearGradient(
                        colors: [accent.opacity(0.22), accent.opacity(0.04), accent.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                if boundary > 0 {
                    graceLine.stroke(
                        accent.opacity(0.55),
                        style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round, dash: [5, 5])
                    )
                }
                mainLine.stroke(
                    accent,
                    style: StrokeStyle(
                        lineWidth: isSparse ? 2.0 : 2.6,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: isSparse ? [5, 5] : []
                    )
                )
                // Point final (lecture instantanée de fin de phase).
                if let last = points.last {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                        .position(last)
                    Circle()
                        .stroke(accent.opacity(0.35), lineWidth: 4)
                        .frame(width: 12, height: 12)
                        .position(last)
                }
            }
        }
    }

    private func monotoneTangents(_ points: [CGPoint]) -> [CGFloat] {
        let n = points.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }
        var delta = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            delta[i] = dx > 0 ? (points[i + 1].y - points[i].y) / dx : 0
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            m[i] = (delta[i - 1] * delta[i] <= 0) ? 0 : (delta[i - 1] + delta[i]) / 2
        }
        for i in 0..<(n - 1) {
            guard delta[i] != 0 else {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / delta[i]
            let b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }
        return m
    }

    /// Trace les segments `segments` (indices de départ) de la courbe Hermite.
    /// `closed` : chemin refermé sur la base (remplissage) — segments complets.
    private func hermitePath(points: [CGPoint], tangents: [CGFloat], height: CGFloat, closed: Bool, segments: Range<Int>) -> Path {
        Path { p in
            let n = points.count
            guard n >= 2, !segments.isEmpty, segments.lowerBound >= 0, segments.upperBound <= n - 1 else { return }
            let startPoint = points[segments.lowerBound]
            if closed {
                p.move(to: CGPoint(x: startPoint.x, y: height))
                p.addLine(to: startPoint)
            } else {
                p.move(to: startPoint)
            }
            for i in segments {
                let p1 = points[i]
                let p2 = points[i + 1]
                let dx = p2.x - p1.x
                let control1 = CGPoint(
                    x: p1.x + dx / 3,
                    y: min(height, max(0, p1.y + tangents[i] * dx / 3))
                )
                let control2 = CGPoint(
                    x: p2.x - dx / 3,
                    y: min(height, max(0, p2.y - tangents[i + 1] * dx / 3))
                )
                p.addCurve(to: p2, control1: control1, control2: control2)
            }
            if closed {
                p.addLine(to: CGPoint(x: points[segments.upperBound].x, y: height))
                p.closeSubpath()
            }
        }
    }

    /// Buckets uniquement au-delà du plafond (les séries fines restent intactes).
    private func simplified(_ values: [Double], maxPoints: Int) -> [Double] {
        guard values.count > maxPoints, maxPoints > 0 else { return values }
        return (0..<maxPoints).map { bucket in
            let start = bucket * values.count / maxPoints
            let end = max(start + 1, min(values.count, (bucket + 1) * values.count / maxPoints))
            let slice = values[start..<end]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
