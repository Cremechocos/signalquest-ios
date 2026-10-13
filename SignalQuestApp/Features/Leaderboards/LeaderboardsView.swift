import SwiftUI

// MARK: - Onglets

enum LeaderboardTab: String, CaseIterable, Identifiable {
    case speed
    case points

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return String(localized: "Vitesse")
        case .points: return String(localized: "Points")
        }
    }

    var icon: String {
        switch self {
        case .speed: return "speedometer"
        case .points: return "star.fill"
        }
    }
}

// MARK: - ViewModel

@MainActor
final class LeaderboardsViewModel: ObservableObject {
    @Published var tab: LeaderboardTab = .speed
    @Published var period = "week" {
        didSet { if period != oldValue { invalidateSpeed(); invalidatePoints() } }
    }
    @Published var scope = "global" {
        didSet { if scope != oldValue { invalidateSpeed(); invalidatePoints() } }
    }
    @Published var category = "download" {
        didSet { if category != oldValue { invalidateSpeed() } }
    }

    @Published var speedResult: LeaderboardResult = .empty
    @Published var pointsResult: PointsLeaderboardResult = .empty
    @Published var profile: GamificationProfile?
    @Published var isLoadingSpeed = false
    @Published var isLoadingPoints = false
    @Published var speedError: String?
    @Published var pointsError: String?
    /// Incrémentés à chaque arrivée de données : servent d'identité au podium
    /// pour rejouer son animation d'entrée quand le classement change.
    @Published private(set) var speedStamp = 0
    @Published private(set) var pointsStamp = 0

    private var speedGeneration = UUID()
    private var pointsGeneration = UUID()

    private func invalidateSpeed() {
        speedGeneration = UUID()
        speedResult = .empty
        speedError = nil
        isLoadingSpeed = false
    }

    private func invalidatePoints() {
        pointsGeneration = UUID()
        pointsResult = .empty
        pointsError = nil
        isLoadingPoints = false
    }

    private let service: LeaderboardServicing
    private let gamification: GamificationServicing?

    init(service: LeaderboardServicing, gamification: GamificationServicing? = nil) {
        self.service = service
        self.gamification = gamification
    }

    var isLoadingCurrent: Bool { tab == .speed ? isLoadingSpeed : isLoadingPoints }

    func loadAll() async {
        async let profileLoad: Void = loadProfile()
        async let speedLoad: Void = loadSpeed()
        async let pointsLoad: Void = loadPoints()
        _ = await (profileLoad, speedLoad, pointsLoad)
    }

    func loadProfile() async {
        if AppEnvironment.usesDemoData {
            profile = .demo
            return
        }
        guard let gamification else { return }
        // Tolérant : sans profil, la page garde ses classements.
        profile = (try? await gamification.profile()) ?? profile
    }

    func loadSpeed() async {
        let generation = UUID()
        speedGeneration = generation
        let requestedPeriod = period
        let requestedScope = scope
        let requestedCategory = category
        if AppEnvironment.usesDemoData {
            speedResult = .demo
            speedError = nil
            speedStamp += 1
            return
        }
        isLoadingSpeed = true
        speedError = nil
        defer { if speedGeneration == generation { isLoadingSpeed = false } }
        do {
            let response = try await service.leaderboard(period: requestedPeriod, scope: requestedScope, category: requestedCategory)
            guard speedGeneration == generation, !Task.isCancelled else { return }
            speedResult = response
            speedError = nil
            speedStamp += 1
        } catch {
            guard speedGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            speedError = error.userFacingMessage
        }
    }

    func loadPoints() async {
        let generation = UUID()
        pointsGeneration = generation
        let requestedPeriod = period
        let requestedScope = scope
        if AppEnvironment.usesDemoData {
            pointsResult = .demo
            pointsError = nil
            pointsStamp += 1
            return
        }
        isLoadingPoints = true
        pointsError = nil
        defer { if pointsGeneration == generation { isLoadingPoints = false } }
        do {
            let response = try await service.pointsLeaderboard(period: requestedPeriod, scope: requestedScope)
            guard pointsGeneration == generation, !Task.isCancelled else { return }
            pointsResult = response
            pointsError = nil
            pointsStamp += 1
        } catch {
            guard pointsGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            pointsError = error.userFacingMessage
        }
    }


    func setPeriod(_ value: String) {
        guard value != period else { return }
        period = value
        Task { await reloadBoth() }
    }

    func toggleScope() {
        scope = scope == "global" ? "friends" : "global"
        Task { await reloadBoth() }
    }

    func setScope(_ value: String) {
        guard value != scope else { return }
        scope = value
        Task { await reloadBoth() }
    }

    func setCategory(_ value: String) {
        guard value != category else { return }
        category = value
        Task { await loadSpeed() }
    }

    /// Un réglage s'écarte du défaut (semaine, réception, tout le monde) : le
    /// bouton de l'en-tête le signale d'un point.
    var hasCustomFilters: Bool { period != "week" || scope != "global" || category != "download" }

    func resetFilters() {
        guard hasCustomFilters else { return }
        period = "week"
        scope = "global"
        category = "download"
        Task { await reloadBoth() }
    }

    private func reloadBoth() async {
        async let speedLoad: Void = loadSpeed()
        async let pointsLoad: Void = loadPoints()
        _ = await (speedLoad, pointsLoad)
    }
}

// MARK: - Vue principale

struct LeaderboardsView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: LeaderboardsViewModel
    @Environment(\.dismiss) private var dismiss
    /// Membre dont on ouvre le profil depuis une ligne du classement (SOC-44).
    @State private var profileAuthor: SocialFeedAuthor?
    @State private var showsFilters = false
    private let gamification: GamificationServicing?
    private let currentUser: AuthUser?

    init(
        service: LeaderboardServicing,
        gamification: GamificationServicing? = nil,
        user: AuthUser? = nil
    ) {
        _model = StateObject(wrappedValue: LeaderboardsViewModel(service: service, gamification: gamification))
        self.gamification = gamification
        self.currentUser = user
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header
                if let profile = model.profile, let gamification {
                    LeaderboardHeroCard(profile: profile, user: currentUser, gamification: gamification)
                        .sqFadeUp()
                }
                controls
                content
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQDock.floatingContentInset)
            .sqReadableWidth()
        }
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : UIKit coupe le balayage retour, rétabli ici (SOC-30, AF-PROF-10).
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task { await model.loadAll() }
        .refreshable { await model.loadAll() }
        .sheet(isPresented: $showsFilters) {
            LeaderboardFiltersSheet(model: model)
        }
        .navigationDestinationItemCompat($profileAuthor) { author in
            UserProfileView(userId: author.id, prefill: author, service: services.feed)
        }
    }

    /// En-tête Halo : retour à gauche, réglages d'affichage à droite (avec un
    /// point quand un choix diffère du défaut), puis le grand titre.
    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "leaderboards.back") { dismiss() }
                Spacer(minLength: 0)
                MapChipIconButton(systemImage: "slider.horizontal.3", label: "Réglages d’affichage", identifier: "leaderboards.filters") {
                    showsFilters = true
                }
                .overlay(alignment: .topTrailing) {
                    if model.hasCustomFilters {
                        Circle()
                            .fill(SQColor.brandRed)
                            .frame(width: 10, height: 10)
                            .overlay { Circle().stroke(SQColor.bg, lineWidth: 2) }
                            .offset(x: -2, y: 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityValue(model.hasCustomFilters ? Text("Réglages modifiés") : Text(verbatim: ""))
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Classements")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                Text("Les plus rapides et les plus actifs de la communauté.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Segment d'onglet, puis une ligne qui résume les réglages actifs : les
    /// menus en pastilles alourdissaient la page, ils vivent dans la feuille.
    private var controls: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            MapSegmented(
                selection: $model.tab,
                options: LeaderboardTab.allCases.map { ($0, $0.title) },
                identifier: "leaderboards.tab"
            )
            Button {
                Haptics.selection()
                showsFilters = true
            } label: {
                HStack(spacing: SQSpace.xs) {
                    Text(summaryText)
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.ink2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SQColor.labelTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, SQSpace.xs)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Affichage : \(summaryText)"))
            .accessibilityHint(Text("Change la période, la mesure ou les membres classés"))
            .accessibilityIdentifier("leaderboards.summary")
            if model.tab == .points, model.period != "all" {
                Text(model.period == "month"
                     ? "Points gagnés ce mois-ci ; le total depuis l’inscription est en dessous."
                     : "Points gagnés cette semaine ; le total depuis l’inscription est en dessous.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.xs)
            }
        }
        .sqAnimation(SQMotion.snappy, value: model.tab)
    }

    private var summaryText: String {
        var parts = [LeaderboardFiltersSheet.periodSummary(model.period)]
        if model.tab == .speed { parts.append(LeaderboardFiltersSheet.categoryLabel(model.category)) }
        parts.append(model.scope == "friends" ? String(localized: "Mes amis") : String(localized: "Tout le monde"))
        return parts.joined(separator: " · ")
    }

    // MARK: Contenu par onglet

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.tab {
            case .speed:
                speedContent
                    .transition(.opacity.combined(with: .offset(y: 12)))
            case .points:
                pointsContent
                    .transition(.opacity.combined(with: .offset(y: 12)))
            }
        }
    }

    @ViewBuilder
    private var speedContent: some View {
        let entries = model.speedResult.entries
        if model.isLoadingSpeed && entries.isEmpty {
            LeaderboardSkeleton()
        } else if let error = model.speedError, entries.isEmpty {
            ErrorStateView(title: "Classement indisponible", message: error) {
                Task { await model.loadSpeed() }
            }
        } else if entries.isEmpty {
            emptyState(
                title: "Pas encore de classement",
                message: model.scope == "friends" ? "Aucun ami classé pour cette période." : "Reviens après quelques mesures de la communauté.",
                systemImage: "trophy"
            )
        } else {
            rankingSection(
                podiumData: entries.prefix(3).map { entry in
                    PodiumEntryData(
                        rank: entry.rank,
                        name: entry.user.displayName,
                        avatarUrl: entry.user.avatarUrl,
                        valueText: Self.valueText(entry.value, unit: entry.unit)
                    )
                },
                podiumID: "speed-\(model.speedStamp)",
                isRefreshing: model.isLoadingSpeed,
                myRank: entries.dropFirst(3).contains(where: isMe) ? nil : model.speedResult.myRank.map { rank in
                    MyRankData(
                        rank: rank.rank,
                        total: rank.total,
                        value: rank.entry.map { Self.valueText($0.value, unit: $0.unit) },
                        gap: speedGap(entries: entries, myRank: rank)
                    )
                },
                error: model.speedError
            ) {
                ForEach(Array(entries.dropFirst(3).enumerated()), id: \.element.id) { index, entry in
                    LeaderboardRowView(
                        rank: entry.rank,
                        name: entry.user.displayName,
                        avatarUrl: entry.user.avatarUrl,
                        valueText: Self.valueText(entry.value, unit: entry.unit),
                        isMe: isMe(entry),
                        showsDivider: index > 0,
                        onOpen: { profileAuthor = entry.user }
                    ) {
                        SpeedRowMeta(city: entry.city, tech: entry.tech, isProbablyIOS: entry.isProbablyIOS)
                    }
                }
            }
        }
    }

    /// Mon score pour la période affichée. Le profil ne porte que le cumul :
    /// hors « Toujours », il n'est connu que si ma rangée figure dans la page,
    /// sinon le rang reste seul plutôt qu'à côté d'un total d'une autre période.
    private func myPoints(entries: [PointsLeaderboardEntry]) -> Int? {
        if let mine = entries.first(where: isMe) {
            return mine.score(for: model.period)
        }
        guard model.period == "all" else { return nil }
        return model.profile?.points
    }

    @ViewBuilder
    private var pointsContent: some View {
        let entries = model.pointsResult.entries
        if model.isLoadingPoints && entries.isEmpty {
            LeaderboardSkeleton()
        } else if let error = model.pointsError, entries.isEmpty {
            ErrorStateView(title: "Classement indisponible", message: error) {
                Task { await model.loadPoints() }
            }
        } else if entries.isEmpty {
            emptyState(
                title: "Pas encore de points",
                message: model.scope == "friends" ? "Aucun ami classé pour cette période." : "Valide des antennes, publie des photos et lance des speedtests pour gagner des points.",
                systemImage: "star"
            )
        } else {
            rankingSection(
                podiumData: entries.prefix(3).map { entry in
                    PodiumEntryData(
                        rank: entry.rank,
                        name: entry.displayName,
                        avatarUrl: entry.avatarUrl,
                        valueText: "\(entry.score(for: model.period).formatted()) pts"
                    )
                },
                podiumID: "points-\(model.pointsStamp)",
                isRefreshing: model.isLoadingPoints,
                myRank: entries.dropFirst(3).contains(where: isMe) ? nil : model.pointsResult.currentUserRank.map { rank in
                    MyRankData(
                        rank: rank,
                        total: nil,
                        value: myPoints(entries: entries).map { "\($0.formatted()) pts" },
                        gap: pointsGap(entries: entries, myRank: rank)
                    )
                },
                error: model.pointsError
            ) {
                ForEach(Array(entries.dropFirst(3).enumerated()), id: \.element.id) { index, entry in
                    LeaderboardRowView(
                        rank: entry.rank,
                        name: entry.displayName,
                        avatarUrl: entry.avatarUrl,
                        valueText: "\(entry.score(for: model.period).formatted()) pts",
                        subValueText: model.period == "all" ? nil : entry.points.map {
                            String(localized: "\($0.formatted()) au total")
                        },
                        isMe: isMe(entry),
                        showsDivider: index > 0,
                        onOpen: entry.userId.map { userId -> () -> Void in
                            {
                                profileAuthor = SocialFeedAuthor(
                                    id: userId, name: entry.displayName, handle: nil,
                                    avatarUrl: entry.avatarUrl, isFriend: nil, isFollowing: nil,
                                    liveRadio: nil
                                )
                            }
                        }
                    ) {
                        PointsRowMeta(level: entry.level, stats: entry.stats)
                    }
                }
            }
        }
    }

    /// État vide ; entre amis, un bouton rend tout le classement d'un geste.
    private func emptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: SQSpace.md) {
            EmptyStateView(title: title, message: message, systemImage: systemImage)
            if model.scope == "friends" {
                GradientButton(String(localized: "Voir tout le monde"), systemImage: "person.2", style: .secondary) {
                    model.setScope("global")
                }
                .accessibilityIdentifier("leaderboards.empty.everyone")
                .padding(.horizontal, SQSpace.xl)
                .padding(.bottom, SQSpace.lg)
            }
        }
        .sqCardBackground()
    }

    /// Assemble podium + carte « mon rang » + liste, avec assombrissement léger
    /// pendant un rafraîchissement de filtre.
    ///
    /// `myRank` vaut `nil` quand ma propre rangée figure déjà dans la liste : la
    /// carte tomberait sinon juste au-dessus d'elle, avec le même rang et la même
    /// valeur (« Mon rang 4 » puis « 4 · Moi »). Le podium ne comptant pas — il
    /// n'étiquette pas « Moi » —, la carte reste affichée quand je suis top 3.
    private func rankingSection<Rows: View>(
        podiumData: [PodiumEntryData],
        podiumID: String,
        isRefreshing: Bool,
        myRank: MyRankData?,
        error: String?,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            LeaderboardPodiumView(entries: podiumData)
                .id(podiumID)
                .padding(.top, SQSpace.xs)
            if let myRank {
                MyRankCard(data: myRank, user: currentUser)
                    .sqFadeUp()
            }
            // Rangées 4 et suivantes dans une seule carte, séparées d'un filet.
            LazyVStack(spacing: 0) {
                rows()
            }
            .padding(.vertical, 2)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqCardBackground()
            if let error {
                ErrorStateView(title: "Actualisation impossible", message: error)
            }
        }
        .opacity(isRefreshing ? 0.55 : 1)
        .sqAnimation(SQMotion.fast, value: isRefreshing)
    }

    /// Débit en Mbit/s (Gbit/s au-delà de 1 000) ; une autre unité (sessions)
    /// reste telle que le serveur l'envoie.
    static func valueText(_ value: Double, unit: String) -> String {
        let lowered = unit.lowercased()
        if lowered == "mbps" || lowered == "mbit/s" {
            return SQUnits.throughput(mbps: value)
        }
        return "\(Int(value).formatted()) \(unit)"
    }

    /// « À 4 Mbit/s du 41e » : l'écart avec le rang juste devant, quand il
    /// figure dans la page.
    private func speedGap(entries: [LeaderboardEntry], myRank: LeaderboardMyRank) -> String? {
        guard myRank.rank > 1, let mine = myRank.entry,
              let ahead = entries.first(where: { $0.rank == myRank.rank - 1 }) else { return nil }
        let gap = ahead.value - mine.value
        guard gap > 0 else { return nil }
        return String(localized: "À \(Self.valueText(gap, unit: mine.unit)) du \(Self.ordinal(ahead.rank))")
    }

    private func pointsGap(entries: [PointsLeaderboardEntry], myRank: Int) -> String? {
        guard myRank > 1, let mine = myPoints(entries: entries),
              let ahead = entries.first(where: { $0.rank == myRank - 1 }) else { return nil }
        let gap = ahead.score(for: model.period) - mine
        guard gap > 0 else { return nil }
        let gapText = "\(gap.formatted()) pts"
        return String(localized: "À \(gapText) du \(Self.ordinal(ahead.rank))")
    }

    static func ordinal(_ rank: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: rank)) ?? "\(rank)"
    }

    private func isMe(_ entry: LeaderboardEntry) -> Bool {
        if let uid = currentUser?.id { return entry.user.id == uid }
        return model.speedResult.myRank?.rank == entry.rank
    }

    private func isMe(_ entry: PointsLeaderboardEntry) -> Bool {
        if let uid = currentUser?.id, let entryUid = entry.userId { return entryUid == uid }
        return model.pointsResult.currentUserRank == entry.rank
    }
}

// MARK: - Carte héros « ma progression »

private struct LeaderboardHeroCard: View {
    let profile: GamificationProfile
    let user: AuthUser?
    let gamification: GamificationServicing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress: Double = 0
    @State private var shownPoints = 0

    private var level: Int { profile.level ?? 1 }
    private var points: Int { profile.points ?? 0 }
    private var streak: Int { profile.consecutiveDays ?? 0 }
    private var unlockedBadges: [GamificationBadge] { profile.badges.filter { $0.unlockedAt != nil } }

    /// Même lecture de la progression que l'écran Récompenses : `xpToNextLevel`
    /// est la taille du palier courant.
    private var xpProgress: Double {
        guard let next = profile.xpToNextLevel, next > 0 else { return 0 }
        return min(1, Double(points % next) / Double(next))
    }

    private var remainingXP: Int? {
        guard let next = profile.xpToNextLevel, next > 0 else { return nil }
        return next - (points % next)
    }

    private var streakText: String {
        streak > 0 ? String(localized: "\(streak) jours de suite") : String(localized: "Pas de série en cours")
    }

    var body: some View {
        NavigationLink {
            GamificationView(service: gamification)
        } label: {
            card
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Ma progression : niveau \(level), \(points) points, \(streakText). Ouvre les récompenses.")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            // En très grand texte, l'anneau passe au-dessus : à côté, il ne
            // laissait au texte qu'une colonne où les phrases se coupaient.
            if dynamicTypeSize.isAccessibilitySize {
                avatarWithRing
                progressSummary
            } else {
                HStack(spacing: SQSpace.md2) {
                    avatarWithRing
                    progressSummary
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SQSpace.xs2) {
                    chips
                    medallions
                    Spacer(minLength: SQSpace.xs)
                    rewardsLink
                }
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    HStack(spacing: SQSpace.xs2) { chips }
                    HStack(spacing: SQSpace.xs2) {
                        medallions
                        Spacer(minLength: SQSpace.xs)
                        rewardsLink
                    }
                }
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .onAppear { animateIn() }
        .onChangeCompat(of: profile) { _, _ in animateIn() }
        .accessibilityElement(children: .combine)
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Ma progression").sqKicker()
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                Text("\(shownPoints)")
                    .font(SQFont.display(28, .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(SQColor.label)
                Text("pts")
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer(minLength: SQSpace.xs)
                LevelPill(level: level, identifier: "leaderboards.hero.level")
            }
            if let remainingXP {
                Text("Encore \(remainingXP.formatted()) pts avant le niveau \(level + 1)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }
    }

    private var avatarWithRing: some View {
        ZStack {
            XPRing(progress: ringProgress)
            SQAvatar(url: user?.avatarUrl, name: user?.name ?? user?.handle ?? String(localized: "Moi"), size: 46)
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var chips: some View {
        heroChip(icon: "flame.fill", text: streakText)
        if !unlockedBadges.isEmpty {
            heroChip(icon: "rosette", text: String(localized: "\(unlockedBadges.count) badges"))
        }
    }

    /// Trois derniers badges en médaillons, qui se chevauchent un peu.
    @ViewBuilder
    private var medallions: some View {
        if !unlockedBadges.isEmpty {
            HStack(spacing: -6) {
                ForEach(unlockedBadges.prefix(3)) { badge in
                    GamificationBadgeMedallion(badge: badge, size: 28)
                        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(SQColor.surface, lineWidth: 2)
                        }
                }
            }
            .padding(.leading, 2)
        }
    }

    private var rewardsLink: some View {
        HStack(spacing: 2) {
            Text("Récompenses")
                .font(SQType.subhead(.semibold))
                .sqSingleLine()
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(SQColor.accentInk)
    }

    private func heroChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SQColor.ink2)
            Text(text)
                .font(SQType.micro)
                .monospacedDigit()
                .sqSingleLine()
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(SQColor.ink2)
        }
        .padding(.horizontal, SQSpace.sm2)
        .frame(minHeight: 26)
        .sqSurface(SQColor.chip, in: Capsule(style: .continuous))
    }

    private func animateIn() {
        if reduceMotion {
            ringProgress = xpProgress
            shownPoints = points
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(SQMotion.slow) {
                ringProgress = xpProgress
                shownPoints = points
            }
        }
    }
}

/// Anneau de progression XP (rempli au chargement) — piste des puces,
/// remplissage brique uni.
private struct XPRing: View {
    let progress: Double
    var lineWidth: CGFloat = 4.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(SQColor.chip, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.015, min(1, progress)))
                .stroke(
                    SQColor.brandRed,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - Feuille « Afficher »

/// Période, mesure et membres classés : les trois réglages qui encombraient la
/// page en pastilles. Chaque choix s'applique tout de suite.
private struct LeaderboardFiltersSheet: View {
    @ObservedObject var model: LeaderboardsViewModel
    @Environment(\.dismiss) private var dismiss

    static func periodSummary(_ period: String) -> String {
        switch period {
        case "month": return String(localized: "Ce mois-ci")
        case "all": return String(localized: "Depuis toujours")
        default: return String(localized: "Cette semaine")
        }
    }

    static func categoryLabel(_ category: String) -> String {
        switch category {
        case "upload": return String(localized: "Envoi")
        case "sessions": return String(localized: "Sessions")
        default: return String(localized: "Réception")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                MapSheetHeader(title: String(localized: "Afficher"), closeIdentifier: "leaderboards.filters.close") { dismiss() }
                section("Période") {
                    MapSegmented(
                        selection: Binding(get: { model.period }, set: { model.setPeriod($0) }),
                        options: [("week", String(localized: "Semaine")), ("month", String(localized: "Mois")), ("all", String(localized: "Toujours"))],
                        identifier: "leaderboards.filters.period"
                    )
                }
                section("Mesure classée", note: "Uniquement pour le classement Vitesse.") {
                    MapSegmented(
                        selection: Binding(get: { model.category }, set: { model.setCategory($0) }),
                        options: [("download", String(localized: "Réception")), ("upload", String(localized: "Envoi")), ("sessions", String(localized: "Sessions"))],
                        identifier: "leaderboards.filters.category"
                    )
                }
                section("Qui") {
                    MapSegmented(
                        selection: Binding(get: { model.scope }, set: { model.setScope($0) }),
                        options: [("global", String(localized: "Tout le monde")), ("friends", String(localized: "Mes amis"))],
                        identifier: "leaderboards.filters.scope"
                    )
                }
                Button {
                    Haptics.selection()
                    model.resetFilters()
                } label: {
                    Text("Revenir aux réglages par défaut")
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(model.hasCustomFilters ? SQColor.accentInk : SQColor.labelTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.hasCustomFilters)
                .accessibilityIdentifier("leaderboards.filters.reset")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.surface.ignoresSafeArea())
        // Grande hauteur seulement : en hauteur moyenne, iOS 26 réduit la feuille
        // à 96 %, et les segments de 44 pt n'en mesuraient plus que 42 à l'écran.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        note: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title).sqKicker().accessibilityAddTraits(.isHeader)
            content()
            if let note {
                Text(note)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Podium

private struct PodiumEntryData: Identifiable, Equatable {
    let rank: Int
    let name: String
    let avatarUrl: URL?
    let valueText: String

    var id: Int { rank }
}

private struct LeaderboardPodiumView: View {
    let entries: [PodiumEntryData]

    /// Ordre visuel 2 — 1 — 3, le champion au centre.
    private var ordered: [PodiumEntryData] {
        let order = [2: 0, 1: 1, 3: 2]
        return entries.sorted { (order[$0.rank] ?? $0.rank) < (order[$1.rank] ?? $1.rank) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: SQSpace.sm) {
            ForEach(ordered) { entry in
                PodiumColumn(entry: entry, delay: delay(for: entry.rank))
            }
        }
    }

    /// Cascade : 3e, puis 2e, le champion en dernier.
    private func delay(for rank: Int) -> Double {
        switch rank {
        case 1: return 0.24
        case 2: return 0.12
        default: return 0
        }
    }
}

/// Colonne du podium : le rang se lit par le chiffre, la hauteur de la marche
/// et le mot (« Premier »), sans couronne ni aplat rouge. La marche du premier
/// est en brique douce, les autres en carte.
private struct PodiumColumn: View {
    let entry: PodiumEntryData
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var isFirst: Bool { entry.rank == 1 }

    var body: some View {
        VStack(spacing: SQSpace.xs + 2) {
            VStack(spacing: SQSpace.xs + 2) {
                SQAvatar(url: entry.avatarUrl, name: entry.name, size: isFirst ? 58 : 46)
                Text(entry.name)
                    .font(SQFont.body(isFirst ? 15 : 14, .bold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(entry.valueText)
                    .font(SQType.caption(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)

            step
                .scaleEffect(x: 1, y: appeared ? 1 : 0.12, anchor: .bottom)
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(SQMotion.bouncy.delay(delay)) { appeared = true }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rankLabel), \(entry.name), \(entry.valueText)")
    }

    /// Rang lu par VoiceOver et écrit sur la marche, traduit : « Premier » et
    /// « 4e » restaient en français dans l'app anglaise (SOC-28).
    private var rankLabel: String {
        switch entry.rank {
        case 1: return String(localized: "Premier")
        case 2: return String(localized: "Deuxième")
        case 3: return String(localized: "Troisième")
        default: return LeaderboardsView.ordinal(entry.rank)
        }
    }

    private var step: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 16,
            bottomLeadingRadius: 6,
            bottomTrailingRadius: 6,
            topTrailingRadius: 16,
            style: .continuous
        )
        return shape
            .fill(isFirst ? SQColor.accentSoft : SQColor.surface)
            // « Noir intense » : `surface` est noir comme le fond, le liseré garde la marche.
            .overlay { if !isFirst { shape.strokeBorder(SQOledPalette.cardStroke, lineWidth: 1) } }
            .frame(height: stepHeight)
            .overlay(
                VStack(spacing: 1) {
                    Text("\(entry.rank)")
                        .font(SQFont.display(isFirst ? 30 : 24, .bold))
                        .monospacedDigit()
                        .foregroundStyle(isFirst ? SQColor.accentInk : SQColor.label)
                    Text(rankLabel)
                        .font(SQFont.body(10.5, .bold))
                        .tracking(0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, SQSpace.xs)
                        .foregroundStyle(isFirst ? SQColor.accentInk : SQColor.labelSecondary)
                }
            )
            .modifier(SQSoftShadowIf(active: !isFirst))
    }

    private var stepHeight: CGFloat {
        switch entry.rank {
        case 1: return 92
        case 2: return 70
        default: return 56
        }
    }
}

/// Ombre conditionnelle : `sqShadowSoft()` quand `active`, sinon `sqShadowAccent()`
/// si demandé (colonne brique du podium) ou aucune ombre (rangée « moi »).
private struct SQSoftShadowIf: ViewModifier {
    let active: Bool
    var accentOtherwise = false

    func body(content: Content) -> some View {
        if active {
            content.sqShadowSoft()
        } else if accentOtherwise {
            content.sqShadowAccent()
        } else {
            content
        }
    }
}

// MARK: - Lignes méta des rangées

/// Étiquettes d'une rangée Vitesse : ville, technologie, provenance iOS.
///
/// Le nombre d'étiquettes se dégrade au lieu d'en tronquer une : à trois, la
/// ville se réduisait à « Na… » alors que laisser tomber le tag « iOS » — la
/// moins utile des trois — permet d'afficher « Nantes » en entier. L'ordre du
/// tableau est l'ordre de priorité.
private struct SpeedRowMeta: View {
    let city: String?
    let tech: String?
    let isProbablyIOS: Bool

    private var tags: [(text: String, color: Color)] {
        var tags: [(text: String, color: Color)] = []
        if let city { tags.append((city, SQColor.label)) }
        if let tech { tags.append((tech, SQBrand.techColor(tech))) }
        if isProbablyIOS { tags.append(("iOS", SQColor.brandRed)) }
        return tags
    }

    var body: some View {
        let tags = tags
        ViewThatFits(in: .horizontal) {
            line(tags)
            line(Array(tags.dropLast()))
            line(Array(tags.prefix(1)))
        }
    }

    private func line(_ tags: [(text: String, color: Color)]) -> some View {
        HStack(spacing: SQSpace.xs2) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                SQEditorialTag(text: tag.text, color: tag.color)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Pastille de niveau + compteurs d'activité, sur UNE ligne.
///
/// Le nombre de compteurs se dégrade (3 → 2 → 1 → 0) au lieu de laisser la
/// rangée replier ses chiffres : sur un iPhone standard, pastille + 3 compteurs
/// + nom + score dépassent la largeur disponible, et l'`HStack` coupait alors
/// « 383 » en trois lignes d'un chiffre. Les compteurs à zéro sont retirés en
/// amont — un `if` dans l'`HStack` laissait une espace fantôme à leur place.
private struct PointsRowMeta: View {
    let level: Int?
    let stats: PointsLeaderboardStats?

    // `label` : phrase lue par VoiceOver (« 320 validations ») — les icônes seules
    // ne disent pas à quoi se rapporte le chiffre.
    private var counters: [(icon: String, count: Int, label: String)] {
        guard let stats else { return [] }
        var result: [(icon: String, count: Int, label: String)] = []
        if let value = stats.validations, value > 0 {
            result.append(("checkmark.seal.fill", value, String(localized: "\(value) validation")))
        }
        if let value = stats.photos, value > 0 {
            result.append(("camera.fill", value, String(localized: "\(value) photo")))
        }
        if let value = stats.speedtests, value > 0 {
            result.append(("speedometer", value, String(localized: "\(value) speedtest")))
        }
        return result
    }

    var body: some View {
        let counters = counters
        ViewThatFits(in: .horizontal) {
            line(Array(counters.prefix(3)))
            line(Array(counters.prefix(2)))
            line(Array(counters.prefix(1)))
            line([])
        }
    }

    private func line(_ counters: [(icon: String, count: Int, label: String)]) -> some View {
        HStack(spacing: SQSpace.sm) {
            if let level { LevelPill(level: level) }
            ForEach(Array(counters.enumerated()), id: \.offset) { _, counter in
                statCount(icon: counter.icon, count: counter.count, label: counter.label)
            }
            // Sans ce ressort, l'`HStack` centrerait la ligne dans la largeur que
            // lui propose la rangée au lieu de la coller à gauche du nom.
            Spacer(minLength: 0)
        }
    }

    private func statCount(icon: String, count: Int, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(count.formatted())
                .font(SQType.micro)
                .monospacedDigit()
                .sqSingleLine()
        }
        .foregroundStyle(SQColor.labelSecondary)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

// MARK: - Pastille niveau

private struct LevelPill: View {
    let level: Int
    var identifier = "leaderboard.levelPill"

    var body: some View {
        Text("Niv. \(level)")
            .font(SQType.micro)
            .monospacedDigit()
            .sqSingleLine()
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, SQSpace.sm)
            .padding(.vertical, 3)
            .background(SQColor.accentSoft, in: Capsule(style: .continuous))
            .foregroundStyle(SQColor.accentInk)
            // Ancre stable : la refonte est passée de « NIV. » à « Niv. » et le
            // test UI matchait la casse d'origine.
            .accessibilityIdentifier(identifier)
    }
}


// MARK: - Carte « mon rang »

private struct MyRankData {
    let rank: Int
    let total: Int?
    let value: String?
    /// « À 4 Mbit/s du 41e », quand le rang devant figure dans la page.
    let gap: String?
}

private struct MyRankCard: View {
    let data: MyRankData
    let user: AuthUser?

    var body: some View {
        HStack(spacing: SQSpace.md) {
            SQAvatar(url: user?.avatarUrl, name: user?.name ?? user?.handle ?? String(localized: "Moi"), size: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mon rang").sqKicker()
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs2) {
                    Text("\(data.rank)")
                        .font(SQFont.display(26, .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(SQColor.accentInk)
                    if let total = data.total {
                        Text("sur \(total.formatted())")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                if let gap = data.gap {
                    Text(gap)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SQSpace.sm)
            if let value = data.value {
                Text(value)
                    .font(SQType.callout(.bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .sqSingleLine()
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Filet brique à gauche : la carte se distingue sans bordure pleine.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(SQColor.brandRed)
                .frame(width: 3)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqCardBackground()
        .accessibilityElement(children: .combine)
        // Identifiant stable pour les tests UI (les enfants combinés ne sont
        // plus exposés individuellement à XCUITest).
        .accessibilityIdentifier("Mon rang")
    }
}

// MARK: - Rangée de classement

/// Une rangée de la carte qui regroupe les rangs 4 et suivants. La mienne est
/// teintée et porte « Moi ».
private struct LeaderboardRowView<Meta: View>: View {
    let rank: Int
    let name: String
    let avatarUrl: URL?
    let valueText: String
    /// Ligne sous la valeur (« 8 420 au total » pour les points d'une période).
    var subValueText: String? = nil
    let isMe: Bool
    /// Filet au-dessus de la rangée, sauf pour la première.
    var showsDivider = false
    /// Ouvre le profil du membre (SOC-44) ; `nil` quand le serveur ne donne
    /// pas son identifiant.
    var onOpen: (() -> Void)? = nil
    @ViewBuilder var meta: () -> Meta

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { row }
                    .buttonStyle(.plain)
                    .accessibilityHint("Ouvre son profil")
                    .accessibilityIdentifier("leaderboard.row.\(rank)")
            } else {
                row.accessibilityIdentifier("leaderboard.row.\(rank)")
            }
        }
        .overlay(alignment: .top) {
            if showsDivider {
                Rectangle()
                    .fill(SQColor.separator)
                    .frame(height: 1)
                    .padding(.leading, 88)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var row: some View {
        HStack(spacing: SQSpace.md) {
            Text("\(rank)")
                .font(SQFont.body(15, .bold))
                .monospacedDigit()
                .foregroundStyle(isMe ? SQColor.accentInk : SQColor.labelSecondary)
                .frame(minWidth: 24)
            SQAvatar(url: avatarUrl, name: name, size: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SQSpace.xs2) {
                    Text(name)
                        .font(SQType.body(.bold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if isMe {
                        SQEditorialTag(text: "Moi", color: SQColor.accentInk)
                    }
                }
                meta()
            }
            Spacer(minLength: SQSpace.sm)
            VStack(alignment: .trailing, spacing: 1) {
                Text(valueText)
                    .font(SQType.callout(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isMe ? SQColor.accentInk : SQColor.label)
                    .sqSingleLine()
                if let subValueText {
                    Text(subValueText)
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                        .sqSingleLine()
                }
            }
            // La valeur classée ne doit jamais être tronquée (« 12 4… ») : elle garde
            // sa largeur, c'est le nom (scale + lineLimit) qui cède.
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.sm)
        .frame(minHeight: 60)
        .background(isMe ? SQColor.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Squelette de chargement

private struct LeaderboardSkeleton: View {
    var body: some View {
        VStack(spacing: SQSpace.lg) {
            HStack(alignment: .bottom, spacing: SQSpace.md) {
                skeletonColumn(avatar: 46, step: 70)
                skeletonColumn(avatar: 58, step: 92)
                skeletonColumn(avatar: 46, step: 56)
            }
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    skeletonRow
                }
            }
            .sqCardBackground(cornerRadius: SQRadius.xl, elevation: .rest)
        }
        .sqShimmer()
        .accessibilityLabel("Chargement du classement")
    }

    private func skeletonColumn(avatar: CGFloat, step: CGFloat) -> some View {
        VStack(spacing: SQSpace.sm) {
            Circle().fill(SQColor.surfaceMuted).frame(width: avatar, height: avatar)
            SkeletonBlock(width: 64, height: 9)
            SkeletonBlock(width: 46, height: 9)
            SkeletonBlock(height: step, radius: SQRadius.md)
        }
        .frame(maxWidth: .infinity)
    }

    private var skeletonRow: some View {
        HStack(spacing: SQSpace.md) {
            SkeletonBlock(width: 22, height: 12)
            Circle().fill(SQColor.surfaceMuted).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(width: 120, height: 11)
                SkeletonBlock(width: 80, height: 9)
            }
            Spacer(minLength: 0)
            SkeletonBlock(width: 64, height: 13)
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.sm)
        .frame(minHeight: 60)
    }
}

// MARK: - Données vides / de démonstration

extension LeaderboardResult {
    static var empty: LeaderboardResult {
        LeaderboardResult(
            category: "download",
            period: "week",
            scope: "global",
            entries: [],
            myRank: nil,
            generatedAt: nil,
            requestId: nil
        )
    }

    static var demo: LeaderboardResult {
        let author1 = SocialFeedAuthor(id: "u1", name: "Camille", handle: "camille", avatarUrl: nil, isFriend: true, isFollowing: true, liveRadio: nil)
        let author2 = SocialFeedAuthor(id: "u2", name: "Nora", handle: "nora", avatarUrl: nil, isFriend: false, isFollowing: true, liveRadio: nil)
        let author3 = SocialFeedAuthor(id: "u3", name: "Alex", handle: "alex", avatarUrl: nil, isFriend: false, isFollowing: false, liveRadio: nil)
        let author4 = SocialFeedAuthor(id: "u4", name: "Lina", handle: "lina", avatarUrl: nil, isFriend: false, isFollowing: false, liveRadio: nil)
        let author5 = SocialFeedAuthor(id: "u5", name: "Théo", handle: "theo", avatarUrl: nil, isFriend: true, isFollowing: false, liveRadio: nil)
        let entries = [
            LeaderboardEntry(rank: 1, user: author1, value: 712, unit: "Mbps", detail: "Android radio", tech: "5G", operator: "SignalQuest", city: "Paris", capturedAt: Date()),
            LeaderboardEntry(rank: 2, user: author2, value: 548, unit: "Mbps", detail: "iOS speedtest", tech: nil, operator: "SignalQuest", city: "Lyon", capturedAt: Date()),
            LeaderboardEntry(rank: 3, user: author3, value: 402, unit: "Mbps", detail: "iPhone", tech: nil, operator: "SignalQuest", city: "Marseille", capturedAt: Date()),
            LeaderboardEntry(rank: 4, user: author4, value: 361, unit: "Mbps", detail: "Android radio", tech: "5G", operator: "SignalQuest", city: "Lille", capturedAt: Date()),
            LeaderboardEntry(rank: 5, user: author5, value: 297, unit: "Mbps", detail: "iOS speedtest", tech: "4G", operator: "SignalQuest", city: "Nantes", capturedAt: Date())
        ]
        return LeaderboardResult(
            category: "download",
            period: "week",
            scope: "global",
            entries: entries,
            myRank: LeaderboardMyRank(rank: 42, total: 1204, entry: nil),
            generatedAt: Date(),
            requestId: "demo"
        )
    }
}

extension PointsLeaderboardResult {
    static var empty: PointsLeaderboardResult {
        PointsLeaderboardResult(scope: "global", period: "week", entries: [], currentUserRank: nil)
    }

    static var demo: PointsLeaderboardResult {
        PointsLeaderboardResult(
            scope: "global",
            period: "week",
            entries: [
                PointsLeaderboardEntry(rank: 1, userId: "u1", name: "Camille", avatarUrl: nil, points: 12480, periodPoints: 1240, level: 18, badges: [], stats: PointsLeaderboardStats(validations: 320, photos: 64, speedtests: 210, badges: 9)),
                PointsLeaderboardEntry(rank: 2, userId: "u2", name: "Nora", avatarUrl: nil, points: 9860, periodPoints: 980, level: 15, badges: [], stats: PointsLeaderboardStats(validations: 244, photos: 41, speedtests: 188, badges: 7)),
                PointsLeaderboardEntry(rank: 3, userId: "u3", name: "Alex", avatarUrl: nil, points: 8120, periodPoints: 760, level: 13, badges: [], stats: PointsLeaderboardStats(validations: 198, photos: 27, speedtests: 154, badges: 6)),
                PointsLeaderboardEntry(rank: 4, userId: "u4", name: "Lina", avatarUrl: nil, points: 6450, periodPoints: 540, level: 11, badges: [], stats: PointsLeaderboardStats(validations: 130, photos: 33, speedtests: 96, badges: 5)),
                PointsLeaderboardEntry(rank: 5, userId: "u5", name: "Théo", avatarUrl: nil, points: 5210, periodPoints: 430, level: 10, badges: [], stats: PointsLeaderboardStats(validations: 104, photos: 18, speedtests: 88, badges: 4))
            ],
            currentUserRank: 12
        )
    }
}

extension GamificationProfile {
    static var demo: GamificationProfile {
        GamificationProfile(
            level: 12,
            points: 4250,
            xpToNextLevel: 1000,
            consecutiveDays: 8,
            badges: [
                GamificationBadge(id: "explorer_silver", title: "Explorateur", description: "10 antennes validées", iconUrl: nil, icon: "🛰️", unlockedAt: Date(), tier: "rare"),
                GamificationBadge(id: "speedtester_silver", title: "Sprinteur", description: "50 speedtests", iconUrl: nil, icon: "⚡️", unlockedAt: Date(), tier: "rare"),
                GamificationBadge(id: "photographer_silver", title: "Photographe", description: "10 photos approuvées", iconUrl: nil, icon: "📸", unlockedAt: Date(), tier: "epic")
            ]
        )
    }
}
