import SwiftUI

/// Couleurs de sévérité, identiques à Android et fixes en clair comme en sombre.
///
/// Sémantiques, donc jamais dérivées du thème : une panne qui changerait de couleur selon
/// l'apparence obligerait à réapprendre le code à chaque bascule. Les mêmes valeurs que la
/// couche carte Android, pour qu'un utilisateur des deux plateformes lise la même chose.
enum OutageTint {
    static let down = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    static let degraded = Color(red: 0xEA / 255, green: 0xB3 / 255, blue: 0x08 / 255)
    static let resolved = Color(red: 0x2E / 255, green: 0x7D / 255, blue: 0x5B / 255)

    static func of(_ severity: OutageSeverity) -> Color {
        severity == .degraded ? degraded : down
    }
}

/// Le bloc « panne » de la fiche antenne.
///
/// Deux visages, comme sur Android : rien de signalé → une invitation discrète ; une panne
/// existe → une carte qui prend la place qu'elle mérite. Un bloc de taille constante aurait soit
/// crié dans le vide, soit chuchoté une coupure.
struct CommunityOutageCard: View {
    let outages: [CommunityOutage]
    var onReport: (() -> Void)?
    var onVote: ((String, String) -> Void)?

    private var active: CommunityOutage? {
        outages.first { $0.state.isVisible }
    }

    var body: some View {
        if let active {
            outageBody(active)
        } else if onReport != nil {
            reportInvitation
        }
    }

    // MARK: - Panne en cours

    @ViewBuilder
    private func outageBody(_ outage: CommunityOutage) -> some View {
        let tint = OutageTint.of(outage.severity)
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateLabel(outage))
                        .font(SQFont.body(13.5, .semibold))
                        .foregroundStyle(SQColor.label)
                    Text(outage.severity == .degraded
                         ? "Service dégradé"
                         : "Plus aucun service")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
            }

            confirmationGauge(outage, tint: tint)

            if !outage.affectedServicesLabel.isEmpty {
                Text("Touché : \(outage.affectedServicesLabel)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            voteRow(outage)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
        )
    }

    private func stateLabel(_ outage: CommunityOutage) -> String {
        if outage.operatorConfirmed { return "Confirmée par l'opérateur" }
        return outage.state == .confirmed ? "Panne confirmée" : "Panne signalée"
    }

    /// Le décompte vers la confirmation.
    ///
    /// Une jauge SEGMENTÉE et non continue : il manque des gens, pas un pourcentage. On voit
    /// combien de crans sont remplis, exactement comme sur Android.
    @ViewBuilder
    private func confirmationGauge(_ outage: CommunityOutage, tint: Color) -> some View {
        let threshold = max(outage.confirmThreshold, 1)
        let filled = min(max(outage.confirmCount, 0), threshold)
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: 5) {
                ForEach(0..<threshold, id: \.self) { index in
                    Capsule()
                        .fill(index < filled ? tint : SQColor.separator)
                        .frame(height: 8)
                }
            }
            Text(progressLabel(outage))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func progressLabel(_ outage: CommunityOutage) -> String {
        if outage.operatorConfirmed {
            return "L'opérateur liste l'incident dans son fichier."
        }
        if outage.state == .confirmed {
            let n = outage.confirmCount
            return n <= 1 ? "1 personne a constaté la panne." : "\(n) personnes ont constaté la panne."
        }
        let remaining = outage.confirmationsRemaining
        if remaining <= 0 { return "En attente de confirmation." }
        return remaining == 1
            ? "Encore 1 personne et la panne est confirmée."
            : "Encore \(remaining) personnes et la panne est confirmée."
    }

    /// Confirmer ou démentir, à poids visuel STRICTEMENT égal.
    ///
    /// Mettre le « oui » en avant orienterait la communauté vers la confirmation — le biais que
    /// l'arbitrage est censé écarter.
    @ViewBuilder
    private func voteRow(_ outage: CommunityOutage) -> some View {
        if let onVote {
            if outage.canVote {
                HStack(spacing: SQSpace.sm) {
                    voteButton(
                        title: "Oui, c'est HS",
                        systemImage: "checkmark",
                        tint: OutageTint.down,
                        action: { onVote(outage.id, "confirm") }
                    )
                    voteButton(
                        title: "Non, ça marche",
                        systemImage: "xmark",
                        tint: OutageTint.resolved,
                        action: { onVote(outage.id, "dispute") }
                    )
                }
            } else {
                // Déjà positionné, ou auteur : on le DIT plutôt que d'afficher des boutons inertes.
                Text(myVoteLabel(outage))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    private func myVoteLabel(_ outage: CommunityOutage) -> String {
        switch outage.myVote {
        case "report": return "Vous avez signalé cette panne."
        case "confirm": return "Vous avez confirmé cette panne."
        case "dispute": return "Vous avez indiqué que ça marche."
        case "repaired": return "Vous avez signalé le rétablissement."
        default: return "Approchez-vous du site pour vous prononcer."
        }
    }

    private func voteButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.label)
            }
            // 44 pt : le minimum d'Apple, et le geste se fait dehors, à une main.
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                SQColor.fill,
                in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Rien de signalé

    private var reportInvitation: some View {
        Button {
            onReport?()
        } label: {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(SQColor.labelSecondary)
                Text("Signaler un problème sur ce site")
                    .font(SQFont.body(13.5, .medium))
                    .foregroundStyle(SQColor.label)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, SQSpace.md)
            .background(
                SQColor.fill,
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
