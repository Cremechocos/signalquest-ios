import SwiftUI
import MapKit

struct MapAdvancedFilterSheet: View {
    @Binding var market: String
    @Binding var operatorName: String
    @Binding var technologies: Set<String>
    @Binding var bands: Set<Int>
    @Binding var bandMatch: BandMatchMode
    @Binding var azimuthStyle: AzimuthStyle
    @Binding var sharing: Set<String>
    @Binding var speedtestDays: Int
    @Binding var coverageDays: Int
    @Binding var layers: Set<MapDisplayItem.Kind>
    @Binding var includeObserved: Bool
    /// Statuts prévisionnels visibles (sous-filtre de la couche Prévisionnels).
    @Binding var plannedStatuses: Set<PlannedActivationStatus>
    /// Marchés `publicSelectable` du registre, dans l'ordre du backend.
    let allMarkets: [MarketRegistryEntry]
    @Environment(\.dismiss) private var dismiss

    /// La couche communautaire est-elle disponible/active dans cette feuille ?
    var communityLayerAvailable: Bool {
        selectedEntry?.isCommunityOnly == true || selectedEntry?.capabilities.communityLayers == true
    }

    /// Entrée du registre correspondant au marché sélectionné dans la feuille.
    var selectedEntry: MarketRegistryEntry? {
        let normalized = market.uppercased()
        return allMarkets.first {
            $0.marketCode.uppercased() == normalized || $0.code.uppercased() == normalized
        }
    }

    var operatorOptions: [String] {
        guard let entry = selectedEntry else { return ["ALL"] }
        var keys = entry.selectableOperators.map(\.key)
        if !keys.contains(where: { $0.uppercased() == "ALL" }) {
            keys.append("ALL")
        }
        return keys
    }

    /// Code marché normalisé pour le catalogue de filtres : préfère le
    /// `marketCode` du registre (robuste aux pays partageant un marché), sinon
    /// le binding brut. Pilote les sections Technologies/Partage/Bandes.
    var catalogMarket: String {
        selectedEntry?.marketCode ?? market
    }

    /// Couches proposées : un marché communautaire se limite aux couches
    /// pertinentes (sites communautaires + speedtests).
    var layerOptions: [(MapDisplayItem.Kind, String, String)] {
        if selectedEntry?.isCommunityOnly == true {
            return [
                (.communitySite, String(localized: "Sites communautaires"), "dot.radiowaves.up.forward"),
                // Sans open data, les sites pointés à la main sont souvent la seule
                // antenne visible du pays : la couche doit rester proposée ici.
                (.customSite, String(localized: "Sites ajoutés"), "mappin.and.ellipse"),
                (.speedtest, String(localized: "Speedtests"), "speedometer")
            ]
        }
        var options: [(MapDisplayItem.Kind, String, String)] = [
            (.antenna, String(localized: "Antennes"), "antenna.radiowaves.left.and.right"),
            (.customSite, String(localized: "Sites ajoutés"), "mappin.and.ellipse"),
            (.speedtest, String(localized: "Speedtests"), "speedometer"),
            (.photo, String(localized: "Photos"), "photo"),
            (.friend, String(localized: "Amis"), "person.2"),
            (.coverage, String(localized: "Couverture communautaire"), "dot.radiowaves.left.and.right")
        ]
        // Pannes & Prévisionnels : données ANFR FR/DROM uniquement (le backend ne
        // répond que pour ces marchés ; ailleurs `load()` ne les charge jamais).
        // On ne propose donc pas ces puces mortes hors FR/DROM.
        if ["FR", "DROM"].contains(catalogMarket.uppercased()) {
            options.append((.outage, "Pannes", "exclamationmark.triangle"))
            options.append((.planned, "Prévisionnels", "calendar.badge.clock"))
        }
        if selectedEntry?.capabilities.communityLayers == true {
            options.append((.communitySite, "Sites communautaires", "dot.radiowaves.up.forward"))
        }
        return options
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.md + 2) {
                    filterSection("Pays", icon: "globe") {
                        Menu {
                            ForEach(allMarkets) { entry in
                                Button {
                                    if !isCurrentMarket(entry) { market = entry.code }
                                } label: {
                                    if isCurrentMarket(entry) {
                                        Label(marketMenuTitle(entry), systemImage: "checkmark")
                                    } else {
                                        Text(marketMenuTitle(entry))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: SQSpace.sm) {
                                Text(flagEmoji(selectedEntry?.countryCode ?? ""))
                                    .font(.system(size: 18))
                                Text(selectedEntry?.label ?? market)
                                    .font(SQFont.body(15, .semibold))
                                    .foregroundStyle(SQColor.label)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .padding(.horizontal, SQSpace.md)
                            .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        }
                        Text("S'ajuste aussi tout seul selon ta position / ta SIM.")
                            .font(SQFont.archivo(11, .regular))
                            .foregroundStyle(SQColor.labelSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }

                    filterSection("Calques", icon: "square.3.layers.3d") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                            ForEach(layerOptions, id: \.0.rawValue) { kind, label, icon in
                                filterChip(
                                    title: label, icon: icon,
                                    active: layers.contains(kind),
                                    disabled: kind == .coverage && operatorName.uppercased() == "ALL"
                                ) {
                                    toggleLayer(kind)
                                }
                            }
                        }
                        if operatorName.uppercased() == "ALL", layerOptions.contains(where: { $0.0 == .coverage }) {
                            Text("Choisis un opérateur pour afficher la couverture.")
                                .font(SQFont.archivo(11, .regular))
                                .foregroundStyle(SQColor.labelSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 2)
                        }
                        if communityLayerAvailable && (layers.contains(.communitySite) || selectedEntry?.isCommunityOnly == true) {
                            Toggle(isOn: $includeObserved) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Cellules observées")
                                            .font(SQFont.archivo(14, .semibold))
                                            .foregroundStyle(SQColor.label)
                                        Text("Affiche aussi les cellules captées, en plus des sites probables consolidés")
                                            .font(SQFont.archivo(11, .regular))
                                            .foregroundStyle(SQColor.labelSecondary)
                                    }
                                } icon: {
                                    Image(systemName: "dot.radiowaves.up.forward")
                                        .foregroundStyle(SQColor.brandPink)
                                }
                            }
                            .tint(SQColor.brandRed)
                            .padding(.top, 4)
                        }
                    }

                    // Sous-filtre de la couche Prévisionnels : n'apparaît que
                    // lorsqu'elle est active (données ANFR FR/DROM).
                    if layers.contains(.planned), ["FR", "DROM"].contains(catalogMarket.uppercased()) {
                        filterSection("Statut prévisionnel", icon: "calendar.badge.clock") {
                            LazyVGrid(columns: filterColumns, spacing: 8) {
                                ForEach(PlannedActivationStatus.allCases, id: \.self) { status in
                                    plannedStatusChip(status)
                                }
                            }
                            Text("Masque ou affiche les antennes prévues selon leur avancement ANFR.")
                                .font(SQFont.archivo(11, .regular))
                                .foregroundStyle(SQColor.labelSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 2)
                        }
                    }

                    // Section « Opérateur » retirée : source unique = la pilule opérateur
                    // bas-gauche de la carte (toujours visible, pastille couleur + libellé
                    // + accès rapide au menu). Évite le doublon feuille ⇄ canevas. Le
                    // binding `operatorName` reste lu par le gating Couverture des Calques.

                    filterSection("Technologies", icon: "cellularbars") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                            filterChip(title: "Toutes", icon: "sparkles", active: technologies.isEmpty) {
                                technologies.removeAll()
                            }
                            ForEach(MapFilterCatalog.technologies(forMarket: catalogMarket), id: \.value) { tech in
                                filterChip(title: tech.label, icon: "cellularbars", active: technologies.contains(tech.value)) {
                                    toggleTechnology(tech.value)
                                }
                            }
                        }
                    }

                    // « Partage » (mutualisation d'antennes) : présent uniquement
                    // pour les marchés qui l'exposent (FR/DROM). Masqué ailleurs.
                    let sharingOptions = MapFilterCatalog.sharing(forMarket: catalogMarket)
                    if !sharingOptions.isEmpty {
                        filterSection("Partage", icon: "point.3.connected.trianglepath.dotted") {
                            LazyVGrid(columns: filterColumns, spacing: 8) {
                                ForEach(sharingOptions, id: \.value) { opt in
                                    filterChip(title: opt.label, icon: opt.icon, active: sharing.contains(opt.value)) {
                                        toggleSharing(opt.value)
                                    }
                                }
                            }
                        }
                    }

                    // « Bandes » : catalogue spécifique au pays (repli européen
                    // pour les marchés sans définition dédiée).
                    filterSection("Bandes", icon: "waveform.path.ecg") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                            ForEach(MapFilterCatalog.bands(forMarket: catalogMarket), id: \.band) { opt in
                                filterChip(title: opt.label, icon: "dot.radiowaves.left.and.right", active: bands.contains(opt.band)) {
                                    toggleBand(opt.band)
                                }
                            }
                        }
                        // Le mode de croisement ne veut rien dire sans bande cochée :
                        // l'afficher tout le temps ferait réfléchir à un réglage sans
                        // effet. Il apparaît quand il commence à compter.
                        if !bands.isEmpty {
                            Picker("Croisement des bandes", selection: $bandMatch) {
                                ForEach(BandMatchMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.top, SQSpace.sm)
                            Text(bandMatch.explanation)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Rendu des azimuts : réglage d'affichage pur, sans rechargement.
                    // Les lobes montrent l'ouverture du faisceau, les traits la seule
                    // direction — l'un ou l'autre selon qu'on est en ville ou non.
                    filterSection("Azimuts", icon: "safari") {
                        LazyVGrid(columns: filterColumns, spacing: 8) {
                            ForEach(AzimuthStyle.allCases, id: \.self) { style in
                                filterChip(title: style.label, icon: style.icon, active: azimuthStyle == style) {
                                    azimuthStyle = style
                                }
                            }
                        }
                    }

                    filterSection("Période", icon: "calendar") {
                        periodPicker("Speedtests", selection: $speedtestDays)
                        periodPicker("Couverture", selection: $coverageDays)
                    }
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Calques & filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Réinitialiser") {
                        // Réinitialiser vers le marché/opérateur AUTO-détectés (SIM/GPS/
                        // locale), pas vers un FR + SFR codés en dur qui vidaient la carte
                        // pour un utilisateur belge/suisse (INT-04).
                        market = MapMarketStore.initialMarketCode()
                        operatorName = MapMarketStore.initialOperatorKey()
                        technologies.removeAll()
                        bands.removeAll()
                        bandMatch = .any
                        azimuthStyle = .lobes
                        sharing.removeAll()
                        speedtestDays = 0
                        coverageDays = 0
                        layers = MapFilterStore.defaultFilters
                        includeObserved = true
                        plannedStatuses = Set(PlannedActivationStatus.allCases)
                    }
                    .font(SQFont.archivo(15, .semibold))
                    .tint(SQColor.brandRed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { dismiss() }
                        .font(SQFont.archivo(15, .bold))
                        .tint(SQColor.brandRed)
                }
            }
            // Le réalignement de l'opérateur sur le nouveau marché est géré
            // par la vue parente (alignWithMarket), pas par la feuille.
        }
    }

    var filterColumns: [GridItem] {
        [GridItem(.flexible(), spacing: SQSpace.sm), GridItem(.flexible(), spacing: SQSpace.sm)]
    }

    func filterSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label(title, systemImage: icon)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    /// Chip de filtre « Crème » : capsule Figtree SemiBold — actif = brique
    /// pleine texte crème ; inactif = tuile `SurfaceMuted` texte encre. Sans bordure.
    func filterChip(title: String, icon: String, active: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: SQSpace.sm - 1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(LocalizedStringKey(title))
                    .font(SQFont.body(12.5, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, SQSpace.sm)
            .background(active ? SQColor.brandRed : SQColor.surfaceMuted, in: Capsule(style: .continuous))
            .foregroundStyle(active ? SQColor.onAccent : SQColor.label)
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(disabled)
        .sqAnimation(SQMotion.fast, value: active)
    }

    /// Chip d'un statut prévisionnel : reprend la couleur du marqueur carte
    /// (actif vert / upgrade ambre / déclaré bleu / prévu ardoise). Sélectionné =
    /// capsule pleine ; sinon capsule teintée douce de cette couleur → lien
    /// visuel direct avec les pastilles de la carte, sans bordure.
    func plannedStatusChip(_ status: PlannedActivationStatus) -> some View {
        let color = MapExplorerView.plannedStatusColor(status)
        let active = plannedStatuses.contains(status)
        return Button {
            Haptics.light()
            togglePlannedStatus(status)
        } label: {
            HStack(spacing: SQSpace.sm - 1) {
                Image(systemName: MapExplorerView.plannedStatusGlyph(status))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(MapExplorerView.plannedStatusLabel(status))
                    .font(SQFont.body(12.5, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, SQSpace.sm)
            .background(active ? color : color.opacity(0.13), in: Capsule(style: .continuous))
            .foregroundStyle(active ? Color.white : color)
        }
        .buttonStyle(SQPressButtonStyle())
        .sqAnimation(SQMotion.fast, value: active)
    }

    func togglePlannedStatus(_ status: PlannedActivationStatus) {
        if plannedStatuses.contains(status) {
            plannedStatuses.remove(status)
        } else {
            plannedStatuses.insert(status)
        }
    }

    /// Le marché `entry` est-il celui actuellement sélectionné dans la feuille ?
    func isCurrentMarket(_ entry: MarketRegistryEntry) -> Bool {
        let m = market.uppercased()
        return entry.code.uppercased() == m || entry.marketCode.uppercased() == m
    }

    func marketMenuTitle(_ entry: MarketRegistryEntry) -> String {
        "\(flagEmoji(entry.countryCode)) \(entry.label)"
    }

    /// Drapeau emoji depuis un code pays ISO 2 lettres ("fr" → 🇫🇷). Repli 🌐.
    func flagEmoji(_ countryCode: String) -> String {
        let code = countryCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 2 else { return "🌐" }
        var result = ""
        for v in code.unicodeScalars {
            guard v.value >= 65, v.value <= 90, let s = UnicodeScalar(127397 + v.value) else { return "🌐" }
            result.unicodeScalars.append(s)
        }
        return result
    }

    func periodPicker(_ title: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(LocalizedStringKey(title))
                .font(SQFont.body(12.5, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
            Picker(title, selection: selection) {
                Text("Tout").tag(0)
                Text("7 j").tag(7)
                Text("30 j").tag(30)
                Text("90 j").tag(90)
            }
            .pickerStyle(.segmented)
        }
    }

    func toggleLayer(_ kind: MapDisplayItem.Kind) {
        if layers.contains(kind) {
            layers.remove(kind)
        } else {
            layers.insert(kind)
        }
    }

    func toggleTechnology(_ tech: String) {
        if technologies.contains(tech) {
            technologies.remove(tech)
        } else {
            technologies.insert(tech)
        }
    }

    func toggleBand(_ band: Int) {
        if bands.contains(band) {
            bands.remove(band)
        } else {
            bands.insert(band)
        }
    }

    func toggleSharing(_ value: String) {
        if sharing.contains(value) {
            sharing.remove(value)
        } else {
            sharing.insert(value)
        }
    }

    func operatorLabel(_ value: String) -> String {
        if let entry = selectedEntry?.operatorEntry(forKey: value) {
            return entry.label
        }
        return value.uppercased() == "ALL" ? "Tous les opérateurs" : value
    }
}
