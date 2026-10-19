import SwiftUI

@MainActor
final class GamificationViewModel: ObservableObject {
    @Published var profile: GamificationProfile?
    @Published var events: [GamificationEvent] = []
    @Published var catalog: [GamificationBadge] = []
    @Published var errorMessage: String?
    @Published private(set) var isLoadingProfile = true

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
    /// Échec de la dernière réclamation : sans texte, seule une vibration le signalait.
    @Published var claimError: String?

    private let service: GamificationServicing
    private var questsService: GamificationV2Servicing?
    init(service: GamificationServicing) { self.service = service }

    /// Injecté par la vue (AppServices vit dans l'environnement, pas dans l'init).
    func configureQuests(_ service: GamificationV2Servicing) {
        guard questsService == nil else { return }
        questsService = service
    }

    func load() async {
        if profile == nil { isLoadingProfile = true }
        defer { isLoadingProfile = false }
        do {
            async let p = service.profile()
            async let e = service.events()
            async let c = service.catalog()
            profile = try await p
            // Catalogue tolérant, lu avant l'activité : un échec d'`events` ne doit pas
            // laisser le catalogue sans valeur, et un échec ici garde le précédent.
            if let freshCatalog = try? await c { catalog = freshCatalog }
            events = try await e
            errorMessage = nil
        } catch {
            // Un rafraîchissement interrompu n'est pas un échec à afficher.
            if error.isCancellation { return }
            errorMessage = error.userFacingMessage
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
        claimError = nil
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
            if !error.isCancellation { claimError = error.userFacingMessage }
            // Retour à la vérité serveur (la quête peut avoir déjà été réclamée ailleurs).
            await loadQuests()
        }
    }
}

struct GamificationView: View {
    @StateObject private var model: GamificationViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var badgeFilter: BadgeFilter = .unlocked
    @State private var openedBadge: OpenedBadge?

    init(service: GamificationServicing) {
        _model = StateObject(wrappedValue: GamificationViewModel(service: service))
    }

    private enum BadgeFilter: Hashable { case unlocked, locked }

    /// Badge ouvert dans la fiche, avec son état : un badge du catalogue reste
    /// à débloquer même si le serveur lui donne une date.
    private struct OpenedBadge: Identifiable {
        let badge: GamificationBadge
        let isUnlocked: Bool
        var id: String { badge.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                // Pas de sqFadeUp sur les grands blocs (badges/quêtes/activité) :
                // plus hauts que le viewport, la scrollTransition ne les amène
                // jamais à l'identité → sections estompées en permanence (même
                // piège que le menu Profil).
                header
                // Rien de chargé : l'erreur tient lieu d'écran, avec de quoi réessayer.
                if model.profile == nil, model.errorMessage != nil {
                    ErrorStateView(title: "Récompenses indisponibles", message: friendlyError) {
                        Task { await model.load() }
                    }
                }
                levelBlock
                    .sqFadeUp()
                questsBlock
                if !badgeList.isEmpty || !lockedBadges.isEmpty { badgesSection }
                if !model.events.isEmpty { eventsSection }
                if model.profile != nil, model.errorMessage != nil {
                    SQInlineError(message: String(localized: "Actualisation impossible. Tire vers le bas pour réessayer."))
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQDock.floatingContentInset)
            .sqReadableWidth()
        }
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : UIKit coupe le balayage retour, rétabli ici.
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .navigationTitle("Récompenses")
        .sheet(item: $openedBadge) { opened in
            GamificationBadgeSheet(badge: opened.badge, isUnlocked: opened.isUnlocked)
        }
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

    /// Le message du serveur peut être technique (et en anglais) : l'écran dit
    /// ce qui se passe et quoi faire, sauf hors ligne, qui a son propre état.
    private var friendlyError: String {
        if model.errorMessage == SQOfflineText.message { return SQOfflineText.message }
        return String(localized: "Impossible de charger ta progression pour l’instant. Vérifie ta connexion, puis réessaie.")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "rewards.back") { dismiss() }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Récompenses")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("rewards.title")
                Text("Ton niveau, tes quêtes et tes badges.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var levelBlock: some View {
        if model.profile != nil {
            levelCard
        } else if model.isLoadingProfile {
            levelCardSkeleton
        }
    }

    /// Ne jamais afficher « Niveau 0 · 0 pts » pendant le réseau : ce sont des
    /// données plausibles mais fausses pour un compte existant, donc plus
    /// trompeuses qu'un squelette explicite.
    private var levelCardSkeleton: some View {
        VStack(alignment: .leading, spacing: SQSpace.md2) {
            HStack {
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .fill(SQColor.surfaceMuted)
                    .frame(width: 126, height: 28)
                Spacer()
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .fill(SQColor.surfaceMuted)
                    .frame(width: 112, height: 34)
            }
            Capsule(style: .continuous)
                .fill(SQColor.surfaceMuted)
                .frame(height: 8)
            RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                .fill(SQColor.surfaceMuted)
                .frame(width: 148, height: 17)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chargement de la progression")
    }

    private var level: Int { model.profile?.level ?? 0 }
    private var points: Int { model.profile?.points ?? 0 }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                Text("Niveau \(level)")
                    .font(SQFont.display(17, .bold, relativeTo: .headline))
                    .foregroundStyle(SQColor.label)
                Spacer(minLength: SQSpace.sm)
                Text(points.formatted())
                    .font(SQFont.display(26, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.accentInk)
                    .contentTransition(.numericText())
                Text("pts")
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            progressBar(xpProgress, height: 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SQSpace.sm) {
                    levelProgressText
                    Spacer(minLength: SQSpace.xs)
                    streakText
                }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    levelProgressText
                    streakText
                }
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Niveau \(level)")
        .accessibilityValue("\(points) points · progression \(Int(xpProgress * 100)) %")
    }

    @ViewBuilder
    private var levelProgressText: some View {
        if let remaining = model.profile?.pointsRemaining {
            Text("Encore \(remaining.formatted()) pts avant le niveau \(level + 1)")
                .font(SQType.caption)
                .monospacedDigit()
                .foregroundStyle(SQColor.ink2)
        }
    }

    private var streakText: some View {
        Label(streakLabel, systemImage: "flame.fill")
            .font(SQType.caption(.semibold))
            .foregroundStyle(SQColor.labelSecondary)
            .labelStyle(.titleAndIcon)
            .sqSingleLine()
    }

    private func progressBar(_ progress: Double, height: CGFloat, tint: Color = SQColor.brandRed) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SQColor.chip)
                if progress > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, proxy.size.width * min(1, progress)))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
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
        let claimable = quests.filter(\.isClaimable).count
        return VStack(alignment: .leading, spacing: SQSpace.sm2) {
            SQSectionHeader("Quêtes") {
                if claimable > 0 {
                    Text("\(claimable) à réclamer")
                        .font(SQType.micro(.bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.onAccent)
                        .padding(.horizontal, SQSpace.sm)
                        .frame(minHeight: 22)
                        .background(SQColor.brandRed, in: Capsule(style: .continuous))
                        .sqSingleLine()
                }
            }
            if let claimError = model.claimError {
                SQInlineError(message: claimError)
            }
            ForEach(questGroups(quests), id: \.cadence) { group in
                // sqFadeUp par groupe (hauteur < viewport) — JAMAIS sur le bloc
                // entier, sinon la section reste estompée en permanence.
                questGroup(cadence: group.cadence, quests: group.quests)
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

    /// Une cadence : son intitulé, puis ses quêtes en liste dans une carte. Le
    /// carrousel horizontal cachait la moitié des quêtes hors de l'écran.
    private func questGroup(cadence: QuestCadenceGroup, quests: [GamificationV2Quest]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs + 2) {
                Image(systemName: cadence.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(cadence.title)
                    .font(SQType.caption(.bold))
                if cadence == .seasonal, let name = model.season?.name, !name.isEmpty {
                    Text(name)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .foregroundStyle(SQColor.ink2)
            .padding(.horizontal, SQSpace.xs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(quests.enumerated()), id: \.element.id) { index, quest in
                    QuestRowView(
                        quest: quest,
                        cadence: cadence,
                        isClaiming: model.claimingQuestIds.contains(quest.id),
                        onClaim: { Task { await model.claim(quest) } }
                    )
                    .mapRowDivider(index > 0)
                }
            }
            .sqCardBackground()
        }
    }

    private var questsSkeleton: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            SQSectionHeader("Quêtes")
            VStack(spacing: 0) {
                questRowSkeleton
                questRowSkeleton
            }
            .sqCardBackground()
            .sqShimmer()
        }
        .accessibilityElement()
        .accessibilityLabel("Quêtes, chargement en cours")
    }

    private var questRowSkeleton: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.md) {
                Circle().fill(SQColor.fill).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: SQSpace.xs2) {
                    SkeletonBlock(width: 120, height: 12)
                    SkeletonBlock(width: 180, height: 9)
                }
                Spacer(minLength: 0)
            }
            SkeletonBlock(height: 6, radius: 3)
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.md)
    }

    // MARK: - Badges

    private var totalBadges: Int { badgeList.count + lockedBadges.count }

    private var badgesSection: some View {
        let showsLocked = badgeFilter == .locked && !lockedBadges.isEmpty
        return VStack(alignment: .leading, spacing: SQSpace.sm2) {
            SQSectionHeader("Badges") {
                Text("\(badgeList.count) / \(totalBadges)")
                    .font(SQType.subhead(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityLabel(Text("Badges débloqués : \(badgeList.count) sur \(totalBadges)"))
            }
            progressBar(totalBadges > 0 ? Double(badgeList.count) / Double(totalBadges) : 0, height: 6)
            if !lockedBadges.isEmpty {
                MapSegmented(
                    selection: $badgeFilter,
                    options: [
                        (.unlocked, String(localized: "Débloqués · \(badgeList.count)")),
                        (.locked, String(localized: "À débloquer · \(lockedBadges.count)"))
                    ],
                    identifier: "rewards.badges.filter"
                )
            }
            if showsLocked {
                lockedList
            } else if badgeList.isEmpty {
                Text("Aucun badge débloqué pour l’instant. Ceux qui restent à gagner sont dans « À débloquer ».")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.xs)
            } else {
                badgesGrid
                rarityLegend
            }
        }
    }

    private var badgesGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 3), spacing: SQSpace.sm) {
            ForEach(badgeList) { badge in
                Button {
                    Haptics.selection()
                    openedBadge = OpenedBadge(badge: badge, isUnlocked: true)
                } label: {
                    badgeTile(badge)
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityIdentifier("rewards.badge.\(badge.id)")
            }
        }
    }

    private func badgeTile(_ badge: GamificationBadge) -> some View {
        VStack(spacing: SQSpace.xs + 2) {
            GamificationBadgeMedallion(badge: badge)
            Text(badge.title ?? String(localized: "Badge"))
                .font(SQFont.body(12.5, .bold, relativeTo: .footnote))
                .multilineTextAlignment(.center)
                .foregroundStyle(SQColor.label)
                .lineLimit(2)
                .frame(minHeight: 30)
            if let rarity = badge.rarityLevel {
                GamificationRarityPill(rarity: rarity)
            }
        }
        .padding(.horizontal, SQSpace.xs + 2)
        .padding(.top, SQSpace.md)
        .padding(.bottom, SQSpace.sm2)
        .frame(maxWidth: .infinity)
        .sqCardBackground(cornerRadius: 18)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre la fiche du badge")
    }

    private var rarityLegend: some View {
        let pills = HStack(spacing: SQSpace.xs + 2) {
            ForEach([GamificationBadgeRarity.common, .rare, .epic, .legendary], id: \.self) { rarity in
                GamificationRarityPill(rarity: rarity)
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.sm) {
                pills
                Text("Rareté du badge").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
            }
            pills
        }
        .padding(.horizontal, SQSpace.xs)
        .accessibilityHidden(true)
    }

    private var lockedList: some View {
        VStack(spacing: 0) {
            ForEach(Array(lockedBadges.enumerated()), id: \.element.id) { index, badge in
                Button {
                    Haptics.selection()
                    openedBadge = OpenedBadge(badge: badge, isUnlocked: false)
                } label: {
                    HStack(spacing: SQSpace.md) {
                        GamificationBadgeMedallion(badge: badge, size: 40, isLocked: true)
                        VStack(alignment: .leading, spacing: 3) {
                            // Nom et rareté sur une ligne s'ils tiennent, sinon la
                            // rareté passe dessous plutôt que de couper le nom.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: SQSpace.xs + 2) {
                                    lockedTitle(badge).fixedSize()
                                    lockedRarity(badge)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    lockedTitle(badge)
                                    lockedRarity(badge)
                                }
                            }
                            if let desc = badge.description {
                                Text(desc)
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.ink2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: SQSpace.sm)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SQColor.labelTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, SQSpace.md2)
                    .padding(.vertical, SQSpace.sm)
                    .frame(minHeight: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .mapRowDivider(index > 0)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Succès : \(badge.title ?? String(localized: "Badge"))")
                .accessibilityValue(badge.description ?? String(localized: "À débloquer"))
                .accessibilityIdentifier("rewards.locked.\(badge.id)")
            }
        }
        .sqCardBackground()
    }

    private func lockedTitle(_ badge: GamificationBadge) -> some View {
        Text(badge.title ?? String(localized: "Badge"))
            .font(SQType.body(.bold))
            .foregroundStyle(SQColor.label)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func lockedRarity(_ badge: GamificationBadge) -> some View {
        if let rarity = badge.rarityLevel {
            GamificationRarityPill(rarity: rarity)
        }
    }

    // MARK: - Activité

    /// Activité groupée par semaine, la plus récente en tête.
    private var eventGroups: [(title: String, events: [GamificationEvent])] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        var groups: [(title: String, events: [GamificationEvent])] = []
        for event in model.events {
            let title: String
            if let date = event.createdAt, let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start {
                let weeks = max(0, calendar.dateComponents([.weekOfYear], from: start, to: thisWeek).weekOfYear ?? 0)
                switch weeks {
                case 0: title = String(localized: "Cette semaine")
                case 1: title = String(localized: "La semaine dernière")
                default: title = String(localized: "Il y a \(weeks) semaines")
                }
            } else {
                title = String(localized: "Plus ancien")
            }
            if let last = groups.indices.last, groups[last].title == title {
                groups[last].events.append(event)
            } else {
                groups.append((title, [event]))
            }
        }
        return groups
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            SQSectionHeader("Activité")
            ForEach(eventGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
                    Text(group.title)
                        .font(SQType.caption(.bold))
                        .foregroundStyle(SQColor.ink2)
                        .padding(.horizontal, SQSpace.xs)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(group.events.enumerated()), id: \.element.id) { index, event in
                            eventRow(event)
                                .mapRowDivider(index > 0)
                        }
                    }
                    .sqCardBackground()
                }
            }
        }
    }

    private func eventRow(_ event: GamificationEvent) -> some View {
        let display = GamificationEventDisplay(kind: event.kind)
        return HStack(spacing: SQSpace.md) {
            SQIconPastille(systemImage: display.icon, size: 36, tint: display.tint, fill: display.tintSoft)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.title)
                    .font(SQType.body(.semibold))
                    .foregroundStyle(SQColor.label)
                if let date = event.createdAt {
                    Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer(minLength: SQSpace.sm)
            if let delta = event.pointsDelta {
                Text(Self.pointsDeltaText(delta))
                    .font(SQType.callout(.bold))
                    .monospacedDigit()
                    .foregroundStyle(delta > 0 ? SQColor.success : delta < 0 ? SQColor.dangerInk : SQColor.labelSecondary)
                    .sqSingleLine()
            }
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.xs + 2)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    /// « +6 pts », « +1 pt », « 0 pt », « −3 pts » : accord et vrai signe moins.
    static func pointsDeltaText(_ delta: Int) -> String {
        let amount = String(localized: "\(abs(delta)) pts")
        if delta > 0 { return "+\(amount)" }
        if delta < 0 { return "−\(amount)" }
        return amount
    }

    private var xpProgress: Double { model.profile?.levelFraction ?? 0 }

    /// « 1 jour de suite » / « 3 jours de suite », « Pas de série en cours » à zéro.
    private var streakLabel: String {
        let days = model.profile?.consecutiveDays ?? 0
        return days > 0 ? String(localized: "\(days) jours de suite") : String(localized: "Pas de série en cours")
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
        case .daily: return String(localized: "Quotidiennes")
        case .weekly: return String(localized: "Hebdo")
        case .seasonal: return String(localized: "Saison")
        case .event: return String(localized: "Évènement")
        case .other: return String(localized: "Autres quêtes")
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
        case .daily: return String(localized: "Quête quotidienne")
        case .weekly: return String(localized: "Quête hebdomadaire")
        case .seasonal: return String(localized: "Quête de saison")
        case .event: return String(localized: "Quête évènement")
        case .other: return String(localized: "Quête")
        }
    }
}

/// Quête v2 en rangée : pastille de cadence, titre et consigne, jauge 6 pt
/// (brique, verte une fois atteinte), progression et gain, et à droite
/// « Réclamer » quand la récompense est encaissable ou « Réclamée ».
private struct QuestRowView: View {
    let quest: GamificationV2Quest
    let cadence: QuestCadenceGroup
    let isClaiming: Bool
    let onClaim: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                summary
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilitySummary)
                    .accessibilityValue(accessibilityProgress)
                Spacer(minLength: 0)
                trailing
            }
            Group {
                progressBar
                metricsRow
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.md)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            SQIconPastille(systemImage: cadence.icon, size: 36, tint: cadence.tint, fill: cadence.tintSoft)
            VStack(alignment: .leading, spacing: 2) {
                Text(quest.title ?? String(localized: "Quête"))
                    .font(SQType.body(.bold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if let description = quest.description, !description.isEmpty {
                    Text(description)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if quest.isClaimable {
            claimButton
        } else if quest.isClaimed {
            Label("Réclamée", systemImage: "checkmark")
                .font(SQType.caption(.bold))
                .foregroundStyle(SQColor.success)
                .labelStyle(.titleAndIcon)
                .sqSingleLine()
                .padding(.top, SQSpace.xs)
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SQColor.chip)
                if quest.progress > 0 {
                    Capsule()
                        .fill(quest.progress >= 1 ? SQColor.success : SQColor.brandRed)
                        .frame(width: max(6, proxy.size.width * min(1, quest.progress)))
                }
            }
        }
        .frame(height: 6)
    }

    private var metricsRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(quest.progressValue) / \(quest.targetValue)")
                .font(SQType.caption(.semibold))
                .monospacedDigit()
                .foregroundStyle(SQColor.labelSecondary)
            Spacer()
            if quest.rewardXp > 0 {
                Text(GamificationView.pointsDeltaText(quest.rewardXp))
                    .font(SQType.caption(.bold))
                    .monospacedDigit()
                    .foregroundStyle(GamificationBadgeFamily.contribution.tint)
            }
        }
    }

    /// Bouton encre de 36 pt, dans une zone de toucher de 44 pt.
    private var claimButton: some View {
        Button(action: onClaim) {
            HStack(spacing: SQSpace.xs2) {
                if isClaiming {
                    SQSpinner()
                        .controlSize(.small)
                        .tint(SQColor.onInk)
                }
                Text(isClaiming ? "Réclamation…" : "Réclamer")
                    .font(SQType.subhead(.bold))
                    .sqSingleLine()
            }
            .foregroundStyle(SQColor.onInk)
            .padding(.horizontal, SQSpace.md2)
            .frame(minHeight: 36)
            .background(SQColor.label, in: Capsule(style: .continuous))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(isClaiming)
        .padding(.vertical, -4)
        .accessibilityLabel("Réclamer la récompense de la quête \(quest.title ?? "")")
    }

    private var accessibilitySummary: String {
        var parts = ["\(cadence.voiceOverLabel) : \(quest.title ?? String(localized: "Quête"))"]
        if let description = quest.description { parts.append(description) }
        return parts.joined(separator: ". ")
    }

    private var accessibilityProgress: String {
        var parts = [String(localized: "\(quest.progressValue) sur \(quest.targetValue)")]
        if quest.rewardXp > 0 { parts.append(String(localized: "plus \(quest.rewardXp) points")) }
        if quest.isClaimed {
            parts.append(String(localized: "récompense réclamée"))
        } else if quest.isClaimable {
            parts.append(String(localized: "récompense à réclamer"))
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
            title = String(localized: "Validation de site")
            icon = "checkmark.seal.fill"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "speedtest", "speed_test":
            title = String(localized: "Speedtest")
            icon = "speedometer"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "daily_login", "login_streak":
            title = String(localized: "Connexion quotidienne")
            icon = "calendar"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "badge_earned", "badge":
            title = String(localized: "Badge obtenu")
            icon = "rosette"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case "photo_upload", "photo":
            title = String(localized: "Photo publiée")
            icon = "camera.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "level_up":
            title = String(localized: "Niveau supérieur")
            icon = "arrow.up.circle.fill"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case "session", "drive_test", "drive":
            title = String(localized: "Session terrain")
            icon = "car.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "identification", "antenna_identification":
            title = String(localized: "Antenne identifiée")
            icon = "antenna.radiowaves.left.and.right"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "post", "story", "comment":
            title = String(localized: "Partage communauté")
            icon = "bubble.left.and.bubble.right.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "coverage", "coverage_upload", "measurement", "coverage_measurement":
            title = String(localized: "Mesure de couverture")
            icon = "dot.radiowaves.left.and.right"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "quest", "quest_completed", "quest_complete", "quest_claim":
            title = String(localized: "Quête accomplie")
            icon = "flag.checkered"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case "streak_bonus":
            title = String(localized: "Bonus de série")
            icon = "flame.fill"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case "new_site_visited":
            title = String(localized: "Nouveau site visité")
            icon = "mappin.and.ellipse"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "new_department":
            title = String(localized: "Nouveau département")
            icon = "map.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "custom_site_created":
            title = String(localized: "Site ajouté à la carte")
            icon = "plus.viewfinder"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "antenna_report":
            title = String(localized: "Signalement accepté")
            icon = "checkmark.shield.fill"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "bug_report_resolved":
            title = String(localized: "Bug confirmé")
            icon = "ladybug.fill"
            tint = SQColor.success; tintSoft = SQColor.successSoft
        case "coverage_session_completed":
            title = String(localized: "Session terrain terminée")
            icon = "car.fill"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case "admob_reward":
            title = String(localized: "Récompense bonus")
            icon = "gift.fill"
            tint = SQColor.warning; tintSoft = SQColor.warningSoft
        case let raw? where raw.hasPrefix("canada_"):
            title = String(localized: "Easter egg Canada")
            icon = "leaf.fill"
            tint = SQColor.danger; tintSoft = SQColor.dangerSoft
        case let raw?:
            // Type inconnu : on nettoie le technique (`bug_report` → « Bug report »).
            let cleaned = raw.replacingOccurrences(of: "_", with: " ")
            title = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
            icon = "sparkles"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        case nil:
            title = String(localized: "Événement")
            icon = "sparkles"
            tint = SQColor.brandRed; tintSoft = SQColor.accentSoft
        }
    }
}

// MARK: - Médaillons de badge

/// Famille d'un badge, celle du catalogue serveur (`gamification-catalog.ts`) :
/// elle donne la teinte du médaillon et le symbole de repli.
enum GamificationBadgeFamily: String, CaseIterable {
    case exploration, coverage, speedtest, validation, contribution, expertise, special

    var title: String {
        switch self {
        case .exploration: return String(localized: "Exploration")
        case .coverage: return String(localized: "Couverture")
        case .speedtest: return String(localized: "Speedtest")
        case .validation: return String(localized: "Validation")
        case .contribution: return String(localized: "Contribution")
        case .expertise: return String(localized: "Expertise")
        case .special: return String(localized: "Spécial")
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .exploration: return "map.fill"
        case .coverage: return "cellularbars"
        case .speedtest: return "speedometer"
        case .validation: return "checkmark.seal.fill"
        case .contribution: return "camera.fill"
        case .expertise: return "graduationcap.fill"
        case .special: return "sparkles"
        }
    }

    /// Teintes de la maquette validée, plus claires en sombre pour garder le
    /// contraste du symbole sur son fond teinté.
    var tint: Color {
        switch self {
        case .speedtest: return SQColor.accentInk
        case .validation: return SQColor.success
        case .contribution: return Self.dynamic(light: 0x8C6313, dark: 0xE3B65E)
        case .exploration: return Self.dynamic(light: 0x0F766E, dark: 0x5EEAD4)
        case .coverage: return Self.dynamic(light: 0x2563EB, dark: 0x93B4FF)
        case .expertise: return Self.dynamic(light: 0x7C3AED, dark: 0xC4B5FD)
        case .special: return Self.dynamic(light: 0xAC4F17, dark: 0xF08B52)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

/// Rareté d'un badge, dite en mots.
enum GamificationBadgeRarity: String {
    case common, rare, epic, legendary

    var title: String {
        switch self {
        case .common: return String(localized: "Commun")
        case .rare: return String(localized: "Rare")
        case .epic: return String(localized: "Épique")
        case .legendary: return String(localized: "Légendaire")
        }
    }
}

extension GamificationBadge {
    /// Symbole, famille et rareté de chaque badge du catalogue serveur, par son
    /// identifiant stable. Des symboles SF plutôt que les emojis du serveur :
    /// ils suivent la teinte, le mode sombre et la taille du texte.
    private static let catalog: [String: (symbol: String, family: GamificationBadgeFamily, rarity: GamificationBadgeRarity)] = [
        "newcomer": ("leaf.fill", .special, .common),
        "explorer_bronze": ("map.fill", .exploration, .common),
        "explorer_silver": ("safari.fill", .exploration, .common),
        "explorer_gold": ("globe.europe.africa.fill", .exploration, .rare),
        "explorer_platinum": ("binoculars.fill", .exploration, .epic),
        "departments_10": ("mappin.and.ellipse", .exploration, .rare),
        "all_departments": ("flag.checkered", .exploration, .legendary),
        "coverage_bronze": ("cellularbars", .coverage, .common),
        "coverage_silver": ("antenna.radiowaves.left.and.right", .coverage, .rare),
        "coverage_gold": ("road.lanes", .coverage, .epic),
        "coverage_sessions_10": ("backpack.fill", .coverage, .rare),
        "multi_cell_hunter": ("circle.hexagongrid.fill", .coverage, .epic),
        "tech_diversity": ("dot.radiowaves.left.and.right", .coverage, .legendary),
        "speedtester_bronze": ("gauge.with.dots.needle.33percent", .speedtest, .common),
        "speedtester_silver": ("gauge.with.dots.needle.67percent", .speedtest, .common),
        "speedtester_gold": ("speedometer", .speedtest, .rare),
        "speedtester_platinum": ("bolt.fill", .speedtest, .epic),
        "speed_demon": ("wind", .speedtest, .legendary),
        "validator_bronze": ("checkmark.seal", .validation, .common),
        "validator_silver": ("checkmark.seal.fill", .validation, .common),
        "validator_gold": ("scope", .validation, .rare),
        "validator_platinum": ("trophy.fill", .validation, .epic),
        "direct_identifier": ("dial.medium.fill", .validation, .rare),
        "offline_mapper": ("wifi.slash", .validation, .epic),
        "photographer_bronze": ("camera.fill", .contribution, .common),
        "photographer_silver": ("camera.aperture", .contribution, .common),
        "photographer_gold": ("photo.stack.fill", .contribution, .rare),
        "reporter_bronze": ("wrench.and.screwdriver.fill", .contribution, .common),
        "reporter_gold": ("magnifyingglass", .contribution, .rare),
        "bug_hunter_bronze": ("ladybug.fill", .contribution, .common),
        "bug_hunter_silver": ("ant.fill", .contribution, .rare),
        "bug_hunter_gold": ("medal.fill", .contribution, .epic),
        "expert_5g_bronze": ("book.fill", .expertise, .common),
        "expert_5g_silver": ("flask.fill", .expertise, .rare),
        "expert_5g_gold": ("graduationcap.fill", .expertise, .epic),
        "expert_5g_platinum": ("crown.fill", .expertise, .legendary),
        "streak_bronze": ("flame.fill", .special, .common),
        "streak_silver": ("flame.fill", .special, .rare),
        "streak_gold": ("flame.fill", .special, .epic),
        "early_adopter": ("star.fill", .special, .legendary),
        "grand_nord": ("snowflake", .special, .legendary)
    ]

    /// Famille : celle du catalogue, sinon celle que renvoie le serveur, sinon
    /// déduite du préfixe de l'identifiant.
    var family: GamificationBadgeFamily {
        if let known = Self.catalog[id]?.family { return known }
        if let category, let family = GamificationBadgeFamily(rawValue: category) { return family }
        let prefixes: [(String, GamificationBadgeFamily)] = [
            ("explorer", .exploration), ("departments", .exploration), ("coverage", .coverage),
            ("speed", .speedtest), ("validator", .validation), ("photographer", .contribution),
            ("reporter", .contribution), ("bug_hunter", .contribution), ("expert", .expertise)
        ]
        return prefixes.first { id.hasPrefix($0.0) }?.1 ?? .special
    }

    var symbol: String { Self.catalog[id]?.symbol ?? family.fallbackSymbol }

    var rarityLevel: GamificationBadgeRarity? {
        if let rarity, let level = GamificationBadgeRarity(rawValue: rarity) { return level }
        return Self.catalog[id]?.rarity
    }
}

/// Médaillon d'un badge : symbole SF dans un carré arrondi teinté par famille,
/// gris quand le badge reste à débloquer.
struct GamificationBadgeMedallion: View {
    let badge: GamificationBadge
    var size: CGFloat = 46
    var isLocked = false

    var body: some View {
        let tint = badge.family.tint
        let shape = RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
        Image(systemName: badge.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(isLocked ? SQColor.labelTertiary : tint)
            .frame(width: size, height: size)
            .background {
                if isLocked {
                    shape.fill(SQColor.chip)
                } else {
                    shape.fill(LinearGradient(
                        colors: [tint.opacity(0.22), tint.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    shape.strokeBorder(tint.opacity(0.32), lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }
}

extension GamificationBadgeRarity {
    /// Commun reste neutre ; plus le badge est rare, plus la pastille se teinte.
    var tint: Color {
        switch self {
        case .common: return SQColor.ink2
        case .rare: return GamificationBadgeFamily.coverage.tint
        case .epic: return GamificationBadgeFamily.expertise.tint
        case .legendary: return GamificationBadgeFamily.contribution.tint
        }
    }
}

/// Rareté écrite en toutes lettres dans une petite pastille teintée.
struct GamificationRarityPill: View {
    let rarity: GamificationBadgeRarity

    var body: some View {
        Text(rarity.title)
            .font(SQFont.body(11, .bold, relativeTo: .caption2))
            .foregroundStyle(rarity.tint)
            .padding(.horizontal, 7)
            .frame(minHeight: 20)
            .background(rarity == .common ? SQColor.chip : rarity.tint.opacity(0.14), in: Capsule(style: .continuous))
            .sqSingleLine()
            .fixedSize()
    }
}

/// Fiche d'un badge : médaillon, nom, rareté, ce qu'il faut faire pour
/// l'obtenir et, s'il est débloqué, la date.
struct GamificationBadgeSheet: View {
    let badge: GamificationBadge
    let isUnlocked: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                HStack {
                    Spacer()
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "rewards.badge.close") { dismiss() }
                }
                VStack(spacing: SQSpace.md) {
                    GamificationBadgeMedallion(badge: badge, size: 88, isLocked: !isUnlocked)
                    Text(badge.title ?? String(localized: "Badge"))
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.center)
                        .sqHeader()
                    if let rarity = badge.rarityLevel {
                        GamificationRarityPill(rarity: rarity)
                    }
                    if let description = badge.description, !description.isEmpty {
                        Text(description)
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.ink2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: SQSpace.xs) {
                    if isUnlocked, let date = badge.unlockedAt {
                        SQFactRow(label: String(localized: "Obtenu le"), value: date.formatted(date: .long, time: .omitted))
                    } else if !isUnlocked {
                        SQFactRow(label: String(localized: "État"), value: String(localized: "À débloquer"))
                    }
                    SQFactRow(label: String(localized: "Famille du badge"), value: badge.family.title)
                    if let rarity = badge.rarityLevel {
                        SQFactRow(label: String(localized: "Rareté"), value: rarity.title)
                    }
                }
                .padding(SQSpace.lg)
                .sqCardBackground()
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.surface.ignoresSafeArea())
        // Pas de détent moyen : iOS 26 y réduit la feuille à 96 % et les
        // cibles de 44 pt tombent à 42.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
