import SwiftUI

/// Carte d'un test de débit. Post automatique : le débit de réception en grand,
/// sa place sur l'échelle de la carte, puis envoi, latence et pointe. Post d'un
/// membre joint à un test (`telecom`) : son texte d'abord, le test en pièce
/// jointe compacte (refonte du 04/11).
struct SpeedtestCardView: View {
    let item: UnifiedSocialFeedItem
    var onTap: () -> Void
    var onLike: () -> Void
    var onRepost: () -> Void
    var onComment: () -> Void
    var onFavorite: () -> Void
    var onShare: () -> Void
    var onAuthorTap: (() -> Void)? = nil
    /// Réaction emoji (appui long sur ❤️). Repli sur onLike si absent.
    var onReact: ((String) -> Void)? = nil

    private var signal: SocialSignalSummary? { item.signal }

    /// Post de membre joint à un test : il arrive en `validation` (revue q34, constat 3).
    private var isMemberPost: Bool { item.kind.lowercased() != "speedtest" }

    private var isWiFi: Bool { TechAccent.shortLabel(for: signal?.technology) == "Wi-Fi" }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                CardHeader(
                    author: item.author,
                    place: signal?.city ?? item.readablePlaceLabel,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.brandRed,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                if isMemberPost {
                    memberContent
                } else {
                    automaticContent
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

    // MARK: Post automatique

    @ViewBuilder
    private var automaticContent: some View {
        FeedKindLine(
            symbol: isWiFi ? "wifi" : "speedometer",
            title: isWiFi ? String(localized: "Test de débit en Wi-Fi") : String(localized: "Test de débit"),
            points: item.earnedPoints
        )

        if let text = item.cardText {
            postText(text)
        }

        if let download = measuredDownload {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs2) {
                Text(verbatim: SQUnits.throughputValue(mbps: download))
                    .font(SQFont.display(44, .heavy, relativeTo: .largeTitle))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(verbatim: SQUnits.throughputUnit(mbps: download))
                    .font(SQType.callout(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Réception"))
            .accessibilityValue(Text(verbatim: SignalFormatters.speed(download)))
            .accessibilityIdentifier("feed.speed.download")

            FeedSpeedScale(mbps: download)
        } else {
            // Anciens posts dont le speedtest a disparu : pas de « — Mb/s » (F-12).
            Text("Résultat indisponible")
                .font(SQType.subhead(.bold))
                .foregroundStyle(SQColor.ink2)
        }

        if !metrics.isEmpty {
            FeedMetricGrid(metrics: metrics)
        }

        FeedNetworkLine(
            operator: signal?.servingOperator ?? signal?.operator,
            technology: signal?.technology,
            detail: roamingDetail
        )

        FeedOpenCapsule(title: String(localized: "Voir le test"), onOpenPost: onTap)
    }

    /// Envoi, latence, puis la pointe quand elle dépasse la moyenne : sans valeur, pas de tuile.
    private var metrics: [FeedMetricGrid.Metric] {
        var metrics: [FeedMetricGrid.Metric] = []
        if let upload = signal?.uploadMbps, upload > 0 {
            metrics.append(.init(label: "Envoi", value: SignalFormatters.speed(upload)))
        }
        if let ping = signal?.pingMs, ping > 0 {
            metrics.append(.init(label: "Latence", value: SignalFormatters.ms(ping)))
        }
        if let peak = signal?.maxDownloadMbps, let download = measuredDownload, peak > download {
            metrics.append(.init(label: "Pointe", value: SignalFormatters.speed(peak)))
        }
        return metrics
    }

    // MARK: Post d'un membre

    @ViewBuilder
    private var memberContent: some View {
        if let text = item.cardText {
            postText(text)
        }
        if !item.hashtags.isEmpty {
            CardHashtags(tags: item.hashtags)
        }
        attachment
    }

    /// Le test joint, compact : débit et réseau, et il s'ouvre d'un toucher.
    private var attachment: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: isWiFi ? "wifi" : "speedometer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(width: 32, height: 32)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                if let download = measuredDownload {
                    HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                        Text(verbatim: SQUnits.throughputValue(mbps: download))
                            .font(SQFont.display(24, .heavy, relativeTo: .title2))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                        Text(verbatim: SQUnits.throughputUnit(mbps: download))
                            .font(SQType.caption(.semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                } else {
                    Text("Résultat indisponible")
                        .font(SQType.subhead(.bold))
                        .foregroundStyle(SQColor.ink2)
                }
                FeedNetworkLine(operator: signal?.servingOperator ?? signal?.operator, technology: signal?.technology)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Test de débit joint"))
        .accessibilityIdentifier("feed.speedtest.attachment")
    }

    // MARK: Commun

    private func postText(_ text: String) -> some View {
        Text(text)
            .font(SQType.body)
            .lineSpacing(3)
            .foregroundStyle(SQColor.label)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("feed.post.text")
    }

    /// Débit de réception réellement mesuré ; zéro ou absent ne s'affiche pas.
    private var measuredDownload: Double? {
        guard let download = signal?.downloadMbps, download > 0 else { return nil }
        return download
    }

    /// SIM d'origine, montrée seulement quand elle voyage.
    private var roamingDetail: String? {
        guard signal?.isRoaming == true, let sim = signal?.simOperator else { return nil }
        return String(localized: "SIM \(sim)")
    }
}
