import SwiftUI
import PhotosUI
import UIKit
import MapKit
import CoreLocation

@MainActor
final class AntennaDetailViewModel: ObservableObject {
    @Published var details: AntennaDetails?
    @Published var error: String?
    @Published var isUploadingPhoto = false
    @Published var photoUploadMessage: String?

    private let service: AntennasServicing
    init(service: AntennasServicing) { self.service = service }

    func load(id: String, market: String, operatorName: String, anfrCode: String?) async {
        do {
            details = try await service.details(id: id, market: market, operatorName: operatorName, anfrCode: anfrCode)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Envoie une photo sur le site via `PhotoService`, puis recharge la fiche
    /// (la photo peut être en attente de modération côté serveur).
    func uploadPhoto(
        item: PhotosPickerItem,
        photos: PhotoServicing,
        siteId: String,
        anfrCode: String?,
        operatorName: String,
        market: String
    ) async {
        isUploadingPhoto = true
        photoUploadMessage = nil
        defer { isUploadingPhoto = false }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self) else {
                photoUploadMessage = "Image illisible."
                return
            }
            // Extraction EXIF + recompression hors du main thread (UI non gelée).
            guard let prepared = await Task.detached(priority: .userInitiated, operation: {
                PhotoUploadPreparation.prepare(from: raw)
            }).value else {
                photoUploadMessage = "Image illisible."
                return
            }
            _ = try await photos.uploadPhoto(
                data: prepared.jpeg,
                siteId: siteId,
                description: nil,
                anfrCode: anfrCode,
                operatorName: operatorName == "ALL" ? nil : operatorName,
                exifMetadata: prepared.exifJSON
            )
            Haptics.success()
            photoUploadMessage = "Photo envoyée — merci ! Elle apparaîtra après validation."
            await load(id: siteId, market: market, operatorName: operatorName, anfrCode: anfrCode)
        } catch {
            Haptics.error()
            photoUploadMessage = error.localizedDescription
        }
    }

}

struct AntennaDetailSheet: View {
    let site: AntennaSite
    let market: String
    /// Opérateur dont on affiche la fiche. Modifiable in-situ pour les sites
    /// partagés (multi-opérateurs) : l'utilisateur passe de l'un à l'autre sans
    /// rouvrir la carte.
    @State private var selectedOperator: String
    @StateObject private var model: AntennaDetailViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var viewerPhoto: AntennaPhotoSummary?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showReportSheet = false

    init(site: AntennaSite, market: String = "FR", operatorName: String = "SFR", service: AntennasServicing) {
        self.site = site
        self.market = market
        let resolved = operatorName == "ALL" ? (site.operators.first ?? "SFR") : operatorName
        _selectedOperator = State(initialValue: resolved)
        _model = StateObject(wrappedValue: AntennaDetailViewModel(service: service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Ordre voulu : ce qui répond aux questions du terrain d'abord
                // (où est ce site par rapport à moi, est-ce que je le vois), la
                // fiche technique ensuite, repliée. Les trois premiers blocs
                // doivent tenir dans le detent `.medium`.
                VStack(alignment: .leading, spacing: 14) {
                    header
                    sightCard
                    miniMap
                    if let details = model.details {
                        keyFigures(details)
                        collapsibleSections(details)
                    } else if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(SQColor.danger)
                    } else {
                        ProgressView().tint(SQColor.brandRed).frame(maxWidth: .infinity)
                    }
                    reportCard
                }
                .padding(SQSpace.lg + 2)
            }
            .signalQuestBackground()
            .navigationTitle("Site \(site.siteId ?? site.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
            // `id: selectedOperator` → recharge la fiche quand l'utilisateur change
            // d'opérateur sur un site partagé.
            .task(id: selectedOperator) {
                model.details = nil
                model.error = nil
                await model.load(id: site.siteId ?? site.id, market: market, operatorName: selectedOperator, anfrCode: site.anfrCode)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(item: $viewerPhoto) { photo in
            AntennaPhotoViewer(photos: model.details?.photos ?? [photo], initialId: photo.id)
        }
        .sheet(isPresented: $showReportSheet) {
            AntennaReportSheet(
                siteId: site.siteId ?? site.id,
                siteLabel: site.siteId ?? site.id,
                availableSectors: reportSectors,
                service: services.antennaReports
            )
        }
        .onChangeCompat(of: photoPickerItem) { _, newValue in
            guard let newValue else { return }
            Task {
                await model.uploadPhoto(
                    item: newValue,
                    photos: services.photos,
                    siteId: site.siteId ?? site.id,
                    anfrCode: site.anfrCode,
                    operatorName: selectedOperator,
                    market: market
                )
                photoPickerItem = nil
            }
        }
    }

    /// « Ajouter une photo » : disponible quelle que soit la présence de photos
    /// existantes. Réutilise `PhotoService.uploadPhoto` (siteId/anfr/opérateur).
    private var addPhotoContent: some View {
        let uploading = model.isUploadingPhoto
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                HStack(spacing: SQSpace.sm) {
                    if uploading {
                        ProgressView().tint(SQColor.onAccent)
                    } else {
                        Image(systemName: "camera.fill").font(.system(size: 15, weight: .semibold))
                    }
                    Text(uploading ? "Envoi…" : "Choisir une photo du site")
                        .font(SQType.button)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .foregroundStyle(SQColor.onAccent)
                .background(SQColor.brandRed, in: Capsule(style: .continuous))
                .sqShadowAccent()
            }
            .disabled(model.isUploadingPhoto)
            if let message = model.photoUploadMessage {
                Text(LocalizedStringKey(message))
                    .font(SQType.caption)
                    .foregroundStyle(message.contains("merci") ? SQColor.success : SQColor.danger)
            }
        }
        .foregroundStyle(SQColor.label)
    }

    /// Carte « Signaler un problème » : ouvre le formulaire de signalement d'antenne.
    /// Style secondaire (surface) pour respecter la règle brique (le bouton photo
    /// tient déjà l'unique grand aplat brique de la fiche).
    private var reportCard: some View {
        Button {
            Haptics.light()
            showReportSheet = true
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 40, height: 40)
                    .background(SQColor.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signaler un problème")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Text("Une donnée incorrecte sur ce site ? Préviens la modération.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .sqSheetCard()
    }

    /// Azimuts connus (degrés arrondis) proposés comme « secteur concerné » dans
    /// le formulaire de signalement.
    private var reportSectors: [Int] {
        let source = (model.details?.core?.azimuts ?? []).isEmpty ? site.azimuths : (model.details?.core?.azimuts ?? [])
        return Array(Set(source.map { Int($0.rounded()) })).sorted()
    }

    /// Couleur de l'opérateur affiché (utilisée par l'éventail d'azimuts).
    private var operatorColor: Color {
        SQBrand.operatorColor(selectedOperator)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 44, height: 44)
                    .background(SQColor.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Site \(site.siteId ?? site.id)")
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                    // L'adresse était reléguée tout en bas de la fiche : c'est
                    // pourtant ce qui permet de reconnaître le site sur place.
                    if let location = locationLine {
                        Text(location)
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(site.owner ?? "Opérateurs inconnus")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Spacer()
            }
            if site.operators.count > 1 {
                Text("Opérateur du site").sqKicker()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SQSpace.xs + 2) {
                    ForEach(site.operators, id: \.self) { op in
                        operatorTag(op)
                    }
                    ForEach(site.technologies, id: \.self) { tech in
                        SQEditorialTag(text: tech, color: SQBrand.techColor(tech))
                    }
                    statusTag
                }
                .padding(.vertical, 1)
            }
        }
    }

    /// Adresse lisible : celle de la fiche détaillée si elle est chargée, sinon
    /// celle portée par le marqueur.
    private var locationLine: String? {
        let candidate = model.details?.core?.fullAddress ?? site.address
        guard let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return candidate
    }

    /// Badge de statut ANFR. Un site « Projet approuvé » est déclaré mais éteint :
    /// sans ce badge, la fiche laissait croire à une antenne en service.
    @ViewBuilder
    private var statusTag: some View {
        if let core = model.details?.core, let status = core.displayStatus {
            SQEditorialTag(
                text: status,
                color: core.isInService ? SQColor.success
                    : core.isPendingStatus ? SQColor.warning
                    : SQColor.labelSecondary
            )
        }
    }

    /// Le bloc calculé « depuis ta position ». Il est en haut parce que c'est la
    /// première question qu'on se pose devant un pylône, pas la dernière.
    private var sightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AntennaSectionHeader(kicker: "Repérage", title: "Depuis ta position", systemImage: "location.north.line")
            AntennaSightCard(
                site: site,
                details: model.details,
                location: services.location,
                tint: operatorColor,
                terrain: services.terrain
            )
        }
        .foregroundStyle(SQColor.label)
        .sqSheetCard(strong: true)
    }

    /// Mini-carte du site. Non interactive : la carte principale est juste
    /// derrière, un pan ici ne ferait que voler des gestes au scroll de la fiche.
    @ViewBuilder
    private var miniMap: some View {
        if let coordinate = siteCoordinate {
            SQRegionMap(
                region: .constant(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                )),
                items: [SQMapPin(coordinate: coordinate)],
                annotationContent: { pin in
                    MapAnnotation(coordinate: pin.coordinate) {
                        SQAntennaMarker(
                            azimuths: displayedAzimuths,
                            isSelected: true,
                            tint: operatorColor,
                            diameter: 30
                        )
                    }
                }
            )
            .frame(height: 150)
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
            .overlay(alignment: .bottomTrailing) {
                if let userLocation = services.location.lastLocation {
                    let distance = userLocation.distance(from: CLLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    ))
                    Text(SQUnits.distance(meters: distance))
                        .font(SQFont.archivo(11, .bold))
                        .foregroundStyle(SQColor.label)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, SQSpace.xs)
                        .background(SQColor.surface, in: Capsule(style: .continuous))
                        .padding(SQSpace.sm)
                }
            }
            .accessibilityLabel("Carte du site")
        }
    }

    private var siteCoordinate: CLLocationCoordinate2D? {
        if let core = model.details?.core, core.lat != 0 || core.lng != 0 {
            return CLLocationCoordinate2D(latitude: core.lat, longitude: core.lng)
        }
        guard site.hasValidCoordinate, let latitude = site.latitude, let longitude = site.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var displayedAzimuths: [Double] {
        let core = model.details?.core?.azimuts ?? []
        return core.isEmpty ? site.azimuths : core
    }

    /// Tag opérateur. Sur un site partagé, il devient un bouton de bascule :
    /// l'opérateur actif est en plein (capsule couleur, texte blanc), les autres
    /// en capsule teintée douce. Sur un site mono-opérateur, simple tag éditorial.
    @ViewBuilder
    private func operatorTag(_ op: String) -> some View {
        let color = SQBrand.operatorColor(op)
        let isSwitchable = site.operators.count > 1
        let isActive = op == selectedOperator
        if isSwitchable {
            Button {
                guard op != selectedOperator else { return }
                Haptics.selection()
                selectedOperator = op
            } label: {
                Text(op)
                    .font(SQFont.body(11.5, .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, SQSpace.sm + 2)
                    .padding(.vertical, SQSpace.xs + 1)
                    .foregroundStyle(isActive ? Color.white : color)
                    .background(
                        isActive ? color : color.opacity(0.13),
                        in: Capsule(style: .continuous)
                    )
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityAddTraits(isActive ? .isSelected : [])
        } else {
            SQEditorialTag(text: op, color: color)
        }
    }

    /// Quatre chiffres, pas six : validations et speedtests redescendent dans
    /// leurs sections respectives, où ils ont le contexte qui les rend lisibles.
    private func keyFigures(_ details: AntennaDetails) -> some View {
        let heightValue = details.core?.siteInfo.radiatingHeightMeters ?? details.height
        let heightLabel = details.core?.siteInfo.radiatingHeightIsEstimated == true
            ? String(localized: "Hauteur (support)")
            : String(localized: "Hauteur")
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            CardMetricTile(label: heightLabel, value: heightValue.map { "\(Int($0.rounded())) m" } ?? "—", highlight: true)
            CardMetricTile(
                label: "Secteurs",
                value: details.core?.siteInfo.sectorCount.map(String.init)
                    ?? (displayedAzimuths.isEmpty ? "—" : String(displayedAzimuths.count))
            )
            // Les bandes figuraient ici ET dans la grille juste en dessous. À la
            // place, le signal communautaire : combien de personnes ont identifié
            // ce site — c'est ce que porte la coche sur la carte.
            CardMetricTile(
                label: "Identifications",
                value: (details.validationsCount ?? (site.validationCount > 0 ? site.validationCount : nil))
                    .map(String.init) ?? "—"
            )
            // `photosCount` est nil sur le chemin wrapper : la galerie déjà
            // chargée est alors la seule source fiable du nombre.
            CardMetricTile(
                label: "Photos",
                value: (details.photosCount ?? (details.photos.isEmpty ? nil : details.photos.count))
                    .map(String.init) ?? "—"
            )
        }
    }

    // MARK: Secteurs & azimuts

    /// Le rayonnement du site : technologies, bandes, et — seulement quand les
    /// secteurs diffèrent réellement — la grille qui montre où est l'écart.
    private func sectorContent(_ details: AntennaDetails) -> some View {
        AntennaSectorGridView(
            azimuths: displayedAzimuths,
            siteBands: (details.core?.frequencyBands ?? []).isEmpty ? details.bands : (details.core?.frequencyBands ?? []),
            sectorSystems: details.core?.sectorSystems ?? [],
            technologies: (details.core?.technologies ?? []).isEmpty ? details.technologies : (details.core?.technologies ?? []),
            projectBands: details.core?.technologiesInProject ?? [],
            antennaHeightMeters: details.core?.siteInfo.radiatingHeightMeters,
            tint: operatorColor
        )
        .foregroundStyle(SQColor.label)
    }

    // MARK: Sections repliables

    /// Toute la fiche technique, repliée. Rien n'est retiré par rapport à la
    /// version précédente : les mêmes blocs sont là, mais fermés par défaut —
    /// sauf le rayonnement, qui est ce qu'on vient chercher le plus souvent.
    @ViewBuilder
    private func collapsibleSections(_ details: AntennaDetails) -> some View {
        if !displayedAzimuths.isEmpty || !details.bands.isEmpty {
            AntennaDisclosureSection(title: "Secteurs & azimuts", systemImage: "safari", initiallyExpanded: true) {
                sectorContent(details)
            }
        }
        if let core = details.core {
            AntennaDisclosureSection(title: "Site", systemImage: "mappin.and.ellipse") {
                siteContent(core)
            }
            AntennaDisclosureSection(title: "Technique", systemImage: "antenna.radiowaves.left.and.right") {
                technicalContent(core)
            }
            if !core.cellIdentifiers.enb.isEmpty || !core.cellIdentifiers.gnb.isEmpty
                || !core.cellIdentifiers.pci.isEmpty || !core.cellIdentifiers.cellId.isEmpty {
                AntennaDisclosureSection(title: "Identifiants radio", systemImage: "number") {
                    radioIdentifiersContent(core)
                }
            }
            if !core.radioCarriers.isEmpty {
                AntennaDisclosureSection(title: "Porteuses radio", systemImage: "dot.radiowaves.left.and.right") {
                    carriersContent(core)
                }
            }
        }
        AntennaDisclosureSection(title: "Communauté", systemImage: "checkmark.seal") {
            communityContent(details)
        }
        if !details.nearbySpeedtests.isEmpty {
            AntennaDisclosureSection(title: "Speedtests proches", systemImage: "speedometer") {
                speedtestsContent(details)
            }
        }
        AntennaDisclosureSection(
            title: details.photos.isEmpty ? "Photos" : "Photos (\(details.photos.count))",
            systemImage: "photo.on.rectangle",
            // Ouverte quand le site EST photographié : une galerie repliée derrière
            // un titre se lit comme une absence de photos.
            initiallyExpanded: !details.photos.isEmpty
        ) {
            photosContent(details)
        }
        Text("Les données radio affichées ici viennent du backend SignalQuest, d’Android ou de sources publiques. iOS ne collecte pas ces métriques.")
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
    }

    private func communityContent(_ details: AntennaDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                CardMetricTile(label: "Validations", value: details.validationsCount.map(String.init) ?? "—", highlight: true)
                CardMetricTile(label: "Mesures", value: details.signalStats.map { "\($0.measurementCount)" } ?? "—")
                CardMetricTile(label: "Speedtests", value: details.speedtestsCount.map(String.init) ?? "—")
                CardMetricTile(label: "RSRP moy.", value: SignalFormatters.dbm(details.signalStats?.avgRsrp))
            }
            if let stats = details.signalStats {
                detailRow("RSRQ moy.", SignalFormatters.db(stats.avgRsrq))
                detailRow("SNR moy.", SignalFormatters.db(stats.avgSnr))
                detailRow("TAC", stats.tac)
                detailRow("Dernière mesure", SignalFormatters.date(stats.lastMeasurement, includingTime: true, relative: true))
            }
        }
        .foregroundStyle(SQColor.label)
    }

    private func siteContent(_ core: AntennaCoreDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                detailRow("SUP ID", core.supId)
                // Le libellé suit le régulateur du marché : « Code ANFR » devant un
                // identifiant ISED ou OFCOM serait faux.
                detailRow(core.registryLabel, core.anfrCode.isEmpty ? nil : core.anfrCode)
                detailRow("Marché", core.market)
                detailRow(core.localityLabel, [core.postalCode, core.commune].compactMap { $0 }.joined(separator: " "))
                detailRow("Adresse", core.address)
                detailRow("Partage", [core.sharingKind, core.crozonLeader.map { "Crozon \($0)" }, core.zbLeader.map { "ZB \($0)" }].compactMap { $0 }.joined(separator: " · "))
                detailRow("Coordonnées", String(format: "%.5f, %.5f", core.lat, core.lng))
        }
        .foregroundStyle(SQColor.label)
    }

    /// Les dates du site, sans répétition.
    ///
    /// Quatre champs décrivent le même cycle de vie par deux chemins : la date de
    /// mise en service administrative de la station (`SUP_STATION`) et la date du
    /// premier émetteur allumé (observatoire ANFR) tombent presque toujours le
    /// même jour, ce qui affichait deux lignes identiques. On ne garde qu'une
    /// occurrence de chaque date, dans l'ordre chronologique du cycle.
    private func lifecycleDates(_ core: AntennaCoreDetails) -> [(String, String)] {
        let candidates: [(String, String?)] = [
            (String(localized: "Implantation"), core.siteInfo.implantationDate),
            (String(localized: "Mise en service"), core.siteInfo.commissioningDate ?? core.siteInfo.firstActivation),
            (String(localized: "Première activation"), core.siteInfo.firstActivation),
            (String(localized: "Dernière évolution"), core.siteInfo.lastCommissioned),
        ]
        var seen = Set<String>()
        var result: [(String, String)] = []
        for (label, raw) in candidates {
            guard let formatted = SignalFormatters.date(raw), seen.insert(formatted).inserted else { continue }
            result.append((label, formatted))
        }
        return result
    }

    private func technicalContent(_ core: AntennaCoreDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                detailRow("Technos", core.technologies.joined(separator: " / "))
                if !core.technologiesInProject.isEmpty {
                    // Déclaré à l'ANFR mais pas allumé : la distinction n'était
                    // visible que sur le site web.
                    detailRow("En projet", core.technologiesInProject.joined(separator: " · "))
                }
                detailRow("Bandes", core.frequencyBands.joined(separator: " / "))
                detailRow("Azimuts", core.azimuts.prefix(12).map { "\(Int($0.rounded()))°" }.joined(separator: " · "))
                detailRow("Support", core.siteInfo.supportType ?? core.technical.supportType)
                // `supportHeight` est une chaîne brute du registre (« 29,5 », « 4 ») :
                // l'afficher telle quelle donnait une hauteur sans unité.
                detailRow(
                    "Hauteur support",
                    (core.siteInfo.supportHeightMeters ?? core.siteInfo.pylonHeight)
                        .map { "\(Int($0.rounded())) m" }
                )
                detailRow("Types d'antennes", core.siteInfo.antennaTypes.prefix(6).joined(separator: " · "))
                detailRow("Propriétaire", core.siteInfo.supportOwner ?? core.rawLicenseeName)
                detailRow("Secteurs", core.siteInfo.sectorCount.map(String.init))
                detailRow("Faisceau hertzien", core.technical.hasFh.map { $0 ? "Oui" : "Non" })
                detailRow("Statut", core.displayStatus)
                ForEach(lifecycleDates(core), id: \.0) { label, value in
                    detailRow(label, value)
                }
                detailRow("Dernière mise à jour", SignalFormatters.date(core.siteInfo.lastUpdated, relative: true))
                // Belgique, Suisse, Canada : le régulateur publie la position et
                // l'opérateur, mais ni hauteur, ni secteurs, ni azimuts. Le dire
                // évite que la fiche passe pour un chargement raté.
                if !core.hasStructuralData {
                    Text(registryCoverageNote(for: core))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
        }
        .foregroundStyle(SQColor.label)
    }

    /// Note de couverture du registre, nommé quand on le connaît : « le régulateur »
    /// tout court laisserait croire à une limite de l'app.
    private func registryCoverageNote(for core: AntennaCoreDetails) -> String {
        let registry: String
        switch core.market?.uppercased() {
        case "BE": registry = "Le registre belge (BIPT)"
        case "CH": registry = "Le registre suisse (OFCOM)"
        case "CA": registry = "Le registre canadien (ISED)"
        default: registry = "Le registre de ce pays"
        }
        return "\(registry) publie la position et l'exploitant, mais ni hauteur, ni secteurs, ni azimuts : ces lignes resteront vides tant que la source ne les donnera pas."
    }

    private func radioIdentifiersContent(_ core: AntennaCoreDetails) -> some View {
        AntennaRadioIdentifiersView(
            identifiers: core.cellIdentifiers,
            azimuths: displayedAzimuths,
            tint: operatorColor
        )
        .foregroundStyle(SQColor.label)
    }

    private func carriersContent(_ core: AntennaCoreDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                        ForEach(core.radioCarriers.prefix(10)) { carrier in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    SQEditorialTag(text: carrier.bandLabel ?? carrier.technology ?? "Radio", color: SQBrand.techColor(carrier.technology ?? ""))
                                    Spacer()
                                    Text(carrier.source ?? "Officiel")
                                        .font(SQType.micro)
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                                detailRow("Fréquences", [carrier.txFrequencyMhz.map { "\($0) MHz TX" }, carrier.rxFrequencyMhz.map { "\($0) MHz RX" }].compactMap { $0 }.joined(separator: " · "))
                                detailRow("Bande passante", carrier.bandwidthMhz.map { "\($0) MHz" })
                                detailRow("DL effectif", carrier.effectiveDownlinkBandwidthMhz.map { "\($0) MHz" })
                                detailRow("Allocation DL", carrier.downlinkAllocationPercent.map { "\(Int($0.rounded())) %" })
                                detailRow("Puissance", carrier.txPowerDbm.map { "\($0) dBm" })
                                detailRow("Secteur", [carrier.sectorAzimuthDeg.map { "\(Int($0.rounded()))°" }, carrier.sectorBeamwidthDeg.map { "beam \(Int($0.rounded()))°" }, carrier.antennaType].compactMap { $0 }.joined(separator: " · "))
                                detailRow("Cell IDs", carrier.cellIds.prefix(5).joined(separator: " · "))
                                detailRow("Physical IDs", carrier.physicalIds.prefix(5).joined(separator: " · "))
                                detailRow("Mise à jour", SignalFormatters.date(carrier.dateLastChanged))
                            }
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(SQColor.separator).frame(height: 1).opacity(0.5)
                            }
                        }
        }
        .foregroundStyle(SQColor.label)
    }

    private func speedtestsContent(_ details: AntennaDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                ForEach(details.nearbySpeedtests.prefix(5)) { speed in
                    detailRow(
                        SignalFormatters.speed(speed.downloadMbps),
                        [
                            SignalFormatters.speed(speed.uploadMbps),
                            SignalFormatters.ms(speed.pingMs),
                            speed.tech,
                            SignalFormatters.date(speed.timestamp, includingTime: true, relative: true)
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                }
        }
        .foregroundStyle(SQColor.label)
    }

    private func photosContent(_ details: AntennaDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !details.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(details.photos.prefix(8)) { photo in
                            Button {
                                Haptics.light()
                                viewerPhoto = photo
                            } label: {
                                RemoteImage(url: photo.thumbnailUrl ?? photo.imageUrl, maxDimension: 110, contentMode: .fill) {
                                    SQColor.surfaceMuted
                                }
                                .frame(width: 110, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                                .sqShadowSoft()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Photo du site, toucher pour agrandir")
                        }
                    }
                }
            }
            // Toujours proposer la contribution d'une photo (avec ou sans galerie).
            addPhotoContent
        }
        .foregroundStyle(SQColor.label)
    }

    private func detailRow(_ label: String, _ value: String?) -> some View {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label))
                .font(SQFont.body(12))
                .foregroundStyle(SQColor.labelSecondary)
            Spacer(minLength: SQSpace.md)
            Text((normalized?.isEmpty == false ? normalized : "—") ?? "—")
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, SQSpace.sm - 1)
        .padding(.horizontal, SQSpace.sm + 2)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
    }
}

/// Carte douce de la fiche antenne : surface crème, rayon 22 continu, ombre
/// carte — sans bordure (règle No-Border de la DA « Crème & Terre cuite »).
/// Entrée fondu-translation douce au scroll (`sqFadeUp`, respecte Reduce Motion).
private extension View {
    func sqSheetCard(strong: Bool = false) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.lg)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
            .sqFadeUp()
    }
}

/// Section repliable de la fiche antenne : même carte crème que les blocs
/// pleins, mais son en-tête est un bouton.
///
/// La fiche empilait huit cartes ouvertes : exhaustive, illisible, et le bloc
/// utile sur le terrain se trouvait au bout de plusieurs écrans de défilement.
/// Rien n'est retiré — tout est à un tap.
private struct AntennaDisclosureSection<Content: View>: View {
    let title: String
    let systemImage: String
    var initiallyExpanded = false
    @ViewBuilder let content: () -> Content

    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        systemImage: String,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.initiallyExpanded = initiallyExpanded
        self.content = content
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            Button {
                Haptics.light()
                withAnimation(reduceMotion ? nil : SQMotion.standard) { isExpanded.toggle() }
            } label: {
                HStack(spacing: SQSpace.sm) {
                    Label(LocalizedStringKey(title), systemImage: systemImage)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            .accessibilityHint(isExpanded ? "Toucher pour replier" : "Toucher pour déplier")
            if isExpanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
        .sqFadeUp()
    }
}

/// En-tête de section de la fiche antenne : titre Bricolage + icône. L'ancien
/// kicker MAJUSCULES est supprimé (DA Crème) — le paramètre est conservé pour
/// ne pas réécrire les appels, mais n'est plus rendu.
private struct AntennaSectionHeader: View {
    let kicker: String
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(SQType.heading)
            .foregroundStyle(SQColor.label)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Éventail des azimuts dessiné en Canvas : chaque secteur est un cône
/// orienté selon son azimut (0° = nord), coloré avec la couleur opérateur.
struct AzimuthFanView: View {
    let azimuths: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 20
            guard radius > 10 else { return }

            // Cercle boussole
            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.stroke(circle, with: .color(color.opacity(0.25)), lineWidth: 1)

            // Repère nord (à l'intérieur du cercle pour ne pas gêner les étiquettes)
            context.draw(
                Text("N")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(Color.secondary),
                at: CGPoint(x: center.x, y: center.y - radius + 11)
            )

            // Secteurs : faisceau ~65°, même convention que les marqueurs carte
            // (azimut 0° = nord, sens horaire).
            for azimuth in azimuths.prefix(8) {
                let halfBeam = 32.5
                let start = Angle.degrees(azimuth - 90 - halfBeam)
                let end = Angle.degrees(azimuth - 90 + halfBeam)
                var wedge = Path()
                wedge.move(to: center)
                wedge.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                wedge.closeSubpath()
                context.fill(wedge, with: .color(color.opacity(0.18)))
                context.stroke(wedge, with: .color(color.opacity(0.6)), lineWidth: 1)

                // Trait central + étiquette d'angle au-delà du cercle
                let radians = (azimuth - 90) * .pi / 180
                var line = Path()
                line.move(to: center)
                line.addLine(to: CGPoint(
                    x: center.x + CGFloat(cos(radians)) * radius,
                    y: center.y + CGFloat(sin(radians)) * radius
                ))
                context.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1.4)
                context.draw(
                    Text("\(Int(azimuth.rounded()))°")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(color),
                    at: CGPoint(
                        x: center.x + CGFloat(cos(radians)) * (radius + 12),
                        y: center.y + CGFloat(sin(radians)) * (radius + 12)
                    )
                )
            }

            // Point central (le support)
            let dot = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
            context.fill(dot, with: .color(color))
        }
        .accessibilityLabel("Éventail des azimuts des secteurs")
    }
}

/// Viewer plein écran des photos du site : pagination horizontale + fermeture.
private struct AntennaPhotoViewer: View {
    let photos: [AntennaPhotoSummary]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String

    init(photos: [AntennaPhotoSummary], initialId: String) {
        self.photos = photos
        _selection = State(initialValue: initialId)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(photos) { photo in
                    RemoteImage(url: photo.imageUrl ?? photo.thumbnailUrl, maxDimension: 1400, contentMode: .fit) {
                        ProgressView()
                            .tint(.white)
                    }
                    .tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .accessibilityLabel("Fermer")
                    .padding(.trailing, 16)
                }
                Spacer()
                if let current = photos.first(where: { $0.id == selection }) {
                    let caption = [current.userName, current.description]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " — ")
                    if !caption.isEmpty {
                        Text(caption)
                            .font(SQFont.body(13, .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, SQSpace.xl)
                            .padding(.bottom, SQSpace.xxl + 4)
                    }
                }
            }
        }
    }
}
