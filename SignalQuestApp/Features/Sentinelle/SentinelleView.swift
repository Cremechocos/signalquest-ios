import SwiftUI

/// Sentinelle — l'état de la connexion fixe, vu depuis la sonde serveur.
///
/// Trois niveaux, du plus général au plus précis :
///
///  1. l'ACCUEIL liste les box surveillées — sauf s'il n'y en a qu'une, auquel
///     cas sa page EST l'accueil : une liste à un seul élément n'est qu'un écran
///     de plus à traverser ;
///  2. la page d'une BOX répond à « est-ce que ma connexion est tombée », et
///     surtout montre CHACUNE de ses adresses avec son état propre ;
///  3. la page d'une ADRESSE dit « quel maillon », « depuis quand » et « qu'est-ce
///     que j'oppose à mon opérateur », pour cette famille seulement.
///
/// Ce découpage n'est pas un rangement : en IPv6 il n'y a pas de NAT, donc une
/// box peut répondre parfaitement en IPv4 pendant que son IPv6 est morte.
/// Fondues dans une moyenne unique, ces pannes-là restent invisibles.
@MainActor
final class SentinelleViewModel: ObservableObject {
    @Published private(set) var targets: [SentinelleTarget] = []
    @Published private(set) var incidents: [String: [SentinelleIncident]] = [:]
    @Published private(set) var points: [String: [SentinelleSeriesPoint]] = [:]
    @Published private(set) var quota: SentinelleQuota?
    @Published private(set) var isLoading = true
    @Published private(set) var accessDenied = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isBusy = false
    /// Échec d'une action de l'utilisateur (création, correction, retrait). Il se
    /// dit tout de suite et à part : le confondre avec une erreur de chargement
    /// remplacerait un écran de données valides par un message d'échec.
    @Published var actionError: String?

    let service: SentinelleServicing

    init(service: SentinelleServicing) {
        self.service = service
    }

    func target(_ id: String) -> SentinelleTarget? {
        targets.first { $0.id == id }
    }

    /// - Parameter silently: rafraîchissement de fond. Une erreur passagère ne
    ///   doit alors PAS remplacer un écran de données valides par un message
    ///   d'échec : perdre le réseau une seconde effacerait ce que l'utilisateur
    ///   est en train de lire. On garde l'affichage précédent et on retentera.
    func load(silently: Bool = false) async {
        do {
            let response = try await loadTargets()
            targets = response.targets
            quota = response.quota

            // Les détails partent EN PARALLÈLE. Enchaînés, ils faisaient sept
            // allers-retours en série pour trois box — plusieurs secondes d'écran
            // vide avant le premier chiffre. Ils sont indépendants les uns des
            // autres : rien ne justifiait de les attendre l'un après l'autre.
            var collectedIncidents: [String: [SentinelleIncident]] = [:]
            var collectedPoints: [String: [SentinelleSeriesPoint]] = [:]

            await withTaskGroup(of: (String, [SentinelleIncident]?, [SentinelleSeriesPoint]?).self) { group in
                for target in response.targets {
                    group.addTask { [service] in
                        // Les deux requêtes d'une même box partent elles aussi
                        // ensemble : la série ne dépend pas du détail.
                        async let detail = try? await service.detail(targetId: target.id)
                        async let series = try? await service.series(
                            targetId: target.id, window: .h24, family: nil
                        )
                        return (target.id, await detail?.incidents, await series?.points)
                    }
                }
                for await (id, incidents, points) in group {
                    // Une requête en échec laisse la clé ABSENTE, et l'écran se
                    // tait. Retomber sur un tableau vide ferait dire « aucune
                    // coupure enregistrée » à une simple perte de réseau — une
                    // affirmation que la donnée ne soutient pas.
                    if let incidents { collectedIncidents[id] = incidents }
                    else if let previous = self.incidents[id] { collectedIncidents[id] = previous }
                    if let points { collectedPoints[id] = points }
                    else if let previous = self.points[id] { collectedPoints[id] = previous }
                }
            }

            incidents = collectedIncidents
            points = collectedPoints
            errorMessage = nil
        } catch is SentinelleAccessDenied {
            accessDenied = true
        } catch {
            if !silently { errorMessage = error.localizedDescription }
        }
        isLoading = false
        lastRefresh = Date()
    }

    /// Charge la liste, avec UNE seconde tentative.
    ///
    /// Au démarrage, cet écran partait avant que la session ne soit rétablie :
    /// l'appel échouait, « Chargement impossible » s'affichait, et un appui sur
    /// « Réessayer » réussissait aussitôt — la preuve que l'échec était de
    /// timing, pas de fond. Une seule reprise suffit donc, et un second échec
    /// reste annoncé : on ne masque pas une panne réelle sous des reprises.
    private func loadTargets() async throws -> SentinelleTargetsResponse {
        do {
            return try await service.targets()
        } catch is SentinelleAccessDenied {
            throw SentinelleAccessDenied()
        } catch {
            try? await Task.sleep(for: .milliseconds(400))
            return try await service.targets()
        }
    }

    func create(label: String, address: String) async {
        await mutate { try await self.service.create(label: label, address: address) }
    }

    func setAddress(targetId: String, family: SentinelleFamily, address: String) async {
        await mutate { try await self.service.setAddress(targetId: targetId, family: family, address: address) }
    }

    /// - Returns: vrai quand la cible a bien été retirée, pour que la page
    ///   ouverte sur cette cible puisse se refermer plutôt que rester vide.
    @discardableResult
    func delete(targetId: String) async -> Bool {
        await mutate { try await self.service.delete(targetId: targetId) }
    }

    func currentIp() async -> SentinelleCurrentIp? {
        try? await service.currentIp()
    }

    /// Toute écriture suit le même chemin : occupée, relecture, et l'échec se
    /// dit — une correction d'adresse avalée en silence est la pire des issues,
    /// l'utilisateur croirait sa box de nouveau surveillée.
    @discardableResult
    private func mutate(_ action: @escaping () async throws -> Void) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await action()
            await load(silently: true)
            return true
        } catch is SentinelleAccessDenied {
            accessDenied = true
            return false
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }
}

struct SentinelleView: View {
    @StateObject private var model: SentinelleViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCreate = false
    @State private var showSettings = false

    init(service: SentinelleServicing) {
        _model = StateObject(wrappedValue: SentinelleViewModel(service: service))
    }

    /// La justification d'origine — « la sonde mesure au mieux une fois par
    /// minute » — n'est plus vraie : la cadence est réglable par cible
    /// (60/30/10 s) et descend à 5 s pendant une coupure. À 60 s, le ping
    /// affiché retardait sur la mesure réelle, et une adresse ajoutée depuis
    /// le web ou Android mettait jusqu'à une minute à apparaître ici.
    private static let refreshInterval: Duration = .seconds(20)

    var body: some View {
        Group {
            if model.isLoading && model.targets.isEmpty {
                loadingState
            } else if model.accessDenied {
                EmptyStateView(
                    title: "Réservé aux membres Premium",
                    message: "Sentinelle surveille votre connexion en continu : disponibilité, "
                        + "latence, perte de paquets et historique daté de chaque coupure.",
                    systemImage: "crown.fill"
                )
                .padding(SQSpace.lg)
            } else if let errorMessage = model.errorMessage, model.targets.isEmpty {
                ErrorStateView(title: "Chargement impossible", message: errorMessage) {
                    Task { await model.load() }
                }
                .padding(SQSpace.lg)
            } else if model.targets.isEmpty {
                EmptyStateView(
                    title: "Aucune connexion surveillée",
                    message: "Ajoutez l’adresse publique de votre box : Sentinelle l’interrogera "
                        + "chaque minute depuis nos serveurs, téléphone éteint compris.",
                    systemImage: "wifi.router"
                )
                .padding(SQSpace.lg)
            } else if let single = singleTarget {
                // Une liste à un seul élément n'apporte rien : la box unique EST
                // l'accueil.
                SentinelleBoxView(model: model, targetId: single.id, isRoot: true)
            } else {
                boxList
            }
        }
        .navigationTitle(title)
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .toolbar {
            // L'ajout n'existe qu'au niveau ACCUEIL, y compris quand celui-ci
            // prend la forme de la box unique : le masquer dans ce cas rendrait
            // la deuxième connexion impossible à créer. Il crée toujours une
            // NOUVELLE box — compléter une box existante se fait sur sa page.
            // Les réglages d'alerte vivaient uniquement sur le web. Or c'est en
            // mobilité qu'on découvre n'avoir pas été prévenu, donc là qu'on veut
            // corriger.
            if !model.accessDenied {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Haptics.light()
                        showSettings = true
                    } label: {
                        Label("Réglages des alertes", systemImage: "bell.badge")
                    }
                    .tint(SQColor.labelSecondary)
                }
            }
            if canCreate {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Haptics.light()
                        showCreate = true
                    } label: {
                        Label("Ajouter une connexion", systemImage: "plus")
                    }
                    .tint(SQColor.brandRed)
                }
            }
        }
        .refreshable { await model.load(silently: true) }
        .task {
            await model.load()
            // Boucle de rafraîchissement. `.task` est annulée quand la vue
            // disparaît, ce qui suffit à l'arrêter à la sortie de l'écran ;
            // l'arrière-plan, lui, ne l'annule pas, d'où le test de phase :
            // rien ne sert de relever des mesures que personne ne regarde.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled, scenePhase == .active else { continue }
                await model.load(silently: true)
            }
        }
        // Forme à un paramètre : l'app est déployée en deçà d'iOS 17, où la
        // variante `onChange(of:initial:_:)` n'existe pas encore.
        .onChange(of: scenePhase) { phase in
            // Au retour au premier plan, l'écran peut afficher un état vieux de
            // plusieurs heures : on rattrape immédiatement plutôt que d'attendre
            // la fin du cycle en cours.
            guard phase == .active, !model.isLoading else { return }
            Task { await model.load(silently: true) }
        }
        .sheet(isPresented: $showSettings) {
            SentinelleAlertSettingsSheet(service: model.service)
        }
        .sheet(isPresented: $showCreate) {
            SentinelleCreateSheet(quota: model.quota, currentIp: { await model.currentIp() }) { label, address in
                Task { await model.create(label: label, address: address) }
            }
        }
        .alert(
            "Action impossible",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("Fermer", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var singleTarget: SentinelleTarget? {
        model.targets.count == 1 ? model.targets.first : nil
    }

    /// Le titre suit le niveau affiché : sur la box unique, c'est son nom qui
    /// situe, pas le nom de la fonctionnalité.
    private var title: String {
        singleTarget?.label ?? String(localized: "Sentinelle")
    }

    private var canCreate: Bool {
        !model.accessDenied && !model.isLoading && model.quota?.isFull != true
    }

    private var boxList: some View {
        ScrollView {
            VStack(spacing: SQSpace.md + 2) {
                ForEach(model.targets) { target in
                    NavigationLink {
                        SentinelleBoxView(model: model, targetId: target.id)
                    } label: {
                        SentinelleBoxCard(
                            target: target,
                            points: model.points[target.id] ?? [],
                            incidents: model.incidents[target.id]
                        )
                    }
                    .buttonStyle(SQPressButtonStyle())
                }
                SentinelleFreshness(date: model.lastRefresh)
            }
            .padding(.horizontal, SQSpace.lg)
            // Rien ne sépare visuellement la barre de navigation du contenu :
            // une marge pleine y creusait un vide que l'utilisateur a signalé.
            // Même valeur qu'Android.
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.huge)
            .sqReadableWidth()
        }
    }

    private var loadingState: some View {
        VStack(spacing: SQSpace.lg) {
            ProgressView().tint(SQColor.brandRed)
            Text("Lecture de la surveillance…")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Une box dans la liste : son verdict, ses familles en raccourci, ses coupures.
struct SentinelleBoxCard: View {
    let target: SentinelleTarget
    let points: [SentinelleSeriesPoint]
    let incidents: [SentinelleIncident]?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(alignment: .top, spacing: SQSpace.sm + 2) {
                    SentinelleStatusDot(color: SentinelleWording.statusColor(target.status))
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SentinelleWording.verdict(target))
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: SQSpace.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                        .sqDecorative()
                }

                SentinelleDeadFamilyNote(target: target, points: points)
                SentinelleSuspendedNote(target: target)
                SentinelleOutagesLine(incidents: incidents)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sqCard(
            label: SentinelleWording.verdict(target),
            value: subtitle,
            hint: NSLocalizedString("Ouvrir le détail de cette connexion", comment: "")
        )
    }

    private var subtitle: String {
        if let hostname = target.hostname { return hostname }
        let families = target.addresses.map(\.familyLabel)
        return families.isEmpty
            ? String(localized: "en attente d’adresse")
            : families.joined(separator: " · ")
    }
}

/// Une famille morte pendant que l'autre répond ne se voit dans AUCUNE moyenne :
/// c'est la seule ligne de la liste qui la signale.
struct SentinelleDeadFamilyNote: View {
    let target: SentinelleTarget
    let points: [SentinelleSeriesPoint]

    var body: some View {
        let dead = target.addresses.filter { points.inFamily($0.family).addressState == .down }
        if !dead.isEmpty, target.status != "down" {
            Text("\(dead.map(\.familyLabel).joined(separator: " et ")) ne répond plus, l’autre famille tient la connexion.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SQSpace.xs)
        }
    }
}

struct SentinelleSuspendedNote: View {
    let target: SentinelleTarget

    var body: some View {
        if target.suspendedReason != nil {
            Text("Surveillance suspendue : l’adresse a changé de réseau. Vérifiez depuis le site qu’elle vous appartient toujours.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SQSpace.xs)
        }
    }
}

/// Le décompte des coupures — ou rien du tout.
///
/// `incidents` vaut `nil` tant que le journal n'a pas été lu : on ne dit alors
/// RIEN, plutôt que d'annoncer « aucune coupure enregistrée » pour une lecture
/// qui n'a simplement pas abouti.
struct SentinelleOutagesLine: View {
    let incidents: [SentinelleIncident]?

    var body: some View {
        if let incidents {
            let outages = incidents.filter(\.isOutage)
            let count = SentinelleWording.outages(outages.count)
            Text(outages.isEmpty
                ? String(localized: "Aucune coupure enregistrée.")
                : String(localized: "\(count) · la dernière \(SentinelleWording.date(outages.first?.startedAt))"))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SQSpace.xs)
        }
    }
}

/// Horodatage de la dernière relecture. Discret par nature : il ne compte que
/// quand on se demande si ce qu'on lit est vieux.
struct SentinelleFreshness: View {
    let date: Date?

    var body: some View {
        if let date {
            Text("Mesures relues à \(date.formatted(date: .omitted, time: .shortened))")
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, SQSpace.sm)
        }
    }
}
