import SwiftUI

/// Comparaison des opérateurs autour de toi : classement par valeur médiane communautaire,
/// en débit ou en signal (sélecteur en tête). Charge son propre classement. Lecture seule.
struct NearbyOperatorComparisonSheet: View {
    let latitude: Double
    let longitude: Double
    var radiusMeters: Int = 1000

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metric: NearbyOperatorMetric
    @State private var stats: [OperatorMetricStat] = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var animate = false

    init(metric: NearbyOperatorMetric, latitude: Double, longitude: Double, radiusMeters: Int = 1000) {
        _metric = State(initialValue: metric)
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }

    private var maxValue: Int { max(stats.map(\.value).max() ?? 1, 1) }
    private var totalSamples: Int { stats.reduce(0) { $0 + $1.sampleCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                metricPicker
                if !loaded {
                    SQSpinner()
                        .frame(maxWidth: .infinity)
                        .padding(.top, SQSpace.xxl)
                } else if loadFailed {
                    ErrorStateView(title: "Chargement impossible", message: "Impossible de charger les mesures. Réessaie.") {
                        loaded = false
                        Task { await load() }
                    }
                } else if stats.isEmpty {
                    EmptyStateView(
                        title: "Pas encore de comparaison",
                        message: "Aucune mesure d'opérateur partagée dans ce rayon pour l'instant.",
                        systemImage: "chart.bar.xaxis"
                    )
                    .padding(.top, SQSpace.lg)
                } else {
                    intro
                    VStack(spacing: 0) {
                        ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                            if index > 0 { Divider().overlay(SQColor.separator) }
                            operatorRow(stat, rank: index + 1)
                        }
                    }
                    .padding(.horizontal, SQSpace.md)
                    .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    footer
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .presentationDetents([.medium, .large])
        .sqSheet()
        .task(id: metric) { await load() }
    }

    private func load() async {
        // Changer de métrique ne laisse pas les anciens chiffres sous la nouvelle unité
        // (Mbit/s lus en dBm le temps de la requête) : retour au chargement.
        stats = []
        loaded = false
        loadFailed = false
        animate = false
        if AppEnvironment.usesDemoData {
            // Tours de captures : un classement plausible, sans réseau.
            stats = metric == .download
                ? [.init(operatorName: "Orange", value: 214, sampleCount: 18, detail: nil),
                   .init(operatorName: "SFR", value: 132, sampleCount: 11, detail: nil),
                   .init(operatorName: "Free Mobile", value: 96, sampleCount: 9, detail: nil),
                   .init(operatorName: "Bouygues", value: 71, sampleCount: 7, detail: nil)]
                : [.init(operatorName: "Orange", value: -84, sampleCount: 18, detail: nil),
                   .init(operatorName: "Bouygues", value: -91, sampleCount: 7, detail: nil),
                   .init(operatorName: "SFR", value: -95, sampleCount: 11, detail: nil),
                   .init(operatorName: "Free Mobile", value: -103, sampleCount: 9, detail: nil)]
            loaded = true
            animate = true
            return
        }
        do {
            // Une panne réseau n'est pas une zone sans mesures : elle a son état.
            stats = try await services.nearbyQuality.loadOperatorRanking(
                metric: metric, latitude: latitude, longitude: longitude, maxAge: 90
            )
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
        loaded = true
        animate = false
        withAnimation(SQMotion.resolve(.easeOut(duration: 0.55), reduceMotion)) { animate = true }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Autour de toi · \(radiusText)").sqKicker()
                Text("Comparer les opérateurs")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "home.compare.close") { dismiss() }
        }
    }

    /// Débit ou signal : deux moitiés égales sur la piste segmentée Halo.
    private var metricPicker: some View {
        HStack(spacing: 3) {
            segment(.download, label: "Débit")
            segment(.signal, label: "Signal")
        }
        .padding(SQSpace.xs)
        .background(SQColor.segTrack, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private func segment(_ value: NearbyOperatorMetric, label: LocalizedStringKey) -> some View {
        let isSelected = metric == value
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            withAnimation(reduceMotion ? nil : SQMotion.snappy) { metric = value }
        } label: {
            Text(label)
                .font(SQType.chip)
                .foregroundStyle(isSelected ? SQColor.label : SQColor.labelSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(SQColor.segThumb)
                            .shadow(color: SQColor.shadowSoft, radius: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("home.compare.metric.\(value == .download ? "download" : "signal")")
    }

    private var intro: some View {
        let sentence: String
        switch metric {
        case .download:
            sentence = String(localized: "Débit médian en réception, mesuré par la communauté à moins de \(radiusText), sur tout l’historique.")
        case .signal:
            sentence = String(localized: "Signal médian capté, mesuré par la communauté à moins de \(radiusText), sur tout l’historique.")
        }
        return Text(sentence)
            .font(SQType.callout)
            .foregroundStyle(SQColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func operatorRow(_ stat: OperatorMetricStat, rank: Int) -> some View {
        let color = SQBrand.operatorColor(stat.operatorName)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Text(verbatim: "\(rank)")
                    .font(SQType.caption(.bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 16)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 4, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: stat.operatorName)
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    Text(verbatim: detailText(stat))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: SQSpace.sm)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: valueText(stat))
                        .font(SQFont.display(20, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: unitText(stat))
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SQColor.chip)
                    Capsule().fill(color)
                        .frame(width: animate ? max(6, geo.size.width * CGFloat(fraction(for: stat))) : 0)
                }
            }
            .frame(height: 6)
            .padding(.leading, 28)
            .accessibilityHidden(true)
        }
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rank). \(stat.operatorName), \(valueText(stat)) \(unitText(stat)), \(measurementCountText(stat.sampleCount)).")
    }

    /// Le débit suit les unités de l'app (« Mbit/s » / « Mbps ») comme l'Accueil ;
    /// le signal reste en dBm.
    private func valueText(_ stat: OperatorMetricStat) -> String {
        switch metric {
        case .download: return SQUnits.throughputValue(mbps: Double(stat.value))
        case .signal: return "\(stat.value)"
        }
    }

    private func unitText(_ stat: OperatorMetricStat) -> String {
        switch metric {
        case .download: return SQUnits.throughputUnit(mbps: Double(stat.value))
        case .signal: return metric.unit
        }
    }

    private var footer: some View {
        Text([String(localized: "\(totalSamples) mesure au total · rayon \(radiusText)"),
              String(localized: "tout l’historique")].joined(separator: " · "))
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// Remplissage de barre : proportion du max pour le débit ; échelle absolue
    /// −120…−60 dBm pour le signal (valeurs négatives, plus proche de 0 = mieux).
    private func fraction(for stat: OperatorMetricStat) -> Double {
        switch metric {
        case .download:
            return maxValue > 0 ? Double(stat.value) / Double(maxValue) : 0
        case .signal:
            return min(1, max(0, (Double(stat.value) + 120) / 60))
        }
    }

    private func detailText(_ stat: OperatorMetricStat) -> String {
        var parts: [String] = []
        if let detail = stat.detail { parts.append(detail) }
        parts.append(measurementCountText(stat.sampleCount))
        return parts.joined(separator: " · ")
    }

    private func measurementCountText(_ count: Int) -> String {
        String(localized: "\(count) mesure")
    }

    private var radiusText: String {
SQUnits.distanceCompact(meters: Double(radiusMeters))
    }
}
