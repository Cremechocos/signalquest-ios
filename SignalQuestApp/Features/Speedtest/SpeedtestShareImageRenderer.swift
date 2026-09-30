import UIKit
import SwiftUI

/// Texte de partage d'un speedtest et lieu affiché. L'image partagée est
/// désormais la carte de `SQShareCardBuilder` ; l'ancien rendu d'image, que
/// seuls les tests appelaient encore, a été retiré (MES-33).
///
/// Le reste du fichier (thème, palette qualité, graphe) sert aux fiches de
/// résultat : couleurs de la DA codées en dur, car ces vues sont aussi rendues
/// hors hiérarchie, où les jetons dynamiques ne se résolvent pas toujours.
enum SpeedtestShareImageRenderer {
    static func shareText(
        for result: SpeedtestRunResult,
        options: SpeedtestShareOptions = .init()
    ) -> String {
        let download = Int(result.downloadAverageMbps.rounded())
        let upload = result.uploadAverageMbps.map { "\(Int($0.rounded())) Mbps up" } ?? "-- Mbps up"
        let ping = (result.primaryPingMs).map { "\(Int($0.rounded())) ms" } ?? "--"
        var context = ""
        if options.includeNetworkContext {
            let net = result.networkShareDisplayName.trimmedNonEmpty ?? String(localized: "réseau mobile")
            context += String(localized: " sur \(net)")
        }
        if options.includeApproximateLocation, let place = result.city?.trimmedNonEmpty {
            context += String(localized: " à \(place)")
        }
        if options.includeServerDetails,
           let server = (result.serverName ?? result.downloadServerName)?.trimmedNonEmpty {
            context += " via \(server)"
        }
        // Dans la langue de l'app : l'app anglaise partageait un texte en
        // français (TRX-06).
        return String(localized: "\(download) Mbps en download\(context), ping \(ping), \(upload) — mesuré avec SignalQuest.")
            + "\n#SignalQuest · signalquest.fr"
    }

    // Conservé pour la dérivation de localisation (tests).
    static func location(for result: SpeedtestRunResult) -> String? {
        // Une ville absente ne prouve ni la France ni aucun autre pays. Laisser la
        // ligne de contexte sans lieu est plus honnête qu'une attribution inventée.
        result.city?.trimmedNonEmpty
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
    var timedSeries: [SpeedtestTimedRate]? = nil
    var timedAverageSeries: [SpeedtestTimedRate]? = nil
    var timeOriginMs: Int64? = nil
    /// Unité de l'axe dans l'app (« Mbit/s », « Mbps » en anglais) ; `nil` garde
    /// les codes universels de l'image de partage, comme sur Android.
    var unitLabel: String? = nil

    /// Série affichée : mesures du moteur si ≥ 2 points ; sinon moyenne réelle
    /// plate (toujours une donnée mesurée, jamais une courbe fantaisie).
    private var displaySeries: [Double] {
        timedSeries?.map(\.mbps) ?? series
    }

    private var isSparse: Bool { displaySeries.count < 2 }
    private var hasData: Bool { displaySeries.contains(where: { $0 > 0 }) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                chart(in: proxy.size)
            }
            if hasData {
                axisLabels
                if let timedSeries, let last = timedSeries.last {
                    VStack {
                        Spacer()
                        HStack {
                            Text("0 s")
                            Spacer()
                            Text("\(Double(last.elapsedMs - (timeOriginMs ?? 0)) / 1000, format: .number.precision(.fractionLength(1))) s")
                        }
                        .font(.caption2).foregroundStyle(labelColor).padding(8)
                    }
                }
            } else if displaySeries.isEmpty {
                Text("Courbe indisponible")
                    .font(.caption)
                    .foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let unitLabel {
                Text(verbatim: "\(maxV.formatted(.number.precision(.fractionLength(maxV >= 10 ? 0 : 1)))) \(unitLabel)")
            } else {
                Text("\(axisLabel(maxV)) Mbps")
            }
            Spacer(minLength: 0)
            if timedSeries == nil { Text("0") }
        }
        .font(SQFont.body(10, .medium, relativeTo: .caption2))
        .foregroundStyle(labelColor)
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
        if timedSeries != nil { return (base, 0) }
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
        let bottomInset: CGFloat = timedSeries == nil ? 6 : 22
        let leftInset: CGFloat = 2
        let rightInset: CGFloat = 6
        let plotHeight = max(1, h - topInset - bottomInset)
        let plotWidth = max(1, w - leftInset - rightInset)
        let step = plotWidth / CGFloat(max(pts.count - 1, 1))
        let x: (Int) -> CGFloat = { index in
            if let timedSeries, let first = timedSeries.first, let last = timedSeries.last,
               last.elapsedMs > first.elapsedMs, index < timedSeries.count {
                let origin = timeOriginMs ?? first.elapsedMs
                return leftInset + CGFloat(timedSeries[index].elapsedMs - origin) / CGFloat(max(1, last.elapsedMs - origin)) * plotWidth
            }
            return leftInset + CGFloat(index) * step
        }
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

        let averagePath = Path { path in
            guard let timedAverageSeries, let last = timedAverageSeries.last, let origin = timeOriginMs else { return }
            for (index, sample) in timedAverageSeries.enumerated() {
                let point = CGPoint(x: leftInset + CGFloat(sample.elapsedMs - origin) / CGFloat(max(1, last.elapsedMs - origin)) * plotWidth,
                                    y: y(sample.mbps))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        return ZStack {
            grid.stroke(gridColor.opacity(0.5), lineWidth: 1)
            averagePath.stroke(labelColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
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
