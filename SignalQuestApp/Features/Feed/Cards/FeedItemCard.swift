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

    var body: some View {
        switch normalizedKind {
        case "speedtest":
            SpeedtestCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
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
        default:
            PostCardView(
                item: item,
                onTap: onTap, onLike: onLike, onRepost: onRepost,
                onComment: onComment, onFavorite: onFavorite, onShare: onShare,
                onAuthorTap: onAuthorTap, onReact: onReact
            )
        }
    }

    private var normalizedKind: String {
        // The backend sometimes returns the historical SocialPost type
        // ("antenna_photo") and sometimes the v2 kind ("photo"). We normalise
        // here so the rest of the code only deals with a small set.
        item.kind.lowercased()
    }
}
