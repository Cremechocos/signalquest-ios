import SwiftUI

/// Réglages du fil : hashtags suivis, hashtags et mots masqués.
///
/// Le backend sert l'inventaire des masquages en un seul appel — il le dit
/// explicitement dans sa route : éviter deux requêtes en cascade sur cet écran.
/// Les suivis sont un second appel, lancé en parallèle.
struct FeedPreferencesView: View {
    let service: SocialFeedServicing
    /// Appelé au retour si un masquage ou un suivi a changé : le fil affiché
    /// doit refléter les nouvelles préférences sans attendre un tirer-pour-rafraîchir.
    var onChange: () -> Void = {}

    @State private var followed: [FollowedHashtag] = []
    @State private var mutes = SocialMutes()
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Vrai si le chargement a échoué : l'écran vide ressemblerait sinon à « rien de suivi ».
    @State private var loadFailed = false
    @State private var didChange = false
    @State private var newMutedTag = ""
    @State private var newMutedWord = ""
    /// Stories masquées : préférence locale à cet appareil (pas de route serveur).
    @State private var hiddenStoryAuthors = HiddenStoryAuthorsStore.entries()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                SQSettingsHeader(
                    title: "Préférences du fil",
                    subtitle: "Ce que tu suis et ce que tu ne veux plus voir.",
                    backIdentifier: "feedPrefs.back"
                )
                .padding(.bottom, SQSpace.xs)

                if let errorMessage {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text(LocalizedStringKey(errorMessage))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.dangerInk)
                        if loadFailed {
                            Button("Réessayer") { Task { await load() } }
                                .font(SQType.subhead(.semibold))
                                .foregroundStyle(SQColor.accentInk)
                                .frame(minHeight: 44)
                                .disabled(isLoading)
                        }
                    }
                    .padding(SQSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sqSurface(SQColor.surface, in: cardShape)
                }

                section("Hashtags suivis", footer: "Suis un hashtag depuis l'explorateur pour le retrouver ici.") {
                    if !followed.isEmpty {
                        card {
                            ForEach(Array(followed.enumerated()), id: \.element.id) { index, follow in
                                if index > 0 { rowDivider }
                                removableRow(
                                    follow.displayTag,
                                    removeLabel: String(localized: "Ne plus suivre \(follow.displayTag)"),
                                    identifier: "feedPrefs.followed.\(follow.hashtag)"
                                ) { unfollow(follow.hashtag) }
                            }
                        }
                    }
                }

                section("Hashtags masqués") {
                    card {
                        ForEach(mutes.hashtags) { muted in
                            removableRow(
                                muted.displayTag,
                                removeLabel: String(localized: "Retirer \(muted.displayTag)"),
                                identifier: "feedPrefs.mutedTag.\(muted.hashtag)"
                            ) { unmuteHashtag(muted.hashtag) }
                            rowDivider
                        }
                        addRow(
                            placeholder: "Ajouter un hashtag",
                            text: $newMutedTag,
                            identifier: "feedPrefs.addTag",
                            action: { muteHashtag(newMutedTag) }
                        )
                    }
                }

                section("Mots masqués", footer: "Les publications contenant ces mots n'apparaîtront plus dans ton fil.") {
                    card {
                        ForEach(mutes.words) { muted in
                            removableRow(
                                muted.pattern,
                                removeLabel: String(localized: "Retirer \(muted.pattern)"),
                                identifier: "feedPrefs.mutedWord"
                            ) { unmuteWord(muted.pattern) }
                            rowDivider
                        }
                        addRow(
                            placeholder: "Ajouter un mot",
                            text: $newMutedWord,
                            identifier: "feedPrefs.addWord",
                            action: { muteWord(newMutedWord) }
                        )
                    }
                }

                section(
                    "Stories masquées",
                    footer: hiddenStoryAuthors.isEmpty
                        ? "Depuis une story, « Masquer les stories de… » les retire de ton fil sans bloquer la personne."
                        : "Seulement sur cet appareil. Leurs publications restent dans ton fil."
                ) {
                    if !hiddenStoryAuthors.isEmpty {
                        card {
                            ForEach(Array(hiddenStoryAuthors.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { rowDivider }
                                HStack(spacing: SQSpace.md) {
                                    SQAvatar(url: nil, name: entry.displayName, size: 30)
                                        .accessibilityHidden(true)
                                    Text(verbatim: entry.displayName)
                                        .font(SQType.body(.semibold))
                                        .foregroundStyle(SQColor.label)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Afficher") {
                                        HiddenStoryAuthorsStore.unhide(authorId: entry.authorId)
                                    }
                                    .font(SQType.subhead(.semibold))
                                    .foregroundStyle(SQColor.accentInk)
                                    .frame(minHeight: 44)
                                    .accessibilityLabel(Text("Afficher de nouveau les stories de \(entry.displayName)"))
                                }
                                .padding(.horizontal, SQSpace.md)
                                .frame(minHeight: 52)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Préférences du fil")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .overlay {
            if isLoading { SQSpinner().tint(SQColor.brandRed) }
        }
        .task { await load() }
        .onDisappear { if didChange { didChange = false; onChange() } }
        .onReceive(NotificationCenter.default.publisher(for: HiddenStoryAuthorsStore.didChange)) { _ in
            hiddenStoryAuthors = HiddenStoryAuthorsStore.entries()
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, SQSpace.md)
    }

    /// Section Halo : titre en petites capitales, contenu, note facultative.
    private func section<Content: View>(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title)
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, SQSpace.xs)
                .padding(.top, SQSpace.sm)
            content()
            if let footer {
                Text(footer)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.xs)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .sqSurface(SQColor.surface, in: cardShape)
    }

    /// Ligne retirable : le libellé, puis une croix ronde.
    private func removableRow(
        _ title: String,
        removeLabel: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: SQSpace.md) {
            Text(verbatim: title)
                .font(SQType.body(.semibold))
                .foregroundStyle(SQColor.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 28, height: 28)
                    .background(SQColor.chip, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: removeLabel))
            .accessibilityIdentifier(identifier)
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, SQSpace.sm)
        .frame(minHeight: 48)
    }

    /// Ligne d'ajout, dernière ligne de la carte : un « + », le champ, puis
    /// « Ajouter » dès qu'il y a quelque chose à ajouter.
    private func addRow(
        placeholder: LocalizedStringKey,
        text: Binding<String>,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let isEmpty = text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: SQSpace.md) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 30, height: 30)
                .background(SQColor.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            TextField(placeholder, text: text)
                .font(SQType.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(action)
                .accessibilityIdentifier(identifier)
            if !isEmpty {
                Button("Ajouter", action: action)
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .frame(minHeight: 48)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        // Données démo : l'écran se lit et se manipule sans serveur.
        if AppEnvironment.usesDemoData {
            followed = [
                FollowedHashtag(hashtag: "5g", notifyOnNew: false, createdAt: nil),
                FollowedHashtag(hashtag: "lyon", notifyOnNew: false, createdAt: nil)
            ]
            mutes = SocialMutes(
                hashtags: [SocialMutes.MutedHashtag(hashtag: "crypto", createdAt: nil)],
                words: [SocialMutes.MutedWord(pattern: "promo", createdAt: nil)]
            )
            return
        }
        // Les deux appels en PARALLÈLE, et surtout indépendants : un échec des
        // suivis ne doit pas vider la liste des masquages, et réciproquement.
        async let followsError = loadFollowed()
        async let mutesError = loadMutes()
        let failure = [await followsError, await mutesError].compactMap { $0 }.first
        if let failure {
            guard !failure.isCancellation else { return }
            errorMessage = failure.userFacingMessage
            loadFailed = true
        } else if loadFailed {
            errorMessage = nil
            loadFailed = false
        }
    }

    private func loadFollowed() async -> Error? {
        do {
            followed = try await service.followedHashtags()
            return nil
        } catch {
            return error
        }
    }

    private func loadMutes() async -> Error? {
        do {
            mutes = try await service.mutes()
            return nil
        } catch {
            return error
        }
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
        guard !AppEnvironment.usesDemoData else { return }
        Task {
            do {
                try await operation()
                errorMessage = nil
                loadFailed = false
                didChange = true
            } catch {
                guard !error.isCancellation else { return }
                errorMessage = error.userFacingMessage
                // Rechargement : l'état optimiste ne correspond plus au serveur,
                // et laisser l'écran mentir serait pire que le clignotement.
                await load()
            }
        }
    }
}
