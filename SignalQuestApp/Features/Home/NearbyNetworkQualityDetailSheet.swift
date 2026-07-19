import SwiftUI

/// Explique le verdict « Réseau … » de l'Accueil : d'où viennent les données
/// (mesures communautaires filtrées sur l'opérateur SIM, dans un rayon donné) et
/// comment il est calculé (le moins bon de la couverture et du débit). Lecture seule.
struct NearbyNetworkQualityDetailSheet: View {
    let quality: NearbyNetworkQuality
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.lg) {
                    hero
                    intro
                    criteriaCard
                    verdictRuleCard
                    footerNote
                }
                .padding(SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
            }
            .signalQuestBackground()
            .navigationTitle("Réseau autour de toi")
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
    }

    // MARK: Hero — jauge du verdict combiné

    private var hero: some View {
        let color = quality.level.swiftUIColor
        let fraction = CGFloat((quality.level.qualityRank ?? 0) + 1) / 5
        return VStack(spacing: SQSpace.md) {
            ZStack {
                Circle().stroke(SQColor.surfaceMuted, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 3) {
                    Image(systemName: "cellularbars")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(color)
                    Text(quality.level.title)
                        .font(SQFont.display(23, .bold))
                        .foregroundStyle(SQColor.label)
                    Text("Réseau \(quality.operatorLabel)")
                        .font(SQFont.body(13))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .frame(width: 190, height: 190)
            .padding(.top, SQSpace.sm)
        }
        .frame(maxWidth: .infinity)
    }

    private var intro: some View {
        Text("Ce diagnostic s'appuie sur les mesures partagées par la communauté SignalQuest à moins de \(radiusText) de toi, pour le réseau \(quality.operatorLabel).")
            .font(SQFont.body(14))
            .foregroundStyle(SQColor.labelSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SQSpace.sm)
    }

    // MARK: Les deux critères

    private var criteriaCard: some View {
        GlassCard {
            VStack(spacing: SQSpace.md) {
                criterionRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Couverture",
                    band: quality.signalBand,
                    valueText: quality.medianRsrpDbm.map { "\($0) dBm" } ?? "—",
                    caption: "Force du signal capté. Plus la valeur est proche de zéro, plus le signal est puissant (ex. −80 vaut mieux que −105)."
                )
                Divider().overlay(SQColor.separator)
                criterionRow(
                    icon: "speedometer",
                    title: "Débit",
                    band: quality.speedBand,
                    valueText: quality.medianDownloadMbps.map { "\($0) Mbps" } ?? "—",
                    caption: "Vitesse de téléchargement typique mesurée par la communauté sur ce réseau."
                )
            }
        }
    }

    private func criterionRow(icon: String, title: String, band: CoverageQualityBand, valueText: String, caption: String) -> some View {
        let tint = band == .unknown ? SQColor.labelTertiary : band.swiftUIColor
        return HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(SQFont.body(15, .semibold)).foregroundStyle(SQColor.label)
                    Spacer()
                    Text(valueText).font(SQFont.body(15, .semibold)).monospacedDigit().foregroundStyle(SQColor.label)
                }
                if band == .unknown {
                    Text("Pas assez de mesures")
                        .font(SQFont.body(11.5, .semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                } else {
                    Text(band.title)
                        .font(SQFont.body(11.5, .bold))
                        .foregroundStyle(band.swiftUIColor)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(band.swiftUIColor.opacity(0.14), in: Capsule(style: .continuous))
                }
                Text(caption)
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: La règle du verdict

    private var verdictRuleCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Label("Comment on décide", systemImage: "questionmark.circle")
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                Text("Un réseau « au top » doit à la fois **bien capter** et **être rapide**. On retient donc le **moins bon** des deux critères.")
                    .font(SQFont.body(13.5))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                limitingText
                    .font(SQFont.body(12.5))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var limitingText: some View {
        switch limiting {
        case .coverage: Text("Ici, c'est la **couverture** qui tire le verdict vers le bas.")
        case .speed: Text("Ici, c'est le **débit** qui tire le verdict vers le bas.")
        case .tie: Text("Ici, **couverture et débit** sont au même niveau.")
        case .coverageOnly: Text("Ici, seule la **couverture** a assez de mesures : le verdict s'appuie dessus.")
        case .speedOnly: Text("Ici, seul le **débit** a assez de mesures : le verdict s'appuie dessus.")
        }
    }

    // MARK: Fiabilité

    private var footerNote: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "person.3.fill").font(.caption).foregroundStyle(SQColor.labelTertiary)
            Text("\(quality.sampleCount) mesure\(quality.sampleCount > 1 ? "s" : "") de la communauté · rayon \(radiusText)")
                .font(SQFont.body(12))
                .foregroundStyle(SQColor.labelTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Dérivés

    private enum Limiting { case coverage, speed, tie, coverageOnly, speedOnly }

    /// Quel critère fixe le verdict (le rang le plus bas), ou lequel est seul disponible.
    private var limiting: Limiting {
        switch (quality.signalBand.qualityRank, quality.speedBand.qualityRank) {
        case let (signal?, speed?):
            if signal < speed { return .coverage }
            if speed < signal { return .speed }
            return .tie
        case (nil, _?): return .speedOnly
        case (_?, nil): return .coverageOnly
        case (nil, nil): return .tie
        }
    }

    private var radiusText: String {
        let m = quality.radiusMeters
        return m >= 1000 ? "\(m / 1000) km" : "\(m) m"
    }
}
