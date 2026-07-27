import SwiftUI

/// Réglages du fil : hashtags suivis, hashtags et mots masqués.
///
/// Le backend sert l'inventaire des masquages en un seul appel — il le dit
/// explicitement dans sa route : éviter deux requêtes en cascade sur cet écran.
/// Les suivis sont un second appel, lancé en parallèle.
struct FeedPreferencesView: View {
    let service: SocialFeedServicing

    @State private var followed: [FollowedHashtag] = []
    @State private var mutes = SocialMutes()
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var newMutedTag = ""
    @State private var newMutedWord = ""

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(LocalizedStringKey(errorMessage))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                }
            }

            Section("Hashtags suivis") {
                if followed.isEmpty {
                    Text("Suis un hashtag depuis l'explorateur pour le retrouver ici.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                } else {
                    ForEach(followed) { follow in
                        HStack {
                            Text(follow.displayTag)
                            Spacer()
                            Button("Ne plus suivre") { unfollow(follow.hashtag) }
                                .font(SQFont.body(13, .medium))
                                .foregroundStyle(SQColor.accentInk)
                        }
                    }
                }
            }
            .listRowBackground(SQColor.surface)

            Section("Hashtags masqués") {
                addRow(
                    placeholder: "Ajouter un hashtag",
                    text: $newMutedTag,
                    action: { muteHashtag(newMutedTag) }
                )
                ForEach(mutes.hashtags) { muted in
                    HStack {
                        Text(muted.displayTag)
                        Spacer()
                        Button("Retirer") { unmuteHashtag(muted.hashtag) }
                            .font(SQFont.body(13, .medium))
                            .foregroundStyle(SQColor.accentInk)
                    }
                }
            }
            .listRowBackground(SQColor.surface)

            Section {
                addRow(
                    placeholder: "Ajouter un mot",
                    text: $newMutedWord,
                    action: { muteWord(newMutedWord) }
                )
                ForEach(mutes.words) { muted in
                    HStack {
                        Text(muted.pattern)
                        Spacer()
                        Button("Retirer") { unmuteWord(muted.pattern) }
                            .font(SQFont.body(13, .medium))
                            .foregroundStyle(SQColor.accentInk)
                    }
                }
            } header: {
                Text("Mots masqués")
            } footer: {
                Text("Les publications contenant ces mots n'apparaîtront plus dans ton fil.")
            }
            .listRowBackground(SQColor.surface)
        }
        .scrollContentBackground(.hidden)
        .background(SQColor.bg)
        .navigationTitle("Préférences du fil")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView().tint(SQColor.brandRed) }
        }
        .task { await load() }
    }

    private func addRow(placeholder: String, text: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack {
            TextField(LocalizedStringKey(placeholder), text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(action)
            Button("Ajouter", action: action)
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.accentInk)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        // Les deux appels en PARALLÈLE, et surtout indépendants : un échec des
        // suivis ne doit pas vider la liste des masquages, et réciproquement.
        async let follows = try? await service.followedHashtags()
        async let inventory = try? await service.mutes()
        followed = await follows ?? []
        mutes = await inventory ?? SocialMutes()
    }

    // MARK: Actions
    //
    // Toutes optimistes : le retrait local est immédiat, et l'inventaire est
    // rechargé en cas d'échec. Attendre le serveur rendrait chaque bascule
    // poussive sur un écran de réglages.

    private func unfollow(_ tag: String) {
        followed.removeAll { $0.hashtag == tag }
        perform { try await service.setHashtagFollowed(tag, following: false) }
    }

    private func muteHashtag(_ raw: String) {
        let tag = raw.normalizedHashtag
        guard !tag.isEmpty, !mutes.hashtags.contains(where: { $0.hashtag == tag }) else { return }
        newMutedTag = ""
        mutes = SocialMutes(
            hashtags: [SocialMutes.MutedHashtag(hashtag: tag, createdAt: Date())] + mutes.hashtags,
            words: mutes.words
        )
        perform { try await service.setHashtagMuted(tag, muted: true) }
    }

    private func unmuteHashtag(_ tag: String) {
        mutes = SocialMutes(hashtags: mutes.hashtags.filter { $0.hashtag != tag }, words: mutes.words)
        perform { try await service.setHashtagMuted(tag, muted: false) }
    }

    private func muteWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !mutes.words.contains(where: { $0.pattern == word }) else { return }
        newMutedWord = ""
        mutes = SocialMutes(
            hashtags: mutes.hashtags,
            words: [SocialMutes.MutedWord(pattern: word, createdAt: Date())] + mutes.words
        )
        perform { try await service.setWordMuted(word, muted: true) }
    }

    private func unmuteWord(_ pattern: String) {
        mutes = SocialMutes(hashtags: mutes.hashtags, words: mutes.words.filter { $0.pattern != pattern })
        perform { try await service.setWordMuted(pattern, muted: false) }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
                errorMessage = nil
            } catch {
                guard !error.isCancellation else { return }
                errorMessage = error.localizedDescription
                // Rechargement : l'état optimiste ne correspond plus au serveur,
                // et laisser l'écran mentir serait pire que le clignotement.
                await load()
            }
        }
    }
}
