import SwiftUI

/// Sélecteur de serveur iPerf3 groupé et repliable.
/// Accordion : une seule section provider ouverte à la fois, animation layout
/// simple (pas de `.move` qui décale le ScrollView parent).
struct SpeedtestServerPicker: View {
    @Binding var selection: SpeedtestDownloadTarget
    /// Serveur LibreSpeed choisi manuellement (hostname) ; vide = le plus proche.
    @Binding var libreSpeedHost: String
    /// POP iPerf3 choisi dans le catalogue distant (id) ; vide = aucun.
    @Binding var iperfServerId: String
    /// Snapshot observable fourni par l'écran après chargement du cache/API.
    /// Le moteur prendra sa propre copie immuable au lancement du test.
    var servers: [IPerfPublicServer] = activeIPerfServers
    /// Dernière position connue, ou `nil`. Volontairement passée par le parent
    /// plutôt que lue ici : ouvrir un sélecteur ne doit pas déclencher une demande
    /// de permission ni attendre un fix GPS.
    var userLocation: Coordinates?
    /// `nil` = tout replié (sauf Auto toujours visible).
    @State private var expandedRegion: String?
    /// Tri par distance plutôt que par fournisseur. Non persisté : c'est un
    /// confort de consultation, pas un réglage de mesure.
    @State private var sortByDistance = false

    /// Vrai quand le tri par distance a un sens. Sans position il est simplement
    /// indisponible — on retombe sur l'affichage habituel, sans message d'erreur :
    /// le sélecteur reste utilisable, et le moteur a de toute façon son propre
    /// repli (POPs FR non-OVH d'abord).
    var canSortByDistance: Bool { userLocation != nil }

    /// Tous les POPs du plus proche au plus lointain, distance en prime.
    ///
    /// ⚠️ Distance GÉOGRAPHIQUE pure, PAS `iperfServersSortedByDistance` : ce
    /// dernier applique les règles d'éligibilité et les éventuelles pénalités du
    /// catalogue destinées au mode Auto. Elles ne doivent jamais peser sur un
    /// choix manuel ni produire des kilomètres fictifs dans cette liste.
    var serversByDistance: [(server: IPerfPublicServer, km: Double)] {
        guard let userLocation else { return [] }
        return servers
            .filter(\.selectable)
            .map { server in
                (server, haversineDistanceKm(
                    from: userLocation,
                    to: Coordinates(latitude: server.latitude, longitude: server.longitude)
                ))
            }
            .sorted { $0.1 < $1.1 }
    }

    var collapsibleGroups: [(region: String, targets: [SpeedtestDownloadTarget])] {
        SpeedtestDownloadTarget.pickerGroups.compactMap { group in
            let targets = group.targets.filter { target in
                servers.contains { $0.id == target.rawValue && $0.selectable }
            }
            return targets.isEmpty ? nil : (region: group.region, targets: targets)
        }
    }
    static let libreSpeedRegionKey = "LibreSpeed"
    static let catalogRegionKey = "Catalogue"

    /// POPs servis par l'API que cette version de l'app ne connaît PAS en dur.
    ///
    /// Ceux qu'elle connaît sont déjà dans leur groupe fournisseur ci-dessus ; les
    /// répéter ferait des doublons. Cette section montre donc exactement ce que le
    /// catalogue distant apporte — et sans elle, ces POPs ne seraient atteignables
    /// qu'en mode Auto, jamais choisis explicitement.
    var catalogOnlyServers: [IPerfPublicServer] {
        let knownIds = Set(SpeedtestDownloadTarget.allCases.map(\.rawValue))
        return servers
            .filter { $0.selectable && !knownIds.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    /// Les mêmes, groupés par PAYS.
    ///
    /// Pas par fournisseur : 29 des 33 POPs apportés par le catalogue portent le
    /// fournisseur générique `community` et s'entasseraient sous un seul en-tête
    /// sans information. Par pays, on obtient une quinzaine de groupes équilibrés.
    /// Le fournisseur reste lisible — il est déjà dans le nom du POP
    /// (« Montréal (GoCo) ») — donc le pays n'est pas une redite.
    ///
    /// Même découpage qu'Android (`SpeedTestScreen.kt`) : les deux apps servent le
    /// même catalogue, les présenter différemment n'aurait aucune justification.
    var catalogServersByCountry: [(country: String, servers: [IPerfPublicServer])] {
        Dictionary(grouping: catalogOnlyServers, by: \.countryCode)
            .sorted { $0.key < $1.key }
            .map { (country: $0.key, servers: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if canSortByDistance { sortToggle }

            // Auto + Cloudflare (moteurs) — toujours en tête. LibreSpeed a sa
            // propre section (data-driven + choix manuel du POP). Ce sont des
            // moteurs, pas des lieux : ils restent en tête même en tri distance.
            card {
                let engines = SpeedtestDownloadTarget.ungroupedCases.filter { $0 != .libreSpeed }
                ForEach(Array(engines.enumerated()), id: \.element.id) { index, target in
                    if index > 0 { rowDivider() }
                    serverRow(target)
                }
            }

            if sortByDistance {
                distanceList
            } else {
                groupedSections
            }

            // BBR et CUBIC en clair : deux noms de réglage TCP affichés sans
            // explication (MES-35).
            if collapsibleGroups.contains(where: { $0.targets.contains(where: \.isCongestionVariant) }) {
                Text("BBR et CUBIC sont deux façons de régler le débit TCP. BBR monte plus vite et tient mieux sur un réseau mobile ; CUBIC reflète le réglage classique des serveurs.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.xs)
            }
        }
        // Animation de hauteur/layout uniquement — fluide dans un ScrollView.
        .sqAnimation(.easeInOut(duration: 0.25), value: expandedRegion)
        .sqAnimation(.easeInOut(duration: 0.25), value: sortByDistance)
        .onAppear {
            expandGroup(containing: selection)
        }
        .onChange(of: selection) { newValue in
            expandGroup(containing: newValue)
        }
    }

    // MARK: Briques Halo — lignes sur une carte

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 2)
            .sqCardBackground()
    }

    private func rowDivider(indent: CGFloat = SQSpace.cardPadding) -> some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(height: 1)
            .padding(.leading, indent)
    }

    private func kicker(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(SQFont.body(12, .bold, relativeTo: .caption))
            .tracking(12 * 0.14)
            .textCase(.uppercase)
            .foregroundStyle(SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.xs)
            .padding(.top, SQSpace.xs)
            .sqHeader()
    }

    /// Ligne à bouton radio : carmin quand elle est choisie.
    private func radioRow(_ title: Text, subtitle: String? = nil, selected: Bool, indented: Bool = false) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: indented ? 18 : 20, weight: .regular))
                .foregroundStyle(selected ? SQColor.brandRed : SQColor.labelSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(SQFont.body(indented ? 14 : 15, selected ? .bold : .semibold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, indented ? SQSpace.cardPadding + SQSpace.md : SQSpace.cardPadding)
        .padding(.trailing, SQSpace.cardPadding)
        .padding(.vertical, SQSpace.xs2)
        .frame(minHeight: indented ? 44 : 50)
        .contentShape(Rectangle())
    }

    /// En-tête repliable d'un groupe : nom, nombre de serveurs, choix courant
    /// quand le groupe est replié, chevron.
    private func groupHeader(_ title: Text, count: Int, isExpanded: Bool, current: String?, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: SQSpace.sm2) {
                title
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(verbatim: "\(count)")
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(SQColor.chip, in: Capsule(style: .continuous))
                Spacer(minLength: 6)
                if let current, !isExpanded {
                    Text(verbatim: current)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .sqAnimation(.easeInOut(duration: 0.22), value: isExpanded)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.cardPadding)
            .padding(.vertical, SQSpace.xs2)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "ouvert" : "fermé")
    }

    /// Bascule d'ordre. Absente sans position : proposer un tri qu'on ne peut pas
    /// calculer serait pire que de ne rien proposer.
    private var sortToggle: some View {
        MapSegmented(
            selection: $sortByDistance,
            options: [(false, String(localized: "Par fournisseur")), (true, String(localized: "Par distance"))],
            identifier: "speedtest.server.order"
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ordre")
        // Forme à UN paramètre : la variante `(of:initial:_:)` exige iOS 17, et le
        // reste du fichier vise plus bas.
        .onChange(of: sortByDistance) { _ in
            // Une section repliée n'a plus de sens dans une liste à plat, et la
            // retrouver ouverte au retour surprendrait.
            expandedRegion = nil
        }
    }

    /// Liste à plat, du plus proche au plus lointain, tous fournisseurs mêlés —
    /// c'est justement l'intérêt : en déplacement, on cherche le POP le plus
    /// proche, pas celui d'un opérateur donné.
    @ViewBuilder private var distanceList: some View {
        card {
            ForEach(Array(serversByDistance.enumerated()), id: \.element.server.id) { index, entry in
                if index > 0 { rowDivider() }
                distanceRow(entry.server, km: entry.km)
            }
        }
        kicker("LibreSpeed")
        card { libreSpeedSection }
    }

    /// Groupes iPerf3 publics : rangés avec LibreSpeed, pas avec les fournisseurs.
    func isPublicIperfGroup(_ region: String) -> Bool { region.hasPrefix("iPerf3") }

    @ViewBuilder private var groupedSections: some View {
        kicker("Fournisseurs")
        card {
            regionGroups(collapsibleGroups.filter { !isPublicIperfGroup($0.region) })
        }

        kicker("iPerf3 et LibreSpeed")
        card {
            let iperfGroups = collapsibleGroups.filter { isPublicIperfGroup($0.region) }
            regionGroups(iperfGroups)
            if !iperfGroups.isEmpty { rowDivider() }
            if !catalogOnlyServers.isEmpty {
                catalogSection
                rowDivider()
            }
            libreSpeedSection
        }
    }

    @ViewBuilder private func regionGroups(_ groups: [(region: String, targets: [SpeedtestDownloadTarget])]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.element.region) { index, group in
            let isExpanded = expandedRegion == group.region
            let selectedInGroup = group.targets.contains(selection)
            if index > 0 { rowDivider() }
            groupHeader(
                Text(verbatim: group.region),
                count: group.targets.count,
                isExpanded: isExpanded,
                current: selectedInGroup ? selection.displayName : nil
            ) {
                // Accordion : ouvrir celle-ci, fermer l'autre.
                expandedRegion = isExpanded ? nil : group.region
            }
            .accessibilityLabel(group.region)
            if isExpanded {
                ForEach(group.targets) { target in
                    serverRow(target, indented: true)
                }
            }
        }
    }

    /// Ouvre le groupe du serveur choisi (Auto / Cloudflare n'en ont pas).
    func expandGroup(containing target: SpeedtestDownloadTarget) {
        if target == .libreSpeed { expandedRegion = Self.libreSpeedRegionKey; return }
        if target == .iperfCatalog { expandedRegion = Self.catalogRegionKey; return }
        let region = target.regionLabel
        guard collapsibleGroups.contains(where: { $0.region == region }) else { return }
        expandedRegion = region
    }

    func serverRow(_ target: SpeedtestDownloadTarget, indented: Bool = false) -> some View {
        let selected = selection == target
        return Button {
            selection = target
            Haptics.selection()
        } label: {
            radioRow(
                Text(verbatim: target.displayName),
                subtitle: target == .hybridAuto ? String(localized: "Recommandé · le plus proche à chaque test") : nil,
                selected: selected,
                indented: indented
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Catalogue — POPs servis par l'API, inconnus de ce binaire

    var catalogCurrentLabel: String {
        catalogOnlyServers.first { $0.id == iperfServerId }?.name ?? ""
    }

    @ViewBuilder private var catalogSection: some View {
        let isExpanded = expandedRegion == Self.catalogRegionKey
        let isSelected = selection == .iperfCatalog
        groupHeader(
            Text("Catalogue"),
            count: catalogOnlyServers.count,
            isExpanded: isExpanded,
            current: isSelected && !catalogCurrentLabel.isEmpty ? catalogCurrentLabel : nil
        ) {
            expandedRegion = isExpanded ? nil : Self.catalogRegionKey
        }
        .accessibilityLabel("Catalogue")

        if isExpanded {
            ForEach(catalogServersByCountry, id: \.country) { group in
                // Code pays brut : neutre linguistiquement, donc aucune
                // chaîne à traduire, et c'est le repère utile quand on
                // cherche un POP proche.
                Text(group.country)
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SQSpace.cardPadding + SQSpace.md)
                    .padding(.top, SQSpace.xs)
                    .accessibilityLabel("Pays : \(group.country)")
                ForEach(group.servers, id: \.id) { server in
                    catalogServerRow(server)
                }
            }
        }
    }

    /// Ligne du tri par distance : le même POP peut être connu de l'enum (il a
    /// alors sa cible dédiée) ou venir seulement du catalogue distant. On résout
    /// les deux ici, sinon choisir un POP OVH depuis cette liste le sélectionnerait
    /// comme un POP de catalogue et perdrait sa cible d'origine.
    func distanceRow(_ server: IPerfPublicServer, km: Double) -> some View {
        let knownTarget = SpeedtestDownloadTarget(rawValue: server.id)
        let selected = knownTarget.map { selection == $0 }
            ?? (selection == .iperfCatalog && iperfServerId == server.id)
        return Button {
            if let knownTarget {
                selection = knownTarget
            } else {
                selection = .iperfCatalog
                iperfServerId = server.id
            }
            Haptics.selection()
        } label: {
            radioRow(Text(verbatim: server.name), subtitle: "\(distanceText(km)) · \(server.code)", selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(server.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Sous les 10 km la précision au kilomètre a un sens ; au-delà elle est du
    /// bruit — la position vient d'un dernier point connu, pas d'un fix frais.
    func distanceText(_ km: Double) -> String {
        km < 10 ? SQUnits.distance(kilometers: km) : "\(Int(km.rounded())) km"
    }

    func catalogServerRow(_ server: IPerfPublicServer) -> some View {
        let selected = selection == .iperfCatalog && iperfServerId == server.id
        return Button {
            selection = .iperfCatalog
            iperfServerId = server.id
            Haptics.selection()
        } label: {
            // `name` porte déjà la ville (« Londres (Clouvider) ») et le pays est
            // dans l'en-tête de groupe. Reste le code POP, qui distingue deux POPs
            // d'une même ville (« PAR-BBR » / « PAR-CUBIC »).
            radioRow(Text(verbatim: server.name), subtitle: server.code, selected: selected, indented: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(server.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: LibreSpeed — section data-driven (Auto + choix manuel du POP mondial)

    var libreSpeedCurrentLabel: String {
        if libreSpeedHost.isEmpty { return String(localized: "Le plus proche") }
        return libreSpeedServers.first { $0.hostname == libreSpeedHost }?.name ?? String(localized: "Le plus proche")
    }

    @ViewBuilder private var libreSpeedSection: some View {
        let isExpanded = expandedRegion == Self.libreSpeedRegionKey
        let isEngineSelected = selection == .libreSpeed
        groupHeader(
            Text(verbatim: "LibreSpeed"),
            count: libreSpeedServers.count,
            isExpanded: isExpanded,
            current: isEngineSelected ? libreSpeedCurrentLabel : nil
        ) {
            expandedRegion = isExpanded ? nil : Self.libreSpeedRegionKey
        }
        .accessibilityLabel("LibreSpeed")

        if isExpanded {
            libreSpeedAutoRow
            ForEach(libreSpeedPickerGroups(), id: \.region) { group in
                Text(group.region)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, SQSpace.cardPadding + SQSpace.md)
                    .padding(.top, SQSpace.xs)
                ForEach(group.servers, id: \.hostname) { server in
                    libreSpeedServerRow(server)
                }
            }
        }
    }

    var libreSpeedAutoRow: some View {
        let selected = selection == .libreSpeed && libreSpeedHost.isEmpty
        return Button {
            selection = .libreSpeed
            libreSpeedHost = ""
            Haptics.selection()
        } label: {
            radioRow(Text("Le plus proche (auto)"),
                     subtitle: String(localized: "Serveur LibreSpeed le plus proche"), selected: selected, indented: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("LibreSpeed le plus proche")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func libreSpeedServerRow(_ server: LibreSpeedServer) -> some View {
        let selected = selection == .libreSpeed && libreSpeedHost == server.hostname
        return Button {
            selection = .libreSpeed
            libreSpeedHost = server.hostname
            Haptics.selection()
        } label: {
            radioRow(Text(verbatim: server.name), subtitle: server.pickerSubtitle, selected: selected, indented: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(server.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Page « Serveur de test » des réglages du Speedtest : retour rond, grand
/// titre, puis le sélecteur.
struct SpeedtestServerPage: View {
    @Binding var selection: SpeedtestDownloadTarget
    @Binding var libreSpeedHost: String
    @Binding var iperfServerId: String
    var servers: [IPerfPublicServer]
    var userLocation: Coordinates?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "speedtest.server.back") {
                    dismiss()
                }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Serveur de test")
                        .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                    Text("Le débit dépend aussi du serveur : plus il est proche, plus la mesure est juste.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, SQSpace.xs)
                SpeedtestServerPicker(
                    selection: $selection,
                    libreSpeedHost: $libreSpeedHost,
                    iperfServerId: $iperfServerId,
                    servers: servers,
                    userLocation: userLocation
                )
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .signalQuestBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}
