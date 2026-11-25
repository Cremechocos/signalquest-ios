import SwiftUI

// MARK: - Onglets

enum LeaderboardTab: String, CaseIterable, Identifiable {
    case speed
    case points

    var id: String { rawValue }
}

/// Les trois mesures du segmenté (planche Classement du 24/11) : Points, puis les deux
/// débits. « Sessions » n'en fait plus partie, il est fondu dans Points.
enum LeaderboardMetric: String, CaseIterable, Identifiable {
    case points
    case download
    case upload

    var id: String { rawValue }

    var title: String {
        switch self {
        case .points: return "Points"
        case .download: return "Download"
        case .upload: return "Upload"
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
    /// Filtre opérateur (clé canonique) des débits ; sans effet sur Points.
    @Published var operatorKey: String? {
        didSet { if operatorKey != oldValue { invalidateSpeed() } }
    }
    /// Filtre réseau des débits : `5G` ou `4G`.
    @Published var tech: String? {
        didSet { if tech != oldValue { invalidateSpeed() } }
    }

    @Published var speedResult: LeaderboardResult = .empty
    /// Points = XP de gamification, sur la même route que les débits (décision d'Alexandre du 25/11).
    @Published var pointsResult: LeaderboardResult = .emptyPoints
    /// `scope=department` sans département connu pour le membre (400 `DEPARTMENT_REQUIRED`).
    @Published private(set) var speedDepartmentMissing = false
    @Published private(set) var pointsDepartmentMissing = false
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
        speedDepartmentMissing = false
        isLoadingSpeed = false
    }

    private func invalidatePoints() {
        pointsGeneration = UUID()
        pointsResult = .emptyPoints
        pointsError = nil
        pointsDepartmentMissing = false
        isLoadingPoints = false
    }

    /// Le serveur ne connaît pas mon département : ce n'est pas une panne, la page le dit.
    static func isDepartmentMissing(_ error: Error) -> Bool {
        if case let APIError.http(status, code, _, _, _) = error { return status == 400 && code == "DEPARTMENT_REQUIRED" }
        return false
    }

    private let service: LeaderboardServicing
    private let gamification: GamificationServicing?

    init(service: LeaderboardServicing, gamification: GamificationServicing? = nil) {
        self.service = service
        self.gamification = gamification
    }

    var isLoadingCurrent: Bool { tab == .speed ? isLoadingSpeed : isLoadingPoints }

    /// Mesure affichée par le segmenté : l'onglet Points, ou le débit choisi.
    var metric: LeaderboardMetric {
        if tab == .points { return .points }
        return category == "upload" ? .upload : .download
    }

    func selectMetric(_ value: LeaderboardMetric) {
        switch value {
        case .points:
            tab = .points
        case .download:
            tab = .speed
            setCategory("download")
        case .upload:
            tab = .speed
            setCategory("upload")
        }
    }

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
        let requestedFilters = LeaderboardFilters(operatorKey: operatorKey, tech: tech)
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
            let response = try await service.leaderboard(period: requestedPeriod, scope: requestedScope,
                                                         category: requestedCategory, filters: requestedFilters)
            guard speedGeneration == generation, !Task.isCancelled else { return }
            speedResult = response
            speedError = nil
            speedStamp += 1
        } catch {
            guard speedGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            if Self.isDepartmentMissing(error) {
                speedDepartmentMissing = true
            } else {
                speedError = error.userFacingMessage
            }
        }
    }

    func loadPoints() async {
        let generation = UUID()
        pointsGeneration = generation
        let requestedPeriod = period
        let requestedScope = scope
        if AppEnvironment.usesDemoData {
            pointsResult = .demoPoints
            pointsError = nil
            pointsStamp += 1
            return
        }
        isLoadingPoints = true
        pointsError = nil
        defer { if pointsGeneration == generation { isLoadingPoints = false } }
        do {
            let response = try await service.leaderboard(period: requestedPeriod, scope: requestedScope,
                                                         category: "points", filters: .none)
            guard pointsGeneration == generation, !Task.isCancelled else { return }
            pointsResult = response
            pointsError = nil
            pointsStamp += 1
        } catch {
            guard pointsGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            if Self.isDepartmentMissing(error) {
                pointsDepartmentMissing = true
            } else {
                pointsError = error.userFacingMessage
            }
        }
    }

    func setPeriod(_ value: String) {
        guard value != period else { return }
        period = value
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

    func setOperator(_ value: String?) {
        guard value != operatorKey else { return }
        operatorKey = value
        Task { await loadSpeed() }
    }

    func setTech(_ value: String?) {
        guard value != tech else { return }
        tech = value
        Task { await loadSpeed() }
    }

    /// Filtres rangés dans la feuille « Affiner » qui s'écartent du défaut : le nombre
    /// s'affiche en pastille sur le bouton. La mesure et la période sont à l'écran, elles
    /// ne comptent pas.
    var sheetFilterCount: Int {
        (scope == "global" ? 0 : 1) + (operatorKey == nil ? 0 : 1) + (tech == nil ? 0 : 1)
    }

    /// « Réinitialiser » de la feuille : seulement ce que la feuille règle, en une relecture.
    func resetSheetFilters() {
        guard sheetFilterCount > 0 else { return }
        scope = "global"
        operatorKey = nil
        tech = nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Membre dont on ouvre le profil depuis une ligne du classement (SOC-44).
    @State private var profileAuthor: SocialFeedAuthor?
    /// Test ouvert depuis une rangée de débit, quand le serveur donne son identifiant.
    @State private var openedTest: OpenedLeaderboardTest?
    @State private var showsFilters = false
    /// La carte « Ma place » a quitté l'écran : la barre repliée la remplace en bas.
    /// Écrit seulement quand la carte entre ou sort de la pile paresseuse, jamais à
    /// chaque image du défilement (règle de fluidité d'IOS-062).
    @State private var myPlaceOffscreen = false
    private let gamification: GamificationServicing?
    private let currentUser: AuthUser?

    private static let myPlaceAnchor = "leaderboards.myPlace"

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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SQSpace.lg) {
                    header
                    controls
                    // « Ma progression » en tête (choix d'Alexandre du 25/11, à la place de la
                    // carte « Ma place » de la planche) ; mon rang revient en barre au défilement.
                    if let profile = model.profile, let gamification {
                        LeaderboardHeroCard(profile: profile, user: currentUser, gamification: gamification)
                            .id(Self.myPlaceAnchor)
                            .onAppear { myPlaceOffscreen = false }
                            .onDisappear { myPlaceOffscreen = true }
                    }
                    content
                }
                .padding(.horizontal, SQSpace.xl)
                .padding(.top, SQSpace.sm)
                .padding(.bottom, SQDock.floatingContentInset + (myPlace?.rank == nil ? 0 : 64))
                .sqReadableWidth()
            }
            .overlay(alignment: .bottom) {
                if myPlaceOffscreen, let place = myPlace {
                    MyPlaceBar(place: place) {
                        withAnimation(SQMotion.resolve(SQMotion.smooth, reduceMotion)) {
                            proxy.scrollTo(Self.myPlaceAnchor, anchor: .top)
                        }
                    }
                    .padding(.horizontal, SQSpace.lg)
                    .padding(.bottom, SQDock.floatingContentInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sqAnimation(SQMotion.snappy, value: myPlaceOffscreen)
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
        .sheet(item: $openedTest) { test in
            AccountSpeedtestDetailSheet(testId: test.id) { [speedtest = services.speedtest] id in
                try await speedtest.details(id: id)
            }
        }
    }

    /// Une rangée de débit ouvre son test quand le serveur donne son identifiant (test public
    /// sur la carte), sinon le profil du membre, comme avant.
    private func open(_ entry: LeaderboardEntry) {
        if let id = entry.speedtestId, !id.isEmpty {
            openedTest = OpenedLeaderboardTest(id: id)
        } else {
            profileAuthor = entry.user
        }
    }

    /// Retour, titre, puis le bouton des filtres rares avec le nombre de filtres actifs.
    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "leaderboards.back") { dismiss() }
            Text("Classement")
                .font(SQFont.display(26, .bold, relativeTo: .largeTitle))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .sqHeader()
            Spacer(minLength: 0)
            MapChipIconButton(systemImage: "line.3.horizontal.decrease", label: "Filtres", identifier: "leaderboards.filters") {
                showsFilters = true
            }
            .overlay(alignment: .topTrailing) {
                if model.sheetFilterCount > 0 {
                    Text("\(model.sheetFilterCount)")
                        .font(SQType.micro)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.onAccent)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(SQColor.brandRed, in: Capsule(style: .continuous))
                        .offset(x: 2, y: -2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(model.sheetFilterCount > 0 ? Text("\(model.sheetFilterCount) filtre actif") : Text(verbatim: ""))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Segmenté des mesures, puis les puces de période et, à droite, le filtre actif
    /// de la feuille, qu'on retire d'un geste.
    private var controls: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            LeaderboardMetricPicker(selection: model.metric) { model.selectMetric($0) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SQSpace.xs2) {
                    periodChips
                    Spacer(minLength: SQSpace.xs)
                    activeFilterChip
                }
                VStack(alignment: .leading, spacing: SQSpace.xs2) {
                    HStack(spacing: SQSpace.xs2) { periodChips }
                    activeFilterChip
                }
                // Très grand texte : les puces défilent plutôt que de sortir de l'écran.
                VStack(alignment: .leading, spacing: SQSpace.xs2) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SQSpace.xs2) { periodChips }
                    }
                    activeFilterChip
                }
            }
        }
    }

    @ViewBuilder
    private var periodChips: some View {
        ForEach([("week", "7 jours"), ("month", "30 jours"), ("all", "Toujours")], id: \.0) { value, label in
            SQChip(label: label, isSelected: model.period == value,
                   selectedFill: SQColor.label, selectedInk: SQColor.onInk) {
                model.setPeriod(value)
            }
            .fixedSize()
            .accessibilityIdentifier("leaderboards.period.\(value)")
        }
    }

    /// Filtres actifs de la feuille, chacun retiré d'un toucher. Opérateur et réseau ne
    /// s'appliquent qu'aux débits : ils ne s'affichent pas sur Points.
    @ViewBuilder
    private var activeFilterChip: some View {
        let chips = activeChips
        if !chips.isEmpty {
            HStack(spacing: SQSpace.xs2) {
                ForEach(chips, id: \.id) { chip in
                    SQChip(label: chip.label, systemImage: "xmark", restFill: SQColor.chip,
                           spokenLabel: LocalizedStringKey(String(localized: "Retirer le filtre \(chip.label)"))) {
                        chip.remove()
                    }
                    .fixedSize()
                    .accessibilityIdentifier("leaderboards.activeFilter.\(chip.id)")
                }
            }
        }
    }

    private var activeChips: [(id: String, label: String, remove: () -> Void)] {
        var chips: [(id: String, label: String, remove: () -> Void)] = []
        if model.scope == "friends" {
            chips.append(("friends", String(localized: "Mes amis"), { model.setScope("global") }))
        } else if model.scope == "department" {
            chips.append(("department", departmentLabel, { model.setScope("global") }))
        }
        if model.metric != .points {
            if let op = model.operatorKey {
                chips.append(("operator", Self.operatorLabel(op), { model.setOperator(nil) }))
            }
            if let tech = model.tech {
                chips.append(("tech", tech, { model.setTech(nil) }))
            }
        }
        return chips
    }

    /// « Mon dép. », complété du nom servi par le serveur (« Mon dép. · Gard »).
    private var departmentLabel: String {
        let result = model.metric == .points ? model.pointsResult : model.speedResult
        if let name = result.department?.name, !name.isEmpty {
            return String(localized: "Mon dép. · \(name)")
        }
        return String(localized: "Mon dép.")
    }

    /// Nom affiché d'une clé canonique d'opérateur.
    static func operatorLabel(_ key: String) -> String {
        switch key {
        case "BOUYGUES": return "Bouygues"
        case "ORANGE": return "Orange"
        case "FREE": return "Free"
        default: return key
        }
    }

    // MARK: Ma place

    /// Mon rang sur la mesure affichée, pour la barre « Ma place » qui paraît au
    /// défilement. `nil` sans compte, pendant le premier chargement ou sans rang.
    private var myPlace: MyPlaceData? {
        guard currentUser != nil || AppEnvironment.usesDemoData else { return nil }
        let result = model.metric == .points ? model.pointsResult : model.speedResult
        guard let rank = result.myRank else { return nil }
        return MyPlaceData(
            rank: rank.rank, total: rank.total,
            value: rank.entry.map { Self.valueParts($0.value, unit: $0.unit) },
            gained: rank.placesGained
        )
    }

    // MARK: Contenu par mesure

    @ViewBuilder
    private var content: some View {
        switch model.metric {
        case .points: pointsContent
        case .download, .upload: speedContent
        }
    }

    @ViewBuilder
    private var speedContent: some View {
        let entries = model.speedResult.entries
        if model.speedDepartmentMissing {
            departmentMissingState
        } else if model.isLoadingSpeed && entries.isEmpty {
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
            LeaderboardPodiumView(entries: entries.prefix(3).map { entry in
                PodiumEntryData(
                    rank: entry.rank,
                    name: entry.user.displayName,
                    avatarUrl: entry.user.avatarUrl,
                    value: Self.valueParts(entry.value, unit: entry.unit),
                    opensTest: entry.speedtestId != nil,
                    onOpen: { open(entry) }
                )
            })
            .id("speed-\(model.speedStamp)")
            .opacity(model.isLoadingSpeed ? 0.55 : 1)
            rowsCard(isRefreshing: model.isLoadingSpeed, error: model.speedError) {
                ForEach(Array(entries.dropFirst(3).enumerated()), id: \.element.id) { index, entry in
                    LeaderboardRowView(
                        rank: entry.rank,
                        name: entry.user.displayName,
                        avatarUrl: entry.user.avatarUrl,
                        value: Self.valueParts(entry.value, unit: entry.unit),
                        isMe: isMe(entry, in: model.speedResult),
                        showsDivider: index > 0,
                        opensTest: entry.speedtestId != nil,
                        onOpen: { open(entry) }
                    ) {
                        SpeedRowMeta(operatorName: entry.operator, tech: entry.tech, city: entry.city, capturedAt: entry.capturedAt)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pointsContent: some View {
        let entries = model.pointsResult.entries
        if model.pointsDepartmentMissing {
            departmentMissingState
        } else if model.isLoadingPoints && entries.isEmpty {
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
            LeaderboardPodiumView(entries: entries.prefix(3).map { entry in
                PodiumEntryData(
                    rank: entry.rank,
                    name: entry.user.displayName,
                    avatarUrl: entry.user.avatarUrl,
                    value: Self.valueParts(entry.value, unit: entry.unit),
                    onOpen: { profileAuthor = entry.user }
                )
            })
            .id("points-\(model.pointsStamp)")
            .opacity(model.isLoadingPoints ? 0.55 : 1)
            rowsCard(isRefreshing: model.isLoadingPoints, error: model.pointsError) {
                ForEach(Array(entries.dropFirst(3).enumerated()), id: \.element.id) { index, entry in
                    LeaderboardRowView(
                        rank: entry.rank,
                        name: entry.user.displayName,
                        avatarUrl: entry.user.avatarUrl,
                        value: Self.valueParts(entry.value, unit: entry.unit),
                        isMe: isMe(entry, in: model.pointsResult),
                        showsDivider: index > 0,
                        onOpen: { profileAuthor = entry.user }
                    ) {
                        // « N sessions » de la période, servi par le serveur.
                        if let detail = entry.detail, !detail.isEmpty {
                            Text(verbatim: detail)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .sqSingleLine()
                        }
                    }
                }
            }
        }
    }

    /// « Mon dép. » sans département connu : on le dit, et on rend tout le classement.
    private var departmentMissingState: some View {
        VStack(spacing: SQSpace.md) {
            EmptyStateView(title: String(localized: "Pas encore de département"),
                           message: String(localized: "Ton département apparaît après ta première contribution localisée."),
                           systemImage: "mappin.and.ellipse")
            GradientButton("Voir tout le monde", systemImage: "person.2", style: .secondary) {
                model.setScope("global")
            }
            .accessibilityIdentifier("leaderboards.department.everyone")
            .padding(.horizontal, SQSpace.xl)
            .padding(.bottom, SQSpace.lg)
        }
        .sqCardBackground()
    }

    /// État vide ; entre amis, un bouton rend tout le classement d'un geste.
    private func emptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: SQSpace.md) {
            EmptyStateView(title: title, message: message, systemImage: systemImage)
            if model.scope != "global" || model.sheetFilterCount > 0 {
                GradientButton("Voir tout le monde", systemImage: "person.2", style: .secondary) {
                    model.resetSheetFilters()
                }
                .accessibilityIdentifier("leaderboards.empty.everyone")
                .padding(.horizontal, SQSpace.xl)
                .padding(.bottom, SQSpace.lg)
            }
        }
        .sqCardBackground()
    }

    /// Rangées 4 et suivantes dans une seule carte, séparées d'un filet, assombries
    /// pendant un rafraîchissement de filtre.
    @ViewBuilder
    private func rowsCard<Rows: View>(isRefreshing: Bool, error: String?, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 0) {
            rows()
        }
        .padding(.vertical, 2)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqCardBackground()
        .opacity(isRefreshing ? 0.55 : 1)
        .sqAnimation(SQMotion.fast, value: isRefreshing)
        if let error {
            ErrorStateView(title: "Actualisation impossible", message: error)
        }
    }

    /// Le nombre et son unité, posés séparément : Mbit/s, Gbit/s à partir de 1 000
    /// (règle commune des trois apps) ; une autre unité reste telle que le serveur l'envoie.
    static func valueParts(_ value: Double, unit: String) -> (number: String, unit: String) {
        let lowered = unit.lowercased()
        if lowered == "mbps" || lowered == "mbit/s" {
            return (SQUnits.throughputValue(mbps: value), SQUnits.throughputUnit(mbps: value))
        }
        return (Int(value).formatted(), unit)
    }

    /// Débit en une chaîne (« 642 Mbit/s »), pour VoiceOver et les textes ; une autre
    /// unité reste telle que le serveur l'envoie.
    static func valueText(_ value: Double, unit: String) -> String {
        let lowered = unit.lowercased()
        if lowered == "mbps" || lowered == "mbit/s" {
            return SQUnits.throughput(mbps: value)
        }
        return "\(Int(value).formatted()) \(unit)"
    }

    static func ordinal(_ rank: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: rank)) ?? "\(rank)"
    }

    private func isMe(_ entry: LeaderboardEntry, in result: LeaderboardResult) -> Bool {
        if let uid = currentUser?.id { return entry.user.id == uid }
        return result.myRank?.rank == entry.rank
    }
}

/// Identifiant d'un test ouvert depuis le classement, pour `.sheet(item:)`.
private struct OpenedLeaderboardTest: Identifiable {
    let id: String
}

// MARK: - Segmenté des mesures

/// Segmenté encre : la mesure choisie est pleine encre, les autres en gris de puce.
private struct LeaderboardMetricPicker: View {
    let selection: LeaderboardMetric
    let onSelect: (LeaderboardMetric) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 2) { segments }
            } else {
                HStack(spacing: 2) { segments }
            }
        }
        .padding(SQSpace.xxs)
        .background(SQColor.chip, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mesure classée")
    }

    private var segments: some View {
        ForEach(LeaderboardMetric.allCases) { metric in
            let selected = metric == selection
            Button {
                Haptics.selection()
                onSelect(metric)
            } label: {
                Text(LocalizedStringKey(metric.title))
                    .font(SQType.subhead(.bold))
                    .foregroundStyle(selected ? SQColor.onInk : SQColor.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(selected ? SQColor.label : Color.clear, in: Capsule(style: .continuous))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("leaderboards.metric.\(metric.rawValue)")
        }
    }
}

// MARK: - Ma place

private struct MyPlaceData {
    let rank: Int
    let total: Int?
    let value: (number: String, unit: String)?
    /// Places gagnées depuis hier (jour de Paris), seulement quand il y en a.
    var gained: Int? = nil
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

    /// Même lecture de la progression que l'écran Récompenses : l'avancement
    /// (`levelProgress`) et le restant (`pointsToNextLevel`) viennent du serveur.
    private var xpProgress: Double { profile.levelFraction ?? 0 }

    private var remainingXP: Int? { profile.pointsRemaining }

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
                // Très grand texte : les puces s'empilent, sinon la carte débordait de l'écran.
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    VStack(alignment: .leading, spacing: SQSpace.xs2) { chips }
                    medallions
                    rewardsLink
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
            // Très grand texte : la pastille de niveau passe sous le score, qui reste
            // sur une ligne ; à côté, la carte débordait de l'écran (IOS-074).
            if dynamicTypeSize.isAccessibilitySize {
                pointsLine
                LevelPill(level: level, identifier: "leaderboards.hero.level")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    pointsLine
                    Spacer(minLength: SQSpace.xs)
                    LevelPill(level: level, identifier: "leaderboards.hero.level")
                }
            }
            if let remainingXP {
                Text("Encore \(remainingXP.formatted()) pts avant le niveau \(level + 1)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            }
        }
    }

    private var pointsLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
            Text("\(shownPoints)")
                .font(SQFont.display(28, .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("pts")
                .font(SQType.caption(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private var avatarWithRing: some View {
        // L'avatar remplit tout l'intérieur de l'anneau, rond comme lui (demande d'Alexandre
        // du 25/11) : anneau de 72 pt, trait de 4,5 pt, intérieur de 63 pt.
        ZStack {
            XPRing(progress: ringProgress)
            SQAvatar(url: user?.avatarUrl, name: user?.name ?? user?.handle ?? String(localized: "Moi"), size: 62)
                .clipShape(Circle())
        }
        .frame(width: 72, height: 72)
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
                .font(SQType.caption(.bold))
        }
        .foregroundStyle(SQColor.accentInk)
    }

    private func heroChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(SQType.caption(.bold))
                .foregroundStyle(SQColor.ink2)
            // Très grand texte : la puce passe à la ligne au lieu de sortir de la carte (IOS-074).
            if dynamicTypeSize.isAccessibilitySize {
                Text(text)
                    .font(SQType.micro)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(SQColor.ink2)
            } else {
                Text(text)
                    .font(SQType.micro)
                    .monospacedDigit()
                    .sqSingleLine()
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(SQColor.ink2)
            }
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

/// « Ma place » repliée en barre encre au-dessus du dock, quand la carte a quitté
/// l'écran ; un toucher y remonte.
private struct MyPlaceBar: View {
    let place: MyPlaceData
    let onTap: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            Haptics.light()
            onTap()
        } label: {
            HStack(spacing: SQSpace.sm) {
                Text("Ma place").font(SQType.caption(.semibold)).opacity(0.75)
                Text(LeaderboardsView.ordinal(place.rank))
                    .font(SQType.heading)
                    .monospacedDigit()
                if let total = place.total, !dynamicTypeSize.isAccessibilitySize {
                    Text("sur \(total.formatted())").font(SQType.caption).opacity(0.75)
                }
                if let gained = place.gained {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up").font(SQType.caption(.bold)).accessibilityHidden(true)
                        Text(verbatim: gained.formatted()).font(SQType.caption(.bold)).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(gained) places gagnées depuis hier"))
                }
                Spacer(minLength: SQSpace.sm)
                if let value = place.value {
                    Text(verbatim: "\(value.number)\u{00A0}\(value.unit)")
                        .font(SQType.subhead(.bold))
                        .monospacedDigit()
                }
                Image(systemName: "chevron.up")
                    .font(SQType.caption(.bold))
                    .accessibilityHidden(true)
            }
            .sqSingleLine()
            .foregroundStyle(SQColor.onInk)
            .padding(.horizontal, SQSpace.lg)
            .frame(minHeight: 52)
            .background(SQColor.label, in: Capsule(style: .continuous))
            .sqShadowDock()
            .contentShape(Capsule())
        }
        .buttonStyle(SQPressButtonStyle(scale: 0.98))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Remonte à ma place")
        .accessibilityIdentifier("leaderboards.myPlace.bar")
    }
}

// MARK: - Feuille « Affiner »

/// Les filtres rares (qui est classé) et la règle de calcul. La mesure et la période
/// sont à l'écran. Chaque choix s'applique tout de suite.
private struct LeaderboardFiltersSheet: View {
    @ObservedObject var model: LeaderboardsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                MapSheetHeader(title: String(localized: "Affiner"), closeIdentifier: "leaderboards.filters.close") { dismiss() }
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Qui").sqKicker().accessibilityAddTraits(.isHeader)
                    MapSegmented(
                        selection: Binding(get: { model.scope }, set: { model.setScope($0) }),
                        options: [("global", String(localized: "Tout le monde")), ("friends", String(localized: "Mes amis")),
                                  ("department", String(localized: "Mon dép."))],
                        identifier: "leaderboards.filters.scope"
                    )
                }
                if model.metric != .points {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Opérateur").sqKicker().accessibilityAddTraits(.isHeader)
                        FlowLayoutChips(model: model)
                    }
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Réseau").sqKicker().accessibilityAddTraits(.isHeader)
                        MapSegmented(
                            selection: Binding(get: { model.tech ?? "all" }, set: { model.setTech($0 == "all" ? nil : $0) }),
                            options: [("all", String(localized: "Tous")), ("5G", "5G"), ("4G", "4G")],
                            identifier: "leaderboards.filters.tech"
                        )
                    }
                }
                if model.metric != .points {
                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        Text("Comment c’est compté").sqKicker().accessibilityAddTraits(.isHeader)
                        rule("speedometer", "Débit moyen du test", "Le chiffre de l’écran de résultat, pas le pic.")
                        rule("antenna.radiowaves.left.and.right", "Réseau mobile seulement", "Les tests Wi-Fi et filaires ne concourent pas.")
                        rule("person", "Un rang par membre", "Ton meilleur test de la période.")
                        rule("clock", "À jour à chaque test", "Sans délai après l’envoi.")
                    }
                    .padding(.top, SQSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        Rectangle().fill(SQColor.separator).frame(height: 1).accessibilityHidden(true)
                    }
                }
                GradientButton("Afficher le classement") { dismiss() }
                    .accessibilityIdentifier("leaderboards.filters.apply")
                Button {
                    Haptics.selection()
                    model.resetSheetFilters()
                } label: {
                    Text("Réinitialiser")
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(model.sheetFilterCount > 0 ? SQColor.accentInk : SQColor.labelTertiary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.sheetFilterCount == 0)
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

    private func rule(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: icon)
                .font(SQType.subhead(.semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 32, height: 32)
                .background(SQColor.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SQType.subhead(.bold)).foregroundStyle(SQColor.label)
                Text(detail).font(SQType.subhead).foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Puces des opérateurs de la feuille : Tous, puis les quatre réseaux, avec leur couleur
/// doublée du nom.
private struct FlowLayoutChips: View {
    @ObservedObject var model: LeaderboardsViewModel

    private static let operators: [(key: String?, label: String, colorName: String?)] = [
        (nil, "Tous", nil), ("ORANGE", "Orange", "Orange"), ("SFR", "SFR", "SFR"),
        ("BOUYGUES", "Bouygues", "Bouygues Telecom"), ("FREE", "Free", "Free Mobile")
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.xs2) { chips }
            VStack(alignment: .leading, spacing: SQSpace.xs2) { chips }
        }
    }

    private var chips: some View {
        ForEach(Self.operators, id: \.label) { option in
            SQChip(label: option.label, isSelected: model.operatorKey == option.key,
                   dot: option.colorName.map { SQBrand.operatorColor($0) },
                   selectedFill: SQColor.label, selectedInk: SQColor.onInk) {
                model.setOperator(option.key)
            }
            .fixedSize()
            .accessibilityIdentifier("leaderboards.filters.operator.\(option.key ?? "all")")
        }
    }
}

// MARK: - Podium

private struct PodiumEntryData: Identifiable, Equatable {
    let rank: Int
    let name: String
    let avatarUrl: URL?
    let value: (number: String, unit: String)
    /// Le toucher ouvre le test classé plutôt que le profil.
    var opensTest = false
    /// Ouvre le test ou le profil ; `nil` quand le serveur ne donne pas d'identifiant.
    var onOpen: (() -> Void)? = nil

    var id: Int { rank }

    static func == (lhs: PodiumEntryData, rhs: PodiumEntryData) -> Bool {
        lhs.rank == rhs.rank && lhs.name == rhs.name && lhs.avatarUrl == rhs.avatarUrl
            && lhs.value.number == rhs.value.number && lhs.value.unit == rhs.value.unit
    }
}

/// Podium en trois cartes, le premier au centre et plus grand. Sans or ni bronze :
/// le rang se lit au chiffre, à la taille et au libellé.
private struct LeaderboardPodiumView: View {
    let entries: [PodiumEntryData]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Ordre visuel 2 — 1 — 3, le premier au centre.
    private var ordered: [PodiumEntryData] {
        let order = [2: 0, 1: 1, 3: 2]
        return entries.sorted { (order[$0.rank] ?? $0.rank) < (order[$1.rank] ?? $1.rank) }
    }

    var body: some View {
        // Très grand texte : trois colonnes coupaient libellés et valeurs ; les cartes
        // s'empilent alors dans l'ordre des rangs.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: SQSpace.sm) {
                ForEach(entries.sorted { $0.rank < $1.rank }) { entry in card(entry) }
            }
        } else {
            HStack(alignment: .bottom, spacing: SQSpace.sm) {
                ForEach(ordered) { entry in card(entry) }
            }
        }
    }

    private func card(_ entry: PodiumEntryData) -> some View {
        Group {
            if let onOpen = entry.onOpen {
                // Même geste que les rangées : le podium ouvre aussi le profil.
                Button(action: onOpen) { PodiumCard(entry: entry) }
                    .buttonStyle(SQPressButtonStyle(scale: 0.98))
                    .accessibilityHint(entry.opensTest ? Text("Ouvre le test") : Text("Ouvre son profil"))
            } else {
                PodiumCard(entry: entry)
            }
        }
        .accessibilityIdentifier("leaderboard.row.\(entry.rank)")
        // Trois colonnes de même largeur : le premier se distingue par sa hauteur.
        .frame(maxWidth: .infinity)
    }
}

private struct PodiumCard: View {
    let entry: PodiumEntryData

    private var isFirst: Bool { entry.rank == 1 }

    /// Rang écrit et lu par VoiceOver, traduit : « Premier » et « 4e » restaient en
    /// français dans l'app anglaise (SOC-28).
    private var rankLabel: String {
        switch entry.rank {
        case 1: return String(localized: "Premier")
        case 2: return String(localized: "Deuxième")
        case 3: return String(localized: "Troisième")
        default: return LeaderboardsView.ordinal(entry.rank)
        }
    }

    var body: some View {
        VStack(spacing: SQSpace.xs) {
            SQAvatar(url: entry.avatarUrl, name: entry.name, size: isFirst ? 58 : 44)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Text("\(entry.rank)")
                    .font(SQFont.display(isFirst ? 24 : 18, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                Text(rankLabel)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(entry.name)
                .font(SQType.subhead(.bold))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            VStack(spacing: 0) {
                Text(entry.value.number)
                    .font(SQFont.body(isFirst ? 18 : 15, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(entry.value.unit)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SQSpace.xs)
        .padding(.top, isFirst ? SQSpace.lg : SQSpace.md)
        .padding(.bottom, SQSpace.md)
        .sqCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rankLabel), \(entry.name), \(entry.value.number) \(entry.value.unit)")
    }
}

// MARK: - Lignes méta des rangées

/// Méta d'une rangée de débit : liseré et nom de l'opérateur, étiquette de génération,
/// puis « ville · date ». La couleur est toujours doublée d'un nom.
///
/// Les éléments se retirent au lieu d'être tronqués : la ville part d'abord, puis la date,
/// puis la génération. L'opérateur reste.
/// Date relative d'une rangée du Classement. `.short` et non `.abbreviated`, qui
/// donne « -16 s » en français, lu « moins 16 secondes » par VoiceOver (IOS-076,
/// même piège que les appareils E2EE).
enum LeaderboardRowDate {
    static func makeFormatter(locale: Locale = .autoupdatingCurrent) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        formatter.locale = locale
        return formatter
    }
}

private struct SpeedRowMeta: View {
    let operatorName: String?
    let tech: String?
    let city: String?
    let capturedAt: Date?

    nonisolated(unsafe) private static let relativeFormatter = LeaderboardRowDate.makeFormatter()

    private var operatorLabel: String? {
        guard let raw = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return SQBrand.operatorShortName(raw) ?? raw
    }

    private var dateText: String? {
        capturedAt.map { Self.relativeFormatter.localizedString(for: $0, relativeTo: Date()) }
    }

    var body: some View {
        let place = [city, dateText].compactMap { $0 }.joined(separator: " · ")
        ViewThatFits(in: .horizontal) {
            line(tech: true, place: place.isEmpty ? nil : place)
            line(tech: true, place: dateText)
            line(tech: true, place: nil)
            line(tech: false, place: nil)
        }
    }

    private func line(tech showsTech: Bool, place: String?) -> some View {
        HStack(spacing: SQSpace.xs2) {
            if let operatorLabel {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(SQBrand.operatorColor(operatorName))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(verbatim: operatorLabel)
                        .font(SQType.caption(.semibold))
                        .foregroundStyle(SQColor.ink2)
                }
                .fixedSize()
            }
            if showsTech, let tech, !tech.isEmpty {
                Text(verbatim: tech)
                    .font(SQType.caption(.semibold).monospaced())
                    .foregroundStyle(SQBrand.techColor(tech))
                    .padding(.horizontal, 6)
                    .background(SQBrand.techColor(tech).opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .fixedSize()
            }
            if let place {
                Text(verbatim: place)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
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


// MARK: - Rangée de classement

/// Une rangée de la carte qui regroupe les rangs 4 et suivants : rang en chiffres
/// tabulaires, avatar, nom et méta, puis la valeur et son unité. La mienne est teintée
/// et porte « Moi ».
private struct LeaderboardRowView<Meta: View>: View {
    let rank: Int
    let name: String
    let avatarUrl: URL?
    let value: (number: String, unit: String)
    /// Ligne sous la valeur (« 8 420 au total » pour les points d'une période).
    var subValueText: String? = nil
    let isMe: Bool
    /// Filet au-dessus de la rangée, sauf pour la première.
    var showsDivider = false
    /// Le toucher ouvre le test classé plutôt que le profil.
    var opensTest = false
    /// Ouvre le test ou le profil du membre (SOC-44) ; `nil` quand le serveur ne
    /// donne pas son identifiant.
    var onOpen: (() -> Void)? = nil
    @ViewBuilder var meta: () -> Meta
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { row }
                    .buttonStyle(.plain)
                    .accessibilityHint(opensTest ? Text("Ouvre le test") : Text("Ouvre son profil"))
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
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var row: some View {
        Group {
            // Très grand texte : la valeur passe sous le nom, sinon elle sortait de l'écran.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    HStack(spacing: SQSpace.sm2) {
                        rankText
                        avatar
                        nameAndMeta
                    }
                    valueBlock(alignment: .leading)
                }
            } else {
                HStack(spacing: SQSpace.sm2) {
                    rankText
                    avatar
                    nameAndMeta
                    Spacer(minLength: SQSpace.sm)
                    valueBlock(alignment: .trailing)
                        // La valeur classée ne doit jamais être tronquée (« 12 4… ») : elle garde
                        // sa largeur, c'est le nom (scale + lineLimit) qui cède.
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.sm)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(isMe ? SQColor.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var rankText: some View {
        Text("\(rank)")
            .font(SQType.subhead(.bold))
            .monospacedDigit()
            .foregroundStyle(isMe ? SQColor.accentInk : SQColor.labelSecondary)
            .frame(minWidth: 26, alignment: .trailing)
    }

    private var avatar: some View {
        SQAvatar(url: avatarUrl, name: name, size: 40)
            .accessibilityHidden(true)
    }

    private var nameAndMeta: some View {
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
    }

    private func valueBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.number)
                    .font(SQType.callout(.bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                if dynamicTypeSize.isAccessibilitySize {
                    Text(value.unit)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .sqSingleLine()
            if !dynamicTypeSize.isAccessibilitySize {
                Text(value.unit)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .sqSingleLine()
            }
            if let subValueText {
                Text(subValueText)
                    .font(SQType.caption)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
                    .sqSingleLine()
            }
        }
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
            myRank: LeaderboardMyRank(rank: 42, total: 1204, entry: nil, previousRank: 45),
            generatedAt: Date(),
            requestId: "demo"
        )
    }

    static var emptyPoints: LeaderboardResult {
        LeaderboardResult(category: "points", period: "week", scope: "global", entries: [],
                          myRank: nil, generatedAt: nil, requestId: nil)
    }

    /// Points de démonstration, à la forme de `category=points` : XP de la période, et
    /// « N sessions » en détail.
    static var demoPoints: LeaderboardResult {
        let rows: [(String, String, Double, Int)] = [
            ("Camille", "camille", 1240, 14), ("Nora", "nora", 980, 11), ("Alex", "alex", 760, 9),
            ("Lina", "lina", 540, 6), ("Théo", "theo", 430, 5)
        ]
        let entries = rows.enumerated().map { index, row in
            LeaderboardEntry(
                rank: index + 1,
                user: SocialFeedAuthor(id: "u\(index + 1)", name: row.0, handle: row.1, avatarUrl: nil,
                                       isFriend: false, isFollowing: false, liveRadio: nil),
                value: row.2, unit: "pts", detail: "\(row.3) sessions", tech: nil, operator: nil,
                city: nil, capturedAt: nil
            )
        }
        return LeaderboardResult(category: "points", period: "week", scope: "global", entries: entries,
                                 myRank: LeaderboardMyRank(rank: 12, total: 214, entry: nil, previousRank: 15),
                                 generatedAt: Date(), requestId: "demo")
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

// MARK: - Reçu après un test

/// Feuille « Test enregistré » de l'écran de résultat (planche Classement du 24/11) :
/// le passage de rang sur 7 jours, le chiffre classé (la moyenne, pas le pic), l'ancien
/// record, ou la raison d'être hors classement. Ne paraît que quand le serveur a joint
/// un reçu à l'accusé de réception.
struct LeaderboardReceiptSheet: View {
    let receipt: SpeedtestLeaderboardReceipt
    /// Heure de l'accusé de réception.
    var countedAt = Date()
    /// Ouvre le classement ; `nil` quand l'écran ne peut pas le montrer.
    var onShowLeaderboard: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                if let shown = receipt.shown {
                    ranked(shown.category, shown.line)
                } else {
                    Text(exclusionText)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: SQSpace.sm) {
                    if receipt.shown != nil, let onShowLeaderboard {
                        GradientButton("Voir ma place") {
                            dismiss()
                            onShowLeaderboard()
                        }
                        .accessibilityIdentifier("speedtest.receipt.showPlace")
                    }
                    GradientButton("Fermer", style: .secondary) { dismiss() }
                        .accessibilityIdentifier("speedtest.receipt.close")
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.xl)
            .padding(.bottom, SQSpace.xl)
            .sqReadableWidth()
        }
        .background(SQColor.surface.ignoresSafeArea())
        // Le reçu tient dans les deux tiers de l'écran ; la grande hauteur reste pour le très grand texte.
        .presentationDetents(receipt.shown == nil ? [.fraction(0.4), .large] : [.fraction(0.66), .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("speedtest.receipt")
    }

    private var header: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: receipt.shown != nil ? "checkmark" : "minus")
                .font(SQType.callout(.bold))
                .foregroundStyle(receipt.shown != nil ? SQColor.success : SQColor.labelSecondary)
                .frame(width: 40, height: 40)
                .background(receipt.shown != nil ? SQColor.successSoft : SQColor.chip, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Test enregistré")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                Text(receipt.shown != nil
                     ? String(localized: "Compté dans le classement à \(countedAt.formatted(date: .omitted, time: .shortened))")
                     : String(localized: "Hors classement"))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    @ViewBuilder
    private func ranked(_ category: LeaderboardMetric, _ line: SpeedtestLeaderboardReceipt.Line) -> some View {
        let value = line.rankedValue ?? 0
        HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
            Text(SQUnits.throughputValue(mbps: value))
                .font(SQFont.display(40, .bold, relativeTo: .largeTitle))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(SQUnits.throughputUnit(mbps: value)) moyen")
                .font(SQType.subhead(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
        }
        .accessibilityElement(children: .combine)
        if let after = line.rankAfter {
            rankMove(before: line.rankBefore, after: after, category: category)
        }
        VStack(spacing: SQSpace.sm) {
            row("Chiffre classé", String(localized: "Moyenne · \(SQUnits.throughput(mbps: value))"))
            if let peak = line.peakValue { row("Pic", SQUnits.throughput(mbps: peak)) }
            if let total = line.total { row("Membres classés", total.formatted()) }
            if let record = line.previousRecord { row("Ton ancien record", SQUnits.throughput(mbps: record)) }
        }
    }

    private func rankMove(before: Int?, after: Int, category: LeaderboardMetric) -> some View {
        let label = String(localized: "7 jours · \(String(localized: String.LocalizationValue(category.title)))")
        return HStack(spacing: SQSpace.md) {
            if let before, before != after {
                Text(LeaderboardsView.ordinal(before))
                    .font(SQFont.display(26, .bold))
                    .monospacedDigit()
                    .strikethrough()
                    .foregroundStyle(SQColor.labelSecondary)
                VStack(spacing: 2) {
                    Image(systemName: "arrow.right").font(SQType.callout(.bold)).foregroundStyle(SQColor.label)
                    Text(label).font(SQType.caption).foregroundStyle(SQColor.ink2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(before == nil ? String(localized: "Entrée au classement") : String(localized: "Rang inchangé"))
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.ink2)
                Text(label).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                Spacer(minLength: SQSpace.sm)
            }
            Text(LeaderboardsView.ordinal(after))
                .font(SQFont.display(26, .bold))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity)
        .background(SQColor.chip, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rankMoveSpoken(before: before, after: after, label: label))
    }

    private func rankMoveSpoken(before: Int?, after: Int, label: String) -> Text {
        if let before, before != after {
            return Text("\(label) : de \(LeaderboardsView.ordinal(before)) à \(LeaderboardsView.ordinal(after))")
        }
        return Text("\(label) : \(LeaderboardsView.ordinal(after))")
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
            Text(label).font(SQType.subhead).foregroundStyle(SQColor.ink2)
            Spacer(minLength: SQSpace.sm)
            Text(verbatim: value).font(SQType.subhead(.bold)).monospacedDigit().foregroundStyle(SQColor.label)
        }
        .accessibilityElement(children: .combine)
    }

    private var exclusionText: String {
        switch receipt.exclusionReason {
        case "WIFI", "WIRED": return String(localized: "Seuls les tests en réseau mobile comptent au classement.")
        case "PRIVATE": return String(localized: "Un test privé ne compte pas au classement.")
        case "NO_SPEED": return String(localized: "Ce test n’a pas de débit mesuré : il ne compte pas au classement.")
        default: return String(localized: "Ce test ne compte pas au classement.")
        }
    }
}
