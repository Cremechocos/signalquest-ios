import SwiftUI

// MARK: - Onglets

enum LeaderboardTab: String, CaseIterable, Identifiable {
    case speed
    case points

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return "Vitesse"
        case .points: return "Points"
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
    @Published var period = "week"
    @Published var scope = "global"
    @Published var category = "download"

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
        if AppEnvironment.usesDemoData {
            speedResult = .demo
            speedError = nil
            speedStamp += 1
            return
        }
        isLoadingSpeed = true
        defer { isLoadingSpeed = false }
        do {
            speedResult = try await service.leaderboard(period: period, scope: scope, category: category)
            speedError = nil
            speedStamp += 1
        } catch {
            speedError = error.localizedDescription
        }
    }

    func loadPoints() async {
        if AppEnvironment.usesDemoData {
            pointsResult = .demo
            pointsError = nil
            pointsStamp += 1
            return
        }
        isLoadingPoints = true
        defer { isLoadingPoints = false }
        do {
            pointsResult = try await service.pointsLeaderboard(period: period, scope: scope)
            pointsError = nil
            pointsStamp += 1
        } catch {
            pointsError = error.localizedDescription
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

    func setCategory(_ value: String) {
        guard value != category else { return }
        category = value
        Task { await loadSpeed() }
    }

    private func reloadBoth() async {
        async let speedLoad: Void = loadSpeed()
        async let pointsLoad: Void = loadPoints()
        _ = await (speedLoad, pointsLoad)
    }
}

// MARK: - Vue principale

struct LeaderboardsView: View {
    @StateObject private var model: LeaderboardsViewModel
    @Environment(\.dismiss) private var dismiss
    private let gamification: GamificationServicing?
    private let currentUser: AuthUser?

    init(
        service: LeaderboardServicing = LeaderboardService(api: APIClient()),
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
                filters
                content
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, 96)
            .sqReadableWidth()
        }
        .toolbar(.hidden, for: .navigationBar)
        .signalQuestBackground()
        .task { await model.loadAll() }
        .refreshable { await model.loadAll() }
    }

    /// En-tête custom (nav bar système masquée) : bouton retour circulaire 40 pt
    /// + titre Bricolage Bold 24, comme le prototype.
    private var header: some View {
        HStack(spacing: SQSpace.md) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 40, height: 40)
                    .background(SQColor.surface, in: Circle())
                    .sqShadowSoft()
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Retour")
            Text("Classements")
                .font(SQFont.display(24, .bold))
                .foregroundStyle(SQColor.label)
            Spacer(minLength: 0)
            // Segment Vitesse | Points compact, intégré au header (gagne une ligne).
            LeaderboardTabSwitcher(selection: $model.tab)
        }
    }

    // MARK: Filtres — une seule ligne : menus capsules + toggle Amis

    private var filters: some View {
        HStack(spacing: SQSpace.sm) {
            // Période : menu natif dans une capsule (Semaine / Mois / Toujours).
            LeaderboardMenuPill(
                icon: "calendar",
                label: periodLabel,
                accessibility: "Période du classement"
            ) {
                Button { model.setPeriod("week") } label: {
                    if model.period == "week" { Label("Semaine", systemImage: "checkmark") } else { Text("Semaine") }
                }
                Button { model.setPeriod("month") } label: {
                    if model.period == "month" { Label("Mois", systemImage: "checkmark") } else { Text("Mois") }
                }
                Button { model.setPeriod("all") } label: {
                    if model.period == "all" { Label("Toujours", systemImage: "checkmark") } else { Text("Toujours") }
                }
            }

            // Métrique (uniquement pour Vitesse) : Download / Upload / Sessions.
            if model.tab == .speed {
                LeaderboardMenuPill(
                    icon: "speedometer",
                    label: categoryLabel,
                    accessibility: "Métrique du classement"
                ) {
                    Button { model.setCategory("download") } label: {
                        if model.category == "download" { Label("Download", systemImage: "checkmark") } else { Text("Download") }
                    }
                    Button { model.setCategory("upload") } label: {
                        if model.category == "upload" { Label("Upload", systemImage: "checkmark") } else { Text("Upload") }
                    }
                    Button { model.setCategory("sessions") } label: {
                        if model.category == "sessions" { Label("Sessions", systemImage: "checkmark") } else { Text("Sessions") }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Spacer(minLength: 0)

            // Portée Amis : toggle icône compact.
            LeaderboardFilterChip(label: "Amis", icon: "person.2.fill", isOn: model.scope == "friends") {
                model.toggleScope()
            }
        }
        .sqAnimation(SQMotion.snappy, value: model.tab)
    }

    private var periodLabel: String {
        switch model.period {
        case "week": return "Semaine"
        case "month": return "Mois"
        default: return "Toujours"
        }
    }

    private var categoryLabel: String {
        switch model.category {
        case "upload": return "Upload"
        case "sessions": return "Sessions"
        default: return "Download"
        }
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
            EmptyStateView(
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
                        valueText: "\(Int(entry.value)) \(entry.unit)"
                    )
                },
                podiumID: "speed-\(model.speedStamp)",
                isRefreshing: model.isLoadingSpeed,
                myRank: model.speedResult.myRank.map { rank in
                    (rank: rank.rank, total: rank.total as Int?, value: rank.entry.map { "\(Int($0.value)) \($0.unit)" })
                },
                error: model.speedError
            ) {
                ForEach(entries.dropFirst(3)) { entry in
                    LeaderboardRowView(
                        rank: entry.rank,
                        name: entry.user.displayName,
                        avatarUrl: entry.user.avatarUrl,
                        valueText: "\(Int(entry.value)) \(entry.unit)",
                        isMe: isMe(entry)
                    ) {
                        HStack(spacing: SQSpace.xs + 2) {
                            if let city = entry.city { SQEditorialTag(text: city, color: SQColor.label) }
                            if let tech = entry.tech { SQEditorialTag(text: tech, color: SQBrand.techColor(tech)) }
                            if entry.isProbablyIOS { SQEditorialTag(text: "iOS", color: SQColor.brandRed) }
                        }
                    }
                    .sqFadeUp()
                }
            }
        }
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
            EmptyStateView(
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
                myRank: model.pointsResult.currentUserRank.map { rank in
                    (rank: rank, total: nil, value: model.profile?.points.map { "\($0.formatted()) pts" })
                },
                error: model.pointsError
            ) {
                ForEach(entries.dropFirst(3)) { entry in
                    LeaderboardRowView(
                        rank: entry.rank,
                        name: entry.displayName,
                        avatarUrl: entry.avatarUrl,
                        valueText: "\(entry.score(for: model.period).formatted()) pts",
                        isMe: isMe(entry)
                    ) {
                        HStack(spacing: SQSpace.sm) {
                            if let level = entry.level { LevelPill(level: level) }
                            if let stats = entry.stats {
                                statCount(icon: "checkmark.seal.fill", count: stats.validations)
                                statCount(icon: "camera.fill", count: stats.photos)
                                statCount(icon: "speedometer", count: stats.speedtests)
                            }
                        }
                    }
                    .sqFadeUp()
                }
            }
        }
    }

    /// Assemble podium + carte « mon rang » + liste, avec assombrissement léger
    /// pendant un rafraîchissement de filtre.
    private func rankingSection<Rows: View>(
        podiumData: [PodiumEntryData],
        podiumID: String,
        isRefreshing: Bool,
        myRank: (rank: Int, total: Int?, value: String?)?,
        error: String?,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            LeaderboardPodiumView(entries: podiumData)
                .id(podiumID)
                .padding(.top, SQSpace.sm)
            if let myRank {
                MyRankCard(rank: myRank.rank, total: myRank.total, valueText: myRank.value)
                    .sqFadeUp()
            }
            LazyVStack(spacing: SQSpace.sm + 2) {
                rows()
            }
            if let error {
                ErrorStateView(title: "Actualisation impossible", message: error)
            }
        }
        .opacity(isRefreshing ? 0.55 : 1)
        .sqAnimation(SQMotion.fast, value: isRefreshing)
    }

    private func statCount(icon: String, count: Int?) -> some View {
        Group {
            if let count, count > 0 {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(count.formatted())
                        .font(SQType.micro)
                        .monospacedDigit()
                }
                .foregroundStyle(SQColor.labelSecondary)
            }
        }
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

    var body: some View {
        NavigationLink {
            GamificationView(service: gamification)
        } label: {
            card
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Ma progression : niveau \(level), \(points) points, \(streak) jours consécutifs. Ouvre les récompenses.")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.lg) {
                avatarWithRing
                VStack(alignment: .leading, spacing: SQSpace.xs + 1) {
                    Text("Ma progression").sqKicker()
                    HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                        Text("\(shownPoints)")
                            .font(SQFont.display(28, .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(SQColor.brandRed)
                        Text("pts")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    if let remainingXP {
                        Text("Encore \(remainingXP.formatted()) pts avant le niveau \(level + 1)")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: SQSpace.sm) {
                        heroChip(icon: "flame.fill", text: streak > 1 ? "\(streak) jours" : "\(streak) jour")
                        if !unlockedBadges.isEmpty {
                            heroChip(icon: "rosette", text: "\(unlockedBadges.count) badge\(unlockedBadges.count > 1 ? "s" : "")")
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
            if !unlockedBadges.isEmpty {
                badgesPreview
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
        .onAppear { animateIn() }
        .onChangeCompat(of: profile) { _, _ in animateIn() }
        .accessibilityElement(children: .combine)
    }

    private var avatarWithRing: some View {
        ZStack {
            XPRing(progress: ringProgress)
            SQAvatar(url: user?.avatarUrl, name: user?.name ?? user?.handle ?? "Moi", size: 64)
        }
        .frame(width: 94, height: 94)
        .overlay(alignment: .bottom) {
            Text("Niv. \(level)")
                .font(SQType.micro)
                .monospacedDigit()
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, 3)
                .background(SQColor.brandRed, in: Capsule(style: .continuous))
                .foregroundStyle(SQColor.onAccent)
                .offset(y: 7)
        }
        .accessibilityHidden(true)
    }

    private var badgesPreview: some View {
        HStack(spacing: SQSpace.sm) {
            HStack(spacing: -8) {
                ForEach(unlockedBadges.prefix(4)) { badge in
                    badgeDot(badge)
                }
            }
            if unlockedBadges.count > 4 {
                Text("+\(unlockedBadges.count - 4)")
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: 0)
            Text("Récompenses")
                .font(SQType.micro)
                .foregroundStyle(SQColor.brandRed)
        }
    }

    private func badgeDot(_ badge: GamificationBadge) -> some View {
        ZStack {
            Circle().fill(SQColor.surfaceMuted)
            if let icon = badge.icon {
                Text(icon).font(.system(size: 14))
            } else {
                RemoteImage(url: badge.iconUrl, maxDimension: 28, contentMode: .fit) {
                    Image(systemName: "rosette")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SQColor.brandRed)
                }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay { Circle().stroke(SQColor.surface, lineWidth: 2) }
    }

    private func heroChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SQColor.brandRed)
            Text(text)
                .font(SQType.micro)
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
        }
        .padding(.horizontal, SQSpace.sm + 2)
        .padding(.vertical, 5)
        .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
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

/// Anneau de progression XP (rempli au chargement) — piste `SurfaceMuted`,
/// remplissage accent brique uni (la DA Crème supprime les dégradés).
private struct XPRing: View {
    let progress: Double
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .stroke(SQColor.surfaceMuted, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.015, min(1, progress)))
                .stroke(
                    SQColor.brandRed,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Switcher d'onglets

// Segments « Crème » : rangée de capsules Figtree SemiBold 13 — l'onglet actif
// est une capsule brique pleine (texte crème), les inactifs surface + ombre douce.
/// Segment compact « Vitesse | Points » : une seule capsule surface avec une
/// pilule brique qui glisse sous l'option active (matchedGeometryEffect).
private struct LeaderboardTabSwitcher: View {
    @Binding var selection: LeaderboardTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LeaderboardTab.allCases) { tab in
                let isOn = tab == selection
                Button {
                    guard !isOn else { return }
                    Haptics.selection()
                    withAnimation(SQMotion.resolve(SQMotion.emphasized, reduceMotion)) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(SQFont.body(13, .semibold))
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, SQSpace.sm - 1)
                        .foregroundStyle(isOn ? SQColor.onAccent : SQColor.labelSecondary)
                        .background {
                            if isOn {
                                Capsule(style: .continuous)
                                    .fill(SQColor.brandRed)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowSoft()
    }
}

/// Capsule-menu de filtre : icône + valeur courante + indicateur, menu natif.
private struct LeaderboardMenuPill<Items: View>: View {
    let icon: String
    let label: String
    let accessibility: String
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                Text(label)
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.surface, in: Capsule(style: .continuous))
            .sqShadowSoft()
            .contentShape(Capsule(style: .continuous))
        }
        .accessibilityLabel("\(accessibility) : \(label)")
    }
}

// MARK: - Chip de filtre

// Capsule de segment/filtre « Crème » : Figtree SemiBold 13 en casse normale ;
// actif = fond brique + texte crème, inactif = surface + ombre douce (sans bordure).
private struct LeaderboardFilterChip: View {
    let label: String
    var icon: String? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(SQFont.body(13, .semibold))
            }
                .padding(.horizontal, SQSpace.md + 2)
                .padding(.vertical, SQSpace.sm)
                .background(
                    isOn ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                    in: Capsule(style: .continuous)
                )
                .foregroundStyle(isOn ? SQColor.onAccent : SQColor.label)
                .sqShadowSoft()
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
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
        HStack(alignment: .bottom, spacing: SQSpace.md) {
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

// Colonne « Crème » alignée sur le composant partagé `LeaderboardPodium`
// (Design/SQComponents.swift) : nº1 = 👑 + avatar 66 + colonne brique pleine ;
// nº2/3 = avatar 56 + colonne surface. Colonnes arrondies en haut uniquement.
private struct PodiumColumn: View {
    let entry: PodiumEntryData
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var isFirst: Bool { entry.rank == 1 }

    var body: some View {
        VStack(spacing: SQSpace.sm) {
            VStack(spacing: SQSpace.sm) {
                if isFirst {
                    Text("👑")
                        .font(SQFont.display(20, .bold))
                        .accessibilityHidden(true)
                }
                avatar
                Text(entry.name)
                    .font(SQFont.body(isFirst ? 13.5 : 13, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
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

    private var rankLabel: String {
        switch entry.rank {
        case 1: return "Premier"
        case 2: return "Deuxième"
        case 3: return "Troisième"
        default: return "\(entry.rank)e"
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if isFirst {
            SQAvatar(url: entry.avatarUrl, name: entry.name, size: 66)
                .sqShadowAccent()
        } else {
            SQAvatar(url: entry.avatarUrl, name: entry.name, size: 56)
        }
    }

    private var step: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: SQRadius.md,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: SQRadius.md,
            style: .continuous
        )
        .fill(isFirst ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface))
        .frame(height: stepHeight)
        .overlay(
            VStack(spacing: 1) {
                Text("\(entry.rank)")
                    .font(SQFont.display(isFirst ? 24 : 20, .bold))
                    .monospacedDigit()
                    .foregroundStyle(isFirst ? SQColor.onAccent : SQColor.label)
                Text(entry.valueText)
                    .font(SQFont.body(isFirst ? 11.5 : 11))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, SQSpace.xs)
                    .foregroundStyle(isFirst ? SQColor.onAccent.opacity(0.85) : SQColor.labelSecondary)
            }
        )
        .modifier(SQSoftShadowIf(active: !isFirst, accentOtherwise: true))
    }

    private var stepHeight: CGFloat {
        switch entry.rank {
        case 1: return 92
        case 2: return 68
        default: return 52
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

// MARK: - Pastille niveau

private struct LevelPill: View {
    let level: Int

    var body: some View {
        Text("Niv. \(level)")
            .font(SQType.micro)
            .monospacedDigit()
            .padding(.horizontal, SQSpace.sm)
            .padding(.vertical, 3)
            .background(SQColor.accentSoft, in: Capsule(style: .continuous))
            .foregroundStyle(SQColor.brandRed)
    }
}

// MARK: - Carte « mon rang »

private struct MyRankCard: View {
    let rank: Int
    let total: Int?
    let valueText: String?

    var body: some View {
        HStack(spacing: SQSpace.md) {
            ZStack {
                Circle().fill(SQColor.brandRed)
                Image(systemName: "person.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SQColor.onAccent)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mon rang").sqKicker()
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs + 2) {
                    Text("#\(rank)")
                        .font(SQFont.display(24, .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(SQColor.brandRed)
                    if let total {
                        Text("sur \(total.formatted())")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
            Spacer(minLength: SQSpace.sm)
            if let valueText {
                Text(valueText)
                    .font(SQFont.body(14, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.brandRed)
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .overlay {
            // Seule bordure autorisée du design system : la rangée/carte « moi ».
            RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                .stroke(SQColor.brandRed, lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
        // Identifiant stable pour les tests UI (les enfants combinés ne sont
        // plus exposés individuellement à XCUITest).
        .accessibilityIdentifier("Mon rang")
    }
}

// MARK: - Rangée de classement

private struct LeaderboardRowView<Meta: View>: View {
    let rank: Int
    let name: String
    let avatarUrl: URL?
    let valueText: String
    let isMe: Bool
    @ViewBuilder var meta: () -> Meta

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
        HStack(spacing: SQSpace.md + 1) {
            Text("\(rank)")
                .font(SQFont.body(14, .semibold))
                .monospacedDigit()
                .foregroundStyle(isMe ? SQColor.brandRed : SQColor.labelSecondary)
                .frame(minWidth: 22, alignment: .leading)
            SQAvatar(url: avatarUrl, name: name, size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs + 1) {
                HStack(spacing: SQSpace.xs + 2) {
                    Text(name)
                        .font(SQFont.body(15, .semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    if isMe {
                        SQEditorialTag(text: "Moi", color: SQColor.brandRed)
                    }
                }
                meta()
            }
            Spacer(minLength: SQSpace.sm)
            Text(valueText)
                .font(SQFont.body(14, .semibold))
                .monospacedDigit()
                .foregroundStyle(isMe ? SQColor.brandRed : SQColor.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md + 1)
        .background(isMe ? AnyShapeStyle(SQColor.accentSoft) : AnyShapeStyle(SQColor.surface), in: shape)
        .overlay {
            if isMe {
                // Seule bordure autorisée du design system : la rangée « moi ».
                shape.stroke(SQColor.brandRed, lineWidth: 1.5)
            }
        }
        .modifier(SQSoftShadowIf(active: !isMe))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Squelette de chargement

private struct LeaderboardSkeleton: View {
    var body: some View {
        VStack(spacing: SQSpace.lg) {
            HStack(alignment: .bottom, spacing: SQSpace.md) {
                skeletonColumn(avatar: 56, step: 68)
                skeletonColumn(avatar: 66, step: 92)
                skeletonColumn(avatar: 56, step: 52)
            }
            VStack(spacing: SQSpace.sm + 2) {
                ForEach(0..<5, id: \.self) { _ in
                    skeletonRow
                }
            }
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
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md + 1)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowSoft()
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
                GamificationBadge(id: "b1", title: "Explorateur", description: "10 antennes validées", iconUrl: nil, icon: "🛰️", unlockedAt: Date(), tier: "rare"),
                GamificationBadge(id: "b2", title: "Sprinteur", description: "50 speedtests", iconUrl: nil, icon: "⚡️", unlockedAt: Date(), tier: "rare"),
                GamificationBadge(id: "b3", title: "Photographe", description: "10 photos approuvées", iconUrl: nil, icon: "📸", unlockedAt: Date(), tier: "epic")
            ]
        )
    }
}
