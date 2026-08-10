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
    /// dernier applique les pénalités du mode Auto (OVH décalé de 1 500 km,
    /// paliers IPv6 et +90 ms) dont sa propre documentation dit qu'elles ne
    /// doivent jamais peser sur un choix manuel. Les réutiliser ici afficherait
    /// des kilomètres qui ne correspondent à rien sur une carte.
    var serversByDistance: [(server: IPerfPublicServer, km: Double)] {
        guard let userLocation else { return [] }
        return activeIPerfServers
            .map { server in
                (server, haversineDistanceKm(
                    from: userLocation,
                    to: Coordinates(latitude: server.latitude, longitude: server.longitude)
                ))
            }
            .sorted { $0.1 < $1.1 }
    }

    var collapsibleGroups: [(region: String, targets: [SpeedtestDownloadTarget])] {
        SpeedtestDownloadTarget.pickerGroups
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
        return activeIPerfServers
            .filter { !knownIds.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Auto + Cloudflare (moteurs) — toujours visibles. LibreSpeed a sa
            // propre section (data-driven + choix manuel du POP). Ce sont des
            // moteurs, pas des lieux : ils restent en tête même en tri distance.
            ForEach(SpeedtestDownloadTarget.ungroupedCases.filter { $0 != .libreSpeed }) { target in
                serverRow(target)
            }

            if canSortByDistance { sortToggle }

            if sortByDistance {
                distanceList
            } else {
                groupedSections
            }
        }
        // Animation de hauteur/layout uniquement — fluide dans un ScrollView.
        .animation(.easeInOut(duration: 0.25), value: expandedRegion)
        .animation(.easeInOut(duration: 0.25), value: sortByDistance)
        .onAppear {
            expandGroup(containing: selection)
        }
        .onChange(of: selection) { newValue in
            expandGroup(containing: newValue)
        }
    }

    /// Bascule d'ordre. Absente sans position : proposer un tri qu'on ne peut pas
    /// calculer serait pire que de ne rien proposer.
    private var sortToggle: some View {
        Picker("Ordre", selection: $sortByDistance) {
            Text("Par fournisseur").tag(false)
            Text("Par distance").tag(true)
        }
        .pickerStyle(.segmented)
        // Forme à UN paramètre : la variante `(of:initial:_:)` exige iOS 17, et le
        // reste du fichier vise plus bas.
        .onChange(of: sortByDistance) { _ in
            Haptics.selection()
            // Une section repliée n'a plus de sens dans une liste à plat, et la
            // retrouver ouverte au retour surprendrait.
            expandedRegion = nil
        }
    }

    /// Liste à plat, du plus proche au plus lointain, tous fournisseurs mêlés —
    /// c'est justement l'intérêt : en déplacement, on cherche le POP le plus
    /// proche, pas celui d'un opérateur donné.
    @ViewBuilder private var distanceList: some View {
        VStack(spacing: 6) {
            ForEach(serversByDistance, id: \.server.id) { entry in
                distanceRow(entry.server, km: entry.km)
            }
        }
        libreSpeedSection
    }

    @ViewBuilder private var groupedSections: some View {
        ForEach(collapsibleGroups, id: \.region) { group in
                let isExpanded = expandedRegion == group.region
                let selectedInGroup = group.targets.contains(selection)

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        Haptics.selection()
                        // Accordion : ouvrir celle-ci, fermer l'autre.
                        expandedRegion = isExpanded ? nil : group.region
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(SQColor.labelTertiary)
                                .frame(width: 12)
                                .animation(.easeInOut(duration: 0.22), value: isExpanded)

                            Text(group.region)
                                .font(SQFont.body(14, .semibold))
                                .foregroundStyle(SQColor.label)

                            Text("\(group.targets.count)")
                                .font(SQFont.body(11, .semibold))
                                .foregroundStyle(SQColor.labelSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(SQColor.fill, in: Capsule(style: .continuous))

                            Spacer(minLength: 6)

                            if selectedInGroup, !isExpanded {
                                Text(selection.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(SQColor.brandRed)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                                .fill(SQColor.surfaceMuted)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(group.region)
                    .accessibilityValue(isExpanded ? "ouvert" : "fermé")

                    if isExpanded {
                        VStack(spacing: 6) {
                            ForEach(group.targets) { target in
                                serverRow(target)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }

        catalogSection
        libreSpeedSection
    }

    /// Ouvre le groupe du serveur choisi (Auto / Cloudflare n'en ont pas).
    func expandGroup(containing target: SpeedtestDownloadTarget) {
        if target == .libreSpeed { expandedRegion = Self.libreSpeedRegionKey; return }
        if target == .iperfCatalog { expandedRegion = Self.catalogRegionKey; return }
        let region = target.regionLabel
        guard collapsibleGroups.contains(where: { $0.region == region }) else { return }
        expandedRegion = region
    }

    func serverRow(_ target: SpeedtestDownloadTarget) -> some View {
        let selected = selection == target
        return Button {
            selection = target
            Haptics.selection()
        } label: {
            HStack(spacing: SQSpace.md) {
                ZStack {
                    Circle()
                        .fill(selected ? SQColor.brandRed.opacity(0.16) : SQColor.fill)
                        .frame(width: 36, height: 36)
                    Image(systemName: target.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? SQColor.brandRed : SQColor.labelSecondary)
                }

                Text(target.displayName)
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? SQColor.brandRed : SQColor.labelTertiary.opacity(0.5))
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .fill(selected ? SQColor.brandRed.opacity(0.08) : SQColor.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .strokeBorder(selected ? SQColor.brandRed.opacity(0.4) : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.displayName)
        .accessibilityValue(selected ? "sélectionné" : "non sélectionné")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Catalogue — POPs servis par l'API, inconnus de ce binaire

    var catalogCurrentLabel: String {
        catalogOnlyServers.first { $0.id == iperfServerId }?.name ?? ""
    }

    @ViewBuilder private var catalogSection: some View {
        // Rien à montrer tant que l'API n'a rien apporté de nouveau : une section
        // vide serait du bruit dans un sélecteur déjà long.
        if !catalogOnlyServers.isEmpty {
            let isExpanded = expandedRegion == Self.catalogRegionKey
            let isSelected = selection == .iperfCatalog
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    Haptics.selection()
                    expandedRegion = isExpanded ? nil : Self.catalogRegionKey
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(SQColor.labelTertiary)
                            .frame(width: 12)
                        Image(systemName: "server.rack")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isSelected ? SQColor.brandRed : SQColor.labelSecondary)
                        Text("Catalogue")
                            .font(SQFont.body(14, .semibold))
                            .foregroundStyle(SQColor.label)
                        Text("\(catalogOnlyServers.count)")
                            .font(SQFont.body(11, .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(SQColor.fill, in: Capsule(style: .continuous))
                        Spacer(minLength: 6)
                        if isSelected, !isExpanded, !catalogCurrentLabel.isEmpty {
                            Text(catalogCurrentLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SQColor.brandRed)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, SQSpace.md).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous).fill(SQColor.surfaceMuted))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Catalogue")
                .accessibilityValue(isExpanded ? "ouvert" : "fermé")

                if isExpanded {
                    VStack(spacing: 6) {
                        ForEach(catalogOnlyServers, id: \.id) { server in
                            catalogServerRow(server)
                        }
                    }
                    .padding(.top, 6)
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
            libreSpeedRowLabel(
                icon: "server.rack",
                title: server.name,
                subtitle: "\(distanceText(km)) · \(server.code)",
                selected: selected
            )
        }
        .buttonStyle(.plain)
    }

    /// Sous les 10 km la précision au kilomètre a un sens ; au-delà elle est du
    /// bruit — la position vient d'un dernier point connu, pas d'un fix frais.
    func distanceText(_ km: Double) -> String {
        km < 10 ? String(format: "%.1f km", km) : "\(Int(km.rounded())) km"
    }

    func catalogServerRow(_ server: IPerfPublicServer) -> some View {
        let selected = selection == .iperfCatalog && iperfServerId == server.id
        return Button {
            selection = .iperfCatalog
            iperfServerId = server.id
            Haptics.selection()
        } label: {
            libreSpeedRowLabel(
                icon: "server.rack",
                title: server.name,
                // `name` porte déjà la ville (« Londres (Clouvider) ») : le
                // sous-titre ajoute le code POP et le pays, pas une redite.
                subtitle: "\(server.code) · \(server.countryCode)",
                selected: selected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(server.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: LibreSpeed — section data-driven (Auto + choix manuel du POP mondial)

    var libreSpeedCurrentLabel: String {
        if libreSpeedHost.isEmpty { return "Le plus proche" }
        return libreSpeedServers.first { $0.hostname == libreSpeedHost }?.name ?? "Le plus proche"
    }

    @ViewBuilder private var libreSpeedSection: some View {
        let isExpanded = expandedRegion == Self.libreSpeedRegionKey
        let isEngineSelected = selection == .libreSpeed
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.selection()
                expandedRegion = isExpanded ? nil : Self.libreSpeedRegionKey
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SQColor.labelTertiary)
                        .frame(width: 12)
                    Image(systemName: "speedometer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isEngineSelected ? SQColor.brandRed : SQColor.labelSecondary)
                    Text("LibreSpeed")
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                    Text("\(libreSpeedServers.count)")
                        .font(SQFont.body(11, .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(SQColor.fill, in: Capsule(style: .continuous))
                    Spacer(minLength: 6)
                    if isEngineSelected, !isExpanded {
                        Text(libreSpeedCurrentLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SQColor.brandRed)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, SQSpace.md).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous).fill(SQColor.surfaceMuted))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("LibreSpeed")
            .accessibilityValue(isExpanded ? "ouvert" : "fermé")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    libreSpeedAutoRow
                    ForEach(libreSpeedPickerGroups(), id: \.region) { group in
                        Text(group.region)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .padding(.top, 4).padding(.leading, 4)
                        ForEach(group.servers, id: \.hostname) { server in
                            libreSpeedServerRow(server)
                        }
                    }
                }
                .padding(.top, 6)
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
            libreSpeedRowLabel(icon: "location.magnifyingglass", title: "Le plus proche (auto)",
                               subtitle: "POP LibreSpeed le plus proche", selected: selected)
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
            libreSpeedRowLabel(icon: "server.rack", title: server.name,
                               subtitle: server.pickerSubtitle, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(server.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func libreSpeedRowLabel(icon: String, title: String, subtitle: String, selected: Bool) -> some View {
        HStack(spacing: SQSpace.md) {
            ZStack {
                Circle().fill(selected ? SQColor.brandRed.opacity(0.16) : SQColor.fill).frame(width: 32, height: 32)
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? SQColor.brandRed : SQColor.labelSecondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title)).font(SQFont.body(14, .semibold)).foregroundStyle(SQColor.label).lineLimit(1)
                Text(subtitle).font(SQType.micro).foregroundStyle(SQColor.labelSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected ? SQColor.brandRed : SQColor.labelTertiary.opacity(0.5))
        }
        .padding(.horizontal, SQSpace.md).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            .fill(selected ? SQColor.brandRed.opacity(0.08) : SQColor.surfaceMuted))
        .contentShape(Rectangle())
    }
}
