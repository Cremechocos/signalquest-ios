import SwiftUI
import MapKit

// MARK: - ViewModel

@MainActor
final class ANFRSiteDetailViewModel: ObservableObject {
    @Published var history: ANFRSiteHistory?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service: ANFRServicing
    init(service: ANFRServicing) { self.service = service }

    func load(supId: String) async {
        #if DEBUG
        if AppEnvironment.usesDemoData {
            history = ANFRDemoData.siteHistory
            return
        }
        #endif
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            history = try await service.siteHistory(supId: supId)
        } catch {
            // Fiche refermée pendant le chargement : pas un échec à afficher.
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }
}

// MARK: - Sheet

struct ANFRSiteDetailSheet: View {
    let site: ANFRMapSite
    /// Date du relevé affiché sur la carte : repère, dans l'historique, la ligne
    /// que l'utilisateur regarde.
    let snapshotDate: String?
    /// Opérateurs dont les azimuts ont changé sur ce support au relevé affiché.
    let reorientations: [ANFRReorientation]
    /// Faux quand le support n'a que des réorientations : aucun changement à lister.
    let showsChanges: Bool
    @StateObject private var model: ANFRSiteDetailViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Fiche principale du même support (photos, mesures, avis), ouverte par « Fiche du site ».
    @State private var showsMainSite = false
    @State private var appeared = false
    @State private var copiedCoordinates = false
    /// Texte du site à envoyer dans une conversation (P2-47) ; non nil = sélecteur ouvert.
    @State private var siteShareDraft: SiteShareDraft?

    init(site: ANFRMapSite, service: ANFRServicing, snapshotDate: String? = nil,
         reorientations: [ANFRReorientation] = [], showsChanges: Bool = true) {
        self.site = site
        self.snapshotDate = snapshotDate
        self.reorientations = reorientations
        self.showsChanges = showsChanges
        _model = StateObject(wrappedValue: ANFRSiteDetailViewModel(service: service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    header
                    actionsRow
                    if !reorientations.isEmpty { reorientationCard }
                    if showsChanges {
                        if let summary = site.summary {
                            summaryCard(summary)
                        } else {
                            currentAntennasCard
                            if !site.sectorsByOperator.isEmpty { sectorsCard }
                        }
                    }
                    timelineSection
                }
                .padding(SQSpace.lg)
                .padding(.bottom, SQSpace.huge)
            }
            .signalQuestBackground()
            // L'en-tête porte le nom et la croix : pas de barre de navigation en double.
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundCompat(SQColor.bg)
        .presentationBackgroundInteractionCompat()
        // Le texte arrive prérempli dans la conversation choisie, qui s'ouvre : la fiche se ferme.
        .siteSharePicker($siteShareDraft) { dismiss() }
        // Le numéro de support ANFR est l'identifiant du site sur la carte principale.
        .sheet(isPresented: $showsMainSite) {
            AntennaDetailSheet(
                site: mainSite,
                market: "FR",
                operatorName: site.operators.count == 1 ? site.operators[0].rawValue.uppercased() : "ALL",
                service: services.antennas
            )
            .presentationDetents([.medium, .large])
            .presentationBackgroundCompat(SQColor.bg)
        }
        .task { await model.load(supId: site.supId) }
        .onAppear {
            withAnimation(reduceMotion ? nil : SQMotion.standard.delay(0.05)) { appeared = true }
        }
    }

    // MARK: Header

    private var title: String {
        site.city.isEmpty ? String(localized: "Support \(site.supId)") : ANFRText.city(site.city)
    }

    /// « Support 3170269 · SFR · 4G » : l'identifiant et ce qui est déclaré, en une ligne.
    private var subtitle: String {
        var parts = [String(localized: "Support \(site.supId)")]
        parts += site.operators.map(\.label)
        if let gen = site.highestGeneration { parts.append(gen.label) }
        return parts.joined(separator: " · ")
    }

    /// Le support vu par la carte principale : son numéro, sa position et ses opérateurs.
    private var mainSite: AntennaSite {
        AntennaSite(
            id: site.supId, siteId: site.supId,
            latitude: site.latitude, longitude: site.longitude,
            operators: site.operators.map { $0.rawValue.uppercased() },
            technologies: [], bands: [], azimuths: [],
            sharingType: nil, crozonLeader: nil,
            address: site.antennas.lazy.compactMap(\.address).first.map(ANFRText.city),
            height: nil, owner: nil
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.sm) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(title)
                    .font(SQType.title)
                    .sqHeader()
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: subtitle)
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                HStack(spacing: SQSpace.xs2) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SQColor.brandRed)
                        .accessibilityHidden(true)
                    Text(Self.coordinateText(site))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Latitude \(Self.decimal(site.latitude)), longitude \(Self.decimal(site.longitude))"))
            }
            Spacer(minLength: 0)
            ANFRSheetCloseButton { dismiss() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private var actionsRow: some View {
        ANFRRoundActionRow {
            Button {
                Haptics.light()
                let item = MKMapItem(placemark: MKPlacemark(coordinate: site.coordinate))
                item.name = title
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            } label: {
                ANFRRoundActionLabel(title: "Itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond.fill", prominent: true)
            }
            .buttonStyle(SQPressButtonStyle())

            // Un suivi vise un opérateur : sur un support partagé, il se choisit dans la fiche du site.
            if site.operators.count == 1 {
                FavoriteAntennaButton(
                    favorites: services.favoriteAntennas,
                    siteId: site.supId,
                    market: "FR",
                    operatorName: site.operators[0].rawValue.uppercased(),
                    operatorLabel: site.operators[0].label,
                    name: title,
                    address: site.antennas.lazy.compactMap(\.address).first.map(ANFRText.city),
                    latitude: site.latitude,
                    longitude: site.longitude,
                    roundStyle: true
                )
            }

            Button {
                Haptics.light()
                showsMainSite = true
            } label: {
                ANFRRoundActionLabel(title: "Fiche du site", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint("Photos, mesures et avis de ce support")
            .accessibilityIdentifier("anfr.detail.mainSite")

            // Partager, envoyer dans une conversation, copier et Cartoradio : un seul bouton, un menu.
            Menu {
                // Même texte que « Envoyer dans une conversation » : le format commun au web, à iOS et à Android.
                ShareLink(item: Self.conversationShareText(for: site, baseURL: AppConfig.current.appBaseURL)) {
                    Label("Partager…", systemImage: "square.and.arrow.up")
                }
                Button {
                    Haptics.selection()
                    siteShareDraft = SiteShareDraft(text: Self.conversationShareText(for: site, baseURL: AppConfig.current.appBaseURL))
                } label: {
                    Label("Envoyer dans une conversation", systemImage: "paperplane")
                }
                .accessibilityIdentifier("anfr.detail.sendToConversation")
                Button {
                    Haptics.light()
                    UIPasteboard.general.string = Self.posixCoordinates(site)
                    copiedCoordinates = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copiedCoordinates = false
                    }
                } label: {
                    Label("Copier les coordonnées", systemImage: "doc.on.doc")
                }
                if let url = Self.cartoradioURL(site) {
                    Link(destination: url) {
                        Label("Ouvrir dans Cartoradio", systemImage: "arrow.up.right.square")
                    }
                }
            } label: {
                ANFRRoundActionLabel(title: copiedCoordinates ? "Coordonnées copiées" : "Partager",
                                     systemImage: copiedCoordinates ? "checkmark" : "square.and.arrow.up")
            }
            .accessibilityIdentifier("anfr.detail.share")
        }
    }

    // MARK: Current antennas

    private var currentAntennasCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionTitle("Changements de ce relevé", systemImage: "antenna.radiowaves.left.and.right")
            // Le relevé ne liste que ce qui a changé : ce n'est pas le parc du pylône.
            Text("Seules les antennes modifiées pendant la période sont listées, pas toutes celles du support.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(site.antennas) { antenna in
                HStack(alignment: .top, spacing: SQSpace.md) {
                    modTypeBadge(antenna.modType, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        ANFRFlowLayout(spacing: SQSpace.xs2) {
                            Text(antenna.system.isEmpty
                                 ? (antenna.operator?.label ?? String(localized: "Antenne"))
                                 : ANFRText.technology(system: antenna.system, generation: antenna.generationRaw))
                                .font(SQType.callout(.semibold))
                                .foregroundStyle(SQColor.label)
                            if antenna.catchUp { catchUpTag }
                            // L'opérateur n'est dit que sur un support partagé.
                            if site.operators.count > 1, let op = antenna.operator {
                                SQEditorialTag(text: op.label, color: op.color)
                            }
                        }
                        Text(antenna.modType.label)
                            .font(SQType.micro)
                            .foregroundStyle(antenna.modType == .deleted ? SQColor.dangerInk : SQColor.label)
                        // Statuts ANFR connus traduits ; toute autre valeur reste affichée telle quelle.
                        Text(LocalizedStringKey(antenna.statut))
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                        if antenna.modType != .deleted, let date = ANFRText.date(antenna.changeDate) {
                            Text("Mise en service le \(date)")
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        if !antenna.azimuths.isEmpty {
                            Text("Azimuts : \(ANFRAzimuth.list(antenna.azimuths))")
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.labelSecondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
                // Une seule phrase par antenne pour VoiceOver, pas cinq éléments épars.
                .accessibilityElement(children: .combine)
                .padding(.vertical, SQSpace.sm)
                .padding(.horizontal, SQSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
            if site.antennas.isEmpty {
                Text("Aucune antenne modifiée dans ce relevé.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    // MARK: Relevé léger

    /// Relevé léger ou comparaison : les compteurs du support, le détail par antenne
    /// étant dans l'historique.
    private func summaryCard(_ summary: ANFRSiteChangeSummary) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionTitle(summary.lastChangeDate == nil ? "Changements de ce relevé" : "Changements sur la période",
                         systemImage: "antenna.radiowaves.left.and.right")
            Group {
                if let last = summary.lastChangeDate.flatMap({ ANFRText.date($0) }) {
                    Text("Bilan net de la comparaison, dernier changement au relevé du \(last). Le détail par antenne est dans l’historique.")
                } else {
                    Text("Ce relevé ne liste pas les antennes. Le détail par antenne est dans l’historique.")
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if !summary.operators.isEmpty || summary.hasOtherOperator {
                ANFRFlowLayout(spacing: SQSpace.xs2) {
                    ForEach(summary.operators) { op in
                        SQEditorialTag(text: op.label, color: op.color)
                    }
                    if summary.hasOtherOperator {
                        SQEditorialTag(text: String(localized: "Autre opérateur"), color: SQColor.labelSecondary)
                    }
                }
            }
            ForEach(summary.presentTypes) { type in
                HStack(spacing: SQSpace.sm) {
                    modTypeBadge(type)
                    Text(type.label)
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.label)
                    Spacer()
                    Text("\(summary.count(for: type)) antennes")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .padding(.vertical, SQSpace.sm)
                .padding(.horizontal, SQSpace.md)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
            if summary.catchUp > 0 {
                HStack(spacing: SQSpace.sm) {
                    catchUpTag
                    Text("Dont \(summary.catchUp) en rattrapage")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    // MARK: Secteurs

    /// Orientation des antennes de ce relevé, un éventail par opérateur.
    private var sectorsCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionTitle("Orientation des secteurs", systemImage: "safari")
            Text("Azimuts déclarés à l’ANFR pour les antennes de ce relevé ; 0° indique le nord.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ANFRFlowLayout(spacing: SQSpace.md) {
                ForEach(site.sectorsByOperator) { entry in
                    VStack(spacing: SQSpace.xs) {
                        AzimuthFanView(azimuths: entry.azimuths.map(Double.init), color: entry.operator.color)
                            .frame(width: site.sectorsByOperator.count == 1 ? 200 : 150,
                                   height: site.sectorsByOperator.count == 1 ? 200 : 150)
                            .accessibilityHidden(true)
                        Text(entry.operator.label)
                            .font(SQType.caption(.semibold))
                            .foregroundStyle(SQColor.label)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(entry.operator.label), azimuts \(ANFRAzimuth.list(entry.azimuths))"))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
    }

    // MARK: Réorientation

    /// Avant et après, par opérateur : les azimuts ne sont pas appariés secteur à
    /// secteur, on montre donc les deux éventails côte à côte.
    private var reorientationCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionTitle("Réorientation", systemImage: ANFRMapLayer.reorientationGlyph)
            Text("Les azimuts de ces antennes ont changé depuis le relevé précédent.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(orderedReorientations) { item in
                reorientationRow(item)
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
    }

    /// Dans l'ordre des opérateurs de la carte ; un opérateur non suivi passe en dernier.
    private var orderedReorientations: [ANFRReorientation] {
        let rank = { (item: ANFRReorientation) in item.operator.flatMap { ANFROperator.allCases.firstIndex(of: $0) } ?? Int.max }
        return reorientations.sorted { rank($0) < rank($1) }
    }

    private func reorientationRow(_ item: ANFRReorientation) -> some View {
        let tint = item.operator?.color ?? SQColor.labelSecondary
        let name = item.operator?.label ?? ANFRText.city(item.operatorRaw)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                SQEditorialTag(text: name, color: tint)
                if !item.systems.isEmpty {
                    Text(item.systems.joined(separator: ", "))
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: SQSpace.sm) {
                reorientationFan(title: "Avant", azimuths: item.before, color: SQColor.labelTertiary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .padding(.top, 60)
                    .accessibilityHidden(true)
                reorientationFan(title: "Après", azimuths: item.after, color: tint)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(SQSpace.md)
        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(name) : avant \(Self.spokenAzimuths(item.before)), après \(Self.spokenAzimuths(item.after))"))
    }

    private func reorientationFan(title: LocalizedStringKey, azimuths: [Int], color: Color) -> some View {
        VStack(spacing: SQSpace.xs) {
            Text(title)
                .font(SQType.caption(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
            // Plus large que haut : les étiquettes d'angle débordent du cercle sur les côtés.
            AzimuthFanView(azimuths: azimuths.map(Double.init), color: color)
                .frame(width: 136, height: 116)
                .accessibilityHidden(true)
            Text(azimuths.isEmpty ? String(localized: "Aucun azimut") : ANFRAzimuth.list(azimuths))
                .font(SQType.micro)
                .foregroundStyle(SQColor.label)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private static func spokenAzimuths(_ azimuths: [Int]) -> String {
        azimuths.isEmpty ? String(localized: "aucun azimut") : ANFRAzimuth.list(azimuths)
    }

    // MARK: Timeline

    @ViewBuilder
    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            sectionTitle("Historique des modifications", systemImage: "clock.arrow.circlepath")

            if model.isLoading {
                HStack(spacing: SQSpace.sm) {
                    SQSpinner().tint(SQColor.brandRed)
                    Text("Chargement de l’historique…")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SQSpace.md)
            } else if let history = model.history, !history.entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                        ANFRTimelineRow(
                            entry: entry,
                            isFirst: index == 0,
                            isLast: index == history.entries.count - 1,
                            isShownOnMap: entry.archiveDate == snapshotDate
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(
                            reduceMotion ? nil : SQMotion.standard.delay(Double(index) * 0.05),
                            value: appeared
                        )
                    }
                }
            } else if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                    Button {
                        Haptics.light()
                        Task { await model.load(supId: site.supId) }
                    } label: {
                        Text("Réessayer")
                            .font(SQType.button)
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("anfr.site.retry")
                }
            } else {
                Text("Aucune modification archivée pour ce support.")
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .sqCardBackground()
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        HStack(spacing: SQSpace.sm) {
            SQIconPastille(systemImage: systemImage, size: 32, font: .system(size: 13, weight: .semibold))
            Text(LocalizedStringKey(title))
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .sqHeader()
        }
    }

    /// Un rattrapage est une antenne déclarée tard : sa mise en service date de plus de 30 jours.
    private var catchUpTag: some View {
        Text("Rattrapage")
            .font(SQType.micro)
            .foregroundStyle(SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.sm)
            .padding(.vertical, 2)
            .background(SQColor.chip, in: Capsule(style: .continuous))
    }

    // Formats : l'écran suit la langue, la copie et les liens restent universels (point décimal).
    static func decimal(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(5)))
    }

    static func coordinateText(_ site: ANFRMapSite) -> String {
        "\(decimal(site.latitude)) · \(decimal(site.longitude))"
    }

    private static func posix(_ value: Double) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func posixCoordinates(_ site: ANFRMapSite) -> String {
        "\(posix(site.latitude)), \(posix(site.longitude))"
    }

    static func cartoradioURL(_ site: ANFRMapSite) -> URL? {
        URL(string: "https://cartoradio.fr/index.html#/cartographie/lonlat/\(posix(site.longitude))/\(posix(site.latitude))")
    }

    /// Le support tel qu'on l'écrit dans une conversation (P2-47, format commun au web, à iOS
    /// et à Android) : support, position, adresse et opérateurs du relevé. En-tête « Antenne
    /// <opérateur> » pour un seul opérateur, « Antenne » sinon. Le relevé ne liste que les
    /// antennes modifiées : ni technologies ni identifiants radio ne sont écrits.
    nonisolated static func conversationShareText(for site: ANFRMapSite, baseURL: URL) -> String {
        let names = site.operators.compactMap { SiteShareCard.metropolitanOperatorName(forKey: $0.rawValue) }
        // Adresse ANFR (capitales, sans accents) remise en casse, puis la commune.
        let street = site.antennas.lazy.compactMap(\.address).first.map(ANFRText.city)
        let city = site.city.isEmpty ? nil : ANFRText.city(site.city)
        let address = [street, city.flatMap { name in
            street?.localizedCaseInsensitiveContains(name) == true ? nil : name
        }].compactMap { $0 }.joined(separator: ", ")
        let card = SiteShareCard(
            operatorName: names.isEmpty ? nil : names.joined(separator: ", "),
            supportId: site.supId.isEmpty ? nil : site.supId,
            market: "FR",
            address: address.isEmpty ? nil : address,
            coordinate: SiteShareCoordinate(latitude: site.latitude, longitude: site.longitude)
        )
        return card.shareText(baseURL: baseURL)
    }

    private func modTypeBadge(_ type: ANFRModType, size: CGFloat = 18) -> some View {
        Image(systemName: type.glyph)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(SQColor.onAccent)
            .frame(width: size, height: size)
            .background(type.color, in: Circle())
            // Seul porteur du type de modification dans la ligne : VoiceOver lisait le nom du symbole.
            .accessibilityLabel(type.label)
    }
}

// MARK: - Timeline row

private struct ANFRTimelineRow: View {
    let entry: ANFRSiteHistoryEntry
    let isFirst: Bool
    let isLast: Bool
    /// Cette ligne est le relevé que la carte affiche.
    let isShownOnMap: Bool

    private var dominantModType: ANFRModType {
        entry.modTypeEnums.max { $0.priority < $1.priority } ?? .added
    }

    var body: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            // Rail + nœud
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : SQColor.separator)
                    .frame(width: 2, height: 10)
                Circle()
                    .fill(dominantModType.color)
                    .frame(width: 14, height: 14)
                    .overlay { Circle().stroke(SQColor.surface, lineWidth: 2) }
                Rectangle()
                    .fill(isLast ? Color.clear : SQColor.separator)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 14)

            // Contenu daté
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                HStack(spacing: SQSpace.sm) {
                    Text(prettyDate(entry.archiveDate))
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                    if entry.isCurrentSnapshot {
                        Text("Actuel")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.accentInk)
                            .padding(.horizontal, SQSpace.sm)
                            .padding(.vertical, 2)
                            .background(SQColor.accentSoft, in: Capsule(style: .continuous))
                    }
                    if isShownOnMap {
                        Text("Sur la carte")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.accentInk)
                            .padding(.horizontal, SQSpace.sm)
                            .padding(.vertical, 2)
                            .background(SQColor.accentSoft, in: Capsule(style: .continuous))
                    }
                    Spacer()
                }
                ForEach(entry.changes) { change in
                    HStack(spacing: SQSpace.sm) {
                        Image(systemName: change.modType.glyph)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SQColor.onAccent)
                            .frame(width: 18, height: 18)
                            .background(change.modType.color, in: Circle())
                            .accessibilityHidden(true) // le libellé du type est lu juste à côté
                        VStack(alignment: .leading, spacing: 1) {
                            Text(changeText(change))
                                .font(SQType.subhead(.semibold))
                                .foregroundStyle(SQColor.label)
                                .lineLimit(2)
                            Text(change.modType.label)
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.labelSecondary)
                            if let note = effectiveNote(change) {
                                Text(note)
                                    .font(SQType.micro)
                                    .foregroundStyle(SQColor.labelSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        if let gen = change.generationEnum {
                            Text(gen.label)
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.bottom, SQSpace.lg)
        }
    }

    private func changeText(_ change: ANFRSiteHistoryChange) -> String {
        let op = change.operator?.label ?? change.operatorRaw.capitalized
        let technology = ANFRText.technology(system: change.technology, generation: change.generation)
        return technology.isEmpty ? op : "\(op) · \(technology)"
    }

    /// La date réelle du changement quand elle diffère de celle du relevé : un
    /// rattrapage a été publié cette semaine-là mais mis en service bien avant.
    private func effectiveNote(_ change: ANFRSiteHistoryChange) -> String? {
        guard change.modType != .deleted,
              let effective = change.effectiveDate, effective.prefix(10) != entry.archiveDate.prefix(10),
              let date = ANFRText.date(effective) else { return nil }
        return change.catchUp
            ? String(localized: "Rattrapage · mis en service le \(date)")
            : String(localized: "Mise en service le \(date)")
    }

    private func prettyDate(_ raw: String) -> String {
        ANFRText.date(raw) ?? raw
    }
}

extension View {
    /// Garde la carte utilisable derrière la fiche à hauteur moyenne (iOS 16.4+) : on
    /// peut déplacer la carte et toucher un autre repère sans la refermer.
    @ViewBuilder
    func presentationBackgroundInteractionCompat() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackgroundInteraction(.enabled(upThrough: .medium))
        } else {
            self
        }
    }
}

// MARK: - Composants des fiches

/// Croix ronde des fiches de la carte des évolutions.
struct ANFRSheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(width: 32, height: 32)
                .background(SQColor.surfaceMuted, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Fermer")
        .accessibilityIdentifier("anfr.detail.close")
    }
}

/// Rangée de boutons ronds à parts égales ; en grandes tailles de texte, une liste.
struct ANFRRoundActionRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SQSpace.sm) { content }
                .environment(\.anfrRoundActionCompact, true)
        } else {
            HStack(alignment: .top, spacing: SQSpace.sm) { content }
                .frame(maxWidth: .infinity)
        }
    }
}

private struct ANFRRoundActionCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var anfrRoundActionCompact: Bool {
        get { self[ANFRRoundActionCompactKey.self] }
        set { self[ANFRRoundActionCompactKey.self] = newValue }
    }
}

/// Un rond teinté et son libellé dessous ; `prominent` pour l'action principale.
struct ANFRRoundActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var prominent = false
    @Environment(\.anfrRoundActionCompact) private var compact

    var body: some View {
        let icon = Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(prominent ? SQColor.onAccent : SQColor.accentInk)
            .frame(width: 52, height: 52)
            .background(prominent ? SQColor.brandRed : SQColor.accentSoft, in: Circle())
        if compact {
            HStack(spacing: SQSpace.md) {
                icon
                Text(title)
                    .font(SQType.body(.semibold))
                    .foregroundStyle(SQColor.label)
            }
            .contentShape(Rectangle())
        } else {
            VStack(spacing: SQSpace.xs + 2) {
                icon
                Text(title)
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }
}
