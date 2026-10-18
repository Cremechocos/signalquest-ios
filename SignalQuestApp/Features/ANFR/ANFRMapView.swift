import SwiftUI
import MapKit
import CoreLocation

// MARK: - Index de filtrage

/// Un site avec l'opérateur, le type de modif et la génération de chaque antenne
/// DÉJÀ résolus. Ces accesseurs reparsent des chaînes brutes (`lowercased` +
/// `contains`) : les rappeler pour chaque antenne à chaque changement de filtre
/// coûtait des centaines de milliers d'analyses de texte sur le fil principal. Le
/// tableau est construit une fois par relevé (hors fil principal) puis seulement lu.
private struct ANFRIndexedSite: Sendable {
    let site: ANFRMapSite
    /// Parallèles à `site.antennas`. Un support léger n'a pas d'antennes : une ligne
    /// par couple opérateur × type présent, ce qui filtre le support entier.
    let operators: [ANFROperator?]
    let modTypes: [ANFRModType]
    let generations: [ANFRGeneration?]
    let catchUps: [Bool]

    init(site: ANFRMapSite) {
        self.site = site
        if let summary = site.summary {
            let operators: [ANFROperator?] = summary.operators.map { Optional($0) } + (summary.hasOtherOperator || summary.operators.isEmpty ? [nil] : [])
            let types = summary.presentTypes
            self.operators = operators.flatMap { op in types.map { _ in op } }
            self.modTypes = operators.flatMap { _ in types }
            self.generations = self.modTypes.map { _ in nil }
            self.catchUps = self.modTypes.map { _ in summary.catchUp > 0 && summary.catchUp >= summary.total }
        } else {
            operators = site.antennas.map(\.operator)
            modTypes = site.antennas.map(\.modType)
            generations = site.antennas.map(\.generationEnum)
            catchUps = site.antennas.map(\.catchUp)
        }
    }
}

/// Un relevé analysé, prêt à être dessiné.
private struct ANFRLoadedSnapshot: Sendable {
    let sites: [ANFRMapSite]
    let index: [ANFRIndexedSite]
    /// Support → site complet (la fiche relit le site entier, pas la version filtrée).
    let lookup: [String: ANFRMapSite]
    let antennaCount: Int
    let snapshotDate: String?
    let servedFromCache: Bool
    let loadedAt: Date
    /// Supports sans antennes (relevé léger ou comparaison).
    let isLite: Bool
    /// Comparaison : les relevés cumulés, du plus ancien au plus récent.
    let weeks: [String]

    /// Construit l'index d'un relevé : à appeler hors du fil principal.
    static func build(_ snapshot: ANFRMapSnapshot, weeks: [String] = []) -> ANFRLoadedSnapshot {
        let sites = snapshot.sites
        let index = sites.map(ANFRIndexedSite.init(site:))
        var lookup: [String: ANFRMapSite] = [:]
        lookup.reserveCapacity(sites.count)
        for site in sites where lookup[site.supId] == nil {
            lookup[site.supId] = site
        }
        return ANFRLoadedSnapshot(
            sites: sites, index: index, lookup: lookup, antennaCount: snapshot.antennaCount,
            snapshotDate: snapshot.snapshotDate, servedFromCache: snapshot.servedFromCache, loadedAt: Date(),
            isLite: snapshot.isLite, weeks: weeks
        )
    }
}

private extension ANFRModType {
    /// Un bit par type, pour compter les types présents d'un site sans allocation.
    var presenceBit: Int {
        switch self {
        case .new: return 1
        case .activated: return 2
        case .deleted: return 4
        case .added: return 8
        case .modified: return 16
        }
    }
}

private extension ANFROperator {
    var presenceBit: Int {
        switch self {
        case .orange: return 1
        case .sfr: return 2
        case .bouygues: return 4
        case .free: return 8
        }
    }
}

// MARK: - Cadrage et zone

/// Demande de cadrage de la carte. Le numéro la distingue d'une précédente : la
/// carte n'applique que les demandes qu'elle n'a pas encore vues.
struct ANFRCameraRequest: Equatable {
    enum Target {
        /// France métropolitaine et Corse en entier.
        case france
        case region(center: CLLocationCoordinate2D, radiusMeters: Double)
        /// Un support ; `aboveSheet` le place dans la moitié haute, que la fiche ne couvre pas.
        case site(CLLocationCoordinate2D, aboveSheet: Bool)
    }

    let id: Int
    let target: Target

    static func == (lhs: ANFRCameraRequest, rhs: ANFRCameraRequest) -> Bool { lhs.id == rhs.id }
}

/// Zone surveillée annoncée par une notification, dessinée en cercle sur la carte.
struct ANFRZone: Equatable {
    let center: CLLocationCoordinate2D
    let radiusMeters: Double

    static func == (lhs: ANFRZone, rhs: ANFRZone) -> Bool {
        lhs.center.latitude == rhs.center.latitude && lhs.center.longitude == rhs.center.longitude
            && lhs.radiusMeters == rhs.radiusMeters
    }
}

/// Une barre du bandeau des semaines.
struct ANFRWeekBar: Identifiable, Equatable {
    /// `nil` : le dernier relevé.
    let date: String?
    /// La date à écrire (celle du dernier relevé quand `date` est `nil`).
    let displayDate: String?
    let total: Int?
    /// Relevé cumulé par la comparaison affichée.
    var inComparison = false

    var id: String { date ?? "current" }
}

/// Deux relevés comparés ; `to` à `nil` : jusqu'au dernier relevé.
struct ANFRComparison: Equatable, Sendable {
    let from: String
    let to: String?

    var key: String { "diff|\(from)|\(to ?? "current")" }
    /// Deux relevés figés : la réponse ne changera plus.
    var isFrozen: Bool { to != nil }
}

/// Ce que la carte des évolutions dessine : les changements du relevé, ou les
/// supports dont un opérateur a changé les azimuts.
enum ANFRMapLayer: String, CaseIterable, Identifiable {
    case changes, reorientations
    var id: String { rawValue }

    /// Symbole et couleur d'un support réorienté (repère, amas, liste, légende).
    static let reorientationGlyph = "arrow.triangle.2.circlepath"
    static var reorientationColor: Color { SQColor.brandRed }
}

/// Chargement des réorientations du relevé affiché.
enum ANFRReorientationState: Equatable {
    case idle, loading, loaded
    /// Aucune réorientation connue pour cette semaine (pas encore calculée).
    case unknown
    case failed(String)
}

// MARK: - ViewModel

@MainActor
final class ANFRMapViewModel: ObservableObject {
    /// Lecture seule hors du modèle : toute écriture passe par `apply`, qui tient
    /// l'index de filtrage à jour.
    @Published private(set) var sites: [ANFRMapSite] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Vrai une fois un premier chargement terminé : avant, une liste vide veut
    /// dire « pas encore de données », pas « aucun site pour ces filtres ».
    @Published private(set) var hasLoadedSnapshot = false
    /// Le relevé réellement dessiné (`nil` : le dernier). Il reste affiché pendant
    /// le chargement d'un autre : `selectedDate` n'est que ce que l'utilisateur demande.
    @Published private(set) var displayedDate: String?
    /// Copie enregistrée sur l'iPhone, servie faute de réseau.
    @Published private(set) var isShowingCachedCopy = false
    /// Change à chaque relevé affiché : annonce VoiceOver.
    @Published private(set) var loadRevision = 0

    @Published var operatorFilters: Set<ANFROperator> = Set(ANFROperator.allCases) { didSet { scheduleRecompute() } }
    @Published var selectedModTypes: Set<ANFRModType> = Set(ANFRModType.allCases) { didSet { scheduleRecompute() } }
    @Published var selectedGenerations: Set<ANFRGeneration> = Set(ANFRGeneration.allCases) { didSet { scheduleRecompute() } }
    /// Masque les rattrapages : mises en service déclarées longtemps après coup.
    @Published var hidesCatchUp = false { didSet { scheduleRecompute() } }
    @Published var layer: ANFRMapLayer = .changes {
        didSet {
            guard layer != oldValue else { return }
            // Les réorientations sont celles d'une semaine, pas d'une période.
            if comparison != nil, layer == .reorientations {
                layer = .changes
                return
            }
            recomputeNow()
            if layer == .reorientations { Task { await loadReorientations() } }
        }
    }
    @Published private(set) var reorientationState: ANFRReorientationState = .idle
    /// Le serveur sait le relevé léger et la comparaison : il annonce le poids des semaines.
    @Published private(set) var supportsLite = false { didSet { refreshSelectableDates() } }
    /// La comparaison demandée ; `nil` : un seul relevé.
    @Published private(set) var comparison: ANFRComparison?
    /// La comparaison réellement dessinée, et les relevés qu'elle cumule.
    @Published private(set) var displayedComparison: ANFRComparison?
    @Published private(set) var comparisonWeeks: [String] = []
    /// Le relevé dessiné est léger : pas d'antennes, donc pas de génération à filtrer.
    @Published private(set) var displaysLite = false
    /// Supports réorientés du dernier relevé, une fois chargés (absent de `weeks`).
    @Published private(set) var currentWeekReoriented: Int?

    /// Dates d'archive d'un même relevé groupées par année, de la plus récente à la
    /// plus ancienne : la liste fait plusieurs dizaines de lignes (hebdomadaires).
    struct DateSection: Identifiable {
        let year: String
        var dates: [String]
        var id: String { year }
    }

    @Published var availableDates: [String] = [] { didSet { refreshSelectableDates() } }
    @Published private(set) var dateSections: [DateSection] = []
    /// Dates proposées, de la plus récente à la plus ancienne : sans les relevés
    /// d'état complet et sans le dernier relevé, qui a sa propre ligne.
    @Published private(set) var selectableDates: [String] = []
    /// Des relevés complets existent mais ne sont pas proposés.
    @Published private(set) var hidesFullStateDates = false
    @Published var currentSnapshotDate: String? { didSet { refreshSelectableDates() } }
    @Published var selectedDate: String?

    /// Les 12 dernières semaines avec leurs compteurs, pour les barres.
    @Published private(set) var weeks: [ANFRWeekSummary] = []
    /// Antennes du dernier relevé, une fois chargé (il n'est pas dans `weeks`).
    @Published private(set) var currentWeekTotal: Int?

    @Published private(set) var cameraRequest = ANFRCameraRequest(id: 0, target: .france)
    @Published private(set) var zone: ANFRZone?
    @Published var userCoordinate: CLLocationCoordinate2D?

    private let service: ANFRServicing
    private var index: [ANFRIndexedSite] = []
    private var lookup: [String: ANFRMapSite] = [:]
    private var recomputeTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var cameraCounter = 0
    private var displayedSnapshotISO: String?
    /// Réorientations du relevé affiché : un repère par support, et par support
    /// les opérateurs concernés pour la fiche.
    private var reorientationSites: [ANFRMapSite] = []
    private var reorientationLookup: [String: [ANFRReorientation]] = [:]
    /// Semaines déjà demandées (immuables une fois calculées) ; `nil` = aucune connue.
    private var reorientationMemory: [String: ANFRReorientationsWeek?] = [:]
    private var reorientationTask: Task<Void, Never>?

    /// Relevés déjà analysés : un aller-retour entre deux semaines ne retélécharge
    /// ni ne redécode rien. Les relevés datés sont immuables ; le dernier se revalide.
    private var memory: [String: ANFRLoadedSnapshot] = [:]
    private var memoryOrder: [String] = []
    private let memoryCapacity = 4
    /// Au-delà, le dernier relevé est redemandé en arrière-plan.
    private let currentFreshness: TimeInterval = 60

    init(service: ANFRServicing) { self.service = service }

    /// Sites filtrés (opérateurs, types, générations, rattrapages), MÉMOÏSÉS :
    /// recalculés seulement sur changement de sites/filtres, pas à chaque accès — le
    /// body de la carte les lit plusieurs fois par rendu.
    @Published private(set) var filteredSites: [ANFRMapSite] = []
    /// Change à chaque recalcul : la carte compare ce nombre au lieu de hacher la
    /// liste pour savoir si elle doit se resynchroniser.
    @Published private(set) var filteredRevision = 0
    /// Sites concernés par chaque type de modif, pour les opérateurs, générations et
    /// rattrapages retenus (indépendant du filtre de type, qui est ce qu'on veut choisir).
    @Published private(set) var modTypeCounts: [ANFRModType: Int] = [:]
    /// Sites concernés par chaque opérateur, pour les types, générations et
    /// rattrapages retenus (indépendant du filtre d'opérateur).
    @Published private(set) var operatorCounts: [ANFROperator: Int] = [:]

    private func apply(_ loaded: ANFRLoadedSnapshot, date: String?, comparison: ANFRComparison? = nil) {
        sites = loaded.sites
        index = loaded.index
        lookup = loaded.lookup
        displayedDate = date
        displayedComparison = comparison
        comparisonWeeks = comparison == nil ? [] : loaded.weeks
        displaysLite = loaded.isLite
        displayedSnapshotISO = loaded.snapshotDate
        isShowingCachedCopy = loaded.servedFromCache
        if date == nil, comparison == nil { currentWeekTotal = loaded.antennaCount }
        hasLoadedSnapshot = true
        errorMessage = nil
        recomputeNow()
        loadRevision &+= 1
    }

    /// Le site complet d'un support du relevé (la carte n'en dessine qu'une version filtrée).
    func site(supId: String) -> ANFRMapSite? { lookup[supId] }

    /// Plusieurs bascules de puces d'affilée (ou « Réinitialiser », qui change
    /// plusieurs jeux de filtres) ne déclenchent qu'un recalcul et qu'une
    /// resynchronisation des repères de la carte.
    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.recomputeNow()
        }
    }

    private func recomputeNow() {
        recomputeTask?.cancel()
        recomputeTask = nil
        if layer == .reorientations {
            recomputeReorientations()
            return
        }
        let operators = operatorFilters
        let modTypes = selectedModTypes
        let generations = selectedGenerations
        let hideCatchUp = hidesCatchUp
        let everyOperator = operators.count == ANFROperator.allCases.count
        // Un relevé léger ne dit pas les générations : le filtre ne s'y applique pas.
        let everyGeneration = displaysLite || generations.count == ANFRGeneration.allCases.count
        var result: [ANFRMapSite] = []
        result.reserveCapacity(index.count)
        var typeCounts: [ANFRModType: Int] = [:]
        var perOperator: [ANFROperator: Int] = [:]
        for entry in index {
            let antennas = entry.site.antennas
            // Génération et rattrapage ne dépendent ni de l'opérateur ni du type : ils
            // s'appliquent aux compteurs comme au dessin.
            func passesShared(_ i: Int) -> Bool {
                if hideCatchUp, entry.catchUps[i] { return false }
                if !everyGeneration {
                    guard let generation = entry.generations[i], generations.contains(generation) else { return false }
                }
                return true
            }
            // Une antenne d'un opérateur non suivi n'a pas de puce : elle reste visible
            // tant qu'aucun opérateur n'est écarté.
            func passesOperator(_ i: Int) -> Bool {
                guard let op = entry.operators[i] else { return everyOperator }
                return operators.contains(op)
            }
            var keptCount = 0
            var typesPresent = 0
            var operatorsPresent = 0
            for i in entry.modTypes.indices where passesShared(i) {
                let typeAllowed = modTypes.contains(entry.modTypes[i])
                if typeAllowed, let op = entry.operators[i] { operatorsPresent |= op.presenceBit }
                guard passesOperator(i) else { continue }
                typesPresent |= entry.modTypes[i].presenceBit
                if typeAllowed { keptCount += 1 }
            }
            if typesPresent != 0 {
                for type in ANFRModType.allCases where typesPresent & type.presenceBit != 0 { typeCounts[type, default: 0] += 1 }
            }
            if operatorsPresent != 0 {
                for op in ANFROperator.allCases where operatorsPresent & op.presenceBit != 0 { perOperator[op, default: 0] += 1 }
            }
            // Le repère ne garde que les antennes retenues : un site Orange + Free
            // filtré sur Free s'affichait en Orange. La fiche relit le site entier.
            guard keptCount > 0 else { continue }
            if entry.site.summary != nil || keptCount == antennas.count {
                result.append(entry.site)
                continue
            }
            var kept: [ANFRMapAntenna] = []
            kept.reserveCapacity(keptCount)
            for i in antennas.indices where passesShared(i) && passesOperator(i) && modTypes.contains(entry.modTypes[i]) {
                kept.append(antennas[i])
            }
            let site = entry.site
            result.append(ANFRMapSite(supId: site.supId, latitude: site.latitude, longitude: site.longitude,
                                      city: site.city, antennas: kept))
        }
        filteredSites = result
        modTypeCounts = typeCounts
        operatorCounts = perOperator
        filteredRevision &+= 1
    }

    /// Couche des réorientations : seul le filtre d'opérateur s'applique.
    private func recomputeReorientations() {
        let operators = operatorFilters
        let everyOperator = operators.count == ANFROperator.allCases.count
        var result: [ANFRMapSite] = []
        var perOperator: [ANFROperator: Int] = [:]
        for site in reorientationSites {
            for op in site.operators { perOperator[op, default: 0] += 1 }
            let kept = site.antennas.filter { $0.operator.map(operators.contains) ?? everyOperator }
            guard !kept.isEmpty else { continue }
            result.append(kept.count == site.antennas.count ? site : ANFRMapSite(
                supId: site.supId, latitude: site.latitude, longitude: site.longitude, city: site.city, antennas: kept
            ))
        }
        filteredSites = result
        modTypeCounts = [:]
        operatorCounts = perOperator
        filteredRevision &+= 1
    }

    /// Les opérateurs réorientés d'un support au relevé affiché (vide hors couche chargée).
    func reorientations(supId: String) -> [ANFRReorientation] { reorientationLookup[supId] ?? [] }

    // MARK: Réorientations

    /// Réorientations du relevé choisi ; une réponse arrivée après un autre choix est ignorée.
    func loadReorientations() async {
        guard layer == .reorientations else { return }
        reorientationTask?.cancel()
        let date = selectedDate
        let task = Task { await fetchReorientations(date: date) }
        reorientationTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func fetchReorientations(date: String?) async {
        let key = date ?? "current"
        if let remembered = reorientationMemory[key] {
            applyReorientations(remembered, date: date)
            return
        }
        reorientationState = .loading
        do {
            let week: ANFRReorientationsWeek?
            #if DEBUG
            if AppEnvironment.usesDemoData {
                week = date == nil ? ANFRDemoData.reorientations : nil
            } else {
                week = try await service.reorientations(date: date)
            }
            #else
            week = try await service.reorientations(date: date)
            #endif
            guard !Task.isCancelled, date == selectedDate else { return }
            // Le dernier relevé peut encore recevoir son calcul : seules les semaines datées restent.
            if date != nil { reorientationMemory[key] = .some(week) }
            applyReorientations(week, date: date)
        } catch {
            guard !error.isCancellation, date == selectedDate else { return }
            reorientationSites = []
            reorientationLookup = [:]
            reorientationState = .failed(error.userFacingMessage)
            recomputeNow()
        }
    }

    private func applyReorientations(_ week: ANFRReorientationsWeek?, date: String?) {
        reorientationSites = week?.sites ?? []
        reorientationLookup = Dictionary(grouping: week?.reorientations ?? [], by: \.supId)
        reorientationState = week == nil ? .unknown : .loaded
        if date == nil { currentWeekReoriented = week.map { Set($0.reorientations.map(\.supId)).count } }
        recomputeNow()
        loadRevision &+= 1
    }

    // MARK: Dates

    private func refreshSelectableDates() {
        let current = currentSnapshotDate
        let sorted = availableDates.sorted(by: >)
        // Sans relevé léger, les relevés de 2022 pèsent des dizaines de Mo : écartés.
        let hidesHeavy = !supportsLite
        hidesFullStateDates = hidesHeavy && sorted.contains(where: ANFRMapPolicy.isFullStateDate)
        let selectable = sorted.filter { !(hidesHeavy && ANFRMapPolicy.isFullStateDate($0)) && $0 != current }
        selectableDates = selectable
        dateSections = Self.sections(from: selectable)
    }

    private static func sections(from dates: [String]) -> [DateSection] {
        var result: [DateSection] = []
        for date in dates {
            let year = String(date.prefix(4))
            if let last = result.last, last.year == year {
                result[result.count - 1].dates.append(date)
            } else {
                result.append(DateSection(year: year, dates: [date]))
            }
        }
        return result
    }

    /// Les relevés, du plus récent au plus ancien ; `nil` est le dernier.
    var timeline: [String?] {
        var dates: [String?] = [nil]
        dates.append(contentsOf: selectableDates.map { Optional($0) })
        return dates
    }

    private var timelineIndex: Int { timeline.firstIndex(of: selectedDate) ?? 0 }
    var canStepOlder: Bool { timelineIndex + 1 < timeline.count }
    var canStepNewer: Bool { timelineIndex > 0 }

    /// Relevé précédent (`offset` 1) ou suivant (`offset` -1).
    func step(_ offset: Int) async {
        let target = timelineIndex + offset
        guard timeline.indices.contains(target) else { return }
        await selectDate(timeline[target])
    }

    /// Les barres du bandeau : les 12 derniers relevés datés, du plus ancien au plus
    /// récent, puis le dernier relevé.
    var weekBars: [ANFRWeekBar] {
        guard !selectableDates.isEmpty || currentSnapshotDate != nil else { return [] }
        let reoriented = layer == .reorientations
        let cumulated = Set(comparisonWeeks)
        var bars: [ANFRWeekBar] = selectableDates.prefix(12).reversed().map { date in
            let week = weeks.first(where: { $0.date == date })
            return ANFRWeekBar(date: date, displayDate: date, total: reoriented ? week?.reoriented : week?.total,
                               inComparison: cumulated.contains(date))
        }
        bars.append(ANFRWeekBar(date: nil, displayDate: currentSnapshotDate, total: reoriented ? currentWeekReoriented : currentWeekTotal,
                                inComparison: displayedComparison != nil && displayedComparison?.to == nil))
        return bars
    }

    /// Ce que le bandeau et le sélecteur disent du relevé : jamais en tant que parc.
    var dateLabel: String {
        let raw = hasLoadedSnapshot
            ? (displayedDate ?? currentSnapshotDate ?? displayedSnapshotISO)
            : (selectedDate ?? currentSnapshotDate)
        return ANFRText.date(raw, month: .abbreviated) ?? String(localized: "Dernier relevé")
    }

    /// « 14 mai → 11 juin 2026 » : la comparaison demandée, `nil` hors comparaison.
    /// L'année du début n'est écrite que si elle diffère de celle de la fin.
    var comparisonLabel: String? {
        guard let comparison else { return nil }
        guard let end = comparison.to ?? currentSnapshotDate else {
            return (ANFRText.date(comparison.from, month: .abbreviated) ?? comparison.from) + " → " + String(localized: "Dernier relevé")
        }
        let sameYear = comparison.from.prefix(4) == end.prefix(4)
        let from = ANFRText.date(comparison.from, month: .abbreviated, year: !sameYear) ?? comparison.from
        let to = ANFRText.date(end, month: .abbreviated) ?? end
        return "\(from) → \(to)"
    }

    /// Le relevé demandé, pour dire ce qu'on charge.
    var pendingDateLabel: String {
        ANFRText.date(selectedDate ?? currentSnapshotDate, month: .abbreviated) ?? String(localized: "Dernier relevé")
    }

    // MARK: Chargement

    func load(focus: ANFRFocus? = nil) async {
        #if DEBUG
        if AppEnvironment.usesDemoData {
            let demo = ANFRLoadedSnapshot.build(ANFRDemoData.mapSnapshot)
            apply(demo, date: nil)
            availableDates = ANFRDemoData.archiveDates.dates
            currentSnapshotDate = ANFRDemoData.archiveDates.current
            supportsLite = true
            return
        }
        #endif
        guard !hasLoadedSnapshot else { return }
        // Un relevé visé par une notification se résout avec la liste des dates,
        // petite réponse qu'on attend alors avant de charger.
        if focus?.date != nil { await loadArchiveDates() }
        if let focus { selectedDate = applyFocus(focus) }
        // Les dates d'archive (une petite réponse) n'attendent plus le relevé, bien
        // plus lourd : le sélecteur est utilisable tout de suite. En `async let`, elles
        // s'arrêtent avec l'écran au lieu de survivre à une tâche annulée.
        async let dates: Void = loadArchiveDatesIfNeeded()
        async let weeksLoad: Void = loadWeeks()
        await startSnapshotLoad()
        await dates
        await weeksLoad
    }

    /// Ouvre un relevé et/ou une zone demandés par une notification, écran déjà ouvert.
    func open(_ focus: ANFRFocus) async {
        if focus.date != nil, availableDates.isEmpty { await loadArchiveDates() }
        let target = applyFocus(focus)
        if hasLoadedSnapshot || isLoading {
            await selectDate(target)
        } else {
            selectedDate = target
            await load()
        }
    }

    /// Pose la zone et le cadrage d'une demande d'ouverture, et renvoie le relevé à
    /// ouvrir. Un relevé introuvable ou d'état complet donne le dernier relevé (`nil`).
    private func applyFocus(_ focus: ANFRFocus) -> String? {
        if let lat = focus.zoneLatitude, let lon = focus.zoneLongitude {
            let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let radius = focus.radiusMeters ?? ANFRFocus.defaultRadiusMeters
            zone = ANFRZone(center: center, radiusMeters: radius)
            requestCamera(.region(center: center, radiusMeters: radius))
        }
        guard let date = focus.date, selectableDates.contains(date) else { return nil }
        return date
    }

    func requestCamera(_ target: ANFRCameraRequest.Target) {
        cameraCounter += 1
        cameraRequest = ANFRCameraRequest(id: cameraCounter, target: target)
    }

    /// Lance (en remplaçant toute demande en cours) le chargement du relevé voulu.
    /// L'annulation de l'appelant s'y propage.
    private func startSnapshotLoad() async {
        snapshotTask?.cancel()
        let task = Task { await loadSnapshot() }
        snapshotTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func loadSnapshot() async {
        guard !Task.isCancelled else { return }
        // Une réponse arrivée après un autre choix est ignorée : elle aurait affiché
        // les sites de la date A sous le libellé de la date B.
        let date = selectedDate
        let comparison = comparison
        let key = requestKey
        #if DEBUG
        if AppEnvironment.usesDemoData {
            if let comparison {
                apply(ANFRLoadedSnapshot.build(ANFRDemoData.mapDiff.snapshot, weeks: ANFRDemoData.mapDiff.weeks),
                      date: nil, comparison: comparison)
            } else {
                apply(ANFRLoadedSnapshot.build(ANFRDemoData.mapSnapshot), date: nil)
            }
            return
        }
        #endif
        let frozen = comparison?.isFrozen ?? (date != nil)
        var shownFromMemory = false
        if let hit = recall(key) {
            apply(hit, date: date, comparison: comparison)
            isLoading = false
            // Un relevé daté ne change plus ; le dernier est redemandé s'il est ancien.
            if frozen || Date().timeIntervalSince(hit.loadedAt) < currentFreshness { return }
            shownFromMemory = true
        } else {
            isLoading = true
        }
        errorMessage = nil
        defer { if key == requestKey { isLoading = false } }
        do {
            let snapshot: ANFRMapSnapshot
            var cumulated: [String] = []
            if let comparison {
                let diff = try await service.mapDiff(from: comparison.from, to: comparison.to)
                snapshot = diff.snapshot
                cumulated = diff.weeks
            } else if let date, loadsLite(date) {
                snapshot = try await service.mapSnapshotLite(date: date)
            } else {
                snapshot = try await service.mapSnapshot(date: date)
            }
            guard key == requestKey else { return }
            // L'index se construit hors du fil principal : la pastille de chargement
            // reste animée pendant l'analyse des antennes.
            let built = await Task.detached(priority: .userInitiated) { ANFRLoadedSnapshot.build(snapshot, weeks: cumulated) }.value
            guard key == requestKey else { return }
            remember(built, for: key)
            apply(built, date: date, comparison: comparison)
        } catch {
            // Le relevé affiché reste à l'écran ; une revalidation manquée ne dit rien.
            if !error.isCancellation, key == requestKey, !shownFromMemory { errorMessage = Self.message(for: error, comparison: comparison) }
        }
    }

    /// Ce que l'écran demande : un relevé ou une comparaison.
    private var requestKey: String { comparison?.key ?? selectedDate ?? "current" }

    /// Relevé chargé en léger : les relevés de 2022 et les semaines très lourdes.
    private func loadsLite(_ date: String) -> Bool {
        guard supportsLite else { return false }
        if ANFRMapPolicy.isFullStateDate(date) { return true }
        return (weeks.first { $0.date == date }?.antennaCount ?? 0) > ANFRMapPolicy.liteAntennaThreshold
    }

    private static func message(for error: Error, comparison: ANFRComparison?) -> String {
        if comparison != nil, case APIError.http(let status, _, _, _, _) = error, status == 422 {
            return String(localized: "Compare au plus \(ANFRMapPolicy.maxComparedWeeks) relevés d’écart.")
        }
        return error.userFacingMessage
    }

    private func recall(_ key: String) -> ANFRLoadedSnapshot? {
        guard let hit = memory[key] else { return nil }
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        return hit
    }

    private func remember(_ snapshot: ANFRLoadedSnapshot, for key: String) {
        // Une copie du disque servie faute de réseau ne doit pas passer pour fraîche.
        guard !snapshot.servedFromCache else { return }
        memory[key] = snapshot
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        while memoryOrder.count > memoryCapacity {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    private func loadArchiveDatesIfNeeded() async {
        if availableDates.isEmpty { await loadArchiveDates() }
    }

    /// Dates d'archive : appelée aussi à l'ouverture du sélecteur quand la liste
    /// est restée vide (réponse manquée).
    func loadArchiveDates() async {
        guard let meta = try? await service.archiveDates() else { return }
        availableDates = meta.dates
        currentSnapshotDate = meta.current
    }

    /// Les barres du bandeau ; sans elles le bandeau n'affiche que les dates.
    func loadWeeks() async {
        guard let loaded = try? await service.archiveWeeks(count: 12) else { return }
        supportsLite = loaded.contains { $0.siteCount != nil }
        weeks = supportsLite ? loaded : loaded.filter { !ANFRMapPolicy.isFullStateDate($0.date) }
    }

    /// « Réessayer » : relit le relevé ET les dates d'archive, que le premier
    /// chargement a pu manquer.
    func reload() async {
        if layer == .reorientations, case .failed = reorientationState { await loadReorientations() }
        await startSnapshotLoad()
        if availableDates.isEmpty { await loadArchiveDates() }
        if weeks.isEmpty { await loadWeeks() }
    }

    func selectDate(_ requested: String?) async {
        var date = requested
        // Sans relevé léger, un relevé de 2022 pèse des dizaines de Mo : on ouvre le dernier.
        if let candidate = date, !supportsLite, ANFRMapPolicy.isFullStateDate(candidate) { date = nil }
        if date != nil, date == currentSnapshotDate { date = nil }
        // Choisir un relevé quitte la comparaison.
        let leavesComparison = comparison != nil
        comparison = nil
        if date == selectedDate, !leavesComparison {
            // Premier chargement en échec : « Dernier relevé » doit réessayer.
            if !isLoading, !hasLoadedSnapshot || errorMessage != nil { await reload() }
            return
        }
        selectedDate = date
        // Le relevé précédent reste dessiné jusqu'à l'arrivée du nouveau. Les choix
        // successifs annulent la requête précédente au lieu de télécharger plusieurs relevés.
        async let reorientationsLoad: Void = loadReorientations()
        await startSnapshotLoad()
        await reorientationsLoad
    }

    // MARK: Comparaison

    /// Relevés du plus récent au plus ancien, le dernier compris.
    private var orderedDates: [String] {
        var dates = availableDates
        if let current = currentSnapshotDate, !dates.contains(current) { dates.append(current) }
        return dates.sorted(by: >)
    }

    /// Fins possibles d'une comparaison : le dernier relevé (`nil`), puis chaque relevé
    /// qui en a un plus ancien.
    var comparisonEnds: [String?] {
        let dates = orderedDates.filter { $0 != currentSnapshotDate }
        return [nil] + dates.dropLast().map { Optional($0) }
    }

    /// Débuts possibles pour la fin `to` : les relevés plus anciens, au plus
    /// `maxComparedWeeks` relevés d'écart (le plafond du serveur).
    func comparisonStarts(to: String?) -> [String] {
        let dates = orderedDates
        let end = to ?? currentSnapshotDate
        guard let end, let index = dates.firstIndex(of: end) else { return [] }
        return Array(dates.dropFirst(index + 1).prefix(ANFRMapPolicy.maxComparedWeeks))
    }

    /// Montre ce qui a changé entre deux relevés, en net sur la période.
    func compare(from: String, to: String?) async {
        let request = ANFRComparison(from: from, to: to == currentSnapshotDate ? nil : to)
        guard supportsLite, request != comparison else { return }
        layer = .changes
        reorientationTask?.cancel()
        comparison = request
        await startSnapshotLoad()
    }

    /// Revient au relevé choisi avant la comparaison.
    func endComparison() async {
        guard comparison != nil else { return }
        comparison = nil
        await startSnapshotLoad()
    }

    // MARK: Filtres

    func toggleOperator(_ op: ANFROperator) {
        if operatorFilters.contains(op) {
            let next = operatorFilters.subtracting([op])
            operatorFilters = next.isEmpty ? [op] : next
        } else {
            operatorFilters.insert(op)
        }
    }

    func toggleModType(_ type: ANFRModType) {
        if selectedModTypes.contains(type) {
            let next = selectedModTypes.subtracting([type])
            selectedModTypes = next.isEmpty ? [type] : next
        } else {
            selectedModTypes.insert(type)
        }
    }

    func toggleGeneration(_ generation: ANFRGeneration) {
        if selectedGenerations.contains(generation) {
            let next = selectedGenerations.subtracting([generation])
            selectedGenerations = next.isEmpty ? [generation] : next
        } else {
            selectedGenerations.insert(generation)
        }
    }

    func resetFilters() {
        operatorFilters = Set(ANFROperator.allCases)
        selectedModTypes = Set(ANFRModType.allCases)
        selectedGenerations = Set(ANFRGeneration.allCases)
        hidesCatchUp = false
    }

    var activeFilterCount: Int {
        var count = 0
        if operatorFilters.count != ANFROperator.allCases.count { count += 1 }
        // Types, générations et rattrapages ne s'appliquent pas aux réorientations.
        if layer == .reorientations { return count }
        if selectedModTypes.count != ANFRModType.allCases.count { count += 1 }
        if !displaysLite, selectedGenerations.count != ANFRGeneration.allCases.count { count += 1 }
        if hidesCatchUp { count += 1 }
        return count
    }

    var hasActiveFilters: Bool { activeFilterCount > 0 }

    /// Phrase lue par VoiceOver à l'arrivée d'un relevé : le nombre de supports et leur répartition.
    var accessibilitySummary: String {
        if layer == .reorientations {
            return String(localized: "Relevé du \(dateLabel) : \(filteredSites.count.formatted()) supports réorientés")
        }
        let counts = ANFRModType.allCases
            .compactMap { type in modTypeCounts[type].map { "\(type.label) : \($0.formatted())" } }
            .joined(separator: ", ")
        let head = displayedComparison != nil
            ? String(localized: "Comparaison \(comparisonLabel ?? dateLabel) : \(filteredSites.count.formatted()) supports modifiés")
            : String(localized: "Relevé du \(dateLabel) : \(filteredSites.count.formatted()) supports modifiés")
        return counts.isEmpty ? head : "\(head). \(counts)"
    }
}

// MARK: - Liste des supports

/// Ordre de la liste des supports modifiés.
enum ANFRSiteListSort: String, CaseIterable, Identifiable {
    case type, city, distance
    var id: String { rawValue }
}

struct ANFRSiteRow: Identifiable, Equatable {
    let site: ANFRMapSite
    let title: String
    let detail: String
    let modType: ANFRModType
    let distance: CLLocationDistance?

    var id: String { site.supId }
}

/// Filtrage et tri de la liste : l'alternative à la carte pour VoiceOver et l'iPad.
enum ANFRSiteList {
    static func rows(from sites: [ANFRMapSite], query: String, sort: ANFRSiteListSort, origin: CLLocationCoordinate2D?,
                     layer: ANFRMapLayer = .changes) -> [ANFRSiteRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let originLocation = origin.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        var rows: [ANFRSiteRow] = []
        rows.reserveCapacity(sites.count)
        for site in sites where matches(site, needle: needle) {
            let operators = site.operators
            let operatorText = operators.isEmpty ? String(localized: "Autre opérateur") : operators.map(\.label).joined(separator: ", ")
            var detail: String
            if layer == .reorientations {
                detail = "\(operatorText) · " + String(localized: "Réorienté")
            } else {
                detail = "\(operatorText) · \(site.dominantModType.label)"
                if site.changeCount > 1 { detail += " · " + String(localized: "\(site.changeCount) antennes") }
            }
            rows.append(ANFRSiteRow(
                site: site,
                title: site.city.isEmpty ? String(localized: "Support \(site.supId)") : ANFRText.city(site.city),
                detail: detail,
                modType: site.dominantModType,
                distance: originLocation.map { CLLocation(latitude: site.latitude, longitude: site.longitude).distance(from: $0) }
            ))
        }
        switch sort {
        case .type:
            rows.sort { lhs, rhs in
                lhs.modType.priority != rhs.modType.priority
                    ? lhs.modType.priority > rhs.modType.priority
                    : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .city:
            rows.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .distance:
            rows.sort { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }
        }
        return rows
    }

    /// Recherche sur la commune, le code du support et l'adresse des antennes, sans
    /// tenir compte de la casse ni des accents.
    static func matches(_ site: ANFRMapSite, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if site.supId.range(of: needle, options: options) != nil { return true }
        if site.city.range(of: needle, options: options) != nil { return true }
        return site.antennas.contains { $0.address?.range(of: needle, options: options) != nil }
    }
}

// MARK: - Screen

struct ANFRMapView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model: ANFRMapViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedSite: ANFRMapSite?
    @State private var showFilters = false
    @State private var showDatePicker = false
    @State private var showList = false
    @State private var showsStats = false
    /// Sur iPad, la liste reste à côté de la carte ; sur iPhone elle s'ouvre en feuille.
    @State private var showsSidePanel = true
    @State private var clusterSelection: ANFRClusterSelection?
    /// Support choisi dans une feuille (liste, amas), ouvert à sa fermeture : deux
    /// feuilles ne se présentent pas ensemble.
    @State private var pendingSite: ANFRMapSite?
    @State private var showsUserLocation = false
    @State private var locationNotice: String?

    init(service: ANFRServicing) {
        _model = StateObject(wrappedValue: ANFRMapViewModel(service: service))
    }

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    private var listTitle: LocalizedStringKey {
        model.layer == .reorientations ? "Supports réorientés" : "Supports modifiés"
    }

    var body: some View {
        Group {
            if isRegularWidth && showsSidePanel {
                HStack(spacing: 0) {
                    mapStack
                    Divider()
                    ANFRSiteListView(
                        title: listTitle, sites: model.filteredSites, revision: model.filteredRevision,
                        origin: model.userCoordinate, showsSearch: true, layer: model.layer, onClose: nil
                    ) { site in focus(on: site) }
                        .frame(width: 380)
                        .background(SQColor.bg)
                }
            } else {
                mapStack
            }
        }
        .navigationTitle("Carte ANFR")
        .toolbarTitleInlineCompat()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    locate()
                } label: {
                    Image(systemName: "location")
                }
                .accessibilityLabel("Me localiser")
                Button {
                    Haptics.light()
                    if isRegularWidth { showsSidePanel.toggle() } else { showList = true }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel(model.layer == .reorientations ? "Liste des supports réorientés" : "Liste des supports modifiés")
                .accessibilityIdentifier("anfr.map.list")
                Button {
                    Haptics.light()
                    showsStats = true
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .accessibilityLabel("Statistiques ANFR")
                .accessibilityIdentifier("anfr.map.stats")
            }
        }
        .navigationDestination(isPresented: $showsStats) {
            ANFRStatsView(service: services.anfr)
        }
        .sheet(item: $selectedSite) { site in
            ANFRSiteDetailSheet(
                site: site, service: services.anfr,
                snapshotDate: site.summary?.lastChangeDate ?? model.displayedDate ?? model.currentSnapshotDate,
                reorientations: model.reorientations(supId: site.supId),
                showsChanges: model.site(supId: site.supId) != nil
            )
            .id(site.supId)
        }
        .sheet(isPresented: $showFilters) {
            ANFRMapFilterSheet(model: model)
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .presentationBackgroundCompat(SQColor.bg)
        }
        .sheet(isPresented: $showDatePicker) {
            ANFRDatePickerSheet(model: model)
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .presentationBackgroundCompat(SQColor.bg)
        }
        .sheet(isPresented: $showList, onDismiss: openPendingSite) {
            ANFRSiteListView(
                title: listTitle, sites: model.filteredSites, revision: model.filteredRevision,
                origin: model.userCoordinate, showsSearch: true, layer: model.layer, onClose: { showList = false }
            ) { site in
                pendingSite = site
                showList = false
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundCompat(SQColor.bg)
        }
        .sheet(item: $clusterSelection, onDismiss: openPendingSite) { selection in
            ANFRSiteListView(
                title: "Supports à cet emplacement", sites: selection.sites, revision: 0,
                origin: model.userCoordinate, showsSearch: false, layer: model.layer, onClose: { clusterSelection = nil }
            ) { site in
                pendingSite = site
                clusterSelection = nil
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundCompat(SQColor.bg)
        }
        .task {
            // Une notification a pu viser un relevé ou une zone : lue une seule fois.
            let focus = router.pendingANFRFocus
            router.pendingANFRFocus = nil
            await model.load(focus: focus)
        }
        .onChangeCompat(of: router.pendingANFRFocus) { _, focus in
            guard let focus else { return }
            router.pendingANFRFocus = nil
            Task { await model.open(focus) }
        }
        .onChangeCompat(of: model.loadRevision) { _, _ in
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: model.accessibilitySummary)
        }
        // ⌘← et ⌘→ (clavier de l'iPad) : relevé précédent et suivant.
        .background {
            HStack {
                Button("Relevé précédent") { Task { await model.step(1) } }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Relevé suivant") { Task { await model.step(-1) } }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var mapStack: some View {
        ZStack {
            mapLayer
            controlsLayer
        }
    }

    // MARK: Actions

    private func openPendingSite() {
        guard let site = pendingSite else { return }
        pendingSite = nil
        focus(on: site)
    }

    /// Cadre le support au-dessus de la fiche et l'ouvre.
    private func focus(on site: ANFRMapSite) {
        Haptics.light()
        let full = model.site(supId: site.supId) ?? site
        model.requestCamera(.site(full.coordinate, aboveSheet: !isRegularWidth))
        selectedSite = full
    }

    private func locate() {
        Task {
            if let location = await services.location.currentLocation(timeoutSeconds: 8) {
                model.userCoordinate = location.coordinate
                showsUserLocation = true
                model.requestCamera(.region(center: location.coordinate, radiusMeters: 4_000))
            } else {
                locationNotice = String(localized: "Position indisponible. Vérifie l’autorisation de localisation dans les Réglages.")
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                locationNotice = nil
            }
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        ANFRMapKitView(
            sites: model.filteredSites,
            revision: model.filteredRevision,
            highlightedSupId: selectedSite?.supId,
            camera: model.cameraRequest,
            zone: model.zone,
            showsUserLocation: showsUserLocation,
            layer: model.layer,
            isCompactWidth: !isRegularWidth,
            bottomInset: SQDock.floatingContentInset,
            onSelectSite: { site in
                Haptics.light()
                selectedSite = model.site(supId: site.supId) ?? site
            },
            onSelectCluster: { sites in
                clusterSelection = ANFRClusterSelection(sites: sites)
            }
        )
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Controls overlay

    private var controlsLayer: some View {
        VStack(spacing: SQSpace.sm2) {
            topBar
            operatorStrip
            Spacer()
            // Les pastilles basses réservent la hauteur du dock : sur iOS 16 à 25 il
            // se superpose à la carte au lieu de décaler la zone sûre.
            VStack(spacing: SQSpace.sm) {
                if model.layer == .reorientations {
                    if model.reorientationState == .loading {
                        loadingPill
                    } else if model.filteredSites.isEmpty, model.reorientationState == .loaded || model.reorientationState == .unknown {
                        emptyPill
                    }
                } else if model.isLoading {
                    loadingPill
                } else if model.hasLoadedSnapshot, model.filteredSites.isEmpty, model.errorMessage == nil {
                    emptyPill
                }
                if model.layer == .reorientations, case .failed(let message) = model.reorientationState {
                    errorPill(message)
                } else if let error = model.errorMessage {
                    errorPill(error)
                } else if model.isShowingCachedCopy {
                    cachedCopyPill
                }
                if let notice = locationNotice {
                    noticePill(notice)
                }
                weekStrip
                if !dynamicTypeSize.isAccessibilitySize {
                    legend
                }
            }
            .padding(.bottom, SQDock.floatingContentInset)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.top, SQSpace.sm)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var topBar: some View {
        VStack(spacing: SQSpace.xs) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.sm) {
                    dateButton
                    HStack(spacing: SQSpace.sm) {
                        countBadge
                        Spacer(minLength: 0)
                        filterButton
                    }
                }
            } else {
                HStack(spacing: SQSpace.sm) {
                    dateButton
                    Spacer(minLength: 0)
                    countBadge
                    filterButton
                }
            }
            if model.comparison != nil {
                comparisonBar
            } else {
                layerPicker
            }
        }
        .padding(SQSpace.xs + 1)
        .sqCardBackground()
    }

    /// En comparaison : ce que la carte montre, et la sortie vers le relevé choisi.
    private var comparisonBar: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SQColor.accentInk)
                .accessibilityHidden(true)
            Group {
                if model.displayedComparison != nil, !model.comparisonWeeks.isEmpty {
                    Text("Changements nets, \(model.comparisonWeeks.count) relevés cumulés")
                } else {
                    Text("Changements nets entre deux relevés")
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                Haptics.light()
                Task { await model.endComparison() }
            } label: {
                Label("Quitter", systemImage: "xmark")
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, SQSpace.sm2)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Quitter la comparaison")
            .accessibilityIdentifier("anfr.map.compare.exit")
        }
        .padding(.leading, SQSpace.sm)
    }

    /// Changements du relevé, ou supports dont les azimuts ont changé.
    private var layerPicker: some View {
        SQSegmentedFilter(selection: $model.layer, options: [
            (value: ANFRMapLayer.changes, label: "Changements", icon: "antenna.radiowaves.left.and.right"),
            (value: ANFRMapLayer.reorientations, label: "Réorientés", icon: ANFRMapLayer.reorientationGlyph),
        ])
        .accessibilityIdentifier("anfr.map.layer")
    }

    private var dateButton: some View {
        Button {
            Haptics.light()
            showDatePicker = true
        } label: {
            HStack(spacing: SQSpace.sm - 1) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 28, height: 28)
                    .background(SQColor.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.comparison != nil ? "Comparaison" : "Relevé")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    Text(model.comparisonLabel ?? model.dateLabel)
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, SQSpace.sm2)
            .frame(minHeight: 48)
            .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityHint(model.supportsLite ? "Choisir une date ou comparer deux relevés" : "Choisir une date")
        .accessibilityIdentifier("anfr.map.date")
    }

    private var countBadge: some View {
        HStack(spacing: SQSpace.xs2) {
            Image(systemName: model.layer == .reorientations ? ANFRMapLayer.reorientationGlyph : "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
            // Séparateur de milliers : « 61 234 » se lit, « 61234 » pas.
            Text(model.filteredSites.count.formatted(.number.grouping(.automatic)))
                .font(SQFont.display(15, .bold, relativeTo: .headline))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(SQColor.onAccent)
        .padding(.horizontal, SQSpace.md - 1)
        .frame(minHeight: 48)
        .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.layer == .reorientations
            ? Text("Supports réorientés affichés : \(model.filteredSites.count)")
            : Text("Supports modifiés affichés : \(model.filteredSites.count)"))
    }

    private var filterButton: some View {
        Button {
            Haptics.light()
            showFilters = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .foregroundStyle(SQColor.label)
                if model.activeFilterCount > 0 {
                    Text("\(model.activeFilterCount)")
                        .font(SQType.micro)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(SQColor.brandRed, in: Circle())
                        .foregroundStyle(SQColor.onAccent)
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Filtres de la carte")
        .accessibilityValue(model.activeFilterCount > 0 ? Text("Filtres actifs : \(model.activeFilterCount)") : Text(verbatim: ""))
        .accessibilityIdentifier("anfr.map.filters")
    }

    private var operatorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm - 1) {
                ForEach(ANFROperator.allCases) { op in
                    let on = model.operatorFilters.contains(op)
                    // La coche de l'état actif double la couleur : l'état ne repose pas sur elle seule.
                    SQChip(
                        label: op.label, isSelected: on, selectedSystemImage: "checkmark", dot: op.color, selectedFill: op.color,
                        selectedInk: SQBrand.operatorBadgeForeground(op.label),
                        spokenLabel: "Filtre \(op.label)",
                        spokenValue: on ? "activé" : "désactivé"
                    ) {
                        withAnimation(reduceMotion ? nil : SQMotion.fast) { model.toggleOperator(op) }
                    }
                }
            }
            .padding(.horizontal, SQSpace.xs)
        }
        .frame(minHeight: 44)
    }

    // MARK: Bandeau des semaines

    @ViewBuilder
    private var weekStrip: some View {
        let bars = model.weekBars
        if bars.count > 1 {
            let maxTotal = max(bars.compactMap(\.total).max() ?? 1, 1)
            HStack(spacing: 0) {
                stepButton(systemImage: "chevron.left", label: "Relevé précédent", enabled: model.canStepOlder) {
                    Task { await model.step(1) }
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: SQSpace.xs) {
                            ForEach(bars) { bar in
                                weekBarButton(bar, maxTotal: maxTotal)
                                    .id(bar.id)
                            }
                        }
                        .padding(.horizontal, SQSpace.xs)
                    }
                    // Fondu des bords : une étiquette à moitié défilée s'estompe au lieu
                    // d'être tranchée net contre les flèches.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.06),
                                .init(color: .black, location: 0.94),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .onAppear { scrollStrip(proxy, animated: false) }
                    .onChangeCompat(of: bars.count) { _, _ in scrollStrip(proxy, animated: false) }
                    .onChangeCompat(of: model.selectedDate) { _, _ in scrollStrip(proxy, animated: true) }
                }
                stepButton(systemImage: "chevron.right", label: "Relevé suivant", enabled: model.canStepNewer) {
                    Task { await model.step(-1) }
                }
            }
            .padding(.vertical, SQSpace.xs)
            .padding(.horizontal, SQSpace.xs)
            .sqCardBackground()
        }
    }

    private func scrollStrip(_ proxy: ScrollViewProxy, animated: Bool) {
        let target = model.selectedDate ?? "current"
        if animated && !reduceMotion {
            withAnimation(SQMotion.fast) { proxy.scrollTo(target, anchor: .center) }
        } else {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private func stepButton(systemImage: String, label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? SQColor.label : SQColor.labelTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func weekBarButton(_ bar: ANFRWeekBar, maxTotal: Int) -> some View {
        let isSelected = model.comparison == nil ? bar.date == model.selectedDate : bar.inComparison
        let barHeight: CGFloat = bar.total.map { max(4, 30 * CGFloat($0) / CGFloat(maxTotal)) } ?? 10
        let dayText = ANFRText.date(bar.displayDate, month: .abbreviated, year: false) ?? String(localized: "Dernier")
        let spoken = ANFRText.date(bar.displayDate) ?? String(localized: "Dernier relevé")
        return Button {
            Haptics.selection()
            Task { await model.selectDate(bar.date) }
        } label: {
            VStack(spacing: 2) {
                Spacer(minLength: 0)
                Capsule(style: .continuous)
                    .fill(isSelected ? SQColor.brandRed : SQColor.labelTertiary.opacity(bar.total == nil ? 0.35 : 0.7))
                    .frame(width: 16, height: barHeight)
                Text(dayText)
                    .font(isSelected ? SQType.micro(.bold) : SQType.micro(.regular))
                    .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 46, height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.total.map {
            model.layer == .reorientations
                ? Text("Relevé du \(spoken), \($0) supports réorientés")
                : Text("Relevé du \(spoken), \($0) changements")
        } ?? Text("Relevé du \(spoken)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Légende

    /// Type de changement = symbole du repère ; opérateur = teinte (puces du haut).
    private var legend: some View {
        Group {
            if model.layer == .reorientations {
                HStack(spacing: SQSpace.xs) {
                    legendGlyph(ANFRMapLayer.reorientationGlyph, color: ANFRMapLayer.reorientationColor)
                    Text("Azimuts changés depuis le relevé précédent ; avant et après dans la fiche")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ANFRFlowLayout(spacing: SQSpace.sm) {
                    ForEach(ANFRModType.allCases) { type in
                        HStack(spacing: SQSpace.xs) {
                            legendGlyph(type.glyph, color: type.color)
                            Text(type.label)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.label)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .frame(maxWidth: .infinity)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func legendGlyph(_ systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(SQColor.onAccent)
            .frame(width: 16, height: 16)
            .background(color, in: Circle())
    }

    // MARK: Pastilles d'état

    private var loadingPill: some View {
        HStack(spacing: SQSpace.sm) {
            SQSpinner().tint(SQColor.brandRed)
            Group {
                if model.layer == .reorientations {
                    Text("Chargement des réorientations du \(model.pendingDateLabel)…")
                } else if let comparison = model.comparisonLabel {
                    Text("Comparaison \(comparison)…")
                } else if model.hasLoadedSnapshot {
                    Text("Chargement du relevé du \(model.pendingDateLabel)…")
                } else {
                    Text("Chargement des changements ANFR…")
                }
            }
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.label)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm + 1)
        .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowCard()
        .accessibilityElement(children: .combine)
    }

    /// Liste vide : soit les filtres excluent tout (et on les remet en un geste),
    /// soit le relevé lui-même ne contient aucun support modifié.
    private var emptyPill: some View {
        VStack(spacing: SQSpace.xs) {
            if model.layer == .reorientations, model.reorientationState == .unknown {
                Label("Aucune réorientation connue pour ce relevé", systemImage: ANFRMapLayer.reorientationGlyph)
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
            } else if model.hasActiveFilters {
                Label(model.layer == .reorientations ? "Aucun support réorienté pour ces filtres" : "Aucun support modifié pour ces filtres",
                      systemImage: "magnifyingglass")
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    Haptics.light()
                    model.resetFilters()
                } label: {
                    Text("Réinitialiser les filtres")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Label(model.layer == .reorientations ? "Aucun support réorienté dans ce relevé" : "Aucun support modifié dans ce relevé",
                      systemImage: "magnifyingglass")
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm + 1)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowCard()
    }

    private func errorPill(_ message: String) -> some View {
        let offline = message == SQOfflineText.message
        return VStack(spacing: SQSpace.sm) {
            Label {
                if offline { Text("Hors ligne") } else { Text(verbatim: message) }
            } icon: {
                Image(systemName: offline ? "wifi.slash" : "exclamationmark.triangle.fill")
            }
            .font(SQType.subhead(.semibold))
            .foregroundStyle(offline ? SQColor.labelSecondary : SQColor.dangerInk)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            if offline, model.hasLoadedSnapshot {
                Text("Le relevé affiché reste celui du \(model.dateLabel).")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await model.reload() }
            } label: {
                Label("Réessayer", systemImage: "arrow.clockwise")
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("anfr.map.retry")
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm + 1)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .frame(maxWidth: 320)
        .sqShadowCard()
    }

    /// Le dernier relevé n'a pas pu être redemandé : la copie de l'iPhone est affichée.
    private var cachedCopyPill: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
            Text("Hors ligne : copie enregistrée sur cet iPhone")
                .font(SQType.caption(.semibold))
                .foregroundStyle(SQColor.label)
            Button {
                Task { await model.reload() }
            } label: {
                Text("Réessayer")
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SQSpace.md)
        .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowCard()
    }

    private func noticePill(_ message: String) -> some View {
        Text(message)
            .font(SQType.caption(.semibold))
            .foregroundStyle(SQColor.label)
            .multilineTextAlignment(.center)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .sqShadowCard()
    }
}

/// Supports regroupés au même endroit, listés pour que chacun soit atteignable.
struct ANFRClusterSelection: Identifiable {
    let id = UUID()
    let sites: [ANFRMapSite]
}

// MARK: - Sheet header

/// Titre d'une feuille de la carte et sa sortie : sans bouton, seule la poignée
/// (invisible pour VoiceOver et Contrôle de sélection) fermait la feuille.
private struct ANFRSheetHeader: View {
    let title: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
            Text(title)
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
                .sqHeader()
            Spacer(minLength: SQSpace.md)
            Button("Terminé", action: onClose)
                .font(SQType.button)
                .foregroundStyle(SQColor.accentInk)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}

// MARK: - Liste des supports

/// Les supports modifiés en liste, avec recherche et tri : l'alternative à la carte
/// pour VoiceOver et Contrôle de sélection, et le panneau latéral de l'iPad.
struct ANFRSiteListView: View {
    let title: LocalizedStringKey
    let sites: [ANFRMapSite]
    /// Change quand `sites` change : évite de comparer des milliers de supports.
    let revision: Int
    let origin: CLLocationCoordinate2D?
    let showsSearch: Bool
    let layer: ANFRMapLayer
    let onClose: (() -> Void)?
    let onSelect: (ANFRMapSite) -> Void

    @State private var query = ""
    @State private var sort: ANFRSiteListSort = .type
    @State private var rows: [ANFRSiteRow] = []

    init(title: LocalizedStringKey, sites: [ANFRMapSite], revision: Int, origin: CLLocationCoordinate2D?,
         showsSearch: Bool, layer: ANFRMapLayer = .changes, onClose: (() -> Void)?, onSelect: @escaping (ANFRMapSite) -> Void) {
        self.title = title
        self.sites = sites
        self.revision = revision
        self.origin = origin
        self.showsSearch = showsSearch
        self.layer = layer
        self.onClose = onClose
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Group {
                if let onClose {
                    ANFRSheetHeader(title: title, onClose: onClose)
                } else {
                    Text(title)
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .sqHeader()
                        .padding(.vertical, SQSpace.sm)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, onClose == nil ? SQSpace.sm : SQSpace.md)

            if showsSearch {
                searchField
                    .padding(.horizontal, SQSpace.lg)
                Picker("Trier par", selection: $sort) {
                    Text("Type").tag(ANFRSiteListSort.type)
                    Text("Commune").tag(ANFRSiteListSort.city)
                    if origin != nil { Text("Distance").tag(ANFRSiteListSort.distance) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, SQSpace.lg)
            }

            Group {
                if layer == .reorientations {
                    Text("Supports réorientés : \(rows.count.formatted())")
                } else {
                    Text("Supports modifiés : \(rows.count.formatted())")
                }
            }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.horizontal, SQSpace.lg)
                .accessibilityAddTraits(.updatesFrequently)

            if rows.isEmpty {
                Text(!query.isEmpty ? "Aucun support ne correspond à ta recherche."
                     : layer == .reorientations ? "Aucun support réorienté à afficher." : "Aucun support modifié à afficher.")
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.horizontal, SQSpace.lg)
                Spacer(minLength: 0)
            } else {
                List(rows) { row in
                    rowView(row)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(SQColor.separator)
                }
                .listStyle(.plain)
                .scrollContentBackgroundHiddenCompat()
            }
        }
        .signalQuestBackground()
        .onAppear(perform: recompute)
        .onChangeCompat(of: query) { _, _ in recompute() }
        .onChangeCompat(of: sort) { _, _ in recompute() }
        .onChangeCompat(of: revision) { _, _ in recompute() }
        .onChangeCompat(of: sites.count) { _, _ in recompute() }
        .onChangeCompat(of: layer) { _, _ in recompute() }
    }

    private var searchField: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
            TextField("Commune, code du support ou adresse", text: $query)
                .font(SQType.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, SQSpace.md)
        .frame(minHeight: 44)
        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private func rowView(_ row: ANFRSiteRow) -> some View {
        Button {
            Haptics.selection()
            onSelect(row.site)
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: layer == .reorientations ? ANFRMapLayer.reorientationGlyph : row.modType.glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SQColor.onAccent)
                    .frame(width: 22, height: 22)
                    .background(layer == .reorientations ? ANFRMapLayer.reorientationColor : row.modType.color, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(SQType.rowTitle)
                        .foregroundStyle(SQColor.label)
                    Text(row.detail)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let distance = row.distance {
                    Text(SQUnits.distance(meters: distance))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func recompute() {
        if sort == .distance && origin == nil { sort = .type }
        rows = ANFRSiteList.rows(from: sites, query: query, sort: sort, origin: origin, layer: layer)
    }
}

private extension View {
    /// `scrollContentBackground(.hidden)` est iOS 16 : la liste laisse voir le fond de l'écran.
    func scrollContentBackgroundHiddenCompat() -> some View {
        scrollContentBackground(.hidden)
    }
}

// MARK: - Filter sheet

struct ANFRMapFilterSheet: View {
    @ObservedObject var model: ANFRMapViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                ANFRSheetHeader(title: "Filtres") { dismiss() }

                section(title: "Opérateurs") {
                    FlexibleChips(ANFROperator.allCases) { op in
                        operatorChip(op)
                    }
                }

                if model.layer == .reorientations {
                    Text("Les réorientations se filtrent par opérateur. Les autres filtres s’appliquent aux changements du relevé.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                section(title: "Type de modification") {
                    FlexibleChips(ANFRModType.allCases) { type in
                        modTypeChip(type)
                    }
                    // Légende de la carte : le symbole des puces est celui du repère.
                    Text("Sur la carte, un repère prend la couleur de l’opérateur dominant du support ; son symbole est le type de modification le plus marquant.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.hasLoadedSnapshot {
                        Text("Les nombres comptent les supports concernés, pour les autres filtres choisis.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if model.displaysLite {
                    section(title: "Génération") {
                        Text("Ce relevé ne détaille pas les antennes : il ne se filtre pas par génération. La fiche d’un support donne ses antennes.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                section(title: "Génération") {
                    FlexibleChips(ANFRGeneration.allCases) { generation in
                        SQChip(
                            label: generation.label, isSelected: model.selectedGenerations.contains(generation),
                            selectedSystemImage: "checkmark", dot: generation.color, selectedFill: generation.color,
                            selectedInk: SQBrand.operatorBadgeForeground(for: generation.color, colorScheme: colorScheme)
                        ) {
                            model.toggleGeneration(generation)
                        }
                    }
                }
                }

                section(title: "Rattrapages") {
                    Toggle(isOn: $model.hidesCatchUp) {
                        Text("Masquer les rattrapages")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                    }
                    .tint(SQColor.brandRed)
                    .frame(minHeight: 44)
                    Text("Un rattrapage est une antenne déclarée tard : sa mise en service date de plus de 30 jours avant le relevé.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.displaysLite {
                        Text("Ici, un support n’est masqué que si tous ses changements sont des rattrapages.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                }

                GradientButton("Réinitialiser les filtres", systemImage: "arrow.counterclockwise", style: .secondary) {
                    model.resetFilters()
                }
            }
            .padding(SQSpace.lg)
            .padding(.bottom, SQSpace.huge)
        }
        .signalQuestBackground()
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text(LocalizedStringKey(title))
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .sqHeader()
            content()
        }
    }

    /// Puce d'opérateur avec le nombre de supports concernés une fois le relevé chargé.
    private func operatorChip(_ op: ANFROperator) -> some View {
        let label = model.hasLoadedSnapshot
            ? "\(op.label) · \((model.operatorCounts[op] ?? 0).formatted(.number.grouping(.automatic)))"
            : op.label
        return SQChip(
            label: label, isSelected: model.operatorFilters.contains(op), selectedSystemImage: "checkmark",
            dot: op.color, selectedFill: op.color,
            selectedInk: SQBrand.operatorBadgeForeground(for: op.color, colorScheme: colorScheme)
        ) {
            model.toggleOperator(op)
        }
    }

    /// Puce d'un type de modification : le symbole du repère sur la carte et, une
    /// fois le relevé chargé, le nombre de supports concernés.
    private func modTypeChip(_ type: ANFRModType) -> some View {
        let label = model.hasLoadedSnapshot
            ? "\(type.label) · \((model.modTypeCounts[type] ?? 0).formatted(.number.grouping(.automatic)))"
            : type.label
        return SQChip(
            label: label, systemImage: type.glyph, isSelected: model.selectedModTypes.contains(type),
            selectedFill: type.color,
            selectedInk: SQBrand.operatorBadgeForeground(for: type.color, colorScheme: colorScheme)
        ) {
            model.toggleModType(type)
        }
    }
}

// MARK: - Date picker sheet

struct ANFRDatePickerSheet: View {
    @ObservedObject var model: ANFRMapViewModel
    @Environment(\.dismiss) private var dismiss
    /// Bornes de la comparaison ; `latestTag` désigne le dernier relevé.
    @State private var compareFrom = ""
    @State private var compareTo = Self.latestTag

    private static let latestTag = "current"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Paresseux : plusieurs dizaines de relevés hebdomadaires, chacun
                // avec ombre, n'ont pas à être tous construits à l'ouverture.
                LazyVStack(alignment: .leading, spacing: SQSpace.md) {
                    ANFRSheetHeader(title: "Choisir une date") { dismiss() }
                    Text("Relevé ANFR")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    Text("L’ANFR publie un relevé à peu près chaque semaine. La carte montre ce qui a changé depuis le relevé précédent : nouveaux supports, antennes mises en service, ajoutées ou retirées.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, SQSpace.sm)

                    if model.supportsLite, !model.comparisonStarts(to: nil).isEmpty {
                        compareCard
                            .padding(.bottom, SQSpace.sm)
                    }

                    dateRow(label: "Dernier relevé", value: model.currentSnapshotDate, detail: nil,
                            isSelected: model.comparison == nil && model.selectedDate == nil) {
                        Task { await model.selectDate(nil) }
                        dismiss()
                    }
                    .id("latest")

                    if model.dateSections.isEmpty {
                        Text("Aucune autre date disponible pour le moment.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    ForEach(model.dateSections) { section in
                        Text(section.year)
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                            .padding(.top, SQSpace.sm)
                        ForEach(section.dates, id: \.self) { date in
                            dateRow(label: prettyDate(date), value: nil, detail: changesText(date),
                                    isSelected: model.comparison == nil && model.selectedDate == date) {
                                Task { await model.selectDate(date) }
                                dismiss()
                            }
                            .id(date)
                        }
                    }

                    if model.hidesFullStateDates {
                        Text("Les relevés complets de 2022 arriveront avec une prochaine version.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, SQSpace.md)
                    }
                }
                .padding(SQSpace.lg)
                .padding(.bottom, SQSpace.huge)
            }
            .signalQuestBackground()
            // La date en cours se retrouve au milieu de la liste, pas en bas d'un défilement.
            .onAppear {
                if let selected = model.selectedDate { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        // Liste vide à l'ouverture : la réponse des dates a pu être manquée.
        .task { if model.availableDates.isEmpty { await model.loadArchiveDates() } }
        .onAppear(perform: prepareComparison)
    }

    // MARK: Comparaison

    private var compareEnd: String? { compareTo == Self.latestTag ? nil : compareTo }

    /// Reprend la comparaison affichée, sinon propose les quatre derniers relevés.
    private func prepareComparison() {
        if let comparison = model.comparison {
            compareTo = comparison.to ?? Self.latestTag
            compareFrom = comparison.from
        } else {
            compareTo = Self.latestTag
            let starts = model.comparisonStarts(to: nil)
            compareFrom = starts.dropFirst(3).first ?? starts.last ?? ""
        }
    }

    private var compareCard: some View {
        let starts = model.comparisonStarts(to: compareEnd)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Comparer deux relevés")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .sqHeader()
            Text("Ce qui a changé entre deux dates, en net : une antenne mise en service puis retirée compte une fois, comme retirée.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            comparePicker(title: "Du relevé", selection: $compareFrom, options: starts.map { ($0, prettyDate($0)) })
                .accessibilityIdentifier("anfr.map.compare.from")
            comparePicker(title: "Au relevé", selection: $compareTo, options: model.comparisonEnds.map { end in
                (end ?? Self.latestTag, end.map(prettyDate) ?? String(localized: "Dernier relevé"))
            })
            .accessibilityIdentifier("anfr.map.compare.to")
            GradientButton(String(localized: "Comparer"), systemImage: "arrow.left.arrow.right") {
                let from = compareFrom
                let to = compareEnd
                Task { await model.compare(from: from, to: to) }
                dismiss()
            }
            .disabled(!starts.contains(compareFrom))
            .accessibilityIdentifier("anfr.map.compare.go")
        }
        .padding(SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        // Une fin plus ancienne que le début : le début se recale sur le relevé précédent.
        .onChangeCompat(of: compareTo) { _, _ in
            let valid = model.comparisonStarts(to: compareEnd)
            if !valid.contains(compareFrom) { compareFrom = valid.first ?? "" }
        }
    }

    private func comparePicker(title: LocalizedStringKey, selection: Binding<String>, options: [(String, String)]) -> some View {
        HStack(spacing: SQSpace.sm) {
            Text(title)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
            Spacer(minLength: SQSpace.sm)
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { option in
                    Text(verbatim: option.1).tag(option.0)
                }
            }
            .pickerStyle(.menu)
            .tint(SQColor.accentInk)
        }
        .frame(minHeight: 44)
    }

    private func dateRow(label: String, value: String?, detail: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? SQColor.brandRed : SQColor.labelTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(label))
                        .font(SQType.body(.semibold))
                        .foregroundStyle(SQColor.label)
                    if let value, let pretty = ANFRText.date(value) {
                        Text(pretty)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, SQSpace.md)
            .padding(.horizontal, SQSpace.md)
            .background(
                isSelected ? AnyShapeStyle(SQColor.accentSoft) : AnyShapeStyle(SQColor.surface),
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
            .sqShadowSoft()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Les changements de la semaine, quand le bandeau les a chargés.
    private func changesText(_ date: String) -> String? {
        if ANFRMapPolicy.isFullStateDate(date) {
            return String(localized: "Relevé très lourd : supports et compteurs, sans le détail des antennes")
        }
        return model.weeks.first(where: { $0.date == date }).map { week in
            let changes = String(localized: "Changements : \(week.total.formatted())")
            guard let reoriented = week.reoriented else { return changes }
            return changes + " · " + String(localized: "Réorientés : \(reoriented.formatted())")
        }
    }

    private func prettyDate(_ raw: String) -> String {
        ANFRText.date(raw) ?? raw
    }
}

// MARK: - Simple flow layout for chips

/// Petit conteneur en flux (wrap) pour des puces de filtre.
struct FlexibleChips<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        ANFRFlowLayout(spacing: SQSpace.sm) {
            ForEach(Array(data), id: \.self) { element in
                content(element)
            }
        }
    }
}

/// Layout en flux maison (wrap horizontal) — évite la dépendance à iOS 16 Layout
/// quirks et garde un comportement déterministe.
struct ANFRFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubview]] = [[]]
        var rowWidths: [CGFloat] = [0]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let currentWidth = rowWidths[rows.count - 1]
            let needed = (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            if currentWidth + needed > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([subview])
                rowWidths.append(size.width)
            } else {
                rows[rows.count - 1].append(subview)
                rowWidths[rows.count - 1] = currentWidth + needed
            }
        }
        let rowHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let totalHeight = CGFloat(rows.count) * rowHeight + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: maxWidth == .infinity ? (rowWidths.max() ?? 0) : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        let rowHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}

// MARK: - Carte ANFR MapKit (migration moteur unique)

/// Annotation MapKit d'un site ANFR (style résolu : couleur opérateur + glyphe modif).
final class ANFRSiteAnnotationMK: NSObject, MKAnnotation {
    let site: ANFRMapSite
    /// Résolu à la demande : MapKit ne demande une vue qu'aux repères affichés hors
    /// amas (quelques centaines), alors qu'un relevé en crée jusqu'à plusieurs milliers.
    lazy var style = ANFRMarkerStyle(site: site)
    var coordinate: CLLocationCoordinate2D { site.coordinate }
    var title: String? { site.city.isEmpty ? String(localized: "Support \(site.supId)") : ANFRText.city(site.city) }
    /// Lu par VoiceOver : sans lui un repère ne disait que sa commune, pas ce qui a changé.
    var subtitle: String? {
        let operators = style.operators.isEmpty
            ? String(localized: "Autre opérateur")
            : style.operators.map(\.label).joined(separator: ", ")
        return "\(operators) · \(style.modType.label)"
    }
    init(site: ANFRMapSite) {
        self.site = site
    }
}

/// Vue d'un amas : un disque teinté par le type de modification le plus marquant de
/// ses supports, avec leur nombre — à la place de la bulle grise de MapKit.
final class ANFRClusterAnnotationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .circle
        displayPriority = .defaultHigh
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(count: Int, tint: UIColor, ink: UIColor) {
        let text = count >= 1000
            ? (Double(count) / 1000).formatted(.number.precision(.fractionLength(0...1))) + "k"
            : String(count)
        let diameter: CGFloat = text.count >= 4 ? 52 : (text.count == 3 ? 46 : 38)
        let size = CGSize(width: diameter, height: diameter)
        image = UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            tint.withAlphaComponent(0.94).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor.white.withAlphaComponent(0.9).setStroke()
            let ring = UIBezierPath(ovalIn: rect)
            ring.lineWidth = 2
            ring.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: diameter > 44 ? 15 : 14, weight: .bold),
                .foregroundColor: ink
            ]
            let label = text as NSString
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        centerOffset = .zero
        accessibilityLabel = String(localized: "\(count) supports regroupés")
        accessibilityHint = String(localized: "Zoome sur ce groupe")
    }
}

/// Vue hôte : MapKit n'ayant pas de taille au moment de `makeUIView`, le cadrage
/// initial attend la première mise en page.
final class ANFRMapHostView: UIView {
    let map = MKMapView(frame: .zero)
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(map)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = bounds
        onLayout?()
    }
}

/// Carte ANFR rendue avec MapKit (Apple Plan natif). Marqueurs colorés par
/// opérateur dominant + glyphe de type de modif ; clustering natif MapKit.
struct ANFRMapKitView: UIViewRepresentable {
    let sites: [ANFRMapSite]
    /// Change quand `sites` change (`ANFRMapViewModel.filteredRevision`) : évite de
    /// parcourir les milliers de sites à chaque rendu de l'écran.
    let revision: Int
    /// Support dont la fiche est ouverte : son repère reste sélectionné.
    let highlightedSupId: String?
    let camera: ANFRCameraRequest?
    let zone: ANFRZone?
    let showsUserLocation: Bool
    /// Couche dessinée : le symbole des repères en dépend.
    let layer: ANFRMapLayer
    let isCompactWidth: Bool
    /// Marge basse réservée au dock : le logo et les mentions d'Apple Plans restent lisibles.
    let bottomInset: CGFloat
    let onSelectSite: (ANFRMapSite) -> Void
    let onSelectCluster: ([ANFRMapSite]) -> Void

    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.applePlan.rawValue
    private var backdrop: MapBackdrop { MapBackdrop.resolve(backdropRaw) }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectSite: onSelectSite, onSelectCluster: onSelectCluster) }

    func makeUIView(context: Context) -> ANFRMapHostView {
        let host = ANFRMapHostView()
        let map = host.map
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        context.coordinator.applyBackdrop(backdrop, on: map)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "anfr-site")
        map.register(ANFRClusterAnnotationView.self, forAnnotationViewWithReuseIdentifier: "anfr-cluster")
        let coordinator = context.coordinator
        host.onLayout = { [weak coordinator, weak map] in
            guard let coordinator, let map else { return }
            coordinator.applyCamera(on: map)
        }
        return host
    }

    func updateUIView(_ host: ANFRMapHostView, context: Context) {
        let map = host.map
        let coordinator = context.coordinator
        coordinator.onSelectSite = onSelectSite
        coordinator.onSelectCluster = onSelectCluster
        coordinator.isCompactWidth = isCompactWidth
        coordinator.applyLayer(layer, on: map)
        coordinator.applyBackdrop(backdrop, on: map)
        if map.showsUserLocation != showsUserLocation { map.showsUserLocation = showsUserLocation }
        if map.layoutMargins.bottom != bottomInset { map.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0) }
        coordinator.sync(sites, revision: revision, on: map)
        coordinator.applyZone(zone, on: map)
        coordinator.requestedCamera = camera
        coordinator.applyCamera(on: map)
        coordinator.applyHighlight(highlightedSupId, on: map)
    }

    static func dismantleUIView(_ host: ANFRMapHostView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelectSite: (ANFRMapSite) -> Void
        var onSelectCluster: ([ANFRMapSite]) -> Void
        var isCompactWidth = true
        var requestedCamera: ANFRCameraRequest?
        /// Annotations posées sur la carte, par support.
        private var annotations: [String: ANFRSiteAnnotationMK] = [:]
        private var lastRevision = -1
        private var appliedBackdrop: MapBackdrop?
        private var tileOverlay: MKTileOverlay?
        private var appliedCameraID: Int?
        private var appliedHighlight: String?
        private var appliedZone: ANFRZone?
        private var zoneOverlay: MKCircle?
        /// Repères restant à poser, par paquets : un relevé de plusieurs milliers de
        /// supports posé d'un bloc figeait le fil principal.
        private var pendingAdds: [ANFRSiteAnnotationMK] = []
        private var drainTask: Task<Void, Never>?
        /// Couleur du repère et encre du symbole, par opérateur : leur résolution
        /// analyse le nom de l'opérateur, trop pour chaque repère affiché.
        private var paints: [ANFROperator: (tint: UIColor, ink: UIColor)] = [:]
        private var layer: ANFRMapLayer = .changes

        init(onSelectSite: @escaping (ANFRMapSite) -> Void, onSelectCluster: @escaping ([ANFRMapSite]) -> Void) {
            self.onSelectSite = onSelectSite
            self.onSelectCluster = onSelectCluster
        }

        func stop() {
            drainTask?.cancel()
            drainTask = nil
            pendingAdds.removeAll()
        }

        func applyBackdrop(_ backdrop: MapBackdrop, on map: MKMapView) {
            guard backdrop != appliedBackdrop else { return }
            appliedBackdrop = backdrop
            if let old = tileOverlay { map.removeOverlay(old); tileOverlay = nil }
            map.showTileAttribution(backdrop.tileAttribution)
            switch backdrop.mapKitKind {
            case .applePlan:
                let c = MKStandardMapConfiguration(elevationStyle: .flat); c.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = c
            case .imagery:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case .raster(let template, let maxZoom):
                let c = MKStandardMapConfiguration(elevationStyle: .flat); c.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = c
                let o = MKTileOverlay(urlTemplate: template); o.canReplaceMapContent = true; o.maximumZ = maxZoom
                map.insertOverlay(o, at: 0, level: .aboveLabels); tileOverlay = o
            }
        }

        // MARK: Cadrage

        /// Applique la demande de cadrage non encore vue, dès que la carte a une taille.
        func applyCamera(on map: MKMapView) {
            guard let request = requestedCamera, request.id != appliedCameraID,
                  map.bounds.width > 0, map.bounds.height > 0 else { return }
            let isFirst = appliedCameraID == nil
            appliedCameraID = request.id
            let animated = !isFirst && !UIAccessibility.isReduceMotionEnabled
            switch request.target {
            case .france:
                // France métropolitaine et Corse : latitudes 41,3 à 51,2, longitudes -5,3 à 9,7.
                let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: 51.2, longitude: -5.3))
                let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: 41.3, longitude: 9.7))
                let rect = MKMapRect(x: northWest.x, y: northWest.y, width: southEast.x - northWest.x, height: southEast.y - northWest.y)
                // Marges : barres du haut, bandeau et légende du bas.
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 150, left: 12, bottom: 240, right: 12), animated: animated)
            case .region(let center, let radius):
                map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: radius * 2.6, longitudinalMeters: radius * 2.6), animated: animated)
            case .site(let coordinate, let aboveSheet):
                let span = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                // Le centre est sous le support : la fiche, qui couvre le bas, ne le cache pas.
                let center = CLLocationCoordinate2D(
                    latitude: coordinate.latitude - (aboveSheet ? span.latitudeDelta * 0.2 : 0), longitude: coordinate.longitude
                )
                map.setRegion(MKCoordinateRegion(center: center, span: span), animated: animated)
            }
        }

        func applyZone(_ zone: ANFRZone?, on map: MKMapView) {
            guard zone != appliedZone else { return }
            appliedZone = zone
            if let old = zoneOverlay { map.removeOverlay(old); zoneOverlay = nil }
            if let zone {
                let circle = MKCircle(center: zone.center, radius: zone.radiusMeters)
                map.addOverlay(circle, level: .aboveLabels)
                zoneOverlay = circle
            }
        }

        /// Garde le repère du support ouvert sélectionné ; le relâche à la fermeture de la fiche.
        func applyHighlight(_ supId: String?, on map: MKMapView) {
            guard supId != appliedHighlight else { return }
            appliedHighlight = supId
            if let supId, let annotation = annotations[supId] {
                if !map.selectedAnnotations.contains(where: { $0 === annotation }) {
                    map.selectAnnotation(annotation, animated: !UIAccessibility.isReduceMotionEnabled)
                }
            } else {
                for selected in map.selectedAnnotations { map.deselectAnnotation(selected, animated: !UIAccessibility.isReduceMotionEnabled) }
            }
        }

        /// Changement de couche : un même support n'a plus le même symbole, tous les
        /// repères sont reposés à la prochaine synchronisation.
        func applyLayer(_ next: ANFRMapLayer, on map: MKMapView) {
            guard next != layer else { return }
            layer = next
            pendingAdds.removeAll()
            map.removeAnnotations(Array(annotations.values))
            annotations = [:]
            appliedHighlight = nil
            lastRevision = -1
        }

        // MARK: Repères

        /// Met la carte au niveau de `sites` en ne touchant QUE les repères qui
        /// changent. Vider puis reposer tous les repères à chaque bascule de filtre
        /// obligeait MapKit à reconstruire ses amas pour tout le relevé.
        func sync(_ sites: [ANFRMapSite], revision: Int, on map: MKMapView) {
            guard revision != lastRevision else { return }
            lastRevision = revision
            var next: [String: ANFRSiteAnnotationMK] = [:]
            next.reserveCapacity(sites.count)
            var added: [ANFRSiteAnnotationMK] = []
            for site in sites where next[site.supId] == nil {
                // Même contenu (antennes retenues, type de modif) : le repère reste tel quel.
                if let existing = annotations[site.supId], Self.sameContent(existing.site, site) {
                    next[site.supId] = existing
                } else {
                    let annotation = ANFRSiteAnnotationMK(site: site)
                    next[site.supId] = annotation
                    added.append(annotation)
                }
            }
            var removed: [ANFRSiteAnnotationMK] = []
            for (supId, annotation) in annotations where next[supId] !== annotation { removed.append(annotation) }
            annotations = next
            // Les repères en attente qui ne sont plus voulus ne seront jamais posés.
            pendingAdds.removeAll { next[$0.site.supId] !== $0 }
            if !removed.isEmpty { map.removeAnnotations(removed) }
            pendingAdds.append(contentsOf: added)
            drainPendingAdds(on: map)
        }

        private func drainPendingAdds(on map: MKMapView) {
            guard drainTask == nil, !pendingAdds.isEmpty else { return }
            // Petit lot : posé tout de suite, sans repasser par une tâche.
            if pendingAdds.count <= 600 {
                map.addAnnotations(pendingAdds)
                pendingAdds.removeAll()
                return
            }
            drainTask = Task { @MainActor [weak self, weak map] in
                while let self, let map, !self.pendingAdds.isEmpty, !Task.isCancelled {
                    let chunk = Array(self.pendingAdds.prefix(500))
                    self.pendingAdds.removeFirst(chunk.count)
                    map.addAnnotations(chunk)
                    // Laisse MapKit et SwiftUI dessiner une image entre deux paquets.
                    try? await Task.sleep(nanoseconds: 8_000_000)
                }
                self?.drainTask = nil
            }
        }

        /// Ce qui détermine l'aspect d'un repère : position, commune et, par antenne,
        /// son identité et son type de modif.
        private static func sameContent(_ a: ANFRMapSite, _ b: ANFRMapSite) -> Bool {
            a.antennas.count == b.antennas.count && a.summary == b.summary
                && a.latitude == b.latitude && a.longitude == b.longitude && a.city == b.city
                && zip(a.antennas, b.antennas).allSatisfy { $0.id == $1.id && $0.modTypeRaw == $1.modTypeRaw }
        }

        private func paint(for op: ANFROperator?) -> (tint: UIColor, ink: UIColor) {
            // Opérateur non suivi : gris neutre, jamais la teinte d'un opérateur.
            guard let op else { return (tint: .systemGray, ink: .white) }
            if let cached = paints[op] { return cached }
            let made = (tint: UIColor(op.color), ink: UIColor(SQBrand.operatorBadgeForeground(op.label)))
            paints[op] = made
            return made
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = map.dequeueReusableAnnotationView(withIdentifier: "anfr-cluster", for: cluster) as? ANFRClusterAnnotationView
                    ?? ANFRClusterAnnotationView(annotation: cluster, reuseIdentifier: "anfr-cluster")
                let members = cluster.memberAnnotations.compactMap { $0 as? ANFRSiteAnnotationMK }
                let dominant = members.map { $0.style.modType }.max { $0.priority < $1.priority } ?? .added
                view.configure(
                    count: members.count,
                    tint: UIColor(layer == .reorientations ? ANFRMapLayer.reorientationColor : dominant.color),
                    ink: UIColor(SQColor.onAccent)
                )
                return view
            }
            guard let site = annotation as? ANFRSiteAnnotationMK else { return nil }
            let v = map.dequeueReusableAnnotationView(withIdentifier: "anfr-site", for: annotation) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "anfr-site")
            let colors = paint(for: site.style.dominantOperator)
            v.markerTintColor = colors.tint
            // Orange et Bouygues demandent un symbole noir : le blanc par défaut n'y tient pas le contraste.
            v.glyphTintColor = colors.ink
            v.glyphImage = UIImage(systemName: layer == .reorientations ? ANFRMapLayer.reorientationGlyph : site.style.modType.glyph)
            v.clusteringIdentifier = "anfr"
            v.displayPriority = .defaultLow
            v.canShowCallout = false
            return v
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                selectCluster(cluster, on: map)
                map.deselectAnnotation(cluster, animated: false)
            } else if let annotation = view.annotation as? ANFRSiteAnnotationMK {
                // Le repère le plus marquant reste devant, et sélectionné tant que la fiche est ouverte.
                view.displayPriority = .required
                // Sélection posée par la liste : la fiche est déjà demandée.
                if annotation.site.supId != appliedHighlight {
                    recenterAboveSheet(annotation.coordinate, on: map)
                    onSelectSite(annotation.site)
                }
            }
        }

        func mapView(_ map: MKMapView, didDeselect view: MKAnnotationView) {
            if view.annotation is ANFRSiteAnnotationMK { view.displayPriority = .defaultLow }
        }

        /// Un amas de supports au même point ne se découpe jamais en zoomant : il
        /// s'ouvre en liste. Les autres se cadrent sur leurs membres.
        private func selectCluster(_ cluster: MKClusterAnnotation, on map: MKMapView) {
            let members = cluster.memberAnnotations.compactMap { $0 as? ANFRSiteAnnotationMK }
            guard let first = members.first else { return }
            let samePoint = members.allSatisfy {
                abs($0.coordinate.latitude - first.coordinate.latitude) < 0.000_01
                    && abs($0.coordinate.longitude - first.coordinate.longitude) < 0.000_01
            }
            let alreadyClose = map.region.span.latitudeDelta < 0.004
            if samePoint || alreadyClose {
                onSelectCluster(members.map(\.site))
            } else {
                map.showAnnotations(members, animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }

        /// Un repère dans la moitié basse passerait sous la fiche : on le remonte.
        private func recenterAboveSheet(_ coordinate: CLLocationCoordinate2D, on map: MKMapView) {
            guard isCompactWidth, map.bounds.height > 0 else { return }
            let point = map.convert(coordinate, toPointTo: map)
            guard point.y > map.bounds.height * 0.45 else { return }
            let span = map.region.span
            let center = CLLocationCoordinate2D(latitude: coordinate.latitude - span.latitudeDelta * 0.2, longitude: coordinate.longitude)
            map.setCenter(center, animated: !UIAccessibility.isReduceMotionEnabled)
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = UIColor(SQColor.brandRed)
                renderer.fillColor = UIColor(SQColor.brandRed).withAlphaComponent(0.08)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
