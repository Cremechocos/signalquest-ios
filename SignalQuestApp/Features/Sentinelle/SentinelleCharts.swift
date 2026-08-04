import SwiftUI
import Charts

/// Les graphes de Sentinelle.
///
/// Ce qu'une courbe doit dire et qu'un nombre ne dit pas : QUAND la ligne a
/// lâché. Les instants sans réponse ne sont donc jamais dessinés à zéro — un
/// zéro se lirait comme une latence parfaite — ils coupent le tracé et
/// s'affichent en bande, à leur place dans le temps.

/// Un point traçable.
///
/// `segment` est ce qui empêche la courbe de traverser une coupure : Swift
/// Charts relie entre eux les points d'une même série, on change donc de série
/// à chaque trou.
struct SentinelleLatencySample: Identifiable {
    let id: String
    let at: Date
    let rttMs: Double
    let segment: Int
    let family: SentinelleFamily?
}

/// Une plage sans réponse, bornée pour être visible même quand elle ne dure
/// qu'un cycle : un instant isolé aurait une largeur nulle, donc invisible.
struct SentinelleOutageSpan: Identifiable {
    let id: String
    let start: Date
    let end: Date
}

/// Ce qu'il faut pour tracer une fenêtre de mesures, calculé une seule fois :
/// le graphe et l'en-tête de la carte lisent la même chose.
struct SentinelleLatencySeries {
    let samples: [SentinelleLatencySample]
    let outages: [SentinelleOutageSpan]
    /// Nombre de salves entièrement perdues sur la fenêtre.
    let lostCount: Int
    /// Vrai quand la fenêtre ne contient QUE des pertes : « rien à tracer parce
    /// que rien ne répond » n'est pas « rien à tracer parce qu'on commence ».
    let allLost: Bool
    let isEmpty: Bool

    var values: [Double] { samples.map(\.rttMs) }
    var last: SentinelleLatencySample? { samples.last }

    init(points: [SentinelleSeriesPoint], family: SentinelleFamily? = nil) {
        let ordered = points
            .filter { family == nil || $0.family == family }
            .sorted { $0.at < $1.at }

        // Demi-pas de mesure : sert à donner une largeur aux plages perdues.
        let halfStep = Self.halfStep(of: ordered)

        var samples: [SentinelleLatencySample] = []
        var outages: [SentinelleOutageSpan] = []
        var segment = 0
        var lost = 0
        var runStart: Date?
        var runEnd: Date?

        for point in ordered {
            if let rtt = point.rttMs, !point.isLost {
                if runStart != nil { segment += 1 }
                Self.flush(&outages, runStart, runEnd, halfStep)
                runStart = nil
                runEnd = nil
                samples.append(SentinelleLatencySample(
                    id: point.id,
                    at: point.at,
                    rttMs: rtt,
                    segment: segment,
                    family: point.family
                ))
            } else {
                if point.isLost { lost += 1 }
                if runStart == nil { runStart = point.at }
                runEnd = point.at
            }
        }
        Self.flush(&outages, runStart, runEnd, halfStep)

        self.samples = samples
        self.outages = outages
        self.lostCount = lost
        self.allLost = !ordered.isEmpty && ordered.allSatisfy(\.isLost)
        self.isEmpty = ordered.isEmpty
    }

    private static func flush(
        _ outages: inout [SentinelleOutageSpan],
        _ start: Date?,
        _ end: Date?,
        _ halfStep: TimeInterval
    ) {
        guard let start, let end else { return }
        outages.append(SentinelleOutageSpan(
            id: "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)",
            start: start.addingTimeInterval(-halfStep),
            end: end.addingTimeInterval(halfStep)
        ))
    }

    /// Médiane des écarts entre deux mesures. La médiane et non la moyenne :
    /// une longue coupure d'ingestion tirerait la seconde et élargirait toutes
    /// les bandes.
    private static func halfStep(of points: [SentinelleSeriesPoint]) -> TimeInterval {
        guard points.count > 1 else { return 30 }
        var gaps: [TimeInterval] = []
        for index in 1..<points.count {
            gaps.append(points[index].at.timeIntervalSince(points[index - 1].at))
        }
        gaps.sort()
        return Swift.max(gaps[gaps.count / 2] / 2, 1)
    }
}

// MARK: - Graphe d'une adresse

/// Latence d'UNE famille sur la fenêtre choisie, avec un curseur de lecture.
///
/// Le curseur EST la navigation dans le temps : la route ne sait servir qu'une
/// fenêtre finissant maintenant, c'est donc en la parcourant du doigt qu'on lit
/// un instant passé — l'en-tête de la carte affiche alors CETTE mesure.
struct SentinelleLatencyChart: View {
    let series: SentinelleLatencySeries
    let window: SentinelleWindow
    @Binding var selected: SentinelleLatencySample?
    var color: Color = SQColor.brandRed

    var body: some View {
        Chart {
            ForEach(series.outages) { span in
                RectangleMark(
                    xStart: .value("Début", span.start),
                    xEnd: .value("Fin", span.end)
                )
                .foregroundStyle(SQColor.danger.opacity(0.16))
            }

            ForEach(series.samples) { sample in
                AreaMark(
                    x: .value("Instant", sample.at),
                    y: .value("Latence", sample.rttMs),
                    series: .value("Segment", sample.segment)
                )
                .foregroundStyle(color.opacity(0.13))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Instant", sample.at),
                    y: .value("Latence", sample.rttMs),
                    series: .value("Segment", sample.segment)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }

            ForEach(cursor) { sample in
                RuleMark(x: .value("Instant", sample.at))
                    .foregroundStyle(SQColor.label.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            ForEach(highlighted) { sample in
                PointMark(x: .value("Instant", sample.at), y: .value("Latence", sample.rttMs))
                    .foregroundStyle(color)
                    .symbolSize(selected == nil ? 70 : 90)
            }
        }
        .chartYScale(domain: 0...SentinelleChartScale.upperBound(series.values))
        .chartYAxis { SentinelleChartAxes.latency }
        .chartXAxis { SentinelleChartAxes.time(window) }
        .chartPlotStyle { plot in plot.background(Color.clear) }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in scrub(to: value.location.x, proxy, geometry) }
                            .onEnded { _ in selected = nil }
                    )
            }
        }
        // Le tracé n'est pas lisible par VoiceOver : on le résume, faute de quoi
        // l'écran ne dirait rien de la période à qui ne voit pas la courbe.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Le trait de lecture n'existe que sous le doigt.
    private var cursor: [SentinelleLatencySample] {
        selected.map { [$0] } ?? []
    }

    /// Le point mis en évidence : celui qu'on lit, ou à défaut la dernière
    /// mesure connue.
    ///
    /// Passés en tableaux et non en `if/else` : la conformité de
    /// `_ConditionalContent` à `ChartContent` n'existe pas sur les versions
    /// d'iOS que l'app dessert, un `if` dans un `Chart` ne compile donc pas.
    private var highlighted: [SentinelleLatencySample] {
        if let selected { return [selected] }
        return series.last.map { [$0] } ?? []
    }

    private func scrub(to x: CGFloat, _ proxy: ChartProxy, _ geometry: GeometryProxy) {
        guard !series.samples.isEmpty else { return }
        let origin = SentinelleChartScale.plotOriginX(proxy, geometry)
        guard let date: Date = proxy.value(atX: x - origin) else { return }
        // Le point le plus proche, jamais une valeur interpolée : on lit une
        // mesure réelle ou rien.
        let nearest = series.samples.min {
            abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date))
        }
        if nearest?.id != selected?.id { Haptics.selection() }
        selected = nearest
    }

    private var accessibilitySummary: String {
        guard let last = series.last else {
            return String(localized: "Aucune latence à tracer sur \(window.periodLabel).")
        }
        let values = series.values
        let minimum = SentinelleWording.ms(values.min())
        let maximum = SentinelleWording.ms(values.max())
        let losses = series.lostCount == 0
            ? String(localized: "aucune salve perdue")
            : SentinelleWording.lostBursts(series.lostCount)
        let current = SentinelleWording.ms(last.rttMs)
        return String(localized: "Latence sur \(window.periodLabel) : dernière mesure \(current), minimum \(minimum), maximum \(maximum), \(losses).")
    }
}

// MARK: - Graphe comparé des deux familles

/// IPv4 et IPv6 superposées, quand les deux sont suivies.
///
/// C'est le seul endroit où les deux piles se lisent ensemble — et l'intérêt est
/// justement de voir qu'elles ne racontent pas la même chose. La distinction ne
/// repose pas sur la seule couleur : l'IPv6 est en trait discontinu, sans quoi
/// le graphe serait muet pour qui distingue mal les teintes.
struct SentinelleFamilyChart: View {
    let points: [SentinelleSeriesPoint]
    let window: SentinelleWindow

    /// Les deux couleurs primaires de la DA, et pas une teinte de plus : brique
    /// pour l'IPv4, encre pour l'IPv6. Une troisième couleur (bleu, ambre…)
    /// entrerait en concurrence avec les états, qui eux SIGNIFIENT quelque chose.
    private static let colors: [SentinelleFamily: Color] = [.v4: SQColor.brandRed, .v6: SQColor.label]

    var body: some View {
        let series = SentinelleFamily.allCases.map { ($0, SentinelleLatencySeries(points: points, family: $0)) }
        let values = series.flatMap { $0.1.values }

        Chart {
            ForEach(series, id: \.0) { family, family_series in
                ForEach(family_series.samples) { sample in
                    LineMark(
                        x: .value("Instant", sample.at),
                        y: .value("Latence", sample.rttMs),
                        series: .value("Série", "\(family.rawValue)-\(sample.segment)")
                    )
                    .foregroundStyle(by: .value("Famille", family.label))
                    .lineStyle(StrokeStyle(
                        lineWidth: 2.2,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: family == .v6 ? [5, 4] : []
                    ))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale([
            SentinelleFamily.v4.label: Self.colors[.v4] ?? SQColor.brandRed,
            SentinelleFamily.v6.label: Self.colors[.v6] ?? SQColor.label,
        ])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...SentinelleChartScale.upperBound(values))
        .chartYAxis { SentinelleChartAxes.latency }
        .chartXAxis { SentinelleChartAxes.time(window) }
        .chartPlotStyle { plot in plot.background(Color.clear) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(series))
    }

    /// Légende maison : celle de Swift Charts ne connaît ni la typographie ni
    /// les teintes de la DA.
    static func legend(for family: SentinelleFamily) -> some View {
        HStack(spacing: SQSpace.xs + 2) {
            Capsule()
                .fill(colors[family] ?? SQColor.brandRed)
                .frame(width: 14, height: 3)
                .opacity(family == .v6 ? 0.85 : 1)
            Text(family.label)
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func summary(_ series: [(SentinelleFamily, SentinelleLatencySeries)]) -> String {
        let parts = series.compactMap { family, values -> String? in
            guard let last = values.last else { return nil }
            return String(localized: "\(family.label) à \(SentinelleWording.ms(last.rttMs))")
        }
        guard !parts.isEmpty else {
            return String(localized: "Aucune mesure comparable sur \(window.periodLabel).")
        }
        return String(localized: "Latence comparée sur \(window.periodLabel) : ")
            + parts.joined(separator: " ; ")
    }
}

// MARK: - Échelles et axes

enum SentinelleChartScale {

    /// Haut de l'axe. On part TOUJOURS de zéro : une échelle qui commence à la
    /// plus petite valeur mesurée transforme deux millisecondes d'écart en
    /// montagne, et c'est le mensonge classique des graphes de latence.
    static func upperBound(_ values: [Double]) -> Double {
        guard let peak = values.max(), peak > 0 else { return 10 }
        return peak * 1.2
    }

    /// Abscisse du bord gauche de la zone tracée, hors libellés d'axe.
    ///
    /// Deux branches parce que `plotAreaFrame` est déprécié depuis iOS 17 mais
    /// reste le seul chemin sous iOS 17, et que l'app se déploie en iOS 16.
    static func plotOriginX(_ proxy: ChartProxy, _ geometry: GeometryProxy) -> CGFloat {
        if #available(iOS 17.0, *) {
            guard let frame = proxy.plotFrame else { return 0 }
            return geometry[frame].origin.x
        }
        return geometry[proxy.plotAreaFrame].origin.x
    }
}

enum SentinelleChartAxes {

    @AxisContentBuilder
    static var latency: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(SQColor.separator.opacity(0.5))
            AxisValueLabel {
                if let milliseconds = value.as(Double.self) {
                    Text("\(Int(milliseconds))")
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }

    @AxisContentBuilder
    static func time(_ window: SentinelleWindow) -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(SQColor.separator.opacity(0.4))
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    // Sous la journée l'heure suffit ; au-delà elle n'apprend
                    // plus rien et c'est le jour qui situe.
                    Text(date, format: window.isIntraday
                        ? Date.FormatStyle.dateTime.hour().minute()
                        : Date.FormatStyle.dateTime.day().month())
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }
}
