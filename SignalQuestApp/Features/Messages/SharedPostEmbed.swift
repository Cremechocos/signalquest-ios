import SwiftUI

// MARK: - Publication partagée « vivante » (parité Android SharedPostCard)
//
// Au lieu de la mini-carte statique « Voir la publication », la bulle rend la
// VRAIE publication : chargée par son id (metadata.shareCard.id) via
// SocialFeedService.post(id:), avec en-tête auteur, contenu (texte / image /
// mesure) et barre d'actions j'aime / commenter / republier FONCTIONNELLE
// directement depuis la conversation (mêmes routes que le feed). Un cache
// mémoire par postId (SharedPostStore, durée de vie : la conversation ouverte)
// évite de re-fetcher à chaque recyclage de la LazyVStack. Post supprimé ou
// inaccessible → repli sur la carte compacte statique (SharedPostCardBubble).

/// État de chargement d'une publication partagée.
enum SharedPostState: Equatable {
    case loading
    case loaded(UnifiedSocialFeedItem)
    /// Post supprimé ou inaccessible.
    case unavailable
}

/// Cible du sheet de commentaires d'une publication partagée.
struct SharedPostCommentsTarget: Identifiable {
    /// Clé du cache SharedPostStore (id porté par la carte de partage).
    let id: String
    /// Id backend attendu par l'API commentaires.
    let backendPostId: String
}

/// Cible du sheet « publication complète » (PostDetailView).
struct SharedPostDetailTarget: Identifiable {
    /// Clé du cache SharedPostStore (id porté par la carte de partage).
    let id: String
    let item: UnifiedSocialFeedItem
}

// MARK: Store

/// Cache mémoire + actions sociales optimistes, mutualisé entre toutes les
/// bulles de partage de la conversation. Mêmes services et même sémantique
/// optimiste (bascule locale → réconciliation serveur → rollback) que le feed.
@MainActor
final class SharedPostStore: ObservableObject {
    @Published private(set) var states: [String: SharedPostState] = [:]
    private var service: SocialFeedServicing?
    private var inFlight: Set<String> = []

    func state(for postId: String) -> SharedPostState {
        states[postId] ?? .loading
    }

    /// Charge le post une seule fois (cache par postId, garde anti-doublon).
    /// Le service est fourni par la vue appelante (AppServices.feed).
    func ensureLoaded(_ postId: String, service: SocialFeedServicing) {
        self.service = service
        guard states[postId] == nil, !inFlight.contains(postId) else { return }
        inFlight.insert(postId)
        states[postId] = .loading
        Task { [weak self] in
            defer { self?.inFlight.remove(postId) }
            do {
                if let item = try await service.post(id: postId) {
                    self?.states[postId] = .loaded(item)
                } else {
                    self?.states[postId] = .unavailable
                }
            } catch {
                if error.isCancellation {
                    // Retentera à la prochaine apparition de la bulle.
                    self?.states[postId] = nil
                } else {
                    // 404 / non accessible / réseau : repli carte compacte.
                    self?.states[postId] = .unavailable
                }
            }
        }
    }

    /// Rafraîchit silencieusement les compteurs (retour d'un sheet commentaires
    /// ou détail), sans repasser par l'état squelette.
    func refresh(_ postId: String) {
        guard let service, case .loaded = states[postId] else { return }
        Task { [weak self] in
            if let item = try? await service.post(id: postId) {
                self?.states[postId] = .loaded(item)
            }
        }
    }

    /// Toggle ❤️ optimiste, réconcilié par la réponse serveur (rollback si échec).
    func toggleLike(_ postId: String) {
        guard case .loaded(let current) = states[postId], let service else { return }
        let previous = current
        var optimistic = current
        optimistic.likedByMe.toggle()
        optimistic.reactions = Self.updatedReactions(current.reactions, emoji: "❤️", selected: optimistic.likedByMe)
        states[postId] = .loaded(optimistic)
        Haptics.light()
        Task { [weak self] in
            do {
                let response = try await service.react(postId: previous.id, emoji: "❤️")
                self?.apply(response: response, postId: postId)
            } catch {
                self?.states[postId] = .loaded(previous)
                Haptics.error()
            }
        }
    }

    /// Toggle republication optimiste, même sémantique que le feed.
    func toggleRepost(_ postId: String) {
        guard case .loaded(let current) = states[postId], let service else { return }
        let previous = current
        var optimistic = current
        optimistic.repostedByMe.toggle()
        optimistic.repostsCount = max(0, current.repostsCount + (optimistic.repostedByMe ? 1 : -1))
        states[postId] = .loaded(optimistic)
        Haptics.medium()
        Task { [weak self] in
            do {
                let response = try await service.repost(postId: previous.id)
                self?.apply(response: response, postId: postId)
            } catch {
                self?.states[postId] = .loaded(previous)
                Haptics.error()
            }
        }
    }

    private func apply(response: ReactionResponse, postId: String) {
        guard case .loaded(var item) = states[postId] else { return }
        if let reactions = response.reactions {
            item.reactions = reactions
            // Le backend ne renvoie pas `likedByMe` : on le dérive du ❤️.
            item.likedByMe = reactions.first(where: { $0.emoji == "❤️" })?.reactedByMe ?? false
        }
        if let reposted = response.reposted { item.repostedByMe = reposted }
        if let repostsCount = response.repostsCount { item.repostsCount = repostsCount }
        if let favorited = response.favorited { item.favoritedByMe = favorited }
        if let favoritesCount = response.favoritesCount { item.favoritesCount = favoritesCount }
        states[postId] = .loaded(item)
    }

    private static func updatedReactions(_ reactions: [SocialReactionSummary], emoji: String, selected: Bool) -> [SocialReactionSummary] {
        var result = reactions
        if let index = result.firstIndex(where: { $0.emoji == emoji }) {
            let count = max(0, result[index].count + (selected ? 1 : -1))
            result[index] = SocialReactionSummary(emoji: emoji, count: count, reactedByMe: selected)
        } else if selected {
            result.append(SocialReactionSummary(emoji: emoji, count: 1, reactedByMe: true))
        }
        return result
    }
}

// MARK: Bulle embed

/// Publication réelle rendue dans une bulle de conversation. L'embed vit
/// TOUJOURS sur un fond `surface` lisible : directement dans la bulle entrante
/// (déjà surface), ou dans une carte surface posée sur la bulle brique
/// sortante — les textes gardent donc les couleurs standard.
struct SharedPostEmbedBubble: View {
    let card: ShareCardData
    /// Id du post (clé du cache = `card.socialPostId`).
    let postId: String
    let mine: Bool
    /// `true` : l'embed EST la bulle (pas de fond brique/surface autour) —
    /// carte `surface` rayon 22 autonome, comme les photos seules.
    var standalone: Bool = false
    let service: SocialFeedServicing
    @ObservedObject var store: SharedPostStore
    /// Ouvre les commentaires du post (sheet CommentsSheet gérée par la conversation).
    let onComment: (UnifiedSocialFeedItem) -> Void
    /// Ouvre la publication complète (sheet PostDetailView gérée par la conversation).
    let onOpen: (UnifiedSocialFeedItem) -> Void

    var body: some View {
        Group {
            switch store.state(for: postId) {
            case .loading:
                loadingSkeleton
            case .loaded(let item):
                embed(item)
            case .unavailable:
                if standalone {
                    surfaceWrap { SharedPostCardBubble(card: card, mine: false) }
                } else {
                    SharedPostCardBubble(card: card, mine: mine)
                }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .onAppear { store.ensureLoaded(postId, service: service) }
    }

    // MARK: Contenu chargé

    private func embed(_ item: UnifiedSocialFeedItem) -> some View {
        surfaceWrap {
            VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
                // Contenu tappable → publication complète (parité Android).
                Button {
                    Haptics.selection()
                    onOpen(item)
                } label: {
                    VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
                        header(item)
                        let text = bodyText(item)
                        if !text.isEmpty {
                            Text(text)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.label)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        media(item)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Publication de \(item.author.displayName)")
                .accessibilityHint("Toucher pour ouvrir la publication")

                Rectangle()
                    .fill(SQColor.separator)
                    .frame(height: 0.5)
                actionsBar(item)
            }
        }
    }

    private func header(_ item: UnifiedSocialFeedItem) -> some View {
        HStack(spacing: SQSpace.sm) {
            SQAvatar(url: item.author.avatarUrl, name: item.author.displayName, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.author.displayName)
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                Text(sourceLine(item))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceLine(_ item: UnifiedSocialFeedItem) -> String {
        if let handle = item.author.handle, !handle.isEmpty {
            let normalized = handle.hasPrefix("@") ? handle : "@\(handle)"
            return "\(normalized) · Fil réseau"
        }
        return "Fil réseau"
    }

    /// Texte du post : version live en priorité, sinon aperçu du partage.
    private func bodyText(_ item: UnifiedSocialFeedItem) -> String {
        if !item.text.isEmpty { return item.text }
        return card.text ?? ""
    }

    /// Média : image du post (live puis snapshot), sinon tuile de mesure.
    @ViewBuilder
    private func media(_ item: UnifiedSocialFeedItem) -> some View {
        let attachment = item.attachments.first
        if let url = attachment?.thumbnailUrl ?? attachment?.url ?? card.imageUrl {
            RemoteImage(url: url, maxDimension: 600, contentMode: .fill) {
                Rectangle()
                    .fill(SQColor.surfaceMuted)
                    .sqShimmer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .accessibilityLabel(attachment?.altText ?? "Photo de la publication")
        } else if let measure = measure(for: item) {
            measurementTile(measure)
        }
    }

    // MARK: Barre d'actions (like / commenter / republier)

    private func actionsBar(_ item: UnifiedSocialFeedItem) -> some View {
        HStack(spacing: SQSpace.xs) {
            actionButton(
                icon: item.likedByMe ? "heart.fill" : "heart",
                count: reactionCount(item),
                tint: item.likedByMe ? SQColor.like : SQColor.labelSecondary,
                label: "J’aime",
                selected: item.likedByMe,
                popTrigger: item.likedByMe
            ) {
                store.toggleLike(postId)
            }
            actionButton(
                icon: "bubble.right",
                count: item.commentsCount,
                tint: SQColor.labelSecondary,
                label: "Commenter"
            ) {
                Haptics.selection()
                onComment(item)
            }
            actionButton(
                icon: "arrow.2.squarepath",
                count: item.repostsCount,
                tint: item.repostedByMe ? SQColor.success : SQColor.labelSecondary,
                label: "Republier",
                selected: item.repostedByMe
            ) {
                store.toggleRepost(postId)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(
        icon: String,
        count: Int,
        tint: Color,
        label: String,
        selected: Bool = false,
        popTrigger: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .sqLikePop(trigger: popTrigger ?? false)
                if count > 0 {
                    Text(SignalFormatters.count(count))
                        .font(SQFont.body(12, .semibold))
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, SQSpace.sm)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(count > 0 ? "\(count)" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func reactionCount(_ item: UnifiedSocialFeedItem) -> Int {
        item.reactions.reduce(0) { $0 + $1.count }
    }

    // MARK: Squelette de chargement

    private var loadingSkeleton: some View {
        surfaceWrap {
            VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
                HStack(spacing: SQSpace.sm) {
                    Circle()
                        .fill(SQColor.surfaceMuted)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(SQColor.surfaceMuted)
                            .frame(width: 110, height: 10)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(SQColor.surfaceMuted)
                            .frame(width: 72, height: 8)
                    }
                    Spacer(minLength: 0)
                }
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .fill(SQColor.surfaceMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 84)
            }
            .sqShimmer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chargement de la publication partagée")
    }

    /// Fond surface lisible : dans la bulle sortante (brique), l'embed est posé
    /// sur sa propre carte surface ; dans la bulle entrante (déjà surface), le
    /// contenu est rendu directement.
    @ViewBuilder
    private func surfaceWrap<Content: View>(_ content: () -> Content) -> some View {
        if standalone {
            // L'embed est la bulle : carte crème autonome, rayon 22.
            content()
                .padding(SQSpace.md + 2)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        } else if mine {
            content()
                .padding(SQSpace.md)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        } else {
            content()
        }
    }

    // MARK: Tuile de mesure (signal / speedtest / session)

    private struct EmbedMeasure {
        let primary: String
        let unit: String
        let tint: Color
        let chips: [String]
    }

    private func measurementTile(_ measure: EmbedMeasure) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(measure.primary)
                    .font(SQFont.display(20, .bold))
                    .foregroundStyle(measure.tint)
                Text(measure.unit)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelTertiary)
            }
            if !measure.chips.isEmpty {
                Text(measure.chips.prefix(3).joined(separator: " · "))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SQSpace.sm + 2)
        .padding(.vertical, SQSpace.sm)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Mesure à afficher : le signal live du post en priorité, sinon le
    /// snapshot du partage (signal → speedtest → session), comme Android.
    private func measure(for item: UnifiedSocialFeedItem) -> EmbedMeasure? {
        if let signal = item.signal {
            switch signal.type?.lowercased() {
            case "speedtest":
                if let down = signal.downloadMbps {
                    return EmbedMeasure(
                        primary: formatMbps(down),
                        unit: "Mbps",
                        tint: SQColor.brandRed,
                        chips: [
                            signal.uploadMbps.map { "↑ \(formatMbps($0))" },
                            signal.pingMs.map { "\(Int($0.rounded())) ms" },
                            signal.operator,
                            signal.technology
                        ].compactMap { $0 }
                    )
                }
            case "session", "coverage", "drive_test":
                let chips: [String] = [
                    signal.distanceMeters.map { String(format: "%.1f km", $0 / 1000) },
                    signal.durationSeconds.flatMap { $0 > 0 ? "\(Int($0 / 60)) min" : nil },
                    signal.detectedTechs.isEmpty ? nil : signal.detectedTechs.joined(separator: " · ")
                ].compactMap { $0 }
                if let points = signal.pointsCount {
                    return EmbedMeasure(primary: "\(points)", unit: "points", tint: SQColor.brandRed, chips: chips)
                }
            default:
                break
            }
            if let rsrp = signal.rsrp {
                let value = Int(rsrp.rounded())
                return EmbedMeasure(
                    primary: "\(value)",
                    unit: "dBm · RSRP",
                    tint: rsrpColor(value),
                    chips: [
                        signal.operator,
                        signal.technology,
                        signal.band.map { "Bande \($0)" },
                        signal.siteLabel
                    ].compactMap { $0 }
                )
            }
        }
        // Snapshot du partage (anciens posts, ou détail non porté par l'API).
        if let s = card.signal, let rsrp = s.rsrp {
            return EmbedMeasure(
                primary: "\(rsrp)",
                unit: "dBm · RSRP",
                tint: rsrpColor(rsrp),
                chips: [s.operatorName, s.technology, s.band.map { "Bande \($0)" }, s.site.map { "Site \($0)" }].compactMap { $0 }
            )
        }
        if let sp = card.speedtest, let down = sp.downloadMbps {
            return EmbedMeasure(
                primary: formatMbps(down),
                unit: "Mbps",
                tint: SQColor.brandRed,
                chips: [
                    sp.uploadMbps.map { "↑ \(formatMbps($0))" },
                    sp.pingMs.map { "\(Int($0.rounded())) ms" },
                    sp.operatorName,
                    sp.technology
                ].compactMap { $0 }
            )
        }
        if let se = card.session, se.points != nil || se.distanceKm != nil {
            return EmbedMeasure(
                primary: se.points.map { "\($0)" } ?? "—",
                unit: "points",
                tint: SQColor.brandRed,
                chips: [
                    se.distanceKm.map { String(format: "%.1f km", $0) },
                    se.durationSeconds.flatMap { $0 > 0 ? "\($0 / 60) min" : nil },
                    se.technologies
                ].compactMap { $0 }
            )
        }
        return nil
    }

    /// Échelle RSRP canonique unique (SQNetworkColors) — mêmes couleurs que la
    /// carte et les fiches.
    private func rsrpColor(_ rsrp: Int) -> Color {
        SQNetworkColors.rsrpColor(Double(rsrp))
    }

    private func formatMbps(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }
}
