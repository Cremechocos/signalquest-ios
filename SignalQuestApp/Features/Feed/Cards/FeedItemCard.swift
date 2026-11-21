import SwiftUI

/// Top-level card view that dispatches to the right specialised card based on
/// `item.kind`. Centralises the action callbacks so the parent feed only wires
/// them once.
struct FeedItemCard: View {
    let item: UnifiedSocialFeedItem
    var onTap: () -> Void = {}
    var onLike: () -> Void = {}
    var onRepost: () -> Void = {}
    var onComment: () -> Void = {}
    var onFavorite: () -> Void = {}
    var onShare: () -> Void = {}
    var onAuthorTap: (() -> Void)? = nil
    /// Réaction emoji (appui long sur ❤️), transmise à la barre d'actions.
    var onReact: ((String) -> Void)? = nil
    /// Vote sur un sondage. Seules les publications ordinaires en portent.
    var onPollVote: ((FeedPoll.Option) -> Void)? = nil

    var body: some View {
        // Posts automatiques (quête, niveau, badge, série, site, récap officiel) :
        // une carte par famille plutôt que le texte seul d'un post (F-09).
        if let activity = FeedActivity(item: item) {
            ActivityCardView(
                item: item, activity: activity,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
        } else {
            kindCard
        }
    }

    @ViewBuilder
    private var kindCard: some View {
        switch normalizedKind {
        case "speedtest":
            SpeedtestCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
        case "experience":
            if let experience = FeedExperience(item: item) {
                ExperienceCardView(
                    item: item, experience: experience,
                    onTap: onTap, onLike: onLike, onRepost: onRepost,
                    onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                    onAuthorTap: onAuthorTap, onReact: onReact
                )
            }
        case "validation":
            ValidationCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
        case "coverage", "session", "drive_test":
            CoverageCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
        case "photo", "antenna_photo":
            PhotoCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
        case "outage":
            OutageCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
        case "rating":
            RatingCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
        default:
            PostCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact, onPollVote: onPollVote
            )
        }
    }

    /// Photo que la carte de `item` affichera, à sa taille d'affichage (E5) : le fil la
    /// précharge quelques cartes avant. Seules les cartes photo et publication en montrent.
    static func prefetchImage(for item: UnifiedSocialFeedItem) -> (url: URL, maxDimension: CGFloat)? {
        guard FeedActivity(item: item) == nil else { return nil }
        switch item.cardKind {
        case "photo", "antenna_photo":
            return PhotoCardView.heroURL(for: item).map { ($0, PhotoCardView.heroMaxDimension) }
        case "speedtest", "experience", "validation", "coverage", "session", "drive_test", "outage", "rating":
            return nil
        default:
            return PostCardView.imageURL(for: item).map { ($0, PostCardView.imageMaxDimension) }
        }
    }

    private var normalizedKind: String {
        // The backend sometimes returns the historical SocialPost type
        // ("antenna_photo") and sometimes the v2 kind ("photo"). We normalise
        // here so the rest of the code only deals with a small set.
        item.cardKind
    }
}
