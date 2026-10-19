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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .navigationTitle("Support \(site.supId)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .font(SQType.button)
                        .foregroundStyle(SQColor.accentInk)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundCompat(SQColor.bg)
        .presentationBackgroundInteractionCompat()
        // Le texte arrive prérempli dans la conversation choisie, qui s'ouvre : la fiche se ferme.
        .siteSharePicker($siteShareDraft) { dismiss() }
        .task { await model.load(supId: site.supId) }
        .onAppear {
            withAnimation(reduceMotion ? nil : SQMotion.standard.delay(0.05)) { appeared = true }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(site.city.isEmpty ? String(localized: "Support \(site.supId)") : ANFRText.city(site.city))
                .font(SQType.title)
                .sqHeader()
                .foregroundStyle(SQColor.label)
            Text("Site ANFR")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            HStack(spacing: SQSpace.xs2) {
                Image(systemName: "mappin.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Text(Self.coordinateText(site))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Latitude \(Self.decimal(site.latitude)), longitude \(Self.decimal(site.longitude))"))
            // Pastilles opérateurs + générations présents.
            HStack(spacing: SQSpace.xs2) {
                ForEach(site.operators) { op in
                    SQEditorialTag(text: op.label, color: op.color)
                }
                if let gen = site.highestGeneration {
                    SQEditorialTag(text: gen.label, color: gen.color)
                }
            }
            .padding(.top, SQSpace.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private var actionsRow: some View {
        ANFRFlowLayout(spacing: SQSpace.sm) {
            Button {
                Haptics.light()
                let item = MKMapItem(placemark: MKPlacemark(coordinate: site.coordinate))
                item.name = site.city.isEmpty ? String(localized: "Support \(site.supId)") : ANFRText.city(site.city)
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            } label: {
                actionLabel("Itinéraire", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
            .buttonStyle(.plain)

            if let url = Self.cartoradioURL(site) {
                Link(destination: url) {
                    actionLabel("Cartoradio", systemImage: "arrow.up.right.square")
                }
            }

            Button {
                Haptics.light()
                UIPasteboard.general.string = Self.posixCoordinates(site)
                copiedCoordinates = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copiedCoordinates = false
                }
            } label: {
                actionLabel(copiedCoordinates ? "Coordonnées copiées" : "Copier les coordonnées",
                            systemImage: copiedCoordinates ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)

            // Même texte que « Envoyer dans une conversation » : le format commun au web, à iOS et à Android.
            ShareLink(item: Self.conversationShareText(for: site, baseURL: AppConfig.current.appBaseURL)) {
                actionLabel("Partager", systemImage: "square.and.arrow.up")
            }

            Button {
                Haptics.selection()
                siteShareDraft = SiteShareDraft(text: Self.conversationShareText(for: site, baseURL: AppConfig.current.appBaseURL))
            } label: {
                actionLabel("Envoyer dans une conversation", systemImage: "paperplane")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("anfr.detail.sendToConversation")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.accentInk)
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 44)
            .background(SQColor.accentSoft, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
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
                HStack(spacing: SQSpace.sm) {
                    Circle()
                        .fill((antenna.operator?.color) ?? SQColor.labelSecondary)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        ANFRFlowLayout(spacing: SQSpace.xs2) {
                            Text(antenna.system.isEmpty
                                 ? (antenna.operator?.label ?? String(localized: "Antenne"))
                                 : ANFRText.technology(system: antenna.system, generation: antenna.generationRaw))
                                .font(SQType.callout(.semibold))
                                .foregroundStyle(SQColor.label)
                            if antenna.catchUp { catchUpTag }
                        }
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
                    Spacer()
                    if let gen = antenna.generationEnum {
                        SQEditorialTag(text: gen.label, color: gen.color)
                    }
                    modTypeBadge(antenna.modType)
                }
                // Une seule phrase par antenne pour VoiceOver, pas cinq éléments épars.
                .accessibilityElement(children: .combine)
                .padding(.vertical, SQSpace.sm)
                .padding(.horizontal, SQSpace.md)
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
                            .frame(width: 150, height: 150)
                            .accessibilityHidden(true)
                        Text(entry.operator.label)
                            .font(SQType.caption(.semibold))
                            .foregroundStyle(SQColor.label)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(entry.operator.label), azimuts \(ANFRAzimuth.list(entry.azimuths))"))
                }
            }
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

    private func modTypeBadge(_ type: ANFRModType) -> some View {
        Image(systemName: type.glyph)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SQColor.onAccent)
            .frame(width: 18, height: 18)
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

private extension View {
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
