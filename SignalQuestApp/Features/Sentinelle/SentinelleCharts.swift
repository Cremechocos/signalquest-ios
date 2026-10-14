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
    /// Plage de temps affichée, quand le plein écran zoome ; sinon toute la fenêtre.
    var xDomain: ClosedRange<Date>? = nil
    /// En plein écran, la lecture reste affichée une fois le doigt levé.
    var keepsReading = false

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
        .modifier(SentinelleXDomain(domain: xDomain))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in scrub(to: value.location.x, proxy, geometry) }
                            .onEnded { _ in if !keepsReading { selected = nil } }
                    )
            }
        }
        // Le tracé n'est pas lisible par VoiceOver : on le résume, faute de quoi
        // l'écran ne dirait rien de la période à qui ne voit pas la courbe.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        // Alternative tabulaire non visuelle : VoiceOver parcourt de vraies
        // mesures datées au lieu de dépendre du glissement sur la courbe.
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                Text(accessibilitySummary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(series.samples.suffix(50))) { sample in
                    Text("\(sample.at.formatted(date: .abbreviated, time: .shortened)) : \(SentinelleWording.ms(sample.rttMs))")
                }
            }
        }
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
            ? String(localized: "aucune mesure perdue")
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
    /// Hauteur du graphe seul : la ligne de lecture (déjà espacée par son propre
    /// padding) s'ajoute en dessous, sans écraser le tracé.
    let height: CGFloat
    /// Plage de temps affichée, quand le plein écran zoome ; sinon toute la fenêtre.
    var xDomain: ClosedRange<Date>? = nil
    /// En plein écran, la lecture reste affichée une fois le doigt levé.
    var keepsReading = false

    /// Instant lu sous le doigt. Il vaut pour les DEUX familles à la fois :
    /// l'intérêt de ce graphe est justement de les comparer au même moment,
    /// donc un curseur par courbe irait contre son propos.
    @State private var readAt: Date?

    /// Les deux couleurs primaires de la DA, et pas une teinte de plus : brique
    /// pour l'IPv4, encre pour l'IPv6. Une troisième couleur (bleu, ambre…)
    /// entrerait en concurrence avec les états, qui eux SIGNIFIENT quelque chose.
    private static let colors: [SentinelleFamily: Color] = [.v4: SQColor.brandRed, .v6: SQColor.label]

    var body: some View {
        let series = SentinelleFamily.allCases.map { ($0, SentinelleLatencySeries(points: points, family: $0)) }
        let values = series.flatMap { $0.1.values }

        VStack(alignment: .leading, spacing: 0) {
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
            .modifier(SentinelleXDomain(domain: xDomain))
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in scrub(to: value.location.x, proxy, geometry, series) }
                                .onEnded { _ in if !keepsReading { readAt = nil } }
                        )
                }
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary(series))
            .accessibilityRepresentation {
                VStack(alignment: .leading) {
                    Text(summary(series))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(accessibilitySamples(series)) { sample in
                        Text("\(sample.family?.label ?? "Réseau"), \(sample.at.formatted(date: .abbreviated, time: .shortened)) : \(SentinelleWording.ms(sample.rttMs))")
                    }
                }
            }

            // Les valeurs des deux piles à l'instant lu, côte à côte. C'est la
            // raison d'être de ce graphe : voir l'écart au MÊME moment, pas deux
            // chiffres relevés à deux instants différents.
            readings(series)
        }
    }

    @ViewBuilder
    private func readings(_ series: [(SentinelleFamily, SentinelleLatencySeries)]) -> some View {
        if let readAt {
            HStack(spacing: SQSpace.md) {
                ForEach(series, id: \.0) { family, familySeries in
                    let sample = Self.nearest(in: familySeries, to: readAt)
                    HStack(spacing: SQSpace.xs) {
                        Text(family.label)
                            .font(SQFont.body(12, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelSecondary)
                        // Une famille muette à cet instant affiche un tiret, et
                        // non la valeur voisine : c'est précisément le trou qu'on
                        // vient chercher.
                        Text(sample.map { String(format: "%.0f ms", $0.rttMs) } ?? "—")
                            .font(SQFont.body(13, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Self.colors[family] ?? SQColor.label)
                    }
                }
                Spacer()
                Text(readAt.formatted(date: .omitted, time: .shortened))
                    .font(SQFont.body(12, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .padding(.top, SQSpace.xs)
        }
    }

    /// Mesure réelle la plus proche, jamais une interpolation — et `nil` quand
    /// cette famille n'a rien relevé dans les parages.
    private static func nearest(
        in series: SentinelleLatencySeries,
        to date: Date
    ) -> SentinelleLatencySample? {
        series.samples.min { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) }
    }

    private func scrub(
        to x: CGFloat,
        _ proxy: ChartProxy,
        _ geometry: GeometryProxy,
        _ series: [(SentinelleFamily, SentinelleLatencySeries)]
    ) {
        guard series.contains(where: { !$0.1.samples.isEmpty }) else { return }
        let origin = SentinelleChartScale.plotOriginX(proxy, geometry)
        guard let date: Date = proxy.value(atX: x - origin) else { return }
        if readAt == nil { Haptics.selection() }
        readAt = date
    }

    private func accessibilitySamples(
        _ series: [(SentinelleFamily, SentinelleLatencySeries)]
    ) -> [SentinelleLatencySample] {
        Array(series.flatMap { $0.1.samples }.sorted { $0.at < $1.at }.suffix(50))
    }

    /// Légende maison : celle de Swift Charts ne connaît ni la typographie ni
    /// les teintes de la DA.
    static func legend(for family: SentinelleFamily) -> some View {
        HStack(spacing: SQSpace.xs2) {
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

// MARK: - Plein écran

/// Fond de tracé transparent ; resserré sur une plage, il coupe ce qui en déborde.
struct SentinelleXDomain: ViewModifier {
    let domain: ClosedRange<Date>?

    func body(content: Content) -> some View {
        if let domain {
            content
                .chartXScale(domain: domain)
                .chartPlotStyle { plot in plot.background(Color.clear).clipped() }
        } else {
            content
                .chartPlotStyle { plot in plot.background(Color.clear) }
        }
    }
}

/// Un graphe de latence en grand, en paysage : le doigt lit chaque mesure,
/// le pincement resserre la période.
struct SentinelleChartFullScreen: View {
    enum Kind {
        /// Une famille : sa courbe et ses coupures.
        case latency(SentinelleLatencySeries)
        /// IPv4 et IPv6 superposées.
        case families([SentinelleSeriesPoint])
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let window: SentinelleWindow
    let onClose: () -> Void

    @State private var selected: SentinelleLatencySample?
    @State private var zoomDomain: ClosedRange<Date>?
    @State private var pinchBase: ClosedRange<Date>?

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm2) {
                MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "sentinelle.chart.fullscreen.close") { onClose() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                        .sqHeader()
                    Text(verbatim: subtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: SQSpace.sm)
                if case .families = kind {
                    HStack(spacing: SQSpace.md) {
                        ForEach(SentinelleFamily.allCases) { SentinelleFamilyChart.legend(for: $0) }
                    }
                }
            }
            chart
                .frame(maxHeight: .infinity)
                .modifier(ANFRPinchZoom(onChange: zoom(scale:anchor:), onEnd: { pinchBase = nil }))
                .accessibilityIdentifier("sentinelle.chart.fullscreen.chart")
            Text("Glisse le doigt pour lire chaque mesure · pince pour zoomer")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.sm)
        .background(SQColor.bg.ignoresSafeArea())
        .accessibilityAction(.escape) { onClose() }
    }

    @ViewBuilder
    private var chart: some View {
        switch kind {
        case .latency(let series):
            ZStack(alignment: .topTrailing) {
                SentinelleLatencyChart(series: series, window: window, selected: $selected,
                                       xDomain: zoomDomain, keepsReading: true)
                if let selected {
                    reading(selected)
                        .padding(SQSpace.sm)
                        .allowsHitTesting(false)
                }
            }
        case .families(let points):
            GeometryReader { proxy in
                // La ligne de lecture des deux familles s'ajoute sous le tracé.
                SentinelleFamilyChart(points: points, window: window,
                                      height: max(proxy.size.height - 32, 120), xDomain: zoomDomain,
                                      keepsReading: true)
            }
        }
    }

    /// « 12:05 · 29 ms », posé au-dessus de la courbe.
    private func reading(_ sample: SentinelleLatencySample) -> some View {
        HStack(spacing: SQSpace.sm) {
            Text(sample.at.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(SQColor.labelSecondary)
            Text(verbatim: SentinelleWording.ms(sample.rttMs))
                .font(SQFont.body(15, .bold, relativeTo: .subheadline))
                .foregroundStyle(SQColor.label)
        }
        .font(SQType.caption)
        .monospacedDigit()
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .sqCardBackground(cornerRadius: SQRadius.md)
    }

    private var fullDomain: ClosedRange<Date>? {
        let dates: [Date]
        switch kind {
        case .latency(let series): dates = series.samples.map(\.at) + series.outages.flatMap { [$0.start, $0.end] }
        case .families(let points): dates = points.map(\.at)
        }
        guard let first = dates.min(), let last = dates.max(), first < last else { return nil }
        return first...last
    }

    /// Pincement : resserre ou élargit la période autour des doigts, sans
    /// descendre sous le vingtième de la fenêtre.
    private func zoom(scale: Double, anchor: Double) {
        guard let full = fullDomain else { return }
        let base = pinchBase ?? (zoomDomain ?? full)
        if pinchBase == nil { pinchBase = base }
        let fullSpan = full.upperBound.timeIntervalSince(full.lowerBound)
        let baseSpan = base.upperBound.timeIntervalSince(base.lowerBound)
        let span = min(max(baseSpan / max(scale, 0.05), fullSpan / 20), fullSpan)
        let a = min(max(anchor, 0), 1)
        let anchorDate = base.lowerBound.addingTimeInterval(baseSpan * a)
        var lower = max(anchorDate.addingTimeInterval(-span * a), full.lowerBound)
        var upper = lower.addingTimeInterval(span)
        if upper > full.upperBound {
            upper = full.upperBound
            lower = upper.addingTimeInterval(-span)
        }
        zoomDomain = span >= fullSpan ? nil : lower...upper
    }
}

/// « Plein écran », posé à côté du titre de la carte du graphe.
struct SentinelleFullScreenButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Plein écran", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier(identifier)
    }
}
