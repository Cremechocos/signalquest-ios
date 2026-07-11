import SwiftUI

@MainActor
final class GamificationViewModel: ObservableObject {
    @Published var profile: GamificationProfile?
    @Published var events: [GamificationEvent] = []
    @Published var catalog: [GamificationBadge] = []
    @Published var errorMessage: String?

    /// État de la section Quêtes v2 — indépendante du reste de la page :
    /// squelette pendant le chargement, masquée silencieusement en cas d'échec.
    enum QuestsV2State: Equatable {
        case loading
        case loaded([GamificationV2Quest])
        case unavailable
    }

    @Published var questsState: QuestsV2State = .loading
    @Published var season: GamificationV2Season?
    @Published var claimingQuestIds: Set<String> = []

    private let service: GamificationServicing
    private var questsService: GamificationV2Servicing?
    init(service: GamificationServicing) { self.service = service }

    /// Injecté par la vue (AppServices vit dans l'environnement, pas dans l'init).
    func configureQuests(_ service: GamificationV2Servicing) {
        guard questsService == nil else { return }
        questsService = service
    }

    func load() async {
        do {
            async let p = service.profile()
            async let e = service.events()
            async let c = service.catalog()
            profile = try await p
            events = try await e
            // Catalogue tolérant : un échec ici ne masque pas profil/activité.
            catalog = (try? await c) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadQuests() async {
        guard let questsService else {
            questsState = .unavailable
            return
        }
        do {
            let home = try await questsService.home()
            season = home.season
            questsState = .loaded(home.displayQuests)
        } catch {
            // Échec silencieux : la page conserve badges/activité. Si des
            // quêtes étaient déjà affichées, on les garde plutôt que de vider.
            if case .loaded = questsState { return }
            questsState = .unavailable
        }
    }

    func claim(_ quest: GamificationV2Quest) async {
        guard let questsService, quest.isClaimable, !claimingQuestIds.contains(quest.id) else { return }
        claimingQuestIds.insert(quest.id)
        defer { claimingQuestIds.remove(quest.id) }
        do {
            _ = try await questsService.claim(questKey: quest.key, scopeKey: quest.scopeKey)
            Haptics.success()
            // Optimiste : la quête passe « réclamée » sans attendre la resynchro.
            if case .loaded(var quests) = questsState,
               let index = quests.firstIndex(where: { $0.id == quest.id }) {
                quests[index] = quest.markedClaimed()
                questsState = .loaded(quests)
            }
            // Le claim crédite des points : on resynchronise quêtes ET niveau/points.
            await loadQuests()
            await load()
        } catch {
            Haptics.error()
            // Retour à la vérité serveur (la quête peut avoir déjà été réclamée ailleurs).
            await loadQuests()
        }
    }
}

struct GamificationView: View {
    @StateObject private var model: GamificationViewModel
    @EnvironmentObject private var services: AppServices
    init(service: GamificationServicing) {
        _model = StateObject(wrappedValue: GamificationViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                // Pas de sqFadeUp sur les grands blocs (badges/quêtes/activité) :
                // plus hauts que le viewport, la scrollTransition ne les amène
                // jamais à l'identité → sections estompées en permanence (même
                // piège que le menu Profil).
                levelCard
                    .sqFadeUp()
                questsBlock
                if !badgeList.isEmpty { badgesGrid }
                if !lockedBadges.isEmpty { lockedAchievementsSection }
                if !model.events.isEmpty { eventsList }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(SQColor.warning)
                }
            }
            .padding(18)
        }
        .signalQuestBackground()
        .navigationTitle("Récompenses")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configureQuests(services.gamificationV2)
            async let base: Void = model.load()
            async let quests: Void = model.loadQuests()
            _ = await (base, quests)
        }
        .refreshable {
            async let base: Void = model.load()
            async let quests: Void = model.loadQuests()
            _ = await (base, quests)
        }
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md + 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Niveau \(model.profile?.level ?? 0)")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    Text("\(model.profile?.points ?? 0)")
                        .font(SQFont.display(30, .black))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.brandRed)
                        .contentTransition(.numericText())
                    Text("pts")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            xpBar
            Text(streakLabel)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    private var xpBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SQColor.surfaceMuted)
                if xpProgress > 0 {
                    Capsule()
                        .fill(SQColor.brandRed)
                        .frame(width: max(8, proxy.size.width * xpProgress))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Progression vers le niveau suivant")
        .accessibilityValue("\(Int(xpProgress * 100)) %")
    }

    private var badgesGrid: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            Text("Badges").font(SQType.title).foregroundStyle(SQColor.label)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.md), count: 3), spacing: SQSpace.md) {
                ForEach(badgeList) { badge in
                    badgeTile(badge)
                }
            }
        }
    }

    private var badgeList: [GamificationBadge] { model.profile?.badges ?? [] }

    /// Badges du catalogue pas encore débloqués = succès à accomplir,
    /// branchés sur le même système de badges/points que la progression.
    /// (Distincts des Quêtes v2, qui ont leur propre section dédiée.)
    private var lockedBadges: [GamificationBadge] {
        let earned = Set(badgeList.map(\.id))
        return model.catalog.filter { !earned.contains($0.id) }
    }

    // MARK: - Quêtes v2

    /// Section Quêtes : squelette pendant le chargement, groupes par cadence
    /// une fois chargée, rien du tout si l'API échoue ou ne renvoie rien.
    @ViewBuilder
    private var questsBlock: some View {
        switch model.questsState {
        case .loading:
            questsSkeleton
        case .loaded(let quests):
            if !quests.isEmpty {
                questsSection(quests)
            }
        case .unavailable:
            EmptyView()
        }
    }

    private func questsSection(_ quests: [GamificationV2Quest]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            Text("Quêtes").font(SQType.title).foregroundStyle(SQColor.label)
            ForEach(questGroups(quests), id: \.cadence) { group in
                // sqFadeUp par groupe (hauteur < viewport) — JAMAIS sur le bloc
                // entier, sinon la section reste estompée en permanence.
                questGroupRow(cadence: group.cadence, quests: group.quests)
                    .sqFadeUp()
            }
        }
    }

    /// Groupes non vides, dans l'ordre quotidien → hebdo → saison → évènement.
    private func questGroups(_ quests: [GamificationV2Quest]) -> [(cadence: QuestCadenceGroup, quests: [GamificationV2Quest])] {
        let grouped = Dictionary(grouping: quests) { QuestCadenceGroup(rawCadence: $0.cadence) }
        return QuestCadenceGroup.allCases.compactMap { cadence in
            guard let items = grouped[cadence], !items.isEmpty else { return nil }
            return (cadence: cadence, quests: items)
        }
    }

    private func questGroupRow(cadence: QuestCadenceGroup, quests: [GamificationV2Quest]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(cadence.title)
                    .font(SQFont.body(13.5, .semibold))
                    .foregroundStyle(SQColor.label)
                if cadence == .seasonal, let name = model.season?.name, !name.isEmpty {
                    Text(name)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: SQSpace.md) {
                    ForEach(quests) { quest in
                        QuestCardView(
                            quest: quest,
                            cadence: cadence,
                            isClaiming: model.claimingQuestIds.contains(quest.id),
                            onClaim: { Task { await model.claim(quest) } }
                        )
                    }
                }
                // Respiration pour l'ombre de carte (rayon 9, y 4), sinon le
                // ScrollView horizontal la rogne.
                .padding(.horizontal, 4)
                .padding(.top, SQSpace.sm)
                .padding(.bottom, SQSpace.lg)
            }
        }
    }

    private var questsSkeleton: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            Text("Quêtes").font(SQType.title).foregroundStyle(SQColor.label)
            HStack(alignment: .top, spacing: SQSpace.md) {
                questCardSkeleton
                questCardSkeleton
            }
            .padding(.top, SQSpace.xs)
        }
        .accessibilityElement()
        .accessibilityLabel("Quêtes, chargement en cours")
    }

    private var questCardSkeleton: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.md) {
                Circle().fill(SQColor.fill).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
                    SkeletonBlock(width: 96, height: 12)
                    SkeletonBlock(width: 130, height: 9)
                }
            }
            SkeletonBlock(height: 8, radius: 4)
            SkeletonBlock(width: 64, height: 9)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
        .sqShimmer()
    }

    // MARK: - Succès (badges verrouillés legacy)

    private var lockedAchievementsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            Text("Succès à débloquer").font(SQType.title).foregroundStyle(SQColor.label)
            ForEach(lockedBadges) { badge in
                HStack(spacing: SQSpace.md) {
                    Group {
                        if let icon = badge.icon {
                            Text(icon).font(.title3)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(SQColor.surfaceMuted, in: Circle())
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(badge.title ?? "Badge")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.label)
                        if let desc = badge.description {
                            Text(desc)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding(SQSpace.md - 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .sqShadowSoft()
                .opacity(0.75)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Succès : \(badge.title ?? "Badge")")
                .accessibilityValue(badge.description ?? "À débloquer")
            }
        }
    }

    private func badgeTile(_ badge: GamificationBadge) -> some View {
        VStack(spacing: SQSpace.sm) {
            RemoteImage(url: badge.iconUrl, maxDimension: 52, contentMode: .fit) {
                if let icon = badge.icon {
                    Text(icon)
                        .font(.largeTitle)
                } else {
                    Image(systemName: "rosette")
                        .font(.title)
                        .foregroundStyle(SQColor.brandRed)
                }
            }
            .frame(width: 52, height: 52)
            .background(SQColor.accentSoft, in: Circle())
            .accessibilityHidden(true)
            Text(badge.title ?? "Badge")
                .font(SQType.micro)
                .multilineTextAlignment(.center)
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(SQSpace.md - 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
    }

    private var eventsList: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            Text("Activité").font(SQType.title).foregroundStyle(SQColor.label)
            ForEach(model.events) { event in
                let display = GamificationEventDisplay(kind: event.kind)
                HStack(spacing: SQSpace.md) {
                    Image(systemName: display.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(display.tint)
                        .frame(width: 36, height: 36)
                        .background(display.tintSoft, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(display.title)
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.label)
                        if let date = event.createdAt {
                            Text(date, format: .relative(presentation: .named))
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Spacer()
                    if let delta = event.pointsDelta {
                        Text("\(delta > 0 ? "+" : "")\(delta) pts")
                            .font(SQFont.archivo(13, .bold, relativeTo: .footnote))
                            .monospacedDigit()
                            .foregroundStyle(delta >= 0 ? SQColor.success : SQColor.danger)
                    }
                }
                .padding(SQSpace.md - 2)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .sqShadowSoft()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var xpProgress: Double {
        guard let points = model.profile?.points, let next = model.profile?.xpToNextLevel, next > 0 else { return 0 }
        let inLevel = Double(points % next)
        return min(1, inLevel / Double(next))
    }

    /// « 1 jour consécutif » / « 3 jours consécutifs » — accord singulier/pluriel.
    private var streakLabel: String {
        let days = model.profile?.consecutiveDays ?? 0
        return days == 1 ? "1 jour consécutif" : "\(days) jours consécutifs"
    }
}

/// Présentation d'une cadence de quête (contrat Android : `daily` / `weekly` /
/// `seasonal` / `event`, plus `local` et inconnus regroupés en « Autres »).
/// Chaque cadence a sa pastille teintée douce, règle Crème & Terre cuite.
enum QuestCadenceGroup: CaseIterable, Hashable {
    case daily, weekly, seasonal, event, other

    init(rawCadence: String?) {
        switch rawCadence?.lowercased() {
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "seasonal", "season": self = .seasonal
        case "event": self = .event
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .daily: return "Quotidiennes"
        case .weekly: return "Hebdo"
        case .seasonal: return "Saison"
        case .event: return "Évènement"
        case .other: return "Autres quêtes"
        }
    }

    var icon: String {
        switch self {
        case .daily: return "sun.max.fill"
        case .weekly: return "calendar"
        case .seasonal: return "leaf.fill"
        case .event: return "sparkles"
        case .other: return "flag.fill"
        }
    }

    var tint: Color {
        switch self {
        case .daily: return SQColor.brandRed
        case .weekly: return SQColor.warning
        case .seasonal: return SQColor.success
        case .event: return SQColor.danger
        case .other: return SQColor.brandRed
        }
    }

    var tintSoft: Color {
        switch self {
        case .daily: return SQColor.accentSoft
        case .weekly: return SQColor.warningSoft
        case .seasonal: return SQColor.successSoft
        case .event: return SQColor.dangerSoft
        case .other: return SQColor.accentSoft
        }
    }

    /// Description VoiceOver — « Quête quotidienne : … ».
    var voiceOverLabel: String {
        switch self {
        case .daily: return "Quête quotidienne"
        case .weekly: return "Quête hebdomadaire"
        case .seasonal: return "Quête de saison"
        case .event: return "Quête évènement"
        case .other: return "Quête"
        }
    }
}

/// Carte de quête v2 — DA Crème : surface douce rayon 22 + ombre carte,
/// pastille de cadence, jauge 8 pt (brique, olive à 100 %), bouton « Réclamer »
/// seulement quand la récompense est encaissable.
private struct QuestCardView: View {
    let quest: GamificationV2Quest
    let cadence: QuestCadenceGroup
    let isClaiming: Bool
    let onClaim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                progressBar
                metricsRow
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(accessibilityProgress)
            if quest.isClaimable {
                claimButton
            }
        }
        .padding(SQSpace.lg)
        .frame(width: 270, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
        .opacity(quest.isClaimed ? 0.62 : 1)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: cadence.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(cadence.tint)
                .frame(width: 36, height: 36)
                .background(cadence.tintSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(quest.title ?? "Quête")
                    .font(SQFont.display(15.5, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(quest.description ?? " ")
                    .font(SQFont.body(12.5))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if quest.isClaimed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SQColor.success)
                    .accessibilityHidden(true)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SQColor.surfaceMuted)
                if quest.progress > 0 {
                    Capsule()
                        .fill(quest.progress >= 1 ? SQColor.success : SQColor.brandRed)
                        .frame(width: max(8, proxy.size.width * quest.progress))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var metricsRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(quest.progressValue) / \(quest.targetValue)")
                .font(SQFont.body(12, .medium))
                .monospacedDigit()
                .foregroundStyle(SQColor.labelSecondary)
            Spacer()
            if quest.rewardXp > 0 {
                Text("+\(quest.rewardXp) pts")
                    .font(SQFont.body(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.warning)
            }
        }
    }

    private var claimButton: some View {
        Button(action: onClaim) {
            HStack(spacing: SQSpace.sm - 2) {
                if isClaiming {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SQColor.onAccent)
                }
                Text(isClaiming ? "Réclamation…" : "Réclamer")
                    .font(SQFont.display(14.5, .semibold))
            }
            .foregroundStyle(SQColor.onAccent)
            .padding(.horizontal, SQSpace.lg + 2)
            .frame(minHeight: 44)
            .background(SQColor.brandRed, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isClaiming)
        .accessibilityLabel("Réclamer la récompense de la quête \(quest.title ?? "")")
    }

    private var accessibilitySummary: String {
        var parts = ["\(cadence.voiceOverLabel) : \(quest.title ?? "Quête")"]
        if let description = quest.description { parts.append(description) }
        return parts.joined(separator: ". ")
    }

    private var accessibilityProgress: String {
        var parts = ["\(quest.progressValue) sur \(quest.targetValue)"]
        if quest.rewardXp > 0 { parts.append("plus \(quest.rewardXp) points") }
        if quest.isClaimed {
            parts.append("récompense réclamée")
        } else if quest.isClaimable {
            parts.append("récompense à réclamer")
        }
        return parts.joined(separator: ", ")
    }
}

/// Présentation des événements de gamification : le backend renvoie des types
/// techniques (`validation`, `daily_login`, `badge_earned`…) — on les traduit
/// en libellés lisibles avec une icône et une teinte par famille d'événement.
/// Type inconnu → libellé « détechnicisé » (underscores → espaces, majuscule)
/// + étincelle générique, pour ne jamais réafficher du brut.
private struct GamificationEventDisplay {
    let title: String
    let icon: String
    let tint: Color
    let tintSoft: Color

    init(kind: String?) {
        switch kind?.lowercased() {
        case "validation", "site_validation", "direct_map_validation", "offline_validation":
            title = "Validation de site"
            icon = "checkmark.seal.fill"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "speedtest", "speed_test":
            title = "Speedtest"
            icon = "speedometer"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "daily_login", "login_streak":
            title = "Connexion quotidienne"
            icon = "calendar"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "badge_earned", "badge":
            title = "Badge obtenu"
            icon = "rosette"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case "photo_upload", "photo":
            title = "Photo publiée"
            icon = "camera.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "level_up":
            title = "Niveau supérieur"
            icon = "arrow.up.circle.fill"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case "session", "drive_test", "drive":
            title = "Session terrain"
            icon = "car.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "identification", "antenna_identification":
            title = "Antenne identifiée"
            icon = "antenna.radiowaves.left.and.right"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "post", "story", "comment":
            title = "Partage communauté"
            icon = "bubble.left.and.bubble.right.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "coverage", "coverage_upload", "measurement", "coverage_measurement":
            title = "Mesure de couverture"
            icon = "dot.radiowaves.left.and.right"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "quest", "quest_completed", "quest_complete", "quest_claim":
            title = "Quête accomplie"
            icon = "flag.checkered"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case "streak_bonus":
            title = "Bonus de série"
            icon = "flame.fill"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case "new_site_visited":
            title = "Nouveau site visité"
            icon = "mappin.and.ellipse"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "new_department":
            title = "Nouveau département"
            icon = "map.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "custom_site_created":
            title = "Site ajouté à la carte"
            icon = "plus.viewfinder"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "antenna_report":
            title = "Signalement accepté"
            icon = "checkmark.shield.fill"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "bug_report_resolved":
            title = "Bug confirmé"
            icon = "ladybug.fill"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "coverage_session_completed":
            title = "Session terrain terminée"
            icon = "car.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "admob_reward":
            title = "Récompense bonus"
            icon = "gift.fill"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case let raw? where raw.hasPrefix("canada_"):
            title = "Easter egg Canada"
            icon = "leaf.fill"
            tint = SQColor.danger; tintSoft = SQColor.dangerSoft
        case let raw?:
            // Type inconnu : on nettoie le technique (`bug_report` → « Bug report »).
            let cleaned = raw.replacingOccurrences(of: "_", with: " ")
            title = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
            icon = "sparkles"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case nil:
            title = "Événement"
            icon = "sparkles"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        }
    }
}
