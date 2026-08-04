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
    /// Chargée à l'OUVERTURE seulement : la précharger ferait une requête par
    /// connexion suivie à chaque affichage de la page.
    var loadSeries: ((SentinelleWindow) async -> [SentinelleSeriesPoint])? = nil

    @State private var points: [SentinelleSeriesPoint] = []
    @State private var window: SentinelleWindow = .h24

    @State private var confirming = false
    // Le détail s'ouvre au TAP sur la carte, comme une box à soi : un bouton
    // « Détails » à côté serait une commande de plus pour le même geste.
    @State private var open = false

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
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                        .sqDecorative()
                }
                // Le tap n'est porté QUE par le résumé : posé sur la carte
                // entière, il refermait le détail dès qu'on glissait sur le
                // graphe pour y lire une valeur.
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } }

                if open {
                    Divider().overlay(SQColor.separator)

                    Picker("Période", selection: $window) {
                        ForEach(SentinelleWindow.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if !points.isEmpty {
                        Text("Latence · IPv4 et IPv6")
                            .font(SQFont.body(12))
                            .foregroundStyle(SQColor.labelSecondary)
                        // Le graphe porte SON propre geste de lecture au doigt.
                        // Il ne doit donc pas hériter du tap de la carte, qui
                        // refermerait le détail au moindre glissement.
                        SentinelleFamilyChart(points: points, window: window)
                            .frame(height: 120)
                    }

                    HStack(spacing: SQSpace.md) {
                        detailStat("Dispo. 30 j", box.uptimePct.map { String(format: "%.2f %%", $0) })
                        detailStat("Latence", box.lastRttMs.map { String(format: "%.0f ms", $0) })
                        detailStat("Coupures", "\(box.outages)")
                    }

                    if box.incidents.isEmpty {
                        Text("Aucune coupure enregistrée sur la période.")
                            .font(SQFont.body(12))
                            .foregroundStyle(SQColor.labelSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: SQSpace.xxs) {
                            ForEach(box.incidents.prefix(6), id: \.startedAt) { incident in
                                HStack {
                                    Text(SentinelleWording.date(incident.startedAt))
                                        .font(SQFont.body(12))
                                    Spacer()
                                    Text(incident.endedAt == nil
                                        ? String(localized: "en cours")
                                        : SentinelleWording.duration(incident.durationSec))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                            }
                        }
                    }

                    Text("Ni adresse ni chemin réseau : c’est ce qui distingue une connexion "
                        + "suivie d’une box à soi.")
                        .font(SQFont.body(11))
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .onChangeCompat(of: open) { _, isOpen in
            guard isOpen, points.isEmpty, let loadSeries else { return }
            Task { points = await loadSeries(window) }
        }
        .onChangeCompat(of: window) { _, newWindow in
            guard open, let loadSeries else { return }
            Task { points = await loadSeries(newWindow) }
        }
    }

    private func detailStat(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
            Text(value ?? "—")
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(SQColor.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// L'invitation venue d'un lien reçu, en tête de la page Sentinelle.
///
/// Elle remplace l'écran dédié : une page à part obligeait à comprendre OÙ
/// l'on était avant de comprendre ce qu'on regardait, pour un contenu qui a sa
/// place dans la liste. Elle disparaît d'elle-même une fois la box suivie.
struct SentinelleShareInvite: View {
    let box: SentinelleSharedBox
    let onFollow: () -> Void

    @State private var busy = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Connexion partagée avec vous")
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.labelSecondary)

                HStack(alignment: .top, spacing: SQSpace.sm + 2) {
                    SentinelleStatusDot(color: SentinelleWording.statusColor(box.status))
                        .padding(.top, 6)
                    if let emoji = box.ownerEmoji, !emoji.isEmpty {
                        Text(emoji).font(.system(size: 19)).sqDecorative()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(box.label)
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                        // Les piles se nomment, elles ne se montrent pas.
                        Text(box.families.isEmpty
                            ? String(localized: "en attente de mesure")
                            : box.families.joined(separator: " · "))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    Spacer(minLength: SQSpace.sm)
                }

                if box.canFollow {
                    GradientButton(busy ? "…" : "Suivre cette connexion", systemImage: "person.badge.plus") {
                        busy = true
                        onFollow()
                    }
                    .disabled(busy)
                } else {
                    // Un bouton qui répondrait « connectez-vous » après coup
                    // serait une fausse promesse : on le dit avant.
                    Text("Connectez-vous pour la suivre et la retrouver ici.")
                        .font(SQFont.body(13))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }
}
