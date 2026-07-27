import SwiftUI

/// Bilan hebdomadaire, consultable et partageable.
///
/// C'est le seul item du chantier social qui génère de l'ACQUISITION : l'image
/// sort de l'app. D'où deux exigences — un rendu déterministe (indépendant du
/// réglage Dynamic Type de l'appareil) et une carte qui se suffit à elle-même
/// hors contexte, marque comprise.
struct WeeklyRecapSheet: View {
    let service: SocialFeedServicing
    @Environment(\.dismiss) private var dismiss

    @State private var stats: WeeklyRecapStats?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var shareURL: URL?
    @State private var isPublishing = false
    @State private var publishNotice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.lg) {
                    if isLoading {
                        ProgressView().tint(SQColor.brandRed).padding(.top, SQSpace.xxl)
                    } else if let stats, stats.hasSomethingToShow {
                        WeeklyRecapCard(stats: stats)
                            .frame(maxWidth: .infinity)
                        actions(for: stats)
                    } else if let message = errorMessage {
                        ErrorStateView(title: "Bilan indisponible", message: message) {
                            Task { await load() }
                        }
                    } else {
                        // Une semaine vide n'a rien à raconter : proposer de la
                        // partager donnerait une carte creuse.
                        EmptyStateView(
                            title: "Pas encore de bilan",
                            message: "Lance un speedtest, valide une antenne ou publie une photo : ton bilan de la semaine se remplira.",
                            systemImage: "calendar"
                        )
                    }
                }
                .padding(SQSpace.lg)
            }
            .background(SQColor.bg)
            .navigationTitle("Ma semaine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .task { await load() }
        .sheet(item: Binding(
            get: { shareURL.map(ShareItem.init) },
            set: { if $0 == nil { shareURL = nil } }
        )) { item in
            ShareSheet(items: [item.url])
        }
    }

    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    @ViewBuilder
    private func actions(for stats: WeeklyRecapStats) -> some View {
        VStack(spacing: SQSpace.sm) {
            GradientButton("Partager mon bilan", systemImage: "square.and.arrow.up") {
                Task { shareURL = await WeeklyRecapImageRenderer.render(stats) }
            }
            Button {
                Task { await publish() }
            } label: {
                if isPublishing {
                    ProgressView().tint(SQColor.brandRed)
                } else {
                    Label("Publier en story", systemImage: "sparkles")
                }
            }
            .buttonStyle(.bordered)
            .tint(SQColor.brandRed)
            .disabled(isPublishing)

            if let publishNotice {
                Text(LocalizedStringKey(publishNotice))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            stats = try await service.weeklyRecap()
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    private func publish() async {
        isPublishing = true
        defer { isPublishing = false }
        do {
            let response = try await service.publishWeeklyRecap()
            // Republier ne crée pas de seconde story : le dire plutôt que de
            // feindre un succès neuf, sinon l'utilisateur republie en boucle.
            publishNotice = response.alreadyExisted == true
                ? "Ton bilan de la semaine est déjà en story."
                : "Bilan publié en story."
        } catch {
            if !error.isCancellation { publishNotice = error.localizedDescription }
        }
    }
}
