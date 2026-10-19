import Foundation
import SwiftUI

@MainActor
final class RadioLogsViewModel: ObservableObject {

    // MARK: Réglages de la page

    /// Ce que la liste affiche. Le critère est UNIQUE : l'eNB/gNB est-il connu
    /// du serveur ? Pas de troisième catégorie — une hypothèse de voisinage n'est
    /// pas une identification, et n'a sa place que là où l'on regarde un site.
    enum Filter: String, CaseIterable, Identifiable {
        case all, identified, unidentified
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return String(localized: "Tous")
            case .identified: return String(localized: "Identifiés")
            case .unidentified: return String(localized: "À identifier")
            }
        }
    }

    /// Le tri devient un réglage de premier plan, plus un comportement figé —
    /// et chaque option dit ce qu'elle FAIT, pas seulement son nom.
    enum SortOrder: String, CaseIterable, Identifiable {
        case relevance, recency, identifier
        var id: String { rawValue }
        var label: String {
            switch self {
            case .relevance: return String(localized: "Les plus relevés")
            case .recency: return String(localized: "Les plus récents")
            case .identifier: return String(localized: "Identifiant")
            }
        }
        var hint: String {
            switch self {
            case .relevance: return String(localized: "D’abord ceux que tu captes le plus")
            case .recency: return String(localized: "Vus en dernier")
            case .identifier: return String(localized: "eNB et gNB croissants")
            }
        }
        /// Résumé du tri, sur la ligne qui ouvre « Trier et afficher ».
        var summary: String {
            switch self {
            case .relevance: return String(localized: "Les plus relevés d’abord")
            case .recency: return String(localized: "Les plus récents d’abord")
            case .identifier: return String(localized: "Par identifiant")
            }
        }
    }

    // MARK: État publié

    @Published private(set) var sites: [RadioLogSite] = []
    @Published private(set) var states: [String: RadioLogSiteState] = [:]
    /// Commune et adresse des sites identifiés, chargées à la demande.
    @Published private(set) var siteNames: [String: String] = [:]
    @Published private(set) var logCount = 0
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncReceived = 0
    @Published private(set) var isScanning = false
    /// Balayage suspendu par l'utilisateur : la carte garde « Reprendre » visible.
    @Published private(set) var isPaused = false
    @Published var errorMessage: String?
    @Published var premiumMessage: String?
    @Published var toast: String?

    @Published var filter: Filter = .all { didSet { rebuild() } }
    @Published var sortOrder: SortOrder = .relevance { didSet { rebuild() } }
    @Published var groupByOperator = true { didSet { rebuild() } }
    /// Le balayage n'a lieu que si le réseau le permet. Le refuser en données
    /// mobiles n'est pas cosmétique : une passe complète, c'est une trentaine de
    /// requêtes qui rejouent la résolution côté serveur.
    @Published var scanOnCellular = UserDefaults.standard.object(forKey: RadioLogsViewModel.scanOnCellularKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(scanOnCellular, forKey: Self.scanOnCellularKey) }
    }
    /// Le choix « vérifier en données mobiles » survit à la fermeture de l'écran.
    nonisolated static let scanOnCellularKey = "radioLogs.scanOnCellular"
    @Published var searchText = "" { didSet { rebuild() } }
    @Published var expandedSiteId: String?

    // MARK: Vues dérivées, CALCULÉES UNE FOIS
    //
    // Le tri et le regroupement portent sur plusieurs milliers de sites. En
    // propriétés calculées, ils repartaient à chaque évaluation du `body` — donc
    // à chaque fenêtre de balayage, à chaque frappe, à chaque page de
    // synchronisation, et plusieurs fois par passe (la liste ET son état vide
    // les lisent). On les recalcule sur changement d'entrée, pas sur rendu.

    @Published private(set) var sections: [Section] = []
    @Published private(set) var filteredCount = 0
    @Published private(set) var identifiedCount = 0
    @Published private(set) var unidentifiedCount = 0
    @Published private(set) var checkedCount = 0
    /// Sites que le balayage ne peut pas vérifier (PLMN ou pays manquant).
    @Published private(set) var uncheckableCount = 0
    /// Sites non identifiés du filtre courant — la matière de la file en chaîne.
    @Published private(set) var chainCandidates: [RadioLogSite] = []

    // MARK: Dépendances

    private let service: RadioLogsServicing
    private let antennas: AntennasServicing
    private let networkPath: NetworkPathMonitor
    private var scanTask: Task<Void, Never>?
    /// Numéro du balayage en cours : la fin d'un balayage annulé ne doit pas éteindre
    /// celui qui l'a remplacé (« Tout revérifier » arrête puis relance dans le même tour).
    private var scanGeneration = 0
    private var nameTasks: Set<String> = []
    /// Détails de commune/adresse demandés au plus quatre à la fois : un défilement
    /// rapide ne lance pas des dizaines de requêtes en parallèle.
    private let maxConcurrentNameLoads = 4
    private var queuedNames: [RadioLogSite] = []
    /// Sites dont le détail vient d'échouer, retentés après un délai seulement.
    private var nameFailures: [String: Date] = [:]
    private let nameRetryDelay: TimeInterval = 60

    init(service: RadioLogsServicing, antennas: AntennasServicing, networkPath: NetworkPathMonitor) {
        self.service = service
        self.antennas = antennas
        self.networkPath = networkPath
    }

    deinit {
        scanTask?.cancel()
    }

    // MARK: Dérivés

    /// Sections affichées : une par opérateur, ou une seule section anonyme.
    struct Section: Identifiable {
        let id: String
        let operatorName: String?
        let sites: [RadioLogSite]
        let logCount: Int
    }

    /// Recalcule tout ce que la vue lit. Appelé quand une ENTRÉE change (sites,
    /// statuts, filtre, tri, regroupement, recherche) — jamais pendant un rendu.
    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var identified = 0
        var unidentified = 0
        var checked = 0
        var uncheckable = 0
        var visible: [RadioLogSite] = []
        visible.reserveCapacity(sites.count)

        // Une SEULE passe pour les compteurs du catalogue entier et le filtrage :
        // trois `filter` séparés relisaient quatre fois les mêmes milliers de sites.
        for site in sites {
            let state = states[site.id] ?? .unchecked
            if state.isIdentified { identified += 1 }
            if state.isUnidentified { unidentified += 1 }
            if state.isChecked { checked += 1 }
            if !state.isChecked, !site.isCheckable { uncheckable += 1 }

            switch filter {
            case .all: break
            case .identified: if !state.isIdentified { continue }
            case .unidentified: if !state.isUnidentified { continue }
            }
            if !query.isEmpty, !matches(site, query: query) { continue }
            visible.append(site)
        }

        identifiedCount = identified
        unidentifiedCount = unidentified
        checkedCount = checked
        uncheckableCount = uncheckable

        visible.sort(by: order)
        filteredCount = visible.count
        sections = groupByOperator ? grouped(visible) : [
            Section(id: "all", operatorName: nil, sites: visible, logCount: visible.reduce(0) { $0 + $1.logCount })
        ]
        // Dans l'ordre d'affichage des sections : la file suit ce que l'on voit.
        chainCandidates = sections.flatMap(\.sites).filter { (states[$0.id] ?? .unchecked).isUnidentified }
    }

    private func matches(_ site: RadioLogSite, query: String) -> Bool {
        if site.node.lowercased().contains(query) { return true }
        if (site.operatorName ?? "").lowercased().contains(query) { return true }
        if site.nodeLabel.lowercased().contains(query) { return true }
        if let name = siteNames[site.id], name.lowercased().contains(query) { return true }
        return false
    }

    private func grouped(_ visible: [RadioLogSite]) -> [Section] {
        var order: [String] = []
        var buckets: [String: [RadioLogSite]] = [:]
        for site in visible {
            let key = site.operatorName ?? String(localized: "Opérateur inconnu")
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(site)
        }
        // Sections classées par volume : l'opérateur le plus relevé d'abord.
        return order
            .map { key in
                let bucket = buckets[key] ?? []
                return Section(
                    id: key,
                    operatorName: key,
                    sites: bucket,
                    logCount: bucket.reduce(0) { $0 + $1.logCount }
                )
            }
            .sorted { $0.sites.count > $1.sites.count }
    }

    /// Compteurs sur le CATALOGUE ENTIER — un décompte réel, pas la taille de la
    /// fenêtre chargée. C'est ce qu'engage la maquette, et c'est ce qui rend la
    /// page utilisable : « 3 567 non identifiés » n'a de sens que si c'est le
    /// nombre vrai.
    var totalCount: Int { sites.count }

    /// Part du catalogue dont on connaît le statut. Reste affichée APRÈS le
    /// balayage : elle dit l'état de CONNAISSANCE du catalogue, pas une tâche.
    var completion: Double {
        // Sans les sites invérifiables : la part ne pouvait jamais atteindre 100 %.
        let verifiable = totalCount - uncheckableCount
        guard verifiable > 0 else { return 0 }
        return Double(checkedCount) / Double(verifiable)
    }

    /// Vrai quand tri et réglages sont ceux d'origine : la feuille masque alors
    /// « Revenir aux réglages par défaut », qui n'aurait rien à faire.
    var hasDefaultDisplaySettings: Bool {
        sortOrder == .relevance && groupByOperator && scanOnCellular
    }

    func resetDisplaySettings() {
        sortOrder = .relevance
        groupByOperator = true
        scanOnCellular = true
    }

    func count(for filter: Filter) -> Int {
        switch filter {
        case .all: return totalCount
        case .identified: return identifiedCount
        case .unidentified: return unidentifiedCount
        }
    }

    func state(of site: RadioLogSite) -> RadioLogSiteState {
        states[site.id] ?? .unchecked
    }

    private func order(_ lhs: RadioLogSite, _ rhs: RadioLogSite) -> Bool {
        switch sortOrder {
        case .relevance:
            if lhs.logCount != rhs.logCount { return lhs.logCount > rhs.logCount }
            return lhs.lastSeenAt > rhs.lastSeenAt
        case .recency:
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.logCount > rhs.logCount
        case .identifier:
            // Numérique quand les deux nœuds sont des nombres — « 9881 » doit
            // venir après « 626 », pas avant comme le voudrait l'ordre texte.
            if let left = Int(lhs.node), let right = Int(rhs.node), left != right {
                return left < right
            }
            return lhs.node < rhs.node
        }
    }

    // MARK: Chargement

    /// Délai en deçà duquel rouvrir la page ne relance PAS de rattrapage.
    ///
    /// Le journal est alimenté par des trajets, pas par la seconde : revenir sur
    /// l'écran deux minutes après n'a aucune chance d'y trouver du neuf, et
    /// chaque passage payait pourtant un aller-retour puis une reconstruction
    /// complète de la liste. Tirer pour rafraîchir contourne toujours ce délai —
    /// c'est le geste par lequel on demande explicitement du frais.
    private let syncCooldown: TimeInterval = 10 * 60

    /// Ouverture : le cache d'abord (affichage immédiat), le réseau seulement
    /// s'il a des chances d'apporter quelque chose.
    func onAppear() async {
        await loadFromCache()
        if let lastSyncedAt, Date().timeIntervalSince(lastSyncedAt) < syncCooldown {
            // Rien à retélécharger, mais le balayage peut avoir des sites dont
            // le statut a expiré depuis la dernière fois.
            await startScanIfNeeded()
            return
        }
        await sync()
    }

    /// Le journal pèse environ 2 Mo : le lire, le décoder et le regrouper en sites
    /// se fait hors du fil principal, sinon l'écran restait figé à l'ouverture
    /// (MES-17). Seules les affectations reviennent ici.
    private func loadFromCache() async {
        let service = self.service
        let (snapshot, builtSites, cachedStates) = await Task.detached(priority: .userInitiated) {
            let snapshot = service.cachedSnapshot()
            return (snapshot, RadioLogSiteBuilder.build(from: snapshot.entries), service.cachedSiteStates())
        }.value
        logCount = snapshot.entries.count
        lastSyncedAt = snapshot.lastSyncedAt
        sites = builtSites
        states = cachedStates
        rebuild()
    }

    /// Regroupement d'une page de rattrapage, lui aussi hors du fil principal.
    nonisolated private static func buildSites(_ entries: [RadioLogEntry]) async -> [RadioLogSite] {
        await Task.detached(priority: .userInitiated) { RadioLogSiteBuilder.build(from: entries) }.value
    }

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncReceived = 0
        errorMessage = nil
        premiumMessage = nil

        for await progress in service.syncStream() {
            let builtSites = await Self.buildSites(progress.snapshot.entries)
            logCount = progress.snapshot.entries.count
            lastSyncedAt = progress.snapshot.lastSyncedAt
            syncReceived = progress.received
            sites = builtSites
            rebuild()
            switch progress.failure {
            case let .premiumRequired(message): premiumMessage = message
            case let .network(message): errorMessage = message
            case nil: break
            }
        }

        isSyncing = false
        await startScanIfNeeded()
    }

    /// Rejoue la synchronisation ET le balayage depuis zéro (tirer pour rafraîchir).
    func refresh() async {
        stopScan()
        await sync()
    }

    // MARK: Balayage

    /// Ne balaie que ce qui n'a pas de statut frais : rouvrir la page ne doit pas
    /// relancer 4 800 résolutions déjà connues.
    func startScanIfNeeded() async {
        guard !isScanning else { return }
        guard scanIsAllowedOnCurrentNetwork else { return }
        let pending = sites.filter { states[$0.id] == nil }
        guard !pending.isEmpty else { return }
        startScan(of: pending)
    }

    /// Relance un balayage COMPLET, statuts frais compris (bouton « Tout revérifier »).
    func rescanAll() {
        guard scanIsAllowedOnCurrentNetwork else {
            toast = String(localized: "Balayage désactivé en données mobiles.")
            return
        }
        stopScan()
        startScan(of: sites)
    }

    private var scanIsAllowedOnCurrentNetwork: Bool {
        if scanOnCellular { return true }
        return networkPath.status.connection != .cellular
    }

    private func startScan(of pending: [RadioLogSite]) {
        guard !pending.isEmpty else { return }
        isScanning = true
        isPaused = false
        scanGeneration += 1
        let generation = scanGeneration
        // Le flux est créé hors de la tâche et `self` est ré-obtenu à chaque
        // fenêtre : un `guard let self` en tête retiendrait le modèle pendant
        // tout le balayage, même une fois l'écran fermé.
        let stream = service.scanStream(sites: pending)
        scanTask = Task { [weak self] in
            for await resolved in stream {
                guard let self, !Task.isCancelled else { break }
                self.states.merge(resolved) { _, new in new }
                self.rebuild()
            }
            // Un balayage annulé ou remplacé ne touche plus à l'état du suivant.
            guard !Task.isCancelled, self?.scanGeneration == generation else { return }
            self?.isScanning = false
        }
    }

    /// Suspension d'un geste, comme l'engage la maquette : le bandeau est un
    /// élément de contenu, pas une barre système qu'on subit.
    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        isScanning = false
    }

    func toggleScan() {
        if isScanning {
            stopScan()
            isPaused = true
        } else {
            isPaused = false
            guard scanIsAllowedOnCurrentNetwork else {
                toast = String(localized: "Balayage désactivé en données mobiles.")
                return
            }
            Task { await startScanIfNeeded() }
        }
    }

    // MARK: Fiche de site (commune / adresse)

    /// Charge commune + adresse d'un site identifié, une seule fois.
    ///
    /// À la demande, jamais en masse : c'est un `GET /antenna/{id}` par site, et
    /// la liste en compte plusieurs milliers. On le déclenche au dépliement d'une
    /// carte et dans les écrans qui montrent UN site.
    func loadSiteName(for site: RadioLogSite) {
        guard let siteId = state(of: site).siteId, !siteId.isEmpty else { return }
        guard siteNames[site.id] == nil, !nameTasks.contains(site.id) else { return }
        if let failedAt = nameFailures[site.id], Date().timeIntervalSince(failedAt) < nameRetryDelay { return }
        nameTasks.insert(site.id)
        // Au-delà du plafond, le site attend son tour : le plus récemment affiché passe d'abord.
        if nameTasks.count - queuedNames.count > maxConcurrentNameLoads {
            queuedNames.append(site)
            return
        }
        startNameLoad(for: site, siteId: siteId)
    }

    private func startNameLoad(for site: RadioLogSite, siteId: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let market = site.resolvedMarketCode else {
                self.finishNameLoad(site)
                return
            }
            let details: AntennaDetails?
            do {
                details = try await self.antennas.details(
                    id: siteId,
                    market: market,
                    operatorName: site.resolvedOperatorKey ?? "ALL"
                )
            } catch {
                // Un échec n'est pas retenté à chaque apparition de la ligne.
                self.nameFailures[site.id] = Date()
                self.finishNameLoad(site)
                return
            }
            self.finishNameLoad(site)
            guard let label = Self.locationLabel(from: details) else { return }
            self.siteNames[site.id] = label
        }
    }

    private func finishNameLoad(_ site: RadioLogSite) {
        nameTasks.remove(site.id)
        guard let next = queuedNames.popLast() else { return }
        if let siteId = state(of: next).siteId, !siteId.isEmpty {
            startNameLoad(for: next, siteId: siteId)
        } else {
            finishNameLoad(next)
        }
    }

    static func locationLabel(from details: AntennaDetails?) -> String? {
        guard let details else { return nil }
        let commune = details.core?.commune?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = details.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [commune, address].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        // La maquette écrit « Vézeronce-Curtin — 96 place de la Mairie ».
        return parts.joined(separator: " — ")
    }

    // MARK: Dépliement

    func toggleExpansion(_ site: RadioLogSite) {
        if expandedSiteId == site.id {
            expandedSiteId = nil
        } else {
            expandedSiteId = site.id
            loadSiteName(for: site)
        }
        Haptics.selection()
    }

    // MARK: Suites d'une identification

    /// Une identification vient d'aboutir : on marque le site sans attendre le
    /// prochain balayage. C'est un fait établi par le serveur, pas une supposition.
    func markIdentified(_ site: RadioLogSite, siteId: String) {
        states[site.id] = .identified(siteId: siteId)
        // ⚠️ ET DANS LE CACHE, sinon le statut ne vit qu'en mémoire : `states` est rechargé
        // depuis `cachedSiteStates()` au retour sur l'écran, et le site repassait « Non
        // identifié » — alors que le serveur avait bien accepté l'écriture.
        service.markIdentified(siteKey: site.id, siteId: siteId)
        siteNames[site.id] = nil
        rebuild()
        loadSiteName(for: site)
    }

    // MARK: Purge

    func purge() async {
        do {
            try await service.purge()
            sites = []
            states = [:]
            siteNames = [:]
            logCount = 0
            lastSyncedAt = nil
            rebuild()
            toast = String(localized: "Journal radio supprimé.")
            Haptics.success()
        } catch {
            // En toast : la bannière d'erreur propose « Réessayer », qui resynchronise
            // le journal au lieu de relancer la suppression.
            toast = error.userFacingMessage
            Haptics.error()
        }
    }
}
