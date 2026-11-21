import SwiftUI

/// Default card for "free form" posts (kind=`post`). Renders text + optional
/// image attachment + a thin signal hint when the payload carries one.
struct PostCardView: View {
    let item: UnifiedSocialFeedItem
    var onTap: () -> Void = {}
    var onLike: () -> Void = {}
    var onRepost: () -> Void = {}
    var onComment: () -> Void = {}
    var onFavorite: () -> Void = {}
    var onShare: () -> Void = {}
    var onAuthorTap: (() -> Void)? = nil
    /// Réaction emoji (appui long sur ❤️). Repli sur onLike si absent.
    var onReact: ((String) -> Void)? = nil
    /// Vote sur le sondage attaché, s'il y en a un.
    var onPollVote: ((FeedPoll.Option) -> Void)? = nil

    /// Première photo et sa taille d'affichage : le fil la précharge avec les mêmes valeurs,
    /// donc dans la même entrée du cache (E5).
    static let imageMaxDimension: CGFloat = 440

    static func imageURL(for item: UnifiedSocialFeedItem) -> URL? {
        guard let attachment = item.imageAttachments.first else { return nil }
        return attachment.thumbnailUrl ?? attachment.url
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                CardHeader(
                    author: item.author,
                    place: item.readablePlaceLabel,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.label,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                if !item.displayText.isEmpty {
                    Text(item.displayText)
                        .font(SQType.body)
                        .lineSpacing(3)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("feed.post.text")
                }

                // Le sondage se place APRÈS le texte et AVANT la pièce jointe :
                // c'est l'ordre de lecture naturel, le texte posant la question
                // que les options répondent.
                if let poll = item.poll, let onPollVote {
                    FeedPollView(poll: poll, onVote: onPollVote, speaksAsOneElement: true)
                }

                // Images seulement : une vidéo ou un audio n'a rien à faire dans un
                // chargeur d'image. Les autres photos sont signalées par une pastille.
                let images = item.imageAttachments
                if let attachment = images.first,
                   let url = Self.imageURL(for: item) {
                    RemoteImage(url: url, maxDimension: Self.imageMaxDimension, contentMode: .fill, showsFailureUI: true) {
                        Rectangle().fill(SQColor.surfaceMuted)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if images.count > 1 {
                            Text(verbatim: "1/\(images.count)")
                                .font(SQType.caption(.semibold))
                                .foregroundStyle(SQColor.onGlass)
                                .padding(.horizontal, SQSpace.sm2)
                                .padding(.vertical, SQSpace.xs)
                                .background(SQColor.glassDense, in: Capsule(style: .continuous))
                                .padding(SQSpace.sm2)
                                .accessibilityHidden(true)
                        }
                    }
                    .onTapGesture(count: 2) {
                        Haptics.medium()
                        // Double-tap = aimer, jamais retirer un like (SOC-16).
                        if !item.likedByMe { onLike() }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(attachment.trimmedAltText ?? String(localized: "Photo de la publication"))
                    .accessibilityValue(images.count > 1 ? String(localized: "\(images.count) photos") : "")
                }

                if !item.hashtags.isEmpty {
                    CardHashtags(tags: item.hashtags)
                }

                if let signal = item.signal, signal.rsrp != nil || signal.technology != nil {
                    SignalBarsView(summary: signal)
                }

                CardActionsBar(
                    item: item,
                    onLike: onLike,
                    onRepost: onRepost,
                    onComment: onComment,
                    onFavorite: onFavorite,
                    onShare: onShare,
                    onReact: onReact
                )
            }
            .padding(SQSpace.lg)
            .sqEditorialCard()
        }
        .buttonStyle(SQPressButtonStyle())
    }
}

struct SignalBarsView: View {
    let summary: SocialSignalSummary?

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            if summary?.rsrp == nil && summary?.technology == nil {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                Text("Radio indisponible sur iOS")
                    .font(SQType.caption)
            } else {
                // Des barres seulement pour un niveau mesuré : la technologie seule
                // n'en dit rien, trois barres sur quatre étaient un faux niveau (F-13).
                // Niveau et teinte de l'échelle commune, comme la carte et CarPlay :
                // les barres étaient toujours vertes, même sur un signal critique (21/11).
                if let quality {
                    Image(systemName: quality.glyph,
                          variableValue: quality.glyph == "cellularbars" ? quality.barsFraction : nil)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(quality.color)
                }
                if let technology = summary?.technology {
                    Text(verbatim: technology)
                        .font(SQType.micro)
                }
            }
        }
        .foregroundStyle(SQColor.labelSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    var accessibilityText: String {
        let technology = summary?.technology ?? ""
        guard let rsrp = summary?.rsrp else {
            return technology.isEmpty ? String(localized: "Radio indisponible sur iOS") : String(localized: "Réseau \(technology)")
        }
        var signal = String(localized: "Signal \(SignalFormatters.dbm(rsrp))")
        if let quality { signal += ", \(quality.label.lowercased())" }
        return technology.isEmpty ? signal : "\(signal), \(technology)"
    }

    /// Niveau de l'échelle commune, aux seuils de la technologie du post ; sans
    /// technologie lisible, aux seuils du RSRP. `nil` sans mesure valable.
    var quality: SQQualityScale.Signal? {
        guard let rsrp = summary?.rsrp else { return nil }
        let byTechnology = SQQualityScale.Signal(dbm: rsrp, technology: summary?.technology)
        let quality = byTechnology == .unknown ? SQQualityScale.Signal(rsrp: rsrp) : byTechnology
        return quality == .unknown ? nil : quality
    }
}
