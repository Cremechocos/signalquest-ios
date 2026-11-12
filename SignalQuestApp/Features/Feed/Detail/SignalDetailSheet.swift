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
    /// Détail d'un test d'expérience : les tests servis, et la ville pour l'auteur.
    @State private var experienceDetail: ExperienceTestDetail?
    @State private var experienceState: ExperienceDetailState = .loading
    /// Test du détail ouvert depuis la liste des tests.
    @State private var openedExperienceTest: OpenedExperienceTest?
    /// Image de partage, préparée pour l'auteur seul.
    @State private var experienceShare: ExperienceShareInput?
    @State private var detailError: String?
    /// Le serveur a refusé le détail : test fait dans une zone privée de son auteur.
    @State private var detailsHiddenByServer = false
    /// Premier commentaire, montré sous les actions : la conversation se lit
    /// sans ouvrir une deuxième feuille.
    @State private var firstComment: SocialComment?
    /// Photo de la publication ouverte en plein écran.
    @State private var viewerImage: MessageImageTarget?
    /// Session ouverte par « Voir la session ».
    @State private var openedSession: OpenedSession?

    private struct OpenedSession: Identifiable { let id: String }

    private var signal: SocialSignalSummary? { item.signal }
    private var detailsHidden: Bool { signal?.detailsHidden == true || detailsHiddenByServer }
    private var accent: Color { TechAccent.color(for: signal?.technology) }
    private var isSpeedtest: Bool { item.cardKind == "speedtest" }
    private var place: String? { signal?.city ?? item.readablePlaceLabel }
    private var experience: FeedExperience? { FeedExperience(item: item) }

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
                    SQInlineError(message: actionError)
                }
                if actionBusy {
                    ProgressView("En cours")
                        .tint(SQColor.brandRed)
                }
                // Post automatique : le même résumé que sa carte, et le lien vers
                // ce qu'il raconte, plutôt que le texte français du serveur (F2).
                if let activity = FeedActivity(item: item) {
                    ActivitySummaryRow(activity: activity)
                    if let description = activity.quest?.description {
                        Text(verbatim: description)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("signal.detail.questDescription")
                    }
                    if let link = activity.link {
                        GradientButton(link.title, systemImage: link.symbol, style: .secondary) {
                            Haptics.selection()
                            dismiss()
                            link.open(with: services.router)
                        }
                        .accessibilityIdentifier("feed.detail.activityLink")
                    }
                } else if let text = item.cardText {
                    Text(text)
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
                photoSiteLink
                if isSpeedtest {
                    // La fiche unique du test, comme depuis l'historique (revue q34, lot C) ;
                    // le bloc du fil tant qu'elle n'est pas chargée ou si le détail est caché.
                    if let speedtestResult {
                        SpeedtestDetailContent(result: speedtestResult)
                            .padding(.horizontal, -SQSpace.lg)
                    } else {
                        FeedMeasureBlock(signal: signal)
                    }
                }
                if let experience {
                    experienceSummary(experience)
                }
                if let block = item.session {
                    // Post de trajet : le résumé de sa carte, sans l'ancienne fiche radio.
                    FeedKindLine(symbol: block.source == .driveTest ? "car" : "point.topleft.down.curvedto.point.bottomright.up",
                                 title: SessionPostText.title(block.source), points: item.earnedPoints)
                    SessionPostSummary(block: block)
                        .accessibilityIdentifier("signal.detail.sessionPost")
                } else {
                    detailsSection
                }
                map
                CardActionsBar(
                    item: item,
                    onLike: onLike,
                    onRepost: onRepost,
                    onComment: onComment,
                    onFavorite: onFavorite,
                    onShare: onShare
                )
                // Hors d'une carte, la barre est un élément à part : son nom
                // précède les compteurs et les actions qu'elle porte.
                .accessibilityLabel("Actions")
                commentsPreview
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .task(id: speedtestId) { await loadSpeedtestDetailIfNeeded() }
        .task(id: experience?.testId) { await loadExperienceDetailIfNeeded() }
        .task(id: item.id) { await loadFirstCommentIfNeeded() }
        .presentationDetents([.medium, .large])
        .sqSheet()
        .fullScreenCover(item: $viewerImage) { target in
            MessageImageViewer(target: target)
        }
        .sheet(item: $openedExperienceTest) { opened in
            if let experienceDetail {
                ScrollView {
                    ExperienceDetailView(tests: experienceDetail.result, methodology: experienceDetail.methodology, test: opened.test) {
                        openedExperienceTest = nil
                    }
                    .padding(SQSpace.lg)
                    .sqReadableWidth()
                }
                .presentationDetents([.large])
                .sqSheet()
            }
        }
        .sheet(item: $experienceShare) { ExperienceSharePreviewSheet(input: $0) }
        .fullScreenCover(item: $openedSession) { opened in
            SharedSessionDetailView(sessionId: opened.id)
                .environmentObject(services)
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
        case "post" where FeedActivity(item: item)?.family == .officialRecap: return String(localized: "Officiel")
        default: return nil
        }
    }

    private var kindColor: Color {
        item.kind.lowercased() == "outage"
            ? OutageFeedBadge.ink(severity: metaString("outageSeverity"), state: metaString("outageState"))
            : accent
    }

    // MARK: Experience

    enum ExperienceDetailState: Equatable {
        case loading, loaded, unavailable, failed(String)
    }

    struct OpenedExperienceTest: Identifiable {
        let test: ExperienceTestKind
        var id: String { test.rawValue }
    }

    /// Maquette validée le 27/10 : la note globale et les 4 usages, puis le détail de
    /// chaque test servi par `GET /api/experience-tests/{id}`, pour tout lecteur du post.
    private func experienceSummary(_ experience: FeedExperience) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Test d’expérience")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                if let context = experience.networkContext {
                    Text(verbatim: context)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            if let experienceDetail {
                experienceLoaded(experienceDetail)
            } else {
                // Avant le détail, ou sans lui : les valeurs du post.
                if !experience.highlights.feedMetrics.isEmpty {
                    FeedMetricGrid(metrics: experience.highlights.feedMetrics)
                }
                switch experienceState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Chargement du test")
                case .unavailable:
                    // Post en « Amis » vu par un non-ami, ou test retiré : sans erreur (maquette).
                    Text("Test non disponible")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityIdentifier("signal.detail.experience.unavailable")
                case .failed(let message):
                    SQNotice(message: message, tone: .warning)
                case .loaded:
                    EmptyView()
                }
            }
        }
        .accessibilityIdentifier("signal.detail.experience")
    }

    @ViewBuilder
    private func experienceLoaded(_ detail: ExperienceTestDetail) -> some View {
        let scores = ExperienceScores(detail.result)
        if !scores.isEmpty {
            ExperienceOverallScoreCard(scores: scores)
        }
        if item.canManage, let input = experienceShareInput(detail) {
            GradientButton("Télécharger l’image", systemImage: "square.and.arrow.down", style: .secondary) {
                Haptics.selection()
                experienceShare = input
            }
            .accessibilityIdentifier("signal.detail.experience.image")
        }
        let items = ExperienceUseItem.items(detail.result, methodology: detail.methodology)
        if !items.isEmpty {
            Text("Détail des tests")
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
            ExperienceUseList(items: items, identifier: "signal.detail.experience") {
                openedExperienceTest = OpenedExperienceTest(test: $0)
            }
        }
        if let line = experienceUsageLine(detail) {
            Text(verbatim: line)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// « Données utilisées : 81,9 Mo · durée 34 s », avec ce que le serveur a servi.
    private func experienceUsageLine(_ detail: ExperienceTestDetail) -> String? {
        switch (detail.bytesUsed, detail.durationMs) {
        case let (bytes?, duration?):
            String(localized: "Données utilisées : \(ExperienceResultText.megabytes(bytes)) · durée \(ExperienceResultText.duration(seconds: Int(duration / 1_000)))")
        case let (bytes?, nil):
            String(localized: "Données utilisées : \(ExperienceResultText.megabytes(bytes))")
        default:
            nil
        }
    }

    /// L'image validée (PNG 1200 × 630), seulement quand un test est mesuré.
    private func experienceShareInput(_ detail: ExperienceTestDetail) -> ExperienceShareInput? {
        guard let measuredAt = detail.measuredAt,
              ExperienceTestKind.allCases.contains(where: { detail.result.state(of: $0) == .measured }) else { return nil }
        return ExperienceShareInput(
            tests: ExperienceSubmission.tests(detail.result), scores: detail.scores, measuredAt: measuredAt,
            connectionType: detail.network?.connectionType ?? "unknown",
            technology: detail.network?.technology, operatorKey: detail.network?.operatorKey
        )
    }

    private var experiencePairs: [(String, String)] {
        // La ville n'est montrée qu'à l'auteur ; le serveur la retire déjà pour les autres.
        guard item.canManage, let city = experienceDetail?.location?.city else { return [] }
        return [("Lieu", city)]
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

    /// Clé de la fiche d'antenne d'un post photo (contrat social-photo-post v1, #827) : le
    /// support, son marché et la clé d'opérateur enregistrés avec la photo. Sans marché ou
    /// sans clé d'opérateur, pas de lien : on ne devine jamais la clé depuis le libellé.
    static func photoSiteKey(of item: UnifiedSocialFeedItem) -> (siteId: String, market: String, operatorKey: String)? {
        guard ["photo", "antenna_photo"].contains(item.kind.lowercased()) else { return nil }
        func value(_ key: String) -> String? {
            guard case .string(let raw)? = item.metadata?[key] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let siteId = value("siteId"), let market = value("marketCode"), let operatorKey = value("operatorKey")
        else { return nil }
        return (siteId, market, operatorKey)
    }

    @ViewBuilder
    private var photoSiteLink: some View {
        if let key = Self.photoSiteKey(of: item) {
            GradientButton("Voir le site", systemImage: "mappin.and.ellipse", style: .secondary) {
                Haptics.selection()
                dismiss()
                services.router.route(toSite: key.siteId, market: key.market, operatorKey: key.operatorKey)
            }
            .accessibilityIdentifier("signal.detail.openSite")
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
        // La fiche du test dit déjà tout ce qu'il y a à savoir sur la mesure.
        guard speedtestResult == nil else { return [] }
        var pairs: [(String, String)] = []
        if let signal {
            pairs += metricPairs(for: signal)
            pairs += [
                ("EARFCN", signal.earfcn.map(String.init) ?? ""),
                ("ARFCN", signal.arfcn.map(String.init) ?? ""),
                ("Secteurs", signal.sectors?.prefix(4).map(String.init).joined(separator: " · ") ?? ""),
                // Le modèle d'appareil ne sert qu'à l'auteur (lot F, F-05).
                ("Appareil", item.canManage ? signal.deviceModel ?? "" : "")
            ]
        }
        pairs += outagePairs
        pairs += photoPairs
        pairs += questPairs
        pairs += experiencePairs
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

    /// Quête atteinte (#835) : sa fréquence et son objectif ; les points gagnés sont dans le résumé.
    private var questPairs: [(String, String)] {
        guard let quest = FeedActivity(item: item)?.quest else { return [] }
        return [
            ("Fréquence", quest.cadence?.frequency ?? ""),
            ("Objectif", quest.goal ?? "")
        ]
    }

    /// L'antenne photographiée (#827) : opérateur et adresse du support, tels qu'enregistrés avec la photo.
    private var photoPairs: [(String, String)] {
        guard ["photo", "antenna_photo"].contains(item.kind.lowercased()) else { return [] }
        let label = metaString("operatorKey") ?? metaString("operator")
        return [
            ("Opérateur", SQBrand.operatorName(label) ?? metaString("operator") ?? ""),
            // La commune seule redirait le « Lieu » de l'en-tête : l'adresse d'abord.
            ("Adresse", metaString("siteAddress") ?? "")
        ]
    }

    private func metricPairs(for signal: SocialSignalSummary) -> [(String, String)] {
        switch item.cardKind {
        case "speedtest":
            let detail = speedtestDetail
            return [
                // Le bloc de mesure affiche la réception du résumé ; le détail
                // serveur la complète quand le résumé ne l'a pas.
                ("Réception", signal.downloadMbps == nil
                    ? SignalFormatters.speed(detail?.averageSpeed ?? detail?.downloadAvg) : ""),
                // Opérateur, techno et latence du bloc de mesure ne s'y répètent pas (F-16) :
                // le détail serveur ne les donne que quand le résumé ne les a pas.
                ("Opérateur", (signal.servingOperator ?? signal.operator) == nil ? detail.flatMap { SpeedtestAccountHistory.operatorLabel(display: $0.operatorDisplay, raw: $0.mobileOperator) } ?? "" : ""),
                ("SIM", signal.isRoaming == true ? signal.simOperator ?? "" : ""),
                ("Technologie", signal.technology == nil ? detail?.networkType ?? "" : ""),
                ("Latence min", latencyMinText(detail: detail, blockPing: signal.pingMs)),
                ("Gigue", SignalFormatters.ms(detail?.jitter ?? signal.jitterMs))
            ]
        case "validation":
            return [
                ("Identifiant", signal.identifierValue ?? ""),
                ("Type", identifierTypeLabel(signal.identifierType)),
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
                ("Mesures", signal.pointsCount.map(String.init) ?? ""),
                ("Signal moy.", SignalFormatters.dbm(signal.averageSignalDbm)),
                ("Min / Max", rangeText(signal: signal)),
                ("Techs", signal.detectedTechs.prefix(3).joined(separator: " / ")),
                // Un trajet traverse plusieurs cellules : PCI, Cell, RSRP, RSRQ, SINR et Bande
                // ne décriraient qu'un seul de ses points (le signal est déjà en moyenne et min / max).
                ("Opérateur", signal.operator ?? "")
            ]
        default:
            return radioPairs(for: signal)
        }
    }

    /// « eNB », « gNB », « PCI », « Cell » comme sur la carte, jamais « ENB ».
    private func identifierTypeLabel(_ type: String?) -> String {
        switch type?.lowercased() {
        case "enb": return "eNB"
        case "gnb": return "gNB"
        case "pci": return "PCI"
        case "cellid", "ci": return "Cell"
        case let other: return other?.uppercased() ?? ""
        }
    }

    /// Latence minimale du détail serveur, si le bloc de mesure n'affiche pas déjà la même.
    private func latencyMinText(detail: SpeedtestDetail?, blockPing: Double?) -> String {
        guard let min = detail?.pingMin ?? detail?.ping ?? blockPing else { return "" }
        if let blockPing, Int(blockPing.rounded()) == Int(min.rounded()) { return "" }
        return SignalFormatters.ms(min)
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
            ("Confirmations", confirmations),
            // Le code du site a quitté la carte du fil (revue q34, constat 10) : il reste ici.
            ("Code opérateur", metaString("outageOperatorSiteId") ?? ""),
            ("Code ANFR", metaString("outageAnfrCode") ?? "")
        ]
    }

    /// Le test d'un post speedtest : `sourceId` est l'identifiant du post, jamais
    /// celui du test (revue q34, constat 13). Un post de membre joint à un test
    /// le désigne par sa cible.
    private var speedtestId: String? {
        if case .string(let id)? = item.metadata?["speedtestId"], !id.isEmpty { return id }
        guard item.targetType?.lowercased() == "speedtest" else { return nil }
        return item.targetId.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Détail serveur mis à la forme de la fiche unique ; sans adresse, position
    /// ni appareil quand le test est celui d'un autre membre.
    private var speedtestResult: SpeedtestRunResult? {
        speedtestDetail.map { SpeedtestAccountHistory.runResult(from: $0, includesPrivateDetails: item.canManage) }
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
        firstComment = try? await services.comments.list(postId: item.backendPostId, cursor: nil, limit: 1).comments.first
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

    /// Session ou drive test : le tracé servi (`signal.mapPoints`), jamais une position isolée.
    /// Un point seul serait le départ du parcours, souvent le domicile : sans tracé, pas de carte
    /// (contrat social-session-preview). `nil` pour les autres publications.
    nonisolated static func trace(kind: String, signal: SocialSignalSummary?) -> [CLLocationCoordinate2D]? {
        guard ["session", "drive_test"].contains(kind.lowercased()) else { return nil }
        let points = (signal?.mapPoints ?? []).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return points.count >= 2 ? points : []
    }

    /// État de chaque point du tracé (contrat session-signal-trace), comme la carte du fil.
    private func traceStates(count: Int) -> [SQQualityScale.Signal]? {
        let points = signal?.mapPoints ?? []
        guard points.count == count, points.contains(where: { $0.technology != nil }) else { return nil }
        return SessionSignalTrace.states(points.map { .init(technology: $0.technology, signalStrength: $0.signalStrength) })
    }

    @ViewBuilder
    private var map: some View {
        if detailsHidden {
            Label("Détails masqués : seul l’auteur peut les voir", systemImage: "lock")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityIdentifier("signal.detail.hidden")
        } else if let trace = Self.trace(kind: item.kind, signal: signal) {
            if !trace.isEmpty {
                SignalTraceMap(coordinates: trace, color: UIColor(accent), states: traceStates(count: trace.count))
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel(Text("Carte du parcours"))
                    .accessibilityIdentifier("signal.detail.trace")
                // Post de trajet : « Voir le trajet », comme sa carte, vers la carte du trajet.
                if let block = item.session {
                    GradientButton(String(localized: "Voir le trajet"), systemImage: "map", style: .secondary) {
                        Haptics.selection()
                        dismiss()
                        FeedActivity.Link.session(id: block.id, title: nil).open(with: services.router)
                    }
                    .accessibilityIdentifier("signal.detail.openTrip")
                // Seulement avec un tracé : sans point, la session n'a rien de plus à montrer.
                } else if let sessionId = metaString("sessionId") {
                    GradientButton("Voir la session", systemImage: "point.topleft.down.to.point.bottomright.curvepath", style: .secondary) {
                        Haptics.selection()
                        openedSession = OpenedSession(id: sessionId)
                    }
                    .accessibilityIdentifier("signal.detail.openSession")
                }
            }
        } else if let lat = item.latitude ?? signal?.latitude ?? (item.canManage ? speedtestDetail?.latitude : nil),
           let lng = item.longitude ?? signal?.longitude ?? (item.canManage ? speedtestDetail?.longitude : nil) {
            let center = CLLocationCoordinate2D(
                latitude: item.canManage ? lat : (lat * 1000).rounded() / 1000,
                longitude: item.canManage ? lng : (lng * 1000).rounded() / 1000
            )
            let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
            SQRegionMap(region: .constant(region), items: [SQMapPin(coordinate: center)]) { pin in
                MapMarker(coordinate: pin.coordinate, tint: accent)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        } else if item.kind.lowercased() == "speedtest", (place ?? "").isEmpty {
            // Seulement sans lieu : sous « Lieu : Lyon », le message se contredisait (F-30).
            Label("Localisation non partagée", systemImage: "location.slash")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func coordinatesText(lat: Double?, lon: Double?) -> String {
        guard let lat, let lon else { return "" }
        // Le détail précis (5 décimales, environ 1 m) reste pour l'auteur ; les
        // autres lecteurs voient la position arrondie (3 décimales, environ 100 m).
        return String(format: item.canManage ? "%.5f, %.5f" : "%.3f, %.3f", lat, lon)
    }

    private func loadExperienceDetailIfNeeded() async {
        guard let id = experience?.testId else { return }
        experienceState = .loading
        do {
            experienceDetail = try await services.feed.experienceTest(id: id)
            experienceState = experienceDetail == nil ? .unavailable : .loaded
        } catch {
            guard !error.isCancellation else { return }
            experienceState = .failed(String(localized: "Le détail de ce test n’a pas pu être chargé. \(error.userFacingMessage)"))
        }
    }

    private func loadSpeedtestDetailIfNeeded() async {
        guard isSpeedtest, let speedtestId = speedtestId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speedtestId.isEmpty, signal?.detailsHidden != true else { return }
        do {
            speedtestDetail = try await services.speedtest.details(id: speedtestId)
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

/// Tracé d'une session sur une carte fixe, cadré sur tout le parcours. MapKit en UIKit :
/// la `Map` SwiftUI ne trace pas de ligne avant iOS 17.
private struct SignalTraceMap: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let color: UIColor
    /// Un état par point : chaque segment prend celui de son point d'arrivée.
    var states: [SQQualityScale.Signal]? = nil

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.color = color
        map.removeOverlays(map.overlays)
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        if let states, states.count == coordinates.count, coordinates.count >= 2 {
            for index in 1..<coordinates.count {
                let segment = TraceSegment(coordinates: [coordinates[index - 1], coordinates[index]], count: 2)
                segment.state = states[index]
                map.addOverlay(segment)
            }
        } else {
            map.addOverlay(line)
        }
        map.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(color: color) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var color: UIColor
        init(color: UIColor) { self.color = color }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = color
            if let state = (line as? TraceSegment)?.state {
                renderer.strokeColor = state.uiColor
                // « Sans réseau constaté » : pointillé ardoise, jamais une teinte de l'échelle.
                if state.isHatched { renderer.lineDashPattern = [4, 6] }
            }
            renderer.lineWidth = 4
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}

/// Segment du tracé et l'état de son point d'arrivée.
private final class TraceSegment: MKPolyline {
    var state: SQQualityScale.Signal?
}
