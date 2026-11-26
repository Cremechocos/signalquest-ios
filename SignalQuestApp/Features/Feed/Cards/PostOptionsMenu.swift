import SwiftUI

/// Options d'une publication, les mêmes partout où elle apparaît : carte du fil, fiche ouverte,
/// profil, détail et Explorer. Contenu et ordre de la planche commune aux trois apps, validée
/// par Alexandre le 25/11 ; la forme reste native (menu iOS).
///
/// En tête, pour tous : Voir le profil · Copier le lien (post public) · Partager. Puis l'auteur :
/// Modifier (post écrit à la main) · Visibilité ▸ · Épingler · Couper les notifications ·
/// ── · Supprimer. Un autre membre : Couper les notifications · ── · Sourdine · Bloquer · Signaler.
/// Pas de Citer sur iOS.
///
/// Une entrée n'apparaît que si l'écran fournit son action ET que le serveur la permet
/// (`permissions`, contrat social-post-author-options §A, servi le 26/11 ; la règle locale
/// `canManage` en repli). Le serveur revérifie (403 sinon).
struct PostOptionsMenu: View {
    let item: UnifiedSocialFeedItem
    var onViewProfile: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onSetVisibility: ((SocialVisibility) -> Void)? = nil
    /// Lieu montré aux autres : `city` ou `none` (§B-2).
    var onSetLocation: ((String) -> Void)? = nil
    var onTogglePin: (() -> Void)? = nil
    var onMute: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onMuteAuthor: (() -> Void)? = nil
    var onBlockAuthor: (() -> Void)? = nil
    var onReport: (() -> Void)? = nil
    /// Préfixe des identifiants d'accessibilité (« feed.post », « signal.detail »…).
    var identifierPrefix = "post"

    enum Entry: Equatable {
        case profile, copyLink, share, edit, visibility, location, pin, mute, delete, muteAuthor, blockAuthor, report

        /// Groupe du menu : un séparateur entre deux groupes.
        var section: Int {
            switch self {
            case .profile, .copyLink, .share: return 0
            case .edit, .visibility, .location, .pin, .mute: return 1
            case .delete, .muteAuthor, .blockAuthor, .report: return 2
            }
        }
    }

    /// Entrées offertes, dans l'ordre. Fonction pure : testée sans vue.
    static func entries(
        for item: UnifiedSocialFeedItem,
        canViewProfile: Bool = false, canShare: Bool = false,
        canEdit: Bool, canSetVisibility: Bool, canSetLocation: Bool = false, canPin: Bool,
        canMute: Bool, canDelete: Bool,
        canMuteAuthor: Bool = false, canBlockAuthor: Bool = false,
        canReport: Bool
    ) -> [Entry] {
        var entries: [Entry] = []
        if canViewProfile { entries.append(.profile) }
        if item.publicWebLink != nil { entries.append(.copyLink) }
        // Un post en zone privée ou « Moi seul » ne se partage à personne (`canShare`).
        if canShare, item.allowsShare { entries.append(.share) }
        if item.canManage {
            // Un post automatique ne se modifie pas (403 GENERATED_POST_READ_ONLY, #694) ;
            // sa visibilité et son lieu, si.
            if canEdit, item.allowsEdit { entries.append(.edit) }
            if canSetVisibility, item.allowsVisibilityChange { entries.append(.visibility) }
            if canSetLocation, item.allowsLocationChange { entries.append(.location) }
            if canPin, item.allowsPin { entries.append(.pin) }
            if canMute, item.allowsMuteNotifications { entries.append(.mute) }
            if canDelete, item.allowsDelete { entries.append(.delete) }
        } else {
            if canMute, item.allowsMuteNotifications { entries.append(.mute) }
            if canMuteAuthor { entries.append(.muteAuthor) }
            if canBlockAuthor { entries.append(.blockAuthor) }
            // On ne signale pas sa propre publication.
            if canReport, item.allowsReport { entries.append(.report) }
        }
        return entries
    }

    private var entries: [Entry] {
        Self.entries(
            for: item,
            canViewProfile: onViewProfile != nil, canShare: onShare != nil,
            canEdit: onEdit != nil, canSetVisibility: onSetVisibility != nil,
            canSetLocation: onSetLocation != nil, canPin: onTogglePin != nil,
            canMute: onMute != nil, canDelete: onDelete != nil,
            canMuteAuthor: onMuteAuthor != nil, canBlockAuthor: onBlockAuthor != nil,
            canReport: onReport != nil
        )
    }

    var body: some View {
        let entries = entries
        ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
            if index > 0, entries[index - 1].section != entry.section {
                Divider()
            }
            row(entry)
        }
    }

    /// Une entrée ; la précision de la planche en deuxième ligne. Le menu iOS ne lit le
    /// sous-titre que si titre, sous-titre et icône sont à plat dans le bouton : rangés dans un
    /// `Label`, la deuxième ligne disparaissait (vu au simulateur le 26/11).
    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        let name = item.author.displayName
        switch entry {
        case .profile:
            Button { onViewProfile?() } label: {
                if let handle = item.author.handle, !handle.isEmpty {
                    Text("Voir le profil")
                    Text(verbatim: "@\(handle)")
                    Image(systemName: "person.crop.circle")
                } else {
                    Label("Voir le profil", systemImage: "person.crop.circle")
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).profile")
        case .copyLink:
            Button { Self.copyLink(of: item) } label: {
                Label("Copier le lien", systemImage: "link")
            }
            .accessibilityIdentifier("\(identifierPrefix).copyLink")
        case .share:
            Button { onShare?() } label: {
                Text("Partager")
                Text("Dans Messages")
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityIdentifier("\(identifierPrefix).share")
        case .edit:
            Button { onEdit?() } label: {
                Label("Modifier", systemImage: "pencil")
            }
            .accessibilityIdentifier("\(identifierPrefix).edit")
        case .visibility:
            PostVisibilityPicker(current: item.visibility) { onSetVisibility?($0) }
                .accessibilityIdentifier("\(identifierPrefix).visibility")
        case .location:
            PostLocationPicker(item: item) { onSetLocation?($0) }
                .accessibilityIdentifier("\(identifierPrefix).location")
        case .pin:
            Button { onTogglePin?() } label: {
                if item.isPinned {
                    Label("Désépingler", systemImage: "pin.slash")
                } else {
                    Text("Épingler")
                    Text("Une seule publication épinglée à la fois")
                    Image(systemName: "pin")
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).pin")
        case .mute:
            Button { onMute?() } label: {
                // Ternaires sortis en variables : imbriqués dans le `Label`, ils faisaient
                // saturer le vérificateur de types.
                let muted = item.notificationsMutedByMe == true
                let title: LocalizedStringKey = muted ? "Réactiver les notifications" : "Couper les notifications"
                let icon = muted ? "bell" : "bell.slash"
                Text(title)
                Text("Pour cette publication")
                Image(systemName: icon)
            }
            .accessibilityIdentifier("\(identifierPrefix).mute")
        case .delete:
            Button(role: .destructive) { onDelete?() } label: {
                Text("Supprimer")
                Text("Annulable quelques secondes")
                Image(systemName: "trash")
            }
            .accessibilityIdentifier("\(identifierPrefix).delete")
        case .muteAuthor:
            Button { onMuteAuthor?() } label: {
                Text("Mettre \(name) en sourdine")
                Text("Retire ses publications de ton fil, sans bloquer ce membre")
                Image(systemName: "speaker.slash")
            }
            .accessibilityIdentifier("\(identifierPrefix).muteAuthor")
        case .blockAuthor:
            Button(role: .destructive) { onBlockAuthor?() } label: {
                Text("Bloquer \(name)")
                Text("Masque ses publications et son profil")
                Image(systemName: "hand.raised")
            }
            .accessibilityIdentifier("\(identifierPrefix).blockAuthor")
        case .report:
            Button(role: .destructive) { onReport?() } label: {
                Text("Signaler")
                Text("Contenu problématique")
                Image(systemName: "flag")
            }
            .accessibilityIdentifier("\(identifierPrefix).report")
        }
    }
}

extension PostOptionsMenu {
    /// Le lien web de la publication, au presse-papiers. Le menu se ferme seul : la confirmation
    /// passe par le retour haptique et VoiceOver.
    static func copyLink(of item: UnifiedSocialFeedItem) {
        guard let url = item.publicWebLink else { return }
        UIPasteboard.general.url = url
        Haptics.success()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Lien copié"))
    }
}

extension UnifiedSocialFeedItem {
    /// Page web publique de la publication (`/posts/<id>`, ouverte aux visiteurs), seulement
    /// pour un post public et partageable : réservé aux amis, le lien mènerait les autres sur un
    /// refus ; en zone privée, il ne se partage à personne (règle commune aux trois apps, 25/11).
    var publicWebLink: URL? {
        guard allowsShare, visibility == nil || visibility == "public",
              sourceType == nil || sourceType == "post" else { return nil }
        return AppConfig.current.appBaseURL
            .appendingPathComponent("posts")
            .appendingPathComponent(backendPostId)
    }
}

// MARK: - Sourdine et blocage d'un membre

/// Sourdine et blocage d'un membre depuis le ⋯ d'une de ses publications (planche commune du
/// 25/11). Le blocage passe par une alerte ; la sourdine est immédiate et annulable.
@MainActor
enum AuthorModeration {
    /// Met le membre en sourdine ; « Annuler » la retire et rend ses publications au prochain
    /// chargement (`onUndone`).
    static func mute(
        _ author: SocialFeedAuthor,
        friends: FriendsServicing,
        notifications: SQInAppNotificationCenter,
        onUndone: @escaping @MainActor () -> Void
    ) {
        Task {
            do {
                try await friends.mute(userId: author.id)
                Haptics.success()
                notifications.showUndo(
                    body: String(localized: "\(author.displayName) est en sourdine"),
                    actionLabel: String(localized: "Annuler")
                ) {
                    Task {
                        do {
                            try await friends.unmute(userId: author.id)
                            onUndone()
                        } catch {
                            if !error.isCancellation { notifications.showError(error.userFacingMessage) }
                        }
                    }
                }
            } catch {
                guard !error.isCancellation else { return }
                Haptics.error()
                notifications.showError(String(localized: "La sourdine n’a pas pu être enregistrée."))
            }
        }
    }
}

/// Alerte « Bloquer X ? » posée sur l'écran qui offre « Bloquer » dans le ⋯. Le blocage réussi
/// retire aussitôt ses publications du fil (`sqMemberBlocked`, envoyé par le service).
struct BlockAuthorAlert: ViewModifier {
    @Binding var author: SocialFeedAuthor?
    let friends: FriendsServicing
    let notifications: SQInAppNotificationCenter

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "Bloquer \(author?.displayName ?? String(localized: "cet utilisateur")) ?"),
            isPresented: Binding(get: { author != nil }, set: { if !$0 { author = nil } }),
            presenting: author
        ) { target in
            Button("Bloquer", role: .destructive) {
                Task {
                    do {
                        try await friends.block(userId: target.id)
                        RecentlyViewedStore.remove(.profile, targetId: target.id)
                        Haptics.success()
                    } catch {
                        guard !error.isCancellation else { return }
                        Haptics.error()
                        notifications.showError(error.userFacingMessage)
                    }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Tu ne verras plus ses publications ni ses messages, et il ne pourra plus te contacter.")
        }
    }
}

extension View {
    func blockAuthorAlert(
        _ author: Binding<SocialFeedAuthor?>,
        friends: FriendsServicing,
        notifications: SQInAppNotificationCenter
    ) -> some View {
        modifier(BlockAuthorAlert(author: author, friends: friends, notifications: notifications))
    }
}

// MARK: - Lieu affiché

/// Sous-menu « Lieu affiché » de l'auteur : Commune ou Aucun lieu (planche commune du 25/11,
/// contrat §B-2). Le point exact d'un test n'est jamais montré aux autres, quel que soit ce choix.
struct PostLocationPicker: View {
    let item: UnifiedSocialFeedItem
    let onSelect: (String) -> Void

    var body: some View {
        Picker(selection: Binding(get: { item.effectiveLocationPrecision }, set: { onSelect($0) })) {
            if let place = item.cardPlace {
                Label(place, systemImage: "mappin.and.ellipse").tag("city")
            } else {
                Label("Commune", systemImage: "mappin.and.ellipse").tag("city")
            }
            Label("Aucun lieu", systemImage: "location.slash").tag("none")
        } label: {
            Label("Lieu affiché", systemImage: "mappin")
        }
        .pickerStyle(.menu)
    }

    /// Ce que dit le bandeau après le choix : qu'un test public reste sur la carte des débits
    /// (encart de la planche), sinon rien.
    @MainActor
    static func announce(_ item: UnifiedSocialFeedItem, precision: String, in center: SQInAppNotificationCenter) {
        guard let text = confirmation(for: item, precision: precision) else { return }
        center.show(SQInAppNotificationItem(body: text, duration: .seconds(5)))
    }

    static func confirmation(for item: UnifiedSocialFeedItem, precision: String) -> String? {
        guard precision == "none", item.signal?.testPublicOnMap == true else { return nil }
        return String(localized: "Lieu masqué. Ton test public reste visible sur la carte des débits.")
    }
}
