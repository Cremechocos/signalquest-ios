import Foundation
import UIKit

/// Partage d'une publication dans une conversation v2 (E2EE-AUTO §7.7, `CARD` `POST`) :
/// l'app construit elle-même l'instantané que le serveur écrit en clair ailleurs
/// (`POST /api/social/posts/{id}/share` répond `409 E2EE_SHARE_REQUIRES_CLIENT` ici).
/// Aucune URL dans la carte ; l'image, ré-encodée, part en blob chiffré.
enum E2EEAutoPostShare {
    /// L'émetteur coupe à 280 caractères affichés, comme la carte en clair.
    static let maxTextCharacters = 280

    /// Mêmes refus que le partage en clair : zone privée, publication inactive.
    static func canShare(_ item: UnifiedSocialFeedItem) -> Bool {
        item.isShareable && (item.status == nil || item.status == "active") && item.createdAt != nil
    }

    /// Instantané de la publication, sans son image. `nil` si elle ne se partage pas.
    static func card(_ item: UnifiedSocialFeedItem) -> E2EEAutoMediaOutbox.Card? {
        guard canShare(item), let createdAt = item.createdAt else { return nil }
        let postId = item.backendPostId
        guard E2EEV2Canonical.isOpaque(postId) else { return nil }
        let authorId = E2EEV2Canonical.isOpaque(item.author.id) ? item.author.id : nil
        let handle = item.author.handle.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }
        let collapsed = item.displayText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return .init(
            postId: postId, authorId: authorId,
            authorName: bounded(item.author.name, maxBytes: 256),
            authorHandle: bounded(handle, maxBytes: 64),
            postedAt: isoMs(createdAt),
            text: bounded(String(collapsed.prefix(maxTextCharacters)), maxBytes: 2_048),
            measure: measure(item.signal)
        )
    }

    /// La mesure que montre la carte en clair, dans le même ordre de choix
    /// (speedtest, puis session, puis signal).
    static func measure(_ summary: SocialSignalSummary?) -> E2EEAutoContentR17.Measure? {
        guard let summary else { return nil }
        let type = summary.type?.lowercased()
        if type == "speedtest", let down = summary.downloadMbps.flatMap(fixed2) {
            return .speedtest(
                downloadMbps: down, uploadMbps: summary.uploadMbps.flatMap(fixed2), pingMs: summary.pingMs.flatMap(fixed2),
                technology: bounded(summary.technology, maxBytes: 32), operator: bounded(summary.operator, maxBytes: 128)
            )
        }
        if type == "session", summary.pointsCount != nil || summary.distanceMeters != nil {
            func integer(_ value: Double?, _ range: ClosedRange<Int64>) -> Int64? {
                guard let value, value.isFinite else { return nil }
                let rounded = Int64(value.rounded())
                return range.contains(rounded) ? rounded : nil
            }
            let points = summary.pointsCount.map(Int64.init).flatMap { (0...10_000_000).contains($0) ? $0 : nil }
            return .session(
                points: points, distanceMeters: integer(summary.distanceMeters, 0...100_000_000),
                durationSeconds: integer(summary.durationSeconds, 0...31_536_000),
                technologies: summary.detectedTechs.compactMap { bounded($0, maxBytes: 32) }.prefix(10).map { $0 }
            )
        }
        if summary.rsrp != nil || summary.technology != nil {
            let rsrp = summary.rsrp.flatMap { value -> Int? in
                guard value.isFinite else { return nil }
                let rounded = Int(value.rounded())
                return (-200...0).contains(rounded) ? rounded : nil
            }
            // Un site exploré en zone privée n'est pas nommé, comme dans la carte en clair.
            let site = summary.detailsHidden == true ? nil : summary.siteLabel
            return .signal(
                rsrp: rsrp, band: bounded(summary.band, maxBytes: 16), site: bounded(site, maxBytes: 256),
                operator: bounded(summary.operator, maxBytes: 128), technology: bounded(summary.technology, maxBytes: 32)
            )
        }
        return nil
    }

    /// Décimal à deux chiffres après la virgule au plus (`"842.5"`), sans zéro inutile.
    static func fixed2(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        let hundredths = (value * 100).rounded()
        guard hundredths < 1_000_000_000 else { return nil }
        let whole = Int64(hundredths) / 100
        let fraction = Int64(hundredths) % 100
        if fraction == 0 { return String(whole) }
        return fraction % 10 == 0 ? "\(whole).\(fraction / 10)" : String(format: "%lld.%02lld", whole, fraction)
    }

    /// Image de la carte : la première image de la publication, ré-encodée en JPEG
    /// sans métadonnée, 1 280 px de côté et 512 Kio au plus.
    static func imageURL(_ item: UnifiedSocialFeedItem) -> URL? {
        let image = item.attachments.first { $0.isDisplayableImage && ($0.thumbnailUrl ?? $0.url) != nil }
        return image.flatMap { $0.thumbnailUrl ?? $0.url }
    }

    static func preview(_ image: UIImage) -> E2EEAutoMediaSource? {
        for side in [1_280, 960, 640] as [CGFloat] {
            guard let data = image.jpegData(compressionQuality: 1),
                  let scaled = ImagePipeline.downsample(data: data, maxPixel: side), let cgImage = scaled.cgImage,
                  max(cgImage.width, cgImage.height) <= E2EEAutoContentR17.maxPreviewSide else { continue }
            for quality in [0.8, 0.6, 0.45] as [CGFloat] {
                if let jpeg = scaled.jpegData(compressionQuality: quality),
                   jpeg.count <= Int(E2EEAutoContentR17.maxPostImageBytes) {
                    return E2EEAutoMediaSource(
                        data: jpeg, fileName: "image.jpg", mimeType: "image/jpeg",
                        width: cgImage.width, height: cgImage.height, durationMs: nil, thumbnail: nil
                    )
                }
            }
        }
        return nil
    }

    /// Envoie la carte par la file durable des pièces chiffrées. Sans image lisible,
    /// la carte part sans elle. `false` si l'envoi n'a pas abouti.
    static func send(
        _ item: UnifiedSocialFeedItem, to conversation: MessageConversation, messaging: E2EEV2MessagingRuntime
    ) async -> Bool {
        guard let card = card(item), let scope = LocalAccountScope.sessionSnapshot()?.ownerScopeId,
              let (client, ownerScopeId) = messaging.blobClient(), ownerScopeId == scope else { return false }
        var sources: [E2EEAutoMediaSource] = []
        if let url = imageURL(item),
           let image = try? await ImagePipeline.shared.image(for: url, maxPixel: CGFloat(E2EEAutoContentR17.maxPreviewSide)),
           let source = preview(image) {
            sources = [source]
        }
        guard let record = try? await E2EEAutoMediaOutbox.shared.stage(
            sources, card: card, caption: nil, replyToRef: nil, ttlSeconds: 0, conversationId: conversation.id,
            isGroup: conversation.isGroup, participantIds: conversation.participants.map(\.userId), ownerScopeId: scope
        ) else { return false }
        let outcome = await E2EEAutoMediaOutbox.shared.process(
            clientRequestId: record.key, ownerScopeId: scope, client: client, cache: .shared
        ) { draft, record in
            await messaging.send(
                draft, clientRequestId: record.clientRequestId, conversationId: record.conversationId,
                isGroup: record.isGroup, participantIds: record.participantIds
            )
        }
        switch outcome {
        case .sent:
            return true
        case .retry, .throttled, .failed:
            // Rien ne reste dans la file : l'échec s'affiche dans la feuille, qu'on peut relancer.
            await E2EEAutoMediaOutbox.shared.remove(record.clientRequestId, ownerScopeId: scope)
            return false
        }
    }

    /// Carte reçue, sous la forme de la carte en clair : sans URL ni image distante (l'aperçu
    /// chiffré s'affiche comme pièce du message) et sans identifiant de chargement en direct.
    static func shareCardData(_ card: E2EEAutoContentR17.PostCard) -> ShareCardData {
        var signal: SignalShareData?
        var speedtest: SpeedtestShareData?
        var session: SessionShareData?
        switch card.measure {
        case .speedtest(let down, let up, let ping, let technology, let op)?:
            speedtest = .init(
                downloadMbps: Double(down), uploadMbps: up.flatMap(Double.init), pingMs: ping.flatMap(Double.init),
                technology: technology, operatorName: op
            )
        case .session(let points, let distance, let duration, let technologies)?:
            session = .init(
                points: points.map { Int($0) }, distanceKm: distance.map { Double($0) / 1_000 },
                durationSeconds: duration.map { Int($0) },
                technologies: technologies.isEmpty ? nil : technologies.joined(separator: " · ")
            )
        case .signal(let rsrp, let band, let site, let op, let technology)?:
            signal = .init(rsrp: rsrp, band: band, site: site, operatorName: op, technology: technology, stars: nil, score: nil)
        case nil:
            break
        }
        let author = ShareCardAuthor(name: card.authorName, handle: card.authorHandle, avatarUrl: nil)
        return ShareCardData(
            kind: "social_post", targetId: nil, title: String(localized: "Publication SignalQuest"),
            subtitle: author.displayName, url: nil, rows: [], signal: signal, author: author, text: card.text,
            imageUrl: nil, speedtest: speedtest, session: session
        )
    }

    static func isoMs(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000))
    }

    /// Texte non vide de 1 à `maxBytes` octets UTF-8, coupé sans casser un caractère.
    static func bounded(_ value: String?, maxBytes: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        for character in value {
            guard result.utf8.count + String(character).utf8.count <= maxBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }
}
