import SwiftUI

/// Qui suit cette box.
///
/// La carte se tait quand personne ne suit ET que le partage est inactif : une
/// carte vide sur une box jamais partagée n'apprend rien. Mais si des abonnés
/// subsistent après la coupure du lien, elle reste — sans quoi on croirait avoir
/// tout révoqué en désactivant le partage.
struct SentinelleFollowersCard: View {
    let target: SentinelleTarget
    let service: SentinelleServicing

    @State private var followers: [SentinelleFollower]?
    @State private var busy: String?
    @State private var shared: Bool?
    @State private var expiresAt: String?
    @State private var sharing = false

    var body: some View {
        // Tant que la liste n'est pas arrivée, on n'affiche RIEN plutôt qu'une
        // carte qui annoncerait « personne » avant d'avoir regardé.
        if let followers {
            let active = followers.filter(\.isActive)
            let past = followers.filter { !$0.isActive }
            card(active: active, past: past)
        } else {
            Color.clear.frame(height: 0).task { await load() }
        }
    }

    @ViewBuilder
    private func card(active: [SentinelleFollower], past: [SentinelleFollower]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            sharingControls

            if !active.isEmpty || !past.isEmpty || isShared {
                Divider().padding(.vertical, SQSpace.xs)
                Text("Qui suit cette connexion")
                .font(SQFont.display(16, .bold))
                .foregroundStyle(SQColor.label)

            Text("Ils voient son état et ses coupures. Ni son adresse, ni le chemin réseau — "
                 + "dont le dernier maillon est justement votre box.")
                .font(SQFont.body(12))
                .foregroundStyle(SQColor.labelSecondary)

            if active.isEmpty {
                Text(target.isPublic == true
                     ? "Personne pour l’instant. Partagez le lien pour qu’un proche puisse suivre."
                     : "Personne. Le partage est désactivé.")
                    .font(SQFont.body(13))
                    .foregroundStyle(SQColor.label)
                    .padding(.top, SQSpace.xs)
            } else {
                ForEach(active) { follower in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(follower.name ?? "Compte sans nom")
                                .font(SQFont.body(14, .medium))
                                .foregroundStyle(SQColor.label)
                            Text("depuis le \(shortDate(follower.since))")
                                .font(SQFont.body(11))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        Spacer()
                        Button(busy == follower.userId ? "Retrait…" : "Retirer") {
                            Task { await revoke(follower.userId) }
                        }
                        .font(SQFont.body(13, .medium))
                        .tint(SQColor.brandRed)
                        .disabled(busy == follower.userId)
                    }
                    .padding(.vertical, 2)
                }
            }

            }

            if !past.isEmpty {
                Text(past.count == 1
                     ? "Un accès a été retiré par le passé."
                     : "\(past.count) accès ont été retirés par le passé.")
                    .font(SQFont.body(11))
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.top, SQSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private var isShared: Bool { shared ?? (target.isPublic == true) }

    @ViewBuilder
    private var sharingControls: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Toggle(isOn: Binding(
                get: { isShared },
                set: { value in Task { await setSharing(.init(isPublic: value)) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isShared ? "Lien de partage actif" : "Partage désactivé")
                        .font(SQFont.body(14, .medium))
                        .foregroundStyle(SQColor.label)
                    Text(isShared
                         ? "Qui a le lien et un compte peut suivre cette connexion."
                         : "Personne ne peut suivre cette connexion.")
                        .font(SQFont.body(11))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .disabled(sharing)
            .tint(SQColor.brandRed)

            // La durée ne se règle QUE si le lien est actif : la proposer avant
            // reviendrait à fixer l'échéance de quelque chose qui n'existe pas.
            if isShared {
                Text("Durée du lien")
                    .font(SQFont.body(11))
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.top, SQSpace.xs)

                Picker("Durée du lien", selection: Binding(
                    get: {
                        SentinelleShareDuration.allCases.first { $0.matches(currentExpiry) }
                            ?? .unlimited
                    },
                    set: { option in
                        Task { await setSharing(.init(publicExpiresInHours: .some(option.hours))) }
                    }
                )) {
                    ForEach(SentinelleShareDuration.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(sharing)
            }
        }
    }

    private var currentExpiry: String? { expiresAt ?? target.publicExpiresAt }

    private func setSharing(_ changes: SentinelleSharingPatch) async {
        sharing = true
        defer { sharing = false }
        // On relit ce que le serveur a écrit plutôt que de supposer : c'est lui
        // qui crée le lien, et afficher un partage actif sans lien serait faux.
        if let updated = try? await service.setSharing(targetId: target.id, changes: changes) {
            shared = updated.isPublic
            expiresAt = updated.publicExpiresAt
        }
    }

    private func load() async {
        followers = (try? await service.followers(targetId: target.id))?.followers ?? []
    }

    private func revoke(_ userId: String) async {
        busy = userId
        defer { busy = nil }
        // On relit après coup : c'est le serveur qui décide, et supposer la
        // révocation réussie afficherait un accès retiré qui ne l'est pas.
        try? await service.revokeFollower(targetId: target.id, followerId: userId)
        await load()
    }

    private func shortDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
