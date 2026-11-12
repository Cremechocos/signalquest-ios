import SwiftUI

/// Textes de l'analyse de trajet, composés ici à partir des codes du serveur
/// (DRIVE-ANALYSIS-1) : le serveur ne sert jamais de phrase.
enum SessionAnalysisText {
    /// « Orange », « Orange (2) » quand deux SIM ont le même opérateur,
    /// « Réseau inconnu » sans opérateur.
    static func operatorLabel(_ series: SessionAnalysis.Series) -> String {
        guard let key = series.operatorKey, !key.isEmpty else { return String(localized: "Réseau inconnu") }
        let name = SQBrand.operatorName(key) ?? key
        guard let rank = series.operatorRank else { return name }
        return "\(name) (\(rank))"
    }

    /// Les 5 bandes du contrat ; nil pour une valeur inconnue (rien d'inventé).
    static func levelLabel(_ level: String?) -> String? {
        switch level {
        case "excellent": return String(localized: "Excellent")
        case "good": return String(localized: "Bon")
        case "fair": return String(localized: "Correct")
        case "poor": return String(localized: "Faible")
        case "critical": return String(localized: "Critique")
        default: return nil
        }
    }

    static func holesLabel(_ holes: Int) -> String {
        holes == 0 ? String(localized: "aucun trou") : String(localized: "\(holes) trou")
    }

    /// « Correct · 2 trous » — la ligne d'un opérateur.
    static func headline(_ series: SessionAnalysis.Series) -> String? {
        let level = levelLabel(series.verdict?.level ?? series.quality?.level)
        let holes = series.verdict?.holes.map(holesLabel)
        let parts = [level, holes].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// « Mesuré sur 86 % du trajet ».
    static func recordedLabel(_ series: SessionAnalysis.Series) -> String? {
        guard let fraction = series.quality?.recordedFraction, fraction >= 0 else { return nil }
        let percent = Int((min(fraction, 1) * 100).rounded())
        return String(localized: "Mesuré sur \(percent) % du trajet")
    }

    /// « Sans relevé : 6 min 50 s sur 4,4 km », rien quand il n'y a pas de trou.
    static func noRecordLabel(_ noRecord: SessionAnalysis.NoRecord?) -> String? {
        guard let noRecord, let seconds = noRecord.totalSec, seconds > 0 else { return nil }
        let duration = Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
        if let km = noRecord.km, km > 0 {
            return String(localized: "Sans relevé : \(duration) sur \(SessionDetailView.formatKm(km))")
        }
        return String(localized: "Sans relevé : \(duration)")
    }
}

/// TRAJET-SIM (règle MVNO-1 commune aux trois apps) : la marque de la SIM ne va
/// jamais dans le titre d'une série, puisque l'itinérance n'est souvent que
/// partielle. Elle se dit dans une mention sous la ligne, « Free · réseau Orange :
/// 18 % des relevés », et sur un point seulement s'il est sur ce réseau.
enum SessionTripBrand {
    enum Share: Equatable {
        case percent(Int)
        /// Arrondi à 0 avec des relevés : jamais « 0 % ».
        case underOne
        /// Arrondi à 100 sans être toute la série.
        case overNinetyNine
    }

    struct Mention: Equatable {
        let brand: String
        let network: String
        let share: Share
    }

    /// Le réseau se nomme comme le titre de la série (sa clé brute) ; le libellé
    /// servi ne sert que pour une clé que l'app ne connaît pas.
    static func networkLabel(key: String, served: String?) -> String {
        SQBrand.operatorName(key) ?? served.flatMap { $0.isEmpty ? nil : $0 } ?? key
    }

    /// Une mention par réseau qui porte une marque, dans l'ordre servi. Sans
    /// `pointCount` ni `networks` (ancien serveur), rien : rien n'est déduit.
    static func mentions(_ display: SessionSeriesOperatorDisplay?) -> [Mention] {
        guard let display, let total = display.pointCount, total > 0 else { return [] }
        return display.networks.compactMap { entry in
            guard entry.pointCount > 0, let brand = brand(entry) else { return nil }
            let percent = Int((100 * Double(entry.pointCount) / Double(total)).rounded())
            let share: Share
            if percent == 0 {
                share = .underOne
            } else if percent >= 100, entry.pointCount < total {
                share = .overNinetyNine
            } else {
                share = .percent(min(percent, 100))
            }
            return Mention(brand: brand, network: networkLabel(key: entry.networkKey, served: entry.network), share: share)
        }
    }

    static func text(_ mention: Mention) -> String {
        let who = String(localized: "\(mention.brand) · réseau \(mention.network)")
        switch mention.share {
        case .percent(let value): return String(localized: "\(who) : \(percentText(value)) des relevés")
        case .underOne: return String(localized: "\(who) : moins de \(percentText(1)) des relevés")
        case .overNinetyNine: return String(localized: "\(who) : plus de \(percentText(99)) des relevés")
        }
    }

    /// « Free · réseau Orange » pour UN relevé : l'entrée dont `networkKey` est
    /// exactement l'`operatorKey` brut du point, jamais un appariement par libellé.
    static func pointLabel(_ display: SessionSeriesOperatorDisplay?, operatorKey: String?) -> String? {
        guard let display, let operatorKey,
              let entry = display.networks.first(where: { $0.networkKey == operatorKey }),
              let brand = brand(entry) else { return nil }
        return String(localized: "\(brand) · réseau \(networkLabel(key: entry.networkKey, served: entry.network))")
    }

    /// La SIM sur son propre réseau (« Free » sur Free) n'a rien à mentionner,
    /// que le serveur y mette sa marque ou non (garde d'Android, 12/11). Le réseau
    /// s'écrit en nom complet (« Free Mobile ») : la marque se compare aussi au nom
    /// court, au libellé servi et à la clé.
    private static func brand(_ entry: SessionSeriesOperatorDisplay.Network) -> String? {
        guard let brand = entry.brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty else { return nil }
        let names = [networkLabel(key: entry.networkKey, served: entry.network),
                     SQBrand.operatorShortName(entry.networkKey), entry.network, entry.networkKey]
        let ownNetwork = names.contains { name in
            name?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(brand) == .orderedSame
        }
        return ownNetwork ? nil : brand
    }

    private static func percentText(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// « Analyse du trajet » : une ligne par opérateur, sans note globale (choix
/// d'Alexandre du 10/11), puis le temps sans relevé du trajet.
struct SessionAnalysisCard: View {
    let analysis: SessionAnalysis
    /// `seriesOperatorDisplay` du détail, par `seriesKey` brut.
    var operatorDisplays: [String: SessionSeriesOperatorDisplay] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Analyse du trajet")
                .font(SQFont.display(17, .bold, relativeTo: .headline))
                .foregroundStyle(SQColor.label)
                .sqHeader()
            ForEach(Array(analysis.operators.enumerated()), id: \.element.id) { position, series in
                if position > 0 { Divider() }
                row(series)
            }
            if let noRecord = SessionAnalysisText.noRecordLabel(analysis.noRecord) {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Label(noRecord, systemImage: "location.slash")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.label)
                    if analysis.noRecord?.source == "server_estimate" {
                        Text("Estimation du serveur")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityIdentifier("sessionDetail.analysis")
    }

    private func row(_ series: SessionAnalysis.Series) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Circle()
                .fill(SQBrand.operatorColor(series.operatorKey))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    Text(verbatim: SessionAnalysisText.operatorLabel(series))
                        .font(SQFont.body(15, .semibold))
                        .foregroundStyle(SQColor.label)
                    Spacer(minLength: 0)
                    if let score = series.quality?.score {
                        Text(verbatim: "\(score)/100")
                            .font(SQFont.body(15, .bold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                    }
                }
                ForEach(Array(SessionTripBrand.mentions(series.seriesKey.flatMap { operatorDisplays[$0] }).enumerated()), id: \.offset) { _, mention in
                    Text(verbatim: SessionTripBrand.text(mention))
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityIdentifier("sessionDetail.analysis.brandMention")
                }
                if let headline = SessionAnalysisText.headline(series) {
                    Text(verbatim: headline)
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.label)
                }
                if let recorded = SessionAnalysisText.recordedLabel(series) {
                    Text(verbatim: recorded)
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if series.isUnreliable {
                    Label("Peu de mesures : à prendre avec prudence", systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(OutageTint.degradedInk)
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
