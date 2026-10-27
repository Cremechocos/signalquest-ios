import SwiftUI

/// Un test d'expérience dans l'historique commun : date, ce qui a été mesuré, réseau. Le
/// détail se charge au toucher (`ExperienceHistoryDetailSheet`) : la liste n'a qu'un résumé.
struct ExperienceHistoryRow: View {
    let item: ExperienceHistoryItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: SQSpace.md) {
            // Aux tailles d'accessibilité, la place va au texte : « d’expérience » ne se coupe pas.
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(width: 34, height: 34)
                    .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: titleLine)
                    .font(SQFont.body(15, .bold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: summaryLine)
                    .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("experience.history.summary")
                if let networkLine = item.networkLine {
                    Text(verbatim: networkLine)
                        .font(SQFont.body(12.5))
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let badge {
                    Text(verbatim: badge.text)
                        .font(SQFont.body(11, .semibold))
                        .foregroundStyle(badge.pending ? SQColor.warning : SQColor.chipInk)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 2)
                        .background(badge.pending ? SQColor.warningSoft : SQColor.chip, in: Capsule(style: .continuous))
                        .padding(.top, 2)
                        .accessibilityIdentifier("experience.history.delivery")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.cardPadding)
        .padding(.vertical, SQSpace.sm2)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// « 27 oct. · Test d’expérience »
    var titleLine: String {
        "\(item.measuredAt.formatted(.dateTime.day().month(.abbreviated))) · \(String(localized: "Test d’expérience"))"
    }

    /// « Vidéo 4K · Page 365 ms · Jeu 13 ms » : seulement ce qui a été mesuré, jamais de tiret.
    var summaryLine: String {
        item.highlights.historySummary ?? String(localized: "Aucun test mesuré")
    }

    /// Un test pas encore confirmé par le serveur le dit ; un test confirmé ou du serveur, rien.
    private var badge: (text: String, pending: Bool)? {
        switch item.delivery {
        case .pending: (String(localized: "À envoyer"), true)
        case .rejected: (String(localized: "Sur cet appareil"), false)
        case .synced, .localOnly, nil: nil
        }
    }
}

extension ExperienceHighlights {
    /// Résumé d'une ligne d'historique, dans l'ordre de la méthode.
    var historySummary: String? {
        var parts: [String] = []
        if let videoMaxQualityLabel { parts.append(String(localized: "Vidéo \(videoMaxQualityLabel)")) }
        if let videoScore { parts.append(String(localized: "Note vidéo \(videoScore)/100")) }
        if let pageMedianMs { parts.append(String(localized: "Page \(Self.waitingTime(pageMedianMs))")) }
        if let gameMedianMs { parts.append(String(localized: "Jeu \(gameMedianMs) ms")) }
        if let uploadPhotoMs { parts.append(String(localized: "Photo \(Self.waitingTime(uploadPhotoMs))")) }
        // Une valeur ne se coupe jamais (« 365 ms ») : la ligne passe à la ligne entre deux valeurs.
        return parts.isEmpty ? nil : parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
    }
}

extension ExperienceHighlights {
    /// « 4K » plutôt que la valeur du contrat « 2160p », comme le reste de l'app.
    var videoMaxQualityLabel: String? {
        videoMaxQuality.map { ExperienceVideoQuality(rawValue: $0)?.label ?? $0 }
    }
}

extension ExperienceHistoryItem {
    /// « Orange · 5G · Lyon », « Wi-Fi · Lyon » ; rien quand le réseau n'est pas connu.
    var networkLine: String? {
        var parts: [String] = []
        switch connectionType {
        case "wifi":
            parts.append(String(localized: "Wi-Fi"))
        case "cellular":
            let mobile = [operatorKey.map { SQBrand.operatorName($0) ?? $0 }, technology].compactMap { $0 }
            parts += mobile.isEmpty ? [String(localized: "Réseau mobile")] : mobile
        default:
            break
        }
        if let city = city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty { parts.append(city) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
