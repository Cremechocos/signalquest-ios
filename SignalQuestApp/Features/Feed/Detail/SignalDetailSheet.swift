import SwiftUI
import MapKit

/// Publication ouverte depuis une carte du fil : en-tête de la carte, texte,
/// bloc de mesure, toutes les valeurs connues en lignes clé-valeur, mini-carte,
/// actions, puis le premier commentaire.
struct SignalDetailSheet: View {
    let item: UnifiedSocialFeedItem
    var onLike: () -> Void = {}
    var onRepost: () -> Void = {}
    var onFavorite: () -> Void = {}
    var onComment: () -> Void = {}
    var onShare: () -> Void = {}
    var onMute: () -> Void = {}
    var onReport: () -> Void = {}
    /// Vote sur le sondage de la publication. Sans lui, le sondage n'est pas montré.
    var onPollVote: ((FeedPoll.Option) -> Void)? = nil
    /// Tap sur l'auteur — le parent ferme le sheet et pousse le profil.
    var onAuthorTap: (() -> Void)? = nil
    var actionError: String? = nil
    var actionBusy = false

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var speedtestDetail: SpeedtestDetail?
    @State private var detailError: String?
    /// Le serveur a refusé le détail : test fait dans une zone privée de son auteur.
    @State private var detailsHiddenByServer = false
    /// Premier commentaire, montré sous les actions : la conversation se lit
    /// sans ouvrir une deuxième feuille.
    @State private var firstComment: SocialComment?
    /// Photo de la publication ouverte en plein écran.
    @State private var viewerImage: MessageImageTarget?

    private var signal: SocialSignalSummary? { item.signal }
    private var detailsHidden: Bool { signal?.detailsHidden == true || detailsHiddenByServer }
    private var accent: Color { TechAccent.color(for: signal?.technology) }
    private var isSpeedtest: Bool { item.kind.lowercased() == "speedtest" }
    private var place: String? { signal?.city ?? item.placeLabel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                topBar
                CardHeader(
                    author: item.author,
                    place: place,
                    createdAt: item.createdAt,
                    kindBadge: kindTag,
                    kindColor: kindColor,
                    onAuthorTap: onAuthorTap.map { tap in { dismiss(); tap() } },
                    isPinned: item.isPinned
                )
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("signal.detail.actionError")
                }
                if actionBusy {
                    ProgressView("En cours")
                        .tint(SQColor.brandRed)
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(SQFont.body(16, .regular, relativeTo: .body))
                        .lineSpacing(4)
                        .foregroundStyle(SQColor.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let poll = item.poll, let onPollVote {
                    FeedPollView(poll: poll, onVote: onPollVote)
                }
                if !item.hashtags.isEmpty {
                    CardHashtags(tags: item.hashtags)
                }
                media
                if isSpeedtest {
                    FeedMeasureBlock(signal: signal)
                }
                detailsSection
                map
                CardActionsBar(
                    item: item,
                    onLike: onLike,
                    onRepost: onRepost,
                    onComment: onComment,
                    onFavorite: onFavorite,
                    onShare: onShare
                )
                commentsPreview
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .task(id: item.sourceId) { await loadSpeedtestDetailIfNeeded() }
        .task(id: item.id) { await loadFirstCommentIfNeeded() }
        .presentationDetents([.medium, .large])
        .sqSheet()
        .fullScreenCover(item: $viewerImage) { target in
            MessageImageViewer(target: target)
        }
    }

    // MARK: Header

    /// Fermer à gauche, ⋯ à droite, sans titre : l'auteur ouvre la feuille.
    private var topBar: some View {
        HStack {
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "signal.detail.close") {
                dismiss()
            }
            Spacer(minLength: 0)
            Menu {
                // Pas de `dismiss()` ici : le parent remplace la fiche par
                // le signalement ; fermer en plus annulait cette présentation (AF-FIL-02).
                // On ne signale pas sa propre publication.
                if !item.canManage {
                    Button(role: .destructive) { onReport() } label: {
                        Label("Signaler", systemImage: "flag")
                    }
                }
                Button { onMute() } label: {
                    Label(
                        item.notificationsMutedByMe == true ? "Réactiver les notifications" : "Couper les notifications",
                        systemImage: item.notificationsMutedByMe == true ? "bell" : "bell.slash"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .sqSurface(SQColor.chip, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Plus d’options")
            .accessibilityIdentifier("signal.detail.more")
        }
    }

    /// Badge réservé aux photos d'antenne et aux pannes, comme sur les cartes
    /// du fil ; jamais le type brut (« DRIVE_TEST », TRX-26).
    private var kindTag: String? {
        switch item.kind.lowercased() {
        // Même état que la carte du fil (Rétabli / Dégradé / Panne), lu dans la metadata.
        case "outage": return OutageFeedBadge.label(severity: metaString("outageSeverity"), state: metaString("outageState"))
        case "photo", "antenna_photo": return String(localized: "Photo d’antenne")
        default: return nil
        }
    }

    private var kindColor: Color {
        item.kind.lowercased() == "outage"
            ? OutageFeedBadge.ink(severity: metaString("outageSeverity"), state: metaString("outageState"))
            : accent
    }

    // MARK: Metadata

    private func metaString(_ key: String) -> String? {
        guard case .string(let value)? = item.metadata?[key], !value.isEmpty else { return nil }
        return value
    }

    private func metaInt(_ key: String) -> Int? {
        guard case .number(let value)? = item.metadata?[key] else { return nil }
        return Int(value)
    }

    private func metaFlag(_ key: String) -> Bool {
        guard case .bool(let value)? = item.metadata?[key] else { return false }
        return value
    }

    // MARK: Media

    /// Photos de la publication, en entier : la carte du fil les recadre, la
    /// publication complète les montre telles quelles. Un toucher ouvre le plein écran.
    static func images(of item: UnifiedSocialFeedItem) -> [(id: String, url: URL, label: String)] {
        // La règle « image seulement » vit sur `UnifiedSocialFeedItem.imageAttachments`,
        // partagée avec les cartes du fil.
        item.imageAttachments.compactMap { attachment in
            guard let url = attachment.url ?? attachment.thumbnailUrl else { return nil }
            return (attachment.id, url, attachment.trimmedAltText ?? String(localized: "Photo de la publication"))
        }
    }

    @ViewBuilder
    private var media: some View {
        let images = Self.images(of: item)
        if images.count == 1, let image = images.first {
            mediaImage(id: image.id, url: image.url, label: image.label)
        } else if images.count > 1 {
            TabView {
                ForEach(images, id: \.id) { image in
                    mediaImage(id: image.id, url: image.url, label: image.label)
                        .padding(.bottom, SQSpace.xl)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(height: 380)
        }
    }

    private func mediaImage(id: String, url: URL, label: String) -> some View {
        Button {
            Haptics.light()
            viewerImage = MessageImageTarget(id: id, url: url, accountSession: nil)
        } label: {
            RemoteImage(url: url, maxDimension: 1200, contentMode: .fit, showsFailureUI: true) {
                Rectangle()
                    .fill(SQColor.surfaceMuted)
                    .frame(height: 240)
                    .overlay(SQSpinner())
            }
            .frame(maxWidth: .infinity, maxHeight: 440)
            .background(SQColor.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityHint(String(localized: "Ouvre la photo en plein écran"))
        .accessibilityIdentifier("signal.detail.photo")
    }

    // MARK: Details

    /// Toutes les valeurs connues en lignes clé-valeur sur une seule carte.
    @ViewBuilder
    private var detailsSection: some View {
        let pairs = detailPairs
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Détails")
                    .sqKicker()
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: SQSpace.sm2) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        SQFactRow(label: pair.0, value: pair.1)
                    }
                }
                .padding(SQSpace.lg)
                .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .accessibilityIdentifier("signal.detail.facts")
            }
        }
        if let detailError {
            Label(detailError, systemImage: "exclamationmark.triangle")
                .font(SQType.caption)
                .foregroundStyle(SQColor.dangerInk)
        }
    }

    private var detailPairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let signal {
            pairs += metricPairs(for: signal)
            pairs += [
                ("EARFCN", signal.earfcn.map(String.init) ?? ""),
                ("ARFCN", signal.arfcn.map(String.init) ?? ""),
                ("Secteurs", signal.sectors?.prefix(4).map(String.init).joined(separator: " · ") ?? ""),
                ("Appareil", signal.deviceModel ?? "")
            ]
        }
        pairs += outagePairs
        pairs += speedtestPairs
        pairs.append(("Lieu", place ?? ""))
        // Une clé n'apparaît qu'une fois : le détail serveur et le résumé du
        // post se recoupent (appareil, opérateur).
        var seen = Set<String>()
        return pairs.filter { pair in
            guard !pair.1.isEmpty, pair.1 != "—", !seen.contains(pair.0) else { return false }
            seen.insert(pair.0)
            return true
        }
    }

    private func metricPairs(for signal: SocialSignalSummary) -> [(String, String)] {
        switch item.kind.lowercased() {
        case "speedtest":
            let detail = speedtestDetail
            return [
                // Le bloc de mesure affiche la réception du résumé ; le détail
                // serveur la complète quand le résumé ne l'a pas.
                ("Réception", signal.downloadMbps == nil
                    ? SignalFormatters.speed(detail?.averageSpeed ?? detail?.downloadAvg) : ""),
                ("Opérateur", signal.servingOperator ?? signal.operator ?? detail?.mobileOperator ?? ""),
                ("SIM", signal.isRoaming == true ? signal.simOperator ?? "" : ""),
                ("Technologie", signal.technology ?? detail?.networkType ?? ""),
                ("Latence min", SignalFormatters.ms(detail?.pingMin ?? detail?.ping ?? signal.pingMs)),
                ("Gigue", SignalFormatters.ms(detail?.jitter ?? signal.jitterMs))
            ]
        case "validation":
            return [
                ("Identifiant", signal.identifierValue ?? ""),
                ("Type", signal.identifierType?.uppercased() ?? ""),
                ("PCI", signal.pci.map(String.init) ?? ""),
                ("Cell", signal.cellId ?? ""),
                ("Bande", signal.band ?? ""),
                ("Fréquence", signal.frequency ?? "")
            ]
        case "outage":
            // Une panne n'a pas de mesure radio : ses valeurs viennent de la metadata (`outagePairs`).
            return []
        case "rating":
            return ratingPairs(for: signal) + radioPairs(for: signal)
        case "coverage", "session", "drive_test":
            return [
                ("Distance", SignalFormatters.meters(signal.distanceMeters)),
                ("Durée", SignalFormatters.duration(signal.durationSeconds)),
                ("Points", signal.pointsCount.map(String.init) ?? ""),
                ("Signal moy.", SignalFormatters.dbm(signal.averageSignalDbm)),
                ("Min / Max", rangeText(signal: signal)),
                ("Techs", signal.detectedTechs.prefix(3).joined(separator: " / "))
            ]
        default:
            return radioPairs(for: signal)
        }
    }

    private func radioPairs(for signal: SocialSignalSummary) -> [(String, String)] {
        [
            ("Opérateur", signal.operator ?? ""),
            ("RSRP", SignalFormatters.dbm(signal.rsrp)),
            ("RSRQ", SignalFormatters.db(signal.rsrq)),
            ("SINR", SignalFormatters.db(signal.sinr)),
            ("Bande", signal.band ?? ""),
            ("Cell", signal.cellId ?? "")
        ]
    }

    /// Note en étoiles et tendance, comme la carte d'évaluation du fil.
    private func ratingPairs(for signal: SocialSignalSummary) -> [(String, String)] {
        let trend: String
        switch signal.ratingTrend?.lowercased() {
        case "improved": trend = String(localized: "En hausse")
        case "degraded": trend = String(localized: "En baisse")
        case "same": trend = String(localized: "Stable")
        default: trend = ""
        }
        return [
            ("Note", signal.ratingStars.map { "\(max(0, min(5, $0))) / 5" } ?? ""),
            ("Tendance", trend)
        ]
    }

    /// Gravité, état, services touchés et confirmations d'une panne, lus dans la
    /// metadata du post exactement comme `OutageCardView`.
    private var outagePairs: [(String, String)] {
        guard item.kind.lowercased() == "outage" else { return [] }
        let severity = OutageSeverity(rawServerValue: metaString("outageSeverity"))
        let state = OutageState(rawServerValue: metaString("outageState"))
        let stateText: String
        if metaFlag("outageOperatorConfirmed") {
            stateText = String(localized: "Confirmée par l'opérateur")
        } else {
            switch state {
            case .resolved: stateText = String(localized: "Rétablie")
            case .confirmed: stateText = String(localized: "Confirmée")
            case .reported: stateText = String(localized: "À confirmer")
            default: stateText = ""
            }
        }
        var services = OutageServices.label(
            data: metaFlag("outageAffectsData"),
            voice: metaFlag("outageAffectsVoice"),
            sms: metaFlag("outageAffectsSms")
        )
        // Posts antérieurs aux drapeaux : la phrase du serveur sert de repli.
        if services.isEmpty { services = metaString("outageServices") ?? "" }
        let confirmations = metaInt("outageConfirmCount").flatMap { $0 > 0 ? String($0) : nil } ?? ""
        return [
            ("Opérateur", metaString("operator") ?? metaString("operatorKey") ?? ""),
            ("Gravité", severity == .degraded ? String(localized: "Réseau dégradé") : String(localized: "Plus de réseau")),
            ("État", stateText),
            ("Touché", OutageTechnologies.detail(services: services, csv: metaString("outageTechnologies"))),
            ("Confirmations", confirmations)
        ]
    }

    private var speedtestPairs: [(String, String)] {
        guard let detail = speedtestDetail else { return [] }
        let uploadSource = SpeedtestDetailContent.resultByteSource(
            detail.measurementTrace?.phases.first(where: { $0.phase == "upload" }), fallback: detail.uploadMeasurementSource)
        return [
            ("Réseau", [detail.connectionType, detail.networkType].compactMap { $0 }.joined(separator: " / ")),
            ("Appareil", [detail.deviceType, detail.deviceModel].compactMap { $0 }.joined(separator: " ")),
            ("Durée", SignalFormatters.duration(detail.testDuration)),
            ("Latence moyenne", SignalFormatters.ms(detail.pingAvg)),
            ("Latence médiane", SignalFormatters.ms(detail.pingMedian)),
            ("Latence max", SignalFormatters.ms(detail.pingMax)),
            ("Octets envoi", uploadSource == "tcp-acknowledged"
                ? SpeedtestDetailContent.byteSourceLabel("tcp-acknowledged") : ""),
            ("Position", coordinatesText(lat: detail.latitude, lon: detail.longitude))
        ]
    }

    // MARK: Comments

    /// Premier commentaire et lien vers la conversation, ou une invitation à
    /// commenter quand il n'y en a pas encore.
    private var commentsPreview: some View {
        let count = item.commentsCount
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            Divider().overlay(SQColor.separator)
            Button {
                Haptics.light()
                onComment()
            } label: {
                VStack(alignment: .leading, spacing: SQSpace.sm2) {
                    if let comment = firstComment {
                        HStack(alignment: .top, spacing: SQSpace.sm2) {
                            SQAvatar(url: comment.author.avatarUrl, name: comment.author.displayName, size: 30)
                            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                                HStack(spacing: SQSpace.xs) {
                                    Text(comment.author.displayName)
                                        .font(SQType.caption(.bold))
                                        .foregroundStyle(SQColor.label)
                                    if let created = comment.createdAt {
                                        Text(verbatim: "·").accessibilityHidden(true)
                                        Text(created, format: .sqRelative)
                                    }
                                }
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                Text(comment.text)
                                    .font(SQType.subhead)
                                    .foregroundStyle(SQColor.label)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                    Text(count > 0 ? "Voir les \(count) commentaires" : "Ajouter un commentaire")
                        .font(SQType.subhead(.bold))
                        .foregroundStyle(SQColor.accentInk)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("signal.detail.comments")
        }
    }

    private func loadFirstCommentIfNeeded() async {
        guard item.commentsCount > 0 else { return }
        // Silencieux en cas d'échec : le lien vers les commentaires reste.
        firstComment = try? await services.comments.list(postId: item.backendPostId, cursor: nil).comments.first
    }

    private func rangeText(signal: SocialSignalSummary) -> String {
        switch (signal.minSignalDbm, signal.maxSignalDbm) {
        case (let min?, let max?):
            return "\(Int(min)) / \(Int(max)) dBm"
        case (let min?, nil):
            return SignalFormatters.dbm(min)
        case (nil, let max?):
            return SignalFormatters.dbm(max)
        default:
            return "—"
        }
    }

    // MARK: Map

    @ViewBuilder
    private var map: some View {
        if detailsHidden {
            Label("Détails masqués : seul l’auteur peut les voir", systemImage: "lock")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityIdentifier("signal.detail.hidden")
        } else if let lat = item.latitude ?? signal?.latitude ?? speedtestDetail?.latitude,
           let lng = item.longitude ?? signal?.longitude ?? speedtestDetail?.longitude {
            let center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
            SQRegionMap(region: .constant(region), items: [SQMapPin(coordinate: center)]) { pin in
                MapMarker(coordinate: pin.coordinate, tint: accent)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        } else if item.kind.lowercased() == "speedtest" {
            Label("Localisation non partagée", systemImage: "location.slash")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func coordinatesText(lat: Double?, lon: Double?) -> String {
        guard let lat, let lon else { return "" }
        return String(format: "%.5f, %.5f", lat, lon)
    }

    private func loadSpeedtestDetailIfNeeded() async {
        guard item.kind.lowercased() == "speedtest",
              let sourceId = item.sourceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceId.isEmpty, signal?.detailsHidden != true else { return }
        do {
            speedtestDetail = try await services.speedtest.details(id: sourceId)
            detailError = nil
        } catch APIError.http(_, "SPEEDTEST_DETAILS_HIDDEN", _, _, _) {
            detailsHiddenByServer = true
        } catch {
            // Le résumé du post reste une source valide : l'échec du détail ne
            // doit pas transformer une publication lisible en écran d'erreur.
            if signal == nil {
                detailError = String(localized: "Détails momentanément indisponibles")
            }
        }
    }
}

