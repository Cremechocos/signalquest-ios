import SwiftUI

/// Comparaison des opérateurs autour de toi pour une métrique (débit ou signal) :
/// classement par valeur médiane communautaire (barres colorées, leader couronné).
/// Ouverte au tap sur une tuile du pouls réseau de l'Accueil. Charge son propre
/// classement. Lecture seule.
struct NearbyOperatorComparisonSheet: View {
    let metric: NearbyOperatorMetric
    let latitude: Double
    let longitude: Double
    var radiusMeters: Int = 1000

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var stats: [OperatorMetricStat] = []
    @State private var loaded = false
    @State private var animate = false

    private var maxValue: Int { max(stats.map(\.value).max() ?? 1, 1) }
    private var totalSamples: Int { stats.reduce(0) { $0 + $1.sampleCount } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, SQSpace.xxl)
                } else if stats.isEmpty {
                    EmptyStateView(
                        title: "Pas encore de comparaison",
                        message: "Aucune mesure d'opérateur partagée dans ce rayon pour l'instant.",
                        systemImage: "chart.bar.xaxis"
                    )
                    .padding(.top, SQSpace.xxl)
                } else {
                    VStack(spacing: SQSpace.lg) {
                        intro
                        VStack(spacing: SQSpace.md) {
                            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                                operatorCard(stat, rank: index + 1, isLeader: index == 0)
                            }
                        }
                        footer
                    }
                    .padding(SQSpace.lg)
                    .padding(.bottom, SQSpace.xl)
                }
            }
            .signalQuestBackground()
            .navigationTitle("Opérateurs autour de toi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .accessibilityLabel("Fermer")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private func load() async {
        stats = await services.nearbyQuality.operatorRanking(
            metric: metric, latitude: latitude, longitude: longitude, maxAge: 90
        )
        loaded = true
        withAnimation(.easeOut(duration: 0.55)) { animate = true }
    }

    private var intro: some View {
        let sentence = "\(metric.introMetric.prefix(1).uppercased())\(metric.introMetric.dropFirst()) mesuré par la communauté à moins de \(radiusText) de toi, tous opérateurs confondus."
        return Text(sentence)
            .font(SQFont.body(14))
            .foregroundStyle(SQColor.labelSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SQSpace.sm)
    }

    private func operatorCard(_ stat: OperatorMetricStat, rank: Int, isLeader: Bool) -> some View {
        let color = SQBrand.operatorColor(stat.operatorName)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Text("\(rank)")
                    .font(SQFont.bodyFixed(13, .bold))
                    .foregroundStyle(isLeader ? SQColor.onAccent : SQColor.labelSecondary)
                    .frame(width: 24, height: 24)
                    .background(isLeader ? color : SQColor.surfaceMuted, in: Circle())
                Circle().fill(color).frame(width: 9, height: 9)
                Text(stat.operatorName)
                    .font(SQFont.body(15.5, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                if isLeader {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                }
                Spacer(minLength: SQSpace.sm)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(stat.value)")
                        .font(SQFont.display(20, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text(metric.unit).font(SQFont.body(11)).foregroundStyle(SQColor.labelSecondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SQColor.surfaceMuted)
                    Capsule().fill(color)
                        .frame(width: animate ? max(6, geo.size.width * CGFloat(fraction(for: stat))) : 0)
                }
            }
            .frame(height: 8)
            Text(detailText(stat))
                .font(SQFont.body(11.5))
                .foregroundStyle(SQColor.labelTertiary)
        }
        .padding(SQSpace.md)
        .background(
            (isLeader ? color.opacity(0.08) : SQColor.surface),
            in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(isLeader ? color.opacity(0.35) : SQColor.separator, lineWidth: isLeader ? 1.5 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rank). \(stat.operatorName), \(stat.value) \(metric.unit), \(stat.sampleCount) mesures.")
    }

    private var footer: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "person.3.fill").font(.caption).foregroundStyle(SQColor.labelTertiary)
            Text("\(totalSamples) mesure\(totalSamples > 1 ? "s" : "") au total · rayon \(radiusText)")
                .font(SQFont.body(12))
                .foregroundStyle(SQColor.labelTertiary)
        }
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
        parts.append("\(stat.sampleCount) mesure\(stat.sampleCount > 1 ? "s" : "")")
        return parts.joined(separator: " · ")
    }

    private var radiusText: String {
        radiusMeters >= 1000 ? "\(radiusMeters / 1000) km" : "\(radiusMeters) m"
    }
}
