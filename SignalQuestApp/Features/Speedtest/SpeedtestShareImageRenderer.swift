import UIKit
import SwiftUI

/// Carte de partage d'un speedtest — même structure que l'image Android
/// (`SpeedTestShareImageGenerator.kt`) mais habillée DA « Crème & Terre cuite » :
/// tableau de bord 1080×720, deux cartes Download (olive) / Upload (ambre) avec
/// gros chiffres Bricolage + Max + **graphes réels** dont le trait est coloré
/// selon la qualité de chaque point (danger→ambre→olive, comme la jauge live),
/// bandeau latence, pied appareil, et logo Signal Quest. Rendu nativement via
/// `ImageRenderer` (instantané, contrairement au WebView Android).
///
/// ⚠️ Rendu HORS hiérarchie de vues : les tokens dynamiques (`SQColor`) ne se
/// résolvent pas de façon déterministe dans `ImageRenderer` — les hex de la DA
/// sont donc codés en dur ici (exception admise par le contrat de design).
enum SpeedtestShareImageRenderer {
    private static let cardSize = CGSize(width: 1080, height: 720)
    private static let exportScale: CGFloat = 3

    static func shareText(for result: SpeedtestRunResult) -> String {
        let download = Int(result.downloadAverageMbps.rounded())
        let upload = result.uploadAverageMbps.map { "\(Int($0.rounded())) Mbps up" } ?? "-- Mbps up"
        let ping = (result.pingMinMs ?? result.pingMs).map { "\(Int($0.rounded())) ms" } ?? "--"
        let net = result.networkShareDisplayName.trimmedNonEmpty ?? "réseau mobile"
        let place = result.city?.trimmedNonEmpty
        let placePart = place.map { " à \($0)" } ?? ""
        return """
        \(download) Mbps en download sur \(net)\(placePart), ping \(ping), \(upload) — mesuré avec SignalQuest.
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

    private var dlSeries: [Double] { cleaned(result.downloadSeriesMbps) }
    private var ulSeries: [Double] { cleaned(result.uploadSeriesMbps) }
    private var dlGaugeMax: Double { SpeedtestGaugeScale.maxSpeed(for: result, upload: false) }
    private var ulGaugeMax: Double { SpeedtestGaugeScale.maxSpeed(for: result, upload: true) }

    private var city: String { result.city?.trimmedNonEmpty ?? "Localisation indisponible" }
    private var network: String { result.networkShareDisplayName.trimmedNonEmpty ?? "Réseau indisponible" }
    private var pingValue: Int { Int((result.pingMinMs ?? result.pingMs ?? 0).rounded()) }
    private var jitter: Double { result.jitterMs ?? 0 }
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

    var body: some View {
        // Mise en page répartie sur toute la hauteur : header épinglé en haut,
        // footer épinglé en bas, bloc hero (cartes + latence) centré entre deux
        // Spacers flexibles. Supprime le ~205 pt de vide qu'imposait l'ancien
        // VStack à espacement nul aligné en haut.
        VStack(spacing: 0) {
            header

            Spacer(minLength: 24)

            HStack(spacing: 30) {
                statCard(
                    label: "Download", accent: downloadAccent,
                    avg: result.downloadAverageMbps, maxValue: result.downloadMaxMbps,
                    series: dlSeries, gaugeMax: dlGaugeMax, graphId: "dl"
                )
                statCard(
                    label: "Upload", accent: uploadAccent,
                    avg: result.uploadAverageMbps ?? 0, maxValue: result.uploadMaxMbps ?? (result.uploadAverageMbps ?? 0),
                    series: ulSeries, gaugeMax: ulGaugeMax, graphId: "ul"
                )
            }

            latencyStrip.padding(.top, 24)

            Spacer(minLength: 24)

            footer
        }
        .padding(50)
        .frame(width: 1080, height: 720)
        .background(bg)
        .environment(\.colorScheme, .dark)
    }

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(accent).frame(width: 88, height: 6)
                Text(device)
                    .font(SQFont.bodyFixed(15))
                    .foregroundStyle(textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("signalquest.fr")
                    .font(SQFont.displayFixed(17, .semibold))
                    .foregroundStyle(textPrimary)
                Text(dateLabel)
                    .font(SQFont.bodyFixed(13))
                    .foregroundStyle(textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 14) {
                Image("SQLogoMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Signal Quest")
                    .font(SQFont.displayFixed(24, .bold))
                    .foregroundStyle(textPrimary)
            }
            Spacer()
            Text("\(city) • \(network)")
                .font(SQFont.bodyFixed(16))
                .foregroundStyle(textSecondary)
                .lineLimit(1)
        }
    }

    private func statCard(label: String, accent: Color, avg: Double, maxValue: Double, series: [Double], gaugeMax: Double, graphId: String) -> some View {
        let lineColor = SpeedtestQualityPalette.color(forValue: avg, gaugeMax: gaugeMax, stops: theme.qualityStops)
        return VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(SQFont.bodyFixed(15, .semibold))
                .foregroundStyle(accent)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatSpeed(avg))
                    .font(SQFont.displayFixed(76, .bold))
                    .foregroundStyle(textPrimary)
                Text("Mbps")
                    .font(SQFont.bodyFixed(20, .medium))
                    .foregroundStyle(textSecondary)
            }
            HStack(spacing: 6) {
                Text("Max")
                    .font(SQFont.bodyFixed(14, .semibold))
                    .foregroundStyle(textSecondary)
                Text(formatSpeed(maxValue))
                    .font(SQFont.displayFixed(17, .bold))
                    .foregroundStyle(textPrimary)
                Text("Mbps")
                    .font(SQFont.bodyFixed(11, .semibold))
                    .foregroundStyle(textSecondary)
            }
            .padding(.top, 6)

            SpeedtestShareGraph(
                series: series,
                gaugeMax: gaugeMax,
                accent: lineColor,
                qualityStops: theme.qualityStops,
                plotBackground: surfaceMuted,
                gridColor: separator,
                emptyTextColor: textSecondary
            )
            .frame(height: 128)
            .padding(.top, 18)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var latencyStrip: some View {
        HStack(spacing: 12) {
            latencyChip(
                label: "Idle",
                value: "\(pingValue)",
                jitter: jitter,
                tint: textSecondary
            )
            latencyChip(
                label: "DL",
                value: result.pingDlMs.map { "\(Int($0.rounded()))" } ?? "—",
                jitter: result.jitterDlMs,
                tint: downloadAccent
            )
            latencyChip(
                label: "UL",
                value: result.pingUlMs.map { "\(Int($0.rounded()))" } ?? "—",
                jitter: result.jitterUlMs,
                tint: uploadAccent
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func latencyChip(label: String, value: String, jitter: Double?, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(SQFont.bodyFixed(12, .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(SQFont.displayFixed(22, .bold))
                    .foregroundStyle(textPrimary)
                Text("ms")
                    .font(SQFont.bodyFixed(11, .semibold))
                    .foregroundStyle(textSecondary)
            }
            Spacer(minLength: 0)
            Text(jitter.map { "jitter \(String(format: "%.1f", $0))" } ?? "jitter —")
                .font(SQFont.bodyFixed(11))
                .foregroundStyle(textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func formatSpeed(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func cleaned(_ source: [Double]?) -> [Double] {
        (source ?? []).filter { $0.isFinite && $0 >= 0 }.map { min($0, 20_000) }
    }
}

/// Graphe d'une série speedtest, fidèle à `generateGraphSvg` d'Android :
/// remplissage dégradé, glow, et trait dont la couleur suit la qualité de
/// chaque point (rampe DA danger→ambre→olive). Trait pointillé si < 2 points.
private struct SpeedtestShareGraph: View {
    let series: [Double]
    let gaugeMax: Double
    let accent: Color
    let qualityStops: [Color]
    let plotBackground: Color
    let gridColor: Color
    let emptyTextColor: Color

    /// Axe Y mis à l'échelle du max de la SÉRIE (avec ~15 % de marge haute) pour
    /// que la courbe remplisse la hauteur — évite les lignes plates en bas
    /// qu'imposerait une échelle commune ou la jauge réseau. La COULEUR, elle,
    /// reste indexée sur la jauge réseau (qualité selon le type de connexion).
    private var axisMax: Double {
        let peak = displaySeries.max() ?? 0
        return peak > 0 ? peak * 1.15 : 1
    }

    private var displaySeries: [Double] {
        if series.count >= 2 {
            return series
        } else if let first = series.first {
            return [first, first]
        } else {
            return [0.0, 0.0]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            chart(in: proxy.size)
        }
        .background(plotBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func chart(in size: CGSize) -> some View {
        let pts = simplified(displaySeries)
        let w = size.width, h = size.height
        let localMax = max(axisMax, 1)
        let step = w / CGFloat(max(pts.count - 1, 1))
        let x: (Int) -> CGFloat = { CGFloat($0) * step }
        // ~6 % de marge basse pour que le minimum ne colle pas au bord.
        let y: (Double) -> CGFloat = { h - (0.06 + CGFloat(min(1, max(0, $0 / localMax))) * 0.9) * h }

        var points: [CGPoint] = []
        for i in 0..<pts.count {
            points.append(CGPoint(x: x(i), y: y(pts[i])))
        }

        let n = points.count
        var m = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            if n <= 2 {
                m[i] = 0
            } else if i == 0 {
                m[i] = (points[1].y - points[0].y) / (points[1].x - points[0].x)
            } else if i == n - 1 {
                m[i] = (points[n-1].y - points[n-2].y) / (points[n-1].x - points[n-2].x)
            } else {
                let dx = points[i+1].x - points[i-1].x
                m[i] = dx > 0 ? (points[i+1].y - points[i-1].y) / dx : 0
            }
        }

        let line = Path { p in
            guard n >= 2 else { return }
            p.move(to: points[0])
            for i in 0..<(n - 1) {
                let p1 = points[i]
                let p2 = points[i+1]
                let dx = p2.x - p1.x
                
                let control1 = CGPoint(
                    x: p1.x + dx * 0.33,
                    y: min(h, max(0, p1.y + m[i] * (dx * 0.33)))
                )
                let control2 = CGPoint(
                    x: p2.x - dx * 0.33,
                    y: min(h, max(0, p2.y - m[i+1] * (dx * 0.33)))
                )
                p.addCurve(to: p2, control1: control1, control2: control2)
            }
        }

        let fill = Path { p in
            guard n >= 2 else { return }
            p.move(to: CGPoint(x: points[0].x, y: h))
            p.addLine(to: points[0])
            for i in 0..<(n - 1) {
                let p1 = points[i]
                let p2 = points[i+1]
                let dx = p2.x - p1.x
                
                let control1 = CGPoint(
                    x: p1.x + dx * 0.33,
                    y: min(h, max(0, p1.y + m[i] * (dx * 0.33)))
                )
                let control2 = CGPoint(
                    x: p2.x - dx * 0.33,
                    y: min(h, max(0, p2.y - m[i+1] * (dx * 0.33)))
                )
                p.addCurve(to: p2, control1: control1, control2: control2)
            }
            p.addLine(to: CGPoint(x: points[n-1].x, y: h))
            p.closeSubpath()
        }

        // Dégradé horizontal du trait : une teinte qualité par point (vs jauge).
        let strokeGradient = LinearGradient(
            stops: pts.enumerated().map { i, v in
                Gradient.Stop(
                    color: SpeedtestQualityPalette.color(forValue: v, gaugeMax: gaugeMax, stops: qualityStops),
                    location: pts.count > 1 ? CGFloat(i) / CGFloat(pts.count - 1) : 0
                )
            },
            startPoint: .leading, endPoint: .trailing
        )
        let grid = Path { p in
            for i in 1...3 {
                let gy = h / 4 * CGFloat(i)
                p.move(to: CGPoint(x: 0, y: gy)); p.addLine(to: CGPoint(x: w, y: gy))
            }
        }

        let isFallback = series.count < 2

        return ZStack {
            grid.stroke(gridColor.opacity(0.6), lineWidth: 1)
            if !isFallback {
                fill.fill(
                    LinearGradient(
                        colors: [accent.opacity(0.16), accent.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                line.stroke(strokeGradient, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .opacity(0.42)
                    .blur(radius: 6)
                line.stroke(strokeGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            } else {
                line.stroke(strokeGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [6, 6]))
                    .opacity(0.5)
            }
        }
    }

    private func simplified(_ values: [Double], maxPoints: Int = 32) -> [Double] {
        guard values.count > maxPoints else { return values }
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
