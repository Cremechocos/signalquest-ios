import SwiftUI

/// La box d'un proche, ouverte depuis le lien reçu.
///
/// Cet écran est ce qui manquait pour que le parcours ait un sens : jusqu'ici le
/// lien ouvrait Safari, et suivre depuis l'app supposait de coller l'URL à la
/// main.
///
/// Ce qu'on montre : l'état, la disponibilité, les coupures, les piles suivies.
/// Ce qu'on ne montre pas, et le serveur ne l'envoie même pas : l'adresse et le
/// chemin réseau — dont le dernier maillon EST l'adresse de la box.
struct SentinelleSharedView: View {
    let slug: String
    let service: SentinelleServicing

    @Environment(\.dismiss) private var dismiss
    @State private var box: SentinelleSharedBox?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView().tint(SQColor.brandRed)
            } else if let box {
                content(box)
            } else {
                EmptyStateView(
                    title: "Ce lien n’est plus actif",
                    // Le serveur répond la même chose pour un lien inconnu et
                    // pour un lien coupé : on ne renseigne pas sur ce qui a existé.
                    message: errorMessage
                        ?? String(localized: "Son propriétaire a peut-être arrêté le partage, ou le lien a expiré."),
                    systemImage: "link.badge.plus"
                )
                .padding(SQSpace.lg)
            }
        }
        .navigationTitle(box?.label ?? String(localized: "Connexion partagée"))
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .task { await load() }
    }

    private func content(_ box: SentinelleSharedBox) -> some View {
        ScrollView {
            VStack(spacing: SQSpace.md + 2) {
                GlassCard {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        HStack(alignment: .top, spacing: SQSpace.sm + 2) {
                            SentinelleStatusDot(color: SentinelleWording.statusColor(box.status))
                                .padding(.top, 6)
                            if let emoji = box.ownerEmoji, !emoji.isEmpty {
                                Text(emoji).font(.system(size: 19)).sqDecorative()
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verdict(box))
                                    .font(SQType.heading)
                                    .foregroundStyle(SQColor.label)
                                    .fixedSize(horizontal: false, vertical: true)
                                // Les piles se nomment, elles ne se montrent pas.
                                Text(box.families.isEmpty
                                    ? String(localized: "en attente de mesure")
                                    : box.families.joined(separator: " · "))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(SQColor.labelSecondary)
                                if let owner = box.ownerLabel, !owner.isEmpty {
                                    Text(owner)
                                        .font(SQFont.body(12))
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                            }
                            Spacer(minLength: SQSpace.sm)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text("Chiffres")
                            .font(SQFont.body(13))
                            .foregroundStyle(SQColor.labelSecondary)
                        Text(box.uptimePct.map { String(format: "Disponibilité sur 30 jours : %.2f %%", $0) }
                            ?? String(localized: "Disponibilité : pas encore mesurable"))
                            .font(SQFont.body(15))
                            .foregroundStyle(SQColor.label)
                        Text(box.outages > 0
                            ? "\(box.outages) coupure\(box.outages > 1 ? "s" : "") sur la période"
                            : String(localized: "Aucune coupure enregistrée sur la période"))
                            .font(SQFont.body(15))
                            .foregroundStyle(SQColor.label)
                    }
                }

                GlassCard { followBlock(box) }

                Text("Cette page est publiée volontairement par son propriétaire. Ni l’adresse "
                    + "surveillée, ni le chemin réseau qui y mène n’y figurent.")
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.huge)
            .sqReadableWidth()
        }
    }

    @ViewBuilder
    private func followBlock(_ box: SentinelleSharedBox) -> some View {
        if box.isOwner {
            Text("C’est votre connexion : vous la retrouvez dans votre liste Sentinelle.")
                .font(SQFont.body(14))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        } else if box.isFollowing {
            Text("Vous suivez cette connexion. Elle apparaît sur votre page Sentinelle, "
                + "où vous pouvez cesser de la suivre.")
                .font(SQFont.body(14))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        } else if !box.canFollow {
            // Un bouton qui répondrait « connectez-vous » après coup serait une
            // fausse promesse : on le dit avant.
            Text("Connectez-vous pour suivre cette connexion et la retrouver sur votre "
                + "page Sentinelle.")
                .font(SQFont.body(14))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Suivez cette connexion pour la retrouver sur votre page Sentinelle. "
                    + "Son propriétaire saura que vous la suivez et pourra retirer cet accès. "
                    + "Aucun abonnement requis.")
                    .font(SQFont.body(13))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                GradientButton(busy ? "…" : "Suivre cette connexion", systemImage: "person.badge.plus") {
                    Task { await follow() }
                }
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)
            }
        }
    }

    private func verdict(_ box: SentinelleSharedBox) -> String {
        switch box.status {
        case "up": return String(localized: "\(box.label) répond normalement.")
        case "down": return String(localized: "\(box.label) ne répond plus.")
        case "degraded": return String(localized: "\(box.label) répond mal.")
        default: return String(localized: "\(box.label) · en attente de mesure")
        }
    }

    private func load() async {
        do {
            box = try await service.sharedBox(slug: slug)
            errorMessage = nil
        } catch {
            box = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func follow() async {
        busy = true
        do {
            try await service.follow(shareInput: slug)
            // On RECHARGE au lieu de basculer un drapeau local : le serveur est
            // la seule source qui sait si l'abonnement a bien été créé.
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }
}
