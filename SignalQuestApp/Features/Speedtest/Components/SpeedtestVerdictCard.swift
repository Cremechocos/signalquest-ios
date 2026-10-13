import SwiftUI

/// Carte verdict d'un test (MES-05) : le palier en mots, ce que la connexion
/// permet, et, quand la zone est connue, la comparaison avec l'habitude de
/// l'opérateur autour de soi. Les métriques d'expert restent dans « Détails
/// de la mesure ».
struct SpeedtestVerdictCard: View {
    struct Typical: Equatable {
        let operatorLabel: String
        let mbps: Int
    }

    let verdict: SpeedtestVerdict
    let measuredMbps: Double
    /// Débit habituel de l'opérateur autour de la mesure (médiane sur 1 km).
    var typical: Typical? = nil
    /// Octets échangés par le test, quand ils ont été comptés (MES-08).
    var dataUsedBytes: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            // Palier en pastille, puis ce qu'il permet : le verdict se lit avant
            // les usages.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SQSpace.sm) {
                    tierPill
                    Spacer(minLength: SQSpace.sm)
                    usageCaption
                }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    tierPill
                    usageCaption
                }
            }
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                ForEach(SpeedtestVerdict.Usage.allCases, id: \.self) { usage in
                    if let fit = verdict.fits[usage] {
                        usageRow(usage, fit: fit)
                    }
                }
            }
            if let seconds = verdict.oneGigabyteSeconds {
                Label {
                    Text("Un fichier de 1 Go en \(Self.duration(seconds))")
                } icon: {
                    Image(systemName: "arrow.down.doc")
                }
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
            }
            if let dataUsedBytes, dataUsedBytes > 0 {
                Label {
                    Text("Ce test a utilisé \(ByteCountFormatter.string(fromByteCount: Int64(dataUsedBytes), countStyle: .file))")
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityIdentifier("speedtest.verdict.dataUsed")
            }
            if let typical {
                Divider().overlay(SQColor.separator)
                Text(verbatim: comparison(typical))
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("speedtest.verdict.comparison")
            }
        }
        .padding(SQSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speedtest.verdict")
    }

    /// La couleur de l'échelle sur le point et le fond doux, le mot à l'encre (TRX-04).
    private var tierPill: some View {
        HStack(spacing: SQSpace.xs2) {
            Circle()
                .fill(verdict.tier.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: verdict.tier.label)
                .font(SQFont.body(15, .bold, relativeTo: .headline))
                .foregroundStyle(SQColor.label)
                .accessibilityIdentifier("speedtest.verdict.tier")
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs2)
        .background(verdict.tier.color.opacity(0.14), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var usageCaption: some View {
        Text("Ce que ce débit permet")
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func usageRow(_ usage: SpeedtestVerdict.Usage, fit: SpeedtestVerdict.Fit) -> some View {
        HStack(spacing: SQSpace.sm) {
            // Icône ET mot : la couleur seule ne dit rien à tout le monde.
            Image(systemName: Self.symbol(fit))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Self.color(fit))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(verbatim: Self.label(usage))
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
            Spacer(minLength: SQSpace.sm)
            Text(verbatim: Self.label(fit))
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func comparison(_ typical: Typical) -> String {
        let usual = SQUnits.throughput(mbps: Double(typical.mbps))
        let ratio = typical.mbps > 0 ? measuredMbps / Double(typical.mbps) : 1
        if ratio >= 1.25 {
            return String(localized: "Autour de toi, \(typical.operatorLabel) fait en général \(usual) : ta mesure est au-dessus.")
        }
        if ratio <= 0.75 {
            return String(localized: "Autour de toi, \(typical.operatorLabel) fait en général \(usual) : ta mesure est en dessous.")
        }
        return String(localized: "Autour de toi, \(typical.operatorLabel) fait en général \(usual) : ta mesure est dans la moyenne.")
    }

    static func label(_ usage: SpeedtestVerdict.Usage) -> String {
        switch usage {
        case .web: return String(localized: "Navigation et messagerie")
        case .hdVideo: return String(localized: "Vidéo HD")
        case .uhdVideo: return String(localized: "Vidéo 4K")
        case .videoCall: return String(localized: "Visio")
        case .gaming: return String(localized: "Jeu en ligne")
        }
    }

    static func label(_ fit: SpeedtestVerdict.Fit) -> String {
        switch fit {
        case .good: return String(localized: "Oui")
        case .limited: return String(localized: "Par moments")
        case .poor: return String(localized: "Difficile")
        }
    }

    private static func symbol(_ fit: SpeedtestVerdict.Fit) -> String {
        switch fit {
        case .good: return "checkmark.circle.fill"
        case .limited: return "exclamationmark.circle.fill"
        case .poor: return "xmark.circle.fill"
        }
    }

    private static func color(_ fit: SpeedtestVerdict.Fit) -> Color {
        switch fit {
        case .good: return SQColor.success
        case .limited: return SQColor.warning
        case .poor: return SQColor.danger
        }
    }

    /// « 38 s », « 2 min », « 1 h 5 min », dans la langue de l'appareil.
    static func duration(_ seconds: Double) -> String {
        let rounded = seconds < 60 ? max(1, seconds.rounded(.up)) : (seconds / 60).rounded() * 60
        return Duration.seconds(rounded).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
