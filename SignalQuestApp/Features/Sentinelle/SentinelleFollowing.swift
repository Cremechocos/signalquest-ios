import SwiftUI

/// Les connexions qu'on SUIT, sans en être propriétaire.
///
/// Deux différences assumées avec ses propres box, et elles sont dans les
/// données autant que dans l'écran :
///
/// - **Aucune adresse.** Le serveur ne l'envoie pas et le modèle n'a pas de
///   champ pour l'accueillir. On nomme les piles, « IPv4 » et « IPv6 », ce qui
///   suffit à lire un incident sans identifier la connexion de quelqu'un.
/// - **Aucun réglage.** Pas de partage, pas d'alerte, pas de suppression : la
///   surveillance appartient à son propriétaire. La seule action est de partir.
///
/// Suivre n'exige pas Premium : c'est le propriétaire qui paie la mesure.
struct SentinelleFollowedCard: View {
    let box: SentinelleFollowedBox
    let onUnfollow: () -> Void

    @State private var confirming = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(alignment: .top, spacing: SQSpace.sm + 2) {
                    SentinelleStatusDot(color: SentinelleWording.statusColor(box.status))
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verdict)
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                        // Les piles se nomment, elles ne se montrent pas.
                        Text(box.families.isEmpty ? "en attente de mesure" : box.families.joined(separator: " · "))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(SQColor.labelSecondary)
                        Text(summary)
                            .font(SQFont.body(12))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    Spacer(minLength: SQSpace.sm)
                }

                if confirming {
                    HStack(spacing: SQSpace.sm) {
                        Button("Annuler") { confirming = false }
                            .buttonStyle(.plain)
                            .foregroundStyle(SQColor.labelSecondary)
                        Button("Ne plus suivre") { confirming = false; onUnfollow() }
                            .buttonStyle(.plain)
                            .foregroundStyle(SQColor.danger)
                    }
                    .font(SQFont.body(14))
                } else {
                    Button("Ne plus suivre") { confirming = true }
                        .buttonStyle(.plain)
                        .font(SQFont.body(14))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }

    private var verdict: String {
        switch box.status {
        case "up": return String(localized: "\(box.displayName) répond normalement.")
        case "down": return String(localized: "\(box.displayName) ne répond plus.")
        case "degraded": return String(localized: "\(box.displayName) répond mal.")
        default: return String(localized: "\(box.displayName) · en attente de mesure")
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let uptime = box.uptimePct { parts.append(String(format: "%.2f %% sur 30 j", uptime)) }
        if let rtt = box.lastRttMs { parts.append(String(format: "%.0f ms", rtt)) }
        if box.outages > 0 {
            parts.append("\(box.outages) coupure\(box.outages > 1 ? "s" : "")")
        }
        return parts.isEmpty ? String(localized: "Aucune coupure enregistrée.") : parts.joined(separator: " · ")
    }
}

/// Coller le lien reçu — c'est le geste réel.
///
/// On accepte l'URL entière comme le code seul : demander « extrayez le code »
/// serait une exigence gratuite pour quelqu'un qui vient de recevoir un message.
struct SentinelleFollowSheet: View {
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SentinelleSheetShell(
            title: String(localized: "Suivre une connexion partagée"),
            subtitle: String(localized: "Collez le lien qu’on vous a envoyé. Vous verrez l’état de la connexion et ses coupures — jamais son adresse. Son propriétaire saura que vous la suivez et pourra retirer cet accès.")
        ) {
            SentinelleField(
                title: "Lien de partage",
                placeholder: "https://signalquest.fr/sentinelle/p/…",
                text: $input,
                hint: error
            )

            GradientButton(busy ? "…" : "Suivre", systemImage: "person.badge.plus") {
                Task {
                    busy = true
                    error = nil
                    do {
                        try await onSubmit(input)
                        dismiss()
                    } catch {
                        // L'erreur reste DANS la feuille : la refermer effacerait
                        // ce qui vient d'être collé, et il faudrait recommencer.
                        self.error = error.localizedDescription
                    }
                    busy = false
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
    }
}

/// La porte d'entrée, toujours visible — c'est le seul geste Sentinelle ouvert
/// sans abonnement.
struct SentinelleFollowInvite: View {
    let onTap: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Suivre la connexion d’un proche")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Text("Collez le lien qu’on vous a partagé. Aucun abonnement requis : c’est le "
                    + "propriétaire qui paie la surveillance.")
                    .font(SQFont.body(13))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onTap) {
                    Label("Coller un lien", systemImage: "link")
                        .font(SQFont.body(14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SQColor.accentInk)
                .padding(.top, SQSpace.xxs)
            }
        }
    }
}
