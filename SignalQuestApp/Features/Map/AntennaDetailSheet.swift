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
            // Un chargement remplacé (changement d'opérateur) n'est pas un échec à afficher.
            guard !error.isCancellation else { return }
            self.error = error.userFacingMessage
        }
    }

    /// Photo choisie, avant envoi : l'original, un aperçu réduit et les
    /// visages qu'on y repère (plan 3, vague 1).
    struct PendingPhoto {
        let raw: Data
        let preview: UIImage
        let faces: [CGRect]
    }

    /// Charge la photo choisie et y cherche des visages, sur l'appareil.
    func loadPhotoForUpload(item: PhotosPickerItem) async -> PendingPhoto? {
        isUploadingPhoto = true
        photoUploadMessage = nil
        defer { isUploadingPhoto = false }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let preview = ImagePipeline.downsample(data: raw, maxPixel: 1600) else {
                photoUploadMessage = "Image illisible."
                return nil
            }
            return PendingPhoto(raw: raw, preview: preview, faces: await PhotoBlur.detectFaces(in: preview))
        } catch {
            Haptics.error()
            photoUploadMessage = error.userFacingMessage
            return nil
        }
    }

    /// Envoie une photo sur le site via `PhotoService`, puis recharge la fiche
    /// (la photo peut être en attente de modération côté serveur). Les zones
    /// floutées sont cuites avant l'encodage ; l'EXIF vient de l'original.
    func uploadPhoto(
        raw: Data,
        blurRegions: [CGRect],
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
            // Extraction EXIF + recompression hors du main thread (UI non gelée).
            guard let prepared = await Task.detached(priority: .userInitiated, operation: {
                PhotoUploadPreparation.prepare(from: raw, blurRegions: blurRegions)
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
            photoUploadMessage = error.userFacingMessage
        }
    }

}

struct AntennaDetailSheet: View {
    let site: AntennaSite
    let market: String
    let sightOrigin: AntennaSightOrigin
    /// Marqueur d'origine quand la fiche est ouverte depuis la couche « Sites
    /// ajoutés ». La route de détail sert les deux types de sites, mais elle ne
    /// renvoie ni l'auteur ni la date d'ajout : ils viennent de la tuile.
    let customSite: AndroidCustomSiteMarker?
    /// Demande à la carte de n'afficher que la couverture de ce site. `nil` quand
    /// la fiche est ouverte hors de la carte.
    var onIsolateCoverage: ((AntennaCoverageFocus) -> Void)?
    /// Fermeture du panneau latéral iPad : hors présentation, `dismiss` ne fait rien.
    var onClose: (() -> Void)?
    /// Appelé après un signalement, une voix ou une fermeture de panne réussis : la carte doit
    /// recharger sa région, sinon le marqueur garderait l'état d'avant.
    var onOutageChanged: (() -> Void)?
    /// Opérateur dont on affiche la fiche. Modifiable in-situ pour les sites
    /// partagés (multi-opérateurs) : l'utilisateur passe de l'un à l'autre sans
    /// rouvrir la carte.
    @State private var selectedOperator: String
    @StateObject private var model: AntennaDetailViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewerPhoto: AntennaPhotoSummary?
    @State private var photoPickerItem: PhotosPickerItem?
    /// L'image est conservée quelques instants le temps de choisir sa facette
    /// sur un support mutualisé. Aucun upload ne part avant ce choix.
    @State private var pendingPhotoUploadItem: PhotosPickerItem?
    /// Photo où des visages ont été repérés, en attente de l'éditeur « Flouter ».
    @State private var photoToBlur: BlurRequest?

    private struct BlurRequest: Identifiable {
        let id = UUID()
        let photo: AntennaDetailViewModel.PendingPhoto
        let operatorName: String
    }
    @State private var showPhotoOperatorPicker = false
    @State private var tab: AntennaDetailTab = .essential
    @State private var showReportSheet = false
    /// Texte du site à envoyer dans une conversation (P2-47) ; non nil = sélecteur ouvert.
    @State private var siteShareDraft: SiteShareDraft?
    /// Type présélectionné à l'ouverture du signalement (lien « opérateur porteur »).
    @State private var reportInitialType: AntennaReportType = .other
    /// Pannes communautaires ouvertes sur ce site, rechargées à chaque changement d'opérateur :
    /// une panne est scopée à un opérateur, donc basculer de facette change la réponse.
    @State private var outages: [CommunityOutage] = []
    /// Incidents que l'OPÉRATEUR déclare lui-même sur ce site. Tenus à part des pannes
    /// communautaires ci-dessus, et chargés par une route séparée : un flux CSV en erreur ne doit
    /// pas empêcher la fiche d'afficher ses signalements, ni l'inverse.
    @State private var operatorIncidents: [SiteOperatorIncident] = []
    /// Entrée de registre du marché, pour écrire « Orange Caraïbe » là où le flux ne porte que
    /// « ORANGE_CARAIBE ». `nil` tant que le registre n'a pas répondu — on retombe alors sur la
    /// clé brute, la seule chose de moins fausse qu'on ait à cet instant.
    @State private var marketEntry: MarketRegistryEntry?
    @State private var showOutageReport = false
    /// Panne dont la fermeture attend confirmation. Le geste est irréversible ET collectif : il ne
    /// part jamais du premier appui, ici comme sur la page « Pannes signalées ».
    @State private var pendingCloseOutage: CommunityOutage?
    /// Fermeture en vol, pour que le bouton se remplace par son indicateur.
    @State private var closingOutageId: String?
    @State private var votingOutageId: String?
    /// Refus d'une écriture de panne — voix ou fermeture.
    ///
    /// Les votes partaient jusqu'ici en `try?` : un refus (« vous êtes trop loin », « cette panne
    /// vient d'être refermée ») ne laissait AUCUNE trace à l'écran, et le compteur revenait
    /// simplement inchangé après le rechargement. On ne peut pas offrir la fermeture ici sans
    /// donner à son refus un endroit où s'écrire.
    @State private var outageError: String?

    /// Le référentiel auquel appartient CE site — c'est le préfixe de `targetKey` côté serveur.
    ///
    /// `custom` pour un site posé à la main, `anfr` sinon. Le figer à `anfr` rendait la panne d'un
    /// site communautaire introuvable depuis sa propre fiche, et son signalement irrésoluble : or
    /// dans les 44 marchés sans référentiel public, c'est la SEULE antenne qui existe.
    private var outageTargetKind: String { isCustomSite ? "custom" : "anfr" }

    init(
        site: AntennaSite,
        market: String = "FR",
        operatorName: String = "ALL",
        service: AntennasServicing,
        customSite: AndroidCustomSiteMarker? = nil,
        sightOrigin: AntennaSightOrigin = .device,
        onIsolateCoverage: ((AntennaCoverageFocus) -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onOutageChanged: (() -> Void)? = nil
    ) {
        self.site = site
        self.market = market
        self.customSite = customSite
        self.sightOrigin = sightOrigin
        self.onIsolateCoverage = onIsolateCoverage
        self.onClose = onClose
        self.onOutageChanged = onOutageChanged
        // Aucun repli SFR : un site étranger ou communautaire ne doit jamais être
        // ouvert sous une facette française inventée. On conserve le choix reçu
        // lorsqu'il existe réellement, sinon la première facette connue du site ;
        // sans facette fiable, "ALL" laisse le backend répondre honnêtement.
        let requested = operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = site.operators.first {
            $0.caseInsensitiveCompare(requested) == .orderedSame
        } ?? site.operators.first ?? (requested.isEmpty ? "ALL" : requested)
        _selectedOperator = State(initialValue: resolved)
        _model = StateObject(wrappedValue: AntennaDetailViewModel(service: service))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Quatre onglets, comme sur le web : ce qui sert sur le terrain
                // d'abord (Essentiel), le registre, les mesures et les photos
                // ensuite, chacun à un appui au lieu de huit sections repliées.
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    header
                    MapSegmented(selection: $tab,
                                 options: AntennaDetailTab.allCases.map { ($0, tabLabel($0)) },
                                 identifier: "antenna.detail.tab")
                    switch tab {
                    case .essential: essentialTab
                    case .identifiers: detailsTab { identifiersTab($0) }
                    case .measures: detailsTab { measuresTab($0) }
                    case .photos: detailsTab { photosContent($0) }
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
            }
            .accessibilityIdentifier("antenna.detail.scroll")
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            // `id: selectedOperator` → recharge la fiche quand l'utilisateur change
            // d'opérateur sur un site partagé.
            .task(id: selectedOperator) {
                model.details = nil
                model.error = nil
                // Les pannes sont scopées à l'opérateur : si leur relecture échoue, celles de la
                // facette précédente ne doivent pas rester affichées sous la nouvelle.
                outages = []
                operatorIncidents = []
                // En parallèle de la fiche : les pannes n'ont pas à attendre `details`.
                async let outagesLoad: Void = loadOutages()
                await model.load(id: site.siteId ?? site.id, market: market, operatorName: selectedOperator, anfrCode: site.anfrCode)
                await loadMarketEntry()
                await outagesLoad
                // Sans cette lecture, l'étoile s'affiche éteinte sur un site pourtant suivi, et
                // un appui écrirait une liste incomplète — le service refuse d'ailleurs d'écrire
                // avant d'avoir chargé.
                await services.favoriteAntennas.load()
            }
        }
        .presentationDetents([.medium, .large])
        .sqSheet(background: SQColor.bg)
        .fullScreenCover(item: $viewerPhoto) { photo in
            MapPhotoViewer(
                items: (model.details?.photos ?? [photo]).map { item in
                    MapPhotoTarget(
                        id: item.id,
                        thumbnailURL: item.thumbnailUrl,
                        imageURL: item.imageUrl,
                        authorName: item.userName,
                        caption: item.description,
                        likeCount: item.likes,
                        commentCount: item.commentCount
                    )
                },
                initialId: photo.id,
                service: services.photos,
                operatorAccent: registryColor,
                site: photoViewerSite
            )
        }
        // `alert` et non `confirmationDialog`, pour la même raison que la page « Pannes signalées »
        // et la feuille de panne : les deux issues doivent être NOMMÉES et la phrase de portée
        // rester lisible, ce qu'un dialogue rendu en popover ne garantit pas.
        .alert(
            "Refermer cette panne ?",
            isPresented: Binding(
                get: { pendingCloseOutage != nil },
                set: { if !$0 { pendingCloseOutage = nil } }
            ),
            presenting: pendingCloseOutage
        ) { outage in
            Button("Refermer", role: .destructive) {
                pendingCloseOutage = nil
                Task { await closeOutage(outage) }
            }
            Button("Annuler", role: .cancel) { pendingCloseOutage = nil }
        } message: { _ in
            Text("Elle disparaîtra de la carte pour tout le monde, tout de suite. On ne peut pas revenir en arrière.")
        }
        // Le texte arrive prérempli dans la conversation choisie, qui s'ouvre : la fiche se ferme.
        .siteSharePicker($siteShareDraft) { close() }
        .sheet(isPresented: $showOutageReport) {
            OutageReportSheet(
                siteId: site.writeSiteId,
                targetKind: outageTargetKind,
                // `headerTitle` et non `site.address` : sur un site communautaire, l'adresse
                // n'arrive qu'avec les détails chargés, et le repli tombait sur l'identifiant
                // technique. La feuille affichait donc « cmpo873aw0jnx2fll7pthh8ii » là où la
                // fiche qui l'ouvre écrit « Château d'eau de Vouillé ». Une même antenne doit se
                // nommer pareil d'un écran à l'autre.
                siteLabel: headerTitle,
                marketCode: market,
                operatorKey: selectedOperator,
                // Le nom du registre, jamais la clé : la feuille écrivait « BOUYGUES_TELECOM »
                // là où le marqueur et la carte de fil de la même panne disent « Bouygues Telecom ».
                operatorLabel: MarketRegistryEntry.operatorLabel(selectedOperator, in: marketEntry),
                siteLatitude: site.latitude,
                siteLongitude: site.longitude,
                // Les bandes et les azimuts viennent de la fiche DÉJÀ chargée : le formulaire ne
                // relance aucune requête, et ne propose que ce que ce site porte réellement.
                // Proposer le catalogue entier offrirait des réponses fausses sur un champ
                // facultatif — pire qu'une absence de réponse.
                siteBands: outageBandOptions,
                siteSectors: reportSectors,
                service: services.communityOutages,
                onSubmitted: { _ in
                    Task { await loadOutages() }
                    onOutageChanged?()
                }
            )
        }
        .sheet(isPresented: $showReportSheet) {
            AntennaReportSheet(
                siteId: site.siteId ?? site.id,
                siteLabel: site.siteId ?? site.id,
                availableSectors: reportSectors,
                service: services.antennaReports,
                leaderReport: leaderReport,
                operatorName: selectedOperator,
                initialType: reportInitialType
            )
        }
        .onChangeCompat(of: photoPickerItem) { _, newValue in
            guard let newValue else { return }
            if photoOperatorChoices.count > 1 {
                pendingPhotoUploadItem = newValue
                showPhotoOperatorPicker = true
                photoPickerItem = nil
            } else {
                submitPhotoUpload(newValue, operatorName: photoOperatorChoices.first ?? selectedOperator)
            }
        }
        .confirmationDialog(
            "Cette photo concerne quel réseau ?",
            isPresented: $showPhotoOperatorPicker,
            titleVisibility: .visible
        ) {
            ForEach(photoOperatorChoices, id: \.self) { networkOperator in
                Button(photoOperatorLabel(networkOperator)) {
                    guard let item = pendingPhotoUploadItem else { return }
                    pendingPhotoUploadItem = nil
                    submitPhotoUpload(item, operatorName: networkOperator)
                }
            }
            Button("Annuler", role: .cancel) {
                pendingPhotoUploadItem = nil
            }
        } message: {
            Text("Le support est partagé. Choisis le réseau réellement visible sur la photo.")
        }
        // Visages repérés : flouter avant l'envoi, ou envoyer sans flou.
        .sheet(item: $photoToBlur) { request in
            PhotoBlurEditor(
                image: request.photo.preview,
                confirmTitle: "Flouter et envoyer",
                emptyConfirmTitle: "Envoyer sans flou"
            ) { _, regions in
                Task { await sendPhoto(request.photo.raw, blurRegions: regions, operatorName: request.operatorName) }
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
                        SQSpinner().tint(SQColor.onInk)
                    } else {
                        Image(systemName: "camera.fill").font(.system(size: 15, weight: .semibold))
                    }
                    Text(uploading ? "Envoi…" : "Ajouter une photo")
                        .font(SQType.button)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: SQSpace.primaryActionHeight)
                .foregroundStyle(SQColor.onInk)
                .background(SQColor.label, in: Capsule(style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle(scale: 0.97))
            .accessibilityIdentifier("antenna.detail.addPhoto")
            .disabled(model.isUploadingPhoto)
            if let message = model.photoUploadMessage {
                Text(LocalizedStringKey(message))
                    .font(SQType.caption)
                    .foregroundStyle(message.contains("merci") ? SQColor.success : SQColor.dangerInk)
            }
        }
        .foregroundStyle(SQColor.label)
    }

    private var photoOperatorChoices: [String] {
        Array(Set(site.operators
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != "ALL" }))
            .sorted()
    }

    private func photoOperatorLabel(_ key: String) -> String {
        MarketRegistryEntry.operatorLabel(key, in: marketEntry)
    }

    /// Des visages sur la photo : l'éditeur « Flouter » s'ouvre avant l'envoi,
    /// qu'on peut aussi faire sans flou. Sans visage, l'envoi part directement.
    private func submitPhotoUpload(_ item: PhotosPickerItem, operatorName: String) {
        Task {
            defer { photoPickerItem = nil }
            guard let pending = await model.loadPhotoForUpload(item: item) else { return }
            if pending.faces.isEmpty {
                await sendPhoto(pending.raw, blurRegions: [], operatorName: operatorName)
            } else {
                photoToBlur = BlurRequest(photo: pending, operatorName: operatorName)
            }
        }
    }

    private func sendPhoto(_ raw: Data, blurRegions: [CGRect], operatorName: String) async {
        await model.uploadPhoto(
            raw: raw,
            blurRegions: blurRegions,
            photos: services.photos,
            siteId: site.siteId ?? site.id,
            anfrCode: site.anfrCode,
            operatorName: operatorName,
            market: market
        )
    }

    /// Deux gestes qu'on veut faire une fois sur place — ou avant d'y aller :
    /// s'y rendre, et voir ce que la communauté a mesuré sur CE site.
    @ViewBuilder
    private var siteActions: some View {
        if let coordinate = siteCoordinate {
            HStack(spacing: SQSpace.sm) {
                if let onIsolateCoverage, let focus = coverageFocus {
                    GradientButton("Sa couverture", systemImage: "dot.radiowaves.left.and.right") {
                        onIsolateCoverage(focus)
                        close()
                    }
                }
                GradientButton("Itinéraire", systemImage: "car.fill",
                               style: onIsolateCoverage != nil && coverageFocus != nil ? .secondary : .primary) {
                    openRoute(to: coordinate)
                }
            }
        }
        if !isCustomSite {
            GradientButton(String(localized: "Envoyer dans une conversation"), systemImage: "paperplane",
                           style: .secondary, allowsMultiline: true) {
                Haptics.selection()
                siteShareDraft = SiteShareDraft(text: siteShareText)
            }
            .accessibilityIdentifier("antenna.detail.sendToConversation")
        }
    }

    /// Le site tel qu'on l'écrit dans une conversation (P2-47, format commun au web, à iOS
    /// et à Android) : une donnée inconnue omet sa ligne. L'opérateur est celui de la fiche
    /// affichée ; sur un support partagé sans choix, la carte n'en nomme aucun.
    private var siteShareText: String {
        let core = model.details?.core
        let operatorKey = selectedOperator.caseInsensitiveCompare("ALL") == .orderedSame
            ? (site.operators.count == 1 ? site.operators.first : nil)
            : selectedOperator
        // Orange, SFR, Bouygues Telecom, Free Mobile en métropole ; ailleurs, le nom du site.
        let operatorName = operatorKey.flatMap { key in
            SiteShareCard.metropolitanOperatorName(forKey: key)
                ?? marketEntry?.operatorEntry(forKey: key)?.label
                ?? core?.rawLicenseeName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
                ?? key
        }
        let identifiers = core?.cellIdentifiers
        // Un PCI par secteur : on n'en écrit un que s'il est le seul du site, jamais un au hasard.
        let pcis = Set((identifiers?.pci ?? []).map(\.value))
        let isFrance = market.caseInsensitiveCompare("FR") == .orderedSame
        let supportId = (core?.supId).flatMap { $0.isEmpty ? nil : $0 } ?? site.siteId
        let anfr = isFrance ? ((core?.anfrCode).flatMap { $0.isEmpty ? nil : $0 } ?? site.anfrCode) : nil
        let card = SiteShareCard(
            operatorName: operatorName,
            technologies: SiteShareCard.generations(in: displayedTechnologies),
            enb: identifiers?.enb.first ?? customSite?.radio?.enb,
            pci: pcis.count == 1 ? pcis.first : nil,
            supportId: supportId,
            anfr: anfr,
            market: market,
            address: locationLine,
            coordinate: siteCoordinate.flatMap { SiteShareCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        )
        return card.shareText(baseURL: AppConfig.current.appBaseURL, linkSiteId: site.writeSiteId)
    }

    /// Identité radio permettant d'isoler les mesures de CE site.
    ///
    /// Sans eNB ni gNB connu, la couverture ne peut pas être rattachée au site :
    /// mieux vaut ne pas proposer le bouton que de renvoyer une carte vide.
    private var coverageFocus: AntennaCoverageFocus? {
        let identifiers = model.details?.core?.cellIdentifiers
        let enb = identifiers?.enb.first ?? customSite?.radio?.enb
        let gnb = identifiers?.gnb.first ?? customSite?.radio?.gnb
        guard enb != nil || gnb != nil else { return nil }
        return AntennaCoverageFocus(
            siteLabel: headerTitle,
            operatorKey: selectedOperator,
            enb: enb,
            gnb: gnb
        )
    }

    /// Ouvre un itinéraire vers le site.
    ///
    /// Quand un véhicule CarPlay est branché, la destination lui est envoyée :
    /// le guidage se fait alors sur NOTRE carte, antennes et lobes visibles
    /// par-dessus la route. Passer par Plan dans ce cas ferait basculer l'écran
    /// du véhicule sur une autre app et perdrait tout l'intérêt.
    ///
    /// Hors CarPlay — ou quand la scène CarPlay ne sait pas guider, faute de la
    /// catégorie `carplay-maps` — comportement inchangé : Plan, avec le nom du
    /// site comme étiquette pour que la destination y soit reconnaissable. Plan
    /// s'affiche de toute façon sur l'écran du véhicule, donc l'utilisateur est
    /// guidé ; le détourner vers une app qui ne peut pas le faire aboutissait à
    /// un bouton sans effet.
    private func openRoute(to coordinate: CLLocationCoordinate2D) {
        Haptics.light()
        if services.isCarPlayGuidanceAvailable {
            CarPlayDestinationStore.record(title: headerTitle, coordinate: coordinate)
            CarPlayDashboardRoute.request(.navigate(title: headerTitle,
                                                    latitude: coordinate.latitude,
                                                    longitude: coordinate.longitude))
            return
        }
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = headerTitle
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    /// Site partagé (Crozon, zone blanche) dont l'opérateur porteur peut être signalé.
    private var leaderReport: AntennaLeaderReport? {
        guard let core = model.details?.core else { return nil }
        return AntennaLeaderReport(sharingKind: core.sharingKind, crozonLeader: core.crozonLeader,
                                   zbLeader: core.zbLeader, operators: core.operators)
    }

    /// Azimuts connus (degrés arrondis) proposés comme « secteur concerné » dans
    /// le formulaire de signalement.
    private var reportSectors: [Int] {
        Array(Set(displayedAzimuths.map { Int($0.rounded()) })).sorted()
    }

    /// Les bandes du site, converties au vocabulaire du signalement (`b28`, `n78`).
    ///
    /// Dérivées des porteuses quand on les a — elles portent le NUMÉRO de bande et la technologie,
    /// donc le jeton est non ambigu. Sans elles, on ne propose rien : deviner « 700 » sans savoir
    /// si c'est B28 ou n28 écrirait une donnée fausse, et ces deux porteuses tombent séparément.
    private var outageBandOptions: [OutageBandOption] {
        let carriers = model.details?.core?.radioCarriers ?? []
        var seen = Set<String>()
        var options: [OutageBandOption] = []
        for carrier in carriers {
            guard let band = carrier.band, band > 0 else { continue }
            let isNr = (carrier.technology ?? "").uppercased().contains("5G")
                || (carrier.technology ?? "").uppercased().contains("NR")
            let token = isNr ? "n\(band)" : "b\(band)"
            guard !seen.contains(token) else { continue }
            seen.insert(token)
            options.append(
                OutageBandOption(
                    token: token,
                    label: carrier.bandLabel ?? SQUnits.band(band, isNR: isNr),
                    freqMhz: carrier.txFrequencyMhz.map { Int($0.rounded()) }
                )
            )
        }
        return options
    }

    /// Couleur de l'opérateur affiché (utilisée par l'éventail d'azimuts).
    private var operatorColor: Color {
        registryColor(selectedOperator)
    }

    /// Couleur du registre du marché, comme les marqueurs de la carte ; la palette
    /// `SQBrand` ne sert que tant que le registre n'a pas répondu.
    private func registryColor(_ key: String) -> Color {
        marketEntry?.operatorColor(forKey: key) ?? SQBrand.operatorColor(key)
    }

    /// Le site tel que la visionneuse photo le résume : la photo garde sous les
    /// yeux ce qu'on vient de lire dans l'en-tête de la fiche.
    private var photoViewerSite: MapPhotoSite {
        let core = model.details?.core
        return MapPhotoSite(
            kicker: supportLine,
            title: headerTitle,
            caption: headerCaption,
            status: core?.displayStatus,
            statusColor: core.map { $0.isInService ? SQColor.success : $0.isPendingStatus ? SQColor.warning : SQColor.labelSecondary }
                ?? SQColor.labelSecondary,
            operators: site.operators.map { MapPhotoSite.Operator(label: photoOperatorLabel($0), color: registryColor($0)) },
            technologies: displayedTechnologies,
            height: (core?.siteInfo.supportHeightMeters ?? core?.siteInfo.pylonHeight).map { "\(Int($0.rounded())) m" }
        )
    }

    // MARK: En-tête et onglets

    /// En-tête Halo : n° du support en petites capitales, le nom du site, son
    /// adresse et sa distance, puis Suivre, Partager et Fermer en boutons ronds.
    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    if let supportLine {
                        Text(supportLine).sqKicker()
                    }
                    Text(headerTitle)
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = headerCaption {
                        Text(subtitle)
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                HStack(spacing: SQSpace.xs2) {
                    FavoriteAntennaButton(
                        favorites: services.favoriteAntennas,
                        siteId: site.writeSiteId,
                        market: market,
                        operatorName: selectedOperator,
                        name: site.address,
                        address: site.address,
                        latitude: site.latitude,
                        longitude: site.longitude
                    )
                    .sqSurface(SQColor.chip, in: Circle())
                    if let shareURL {
                        ShareLink(item: shareURL, subject: Text(headerTitle)) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SQColor.label)
                                .frame(width: 44, height: 44)
                                .sqSurface(SQColor.chip, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .accessibilityLabel("Partager ce site")
                        .accessibilityIdentifier("antenna.detail.share")
                    }
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "antenna.detail.close") {
                        close()
                    }
                }
            }
            if hasStatusTags {
                HStack(spacing: SQSpace.xs2) {
                    statusTag
                    if site.operators.count > 1 {
                        SQEditorialTag(
                            text: String(localized: "Partagé · \(site.operators.count) opérateurs"),
                            color: SQColor.labelSecondary
                        )
                    }
                    fhTag
                }
            }
            contributionBanner
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// « Support 0381234 » : le numéro du registre, que l'on recopie sur place.
    private var supportLine: String? {
        let number = model.details?.core?.supId ?? site.siteId
        guard let number, !number.isEmpty, !isCustomSite else { return nil }
        return String(localized: "Support \(number)")
    }

    /// Adresse (ou nature du site) et distance depuis l'origine du repérage.
    private var headerCaption: String? {
        let parts = [headerSubtitle, distanceText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var distanceText: String? {
        guard let coordinate = siteCoordinate,
              let origin = sightOrigin.coordinate(deviceLocation: services.location.cachedLocation()) else { return nil }
        let distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        return SQUnits.distance(meters: distance)
    }

    private var hasStatusTags: Bool {
        model.details?.core?.displayStatus != nil || site.operators.count > 1
            || model.details?.core?.hasFhLink == true
    }

    /// Lien du site sur la carte web, au format de `buildMapLink` côté site :
    /// il ouvre la même fiche, sur le même opérateur.
    private var shareURL: URL? {
        guard !isCustomSite, let coordinate = siteCoordinate else { return nil }
        var components = URLComponents(
            url: AppConfig.current.appBaseURL.appendingPathComponent("carte"),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "lat", value: String(format: "%.5f", coordinate.latitude)),
            URLQueryItem(name: "lng", value: String(format: "%.5f", coordinate.longitude)),
            URLQueryItem(name: "siteId", value: site.writeSiteId),
            URLQueryItem(name: "market", value: market),
        ]
        if selectedOperator != "ALL" {
            items.append(URLQueryItem(name: "operator", value: selectedOperator))
        }
        items.append(URLQueryItem(name: "open", value: "antenna"))
        components?.queryItems = items
        return components?.url
    }

    private func tabLabel(_ tab: AntennaDetailTab) -> String {
        switch tab {
        case .essential: return String(localized: "Essentiel")
        case .identifiers: return String(localized: "Identifiants")
        case .measures: return String(localized: "Mesures")
        case .photos:
            let count = model.details.map { $0.photosCount ?? $0.photos.count } ?? 0
            return count > 0 ? String(localized: "Photos \(count)") : String(localized: "Photos")
        }
    }

    /// Les onglets qui lisent la fiche détaillée : chargement, erreur, contenu.
    @ViewBuilder
    private func detailsTab<Content: View>(@ViewBuilder _ content: (AntennaDetails) -> Content) -> some View {
        if let details = model.details {
            content(details)
        } else if let error = model.error {
            // Sans relance, il fallait fermer et rouvrir la fiche (AF-CARTE-12).
            ErrorStateView(title: "Détails indisponibles", message: error) {
                Task {
                    model.error = nil
                    await model.load(id: site.siteId ?? site.id, market: market, operatorName: selectedOperator, anfrCode: site.anfrCode)
                }
            }
        } else {
            SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity).padding(.vertical, SQSpace.xl)
        }
    }

    // MARK: Essentiel

    /// Ce qu'on vient chercher devant un pylône : une panne en cours d'abord,
    /// qui émet ici, où est le site, ce qu'il rayonne, puis les gestes.
    private var essentialTab: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            // L'OPÉRATEUR D'ABORD, la communauté ensuite. C'est l'ordre de l'autorité : une
            // déclaration de première main précède une observation qui attend d'être corroborée.
            // Les deux blocs restent distincts et ne se remplacent jamais l'un l'autre.
            OperatorIncidentCard(
                incidents: operatorIncidents,
                operatorLabel: { MarketRegistryEntry.operatorLabel($0, in: marketEntry) }
            )
            CommunityOutageCard(
                outages: outages,
                onVote: { outageId, kind in
                    Task { await voteOnOutage(outageId, kind: kind) }
                },
                // Décision produit n° 12 : la fiche antenne est le quatrième chemin vers une panne,
                // et le seul qui n'offrait pas « La panne est terminée ».
                onClose: { pendingCloseOutage = $0 },
                closingOutageId: closingOutageId,
                votingOutageId: votingOutageId
            )
            if let outageError {
                SQNotice(message: outageError, tone: .warning)
            }
            radioBlock
            sightCard
            if let details = model.details {
                if !displayedAzimuths.isEmpty || !details.bands.isEmpty {
                    section("Secteurs et bandes") {
                        sectorContent(details)
                            .padding(SQSpace.md)
                            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    }
                }
            } else if let error = model.error {
                ErrorStateView(title: "Détails indisponibles", message: error) {
                    Task {
                        model.error = nil
                        await model.load(id: site.siteId ?? site.id, market: market, operatorName: selectedOperator, anfrCode: site.anfrCode)
                    }
                }
            } else {
                SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity)
            }
            // Ouverte depuis la carte, la fiche a le site juste derrière elle :
            // la mini-carte ne sert que depuis une liste (favoris, photos, trajet).
            if onIsolateCoverage == nil { miniMap }
            siteActions
            reportRows
        }
    }

    /// Une ligne par opérateur du support : sa couleur, ses technologies et son
    /// identifiant. Sur un site partagé, une ligne bascule la fiche sur lui.
    private var radioBlock: some View {
        section("Radio") {
            VStack(spacing: 0) {
                ForEach(Array(site.operators.enumerated()), id: \.element) { index, op in
                    operatorRow(op)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(SQColor.separator).frame(height: 1) }
                        }
                }
                if site.operators.isEmpty {
                    operatorRow(selectedOperator)
                }
            }
            .padding(.horizontal, SQSpace.md)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            if site.operators.count > 1 {
                Text("Touche un opérateur pour voir sa fiche.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    @ViewBuilder
    private func operatorRow(_ op: String) -> some View {
        let isActive = op == selectedOperator
        let isSwitchable = site.operators.count > 1 && !isActive
        let row = HStack(spacing: SQSpace.sm) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(registryColor(op))
                .frame(width: 4, height: 22)
            Text(photoOperatorLabel(op))
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(technologies(for: op), id: \.self) { tech in
                MapTechTag(technology: tech, label: tech)
            }
            if isActive, model.details != nil {
                Text(identityLine ?? String(localized: "n° non publié"))
                    .font(SQType.caption(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            } else if isSwitchable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
        }
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        if isSwitchable {
            Button {
                Haptics.selection()
                selectedOperator = op
            } label: { row }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint("Affiche la fiche de cet opérateur")
            .accessibilityIdentifier("antenna.detail.operator.\(op)")
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(site.operators.count > 1 ? .isSelected : [])
                .accessibilityIdentifier("antenna.detail.operator.\(op)")
        }
    }

    /// « eNB 812345 » ou « gNB 1203344 » : le numéro du site pour l'opérateur affiché.
    private var identityLine: String? {
        let identifiers = model.details?.core?.cellIdentifiers
        if let enb = identifiers?.enb.first ?? customSite?.radio?.enb {
            return "eNB \(enb)"
        }
        if let gnb = identifiers?.gnb.first ?? customSite?.radio?.gnb {
            return "gNB \(gnb)"
        }
        return nil
    }

    /// Technologies d'un opérateur du support : celles de la fiche pour
    /// l'opérateur affiché, sinon la fusion du support, sans prêter la 5G d'un
    /// voisin (`operators5G`).
    private func technologies(for op: String) -> [String] {
        if op == selectedOperator { return displayedTechnologies }
        guard !site.operators5G.isEmpty else { return site.technologies }
        let has5G = site.operators5G.contains { $0.caseInsensitiveCompare(op) == .orderedSame }
        return has5G ? site.technologies : site.technologies.filter { $0 != "5G" }
    }

    /// Les signalements, en lignes au bas de l'onglet plutôt qu'en grande carte.
    private var reportRows: some View {
        VStack(spacing: 0) {
            if !outages.contains(where: { $0.state.isVisible }) {
                reportRow("Signaler une panne", icon: "exclamationmark.triangle", identifier: "antenna.detail.reportOutage") {
                    showOutageReport = true
                }
                Rectangle().fill(SQColor.separator).frame(height: 1)
            }
            reportRow("Signaler une erreur sur ce site", icon: "exclamationmark.bubble", identifier: "antenna.detail.reportError") {
                reportInitialType = .other
                showReportSheet = true
            }
        }
        .padding(.horizontal, SQSpace.md)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func reportRow(_ title: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: SQSpace.sm2) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 22)
                Text(LocalizedStringKey(title))
                    .font(SQType.callout(.semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    /// Bloc à petites capitales : le titre, puis son contenu.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            Text(LocalizedStringKey(title)).sqKicker().accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Se prononcer sur une panne, puis relire : les compteurs affichés doivent suivre le vote.
    ///
    /// Le refus est mis en mots par le CLIENT, sur le code applicatif : la phrase du serveur
    /// n'existe qu'en français.
    private func voteOnOutage(_ outageId: String, kind: String) async {
        // Un double appui envoyait deux voix (AF-CARTE-05).
        guard votingOutageId == nil else { return }
        votingOutageId = outageId
        defer { votingOutageId = nil }
        let here = services.location.cachedLocation()
        outageError = nil
        do {
            _ = try await services.communityOutages.vote(
                outageId: outageId,
                kind: kind,
                latitude: here?.coordinate.latitude,
                longitude: here?.coordinate.longitude,
                accuracyMeters: here.flatMap { $0.horizontalAccuracy > 0 ? $0.horizontalAccuracy : nil }
            )
            onOutageChanged?()
        } catch {
            // Une annulation n'est pas un refus : elle survient quand la fiche recharge sous nos
            // pieds (changement d'opérateur), et l'afficher accuserait l'utilisateur d'un échec
            // qui n'a pas eu lieu.
            if !error.isCancellation { outageError = OutageWriteError.message(for: error) }
        }
        await loadOutages()
    }

    /// L'auteur referme sa panne depuis la fiche du site.
    ///
    /// On relit ensuite plutôt que d'adopter la panne renvoyée : sans `includeClosed`, la lecture
    /// par site ne rend que les états VISIBLES (cf. `OUTAGE_VISIBLE_STATES` dans
    /// `/api/community-outages`), donc la panne refermée en sort d'elle-même et le bloc retombe
    /// sur son invitation à signaler.
    private func closeOutage(_ outage: CommunityOutage) async {
        guard closingOutageId == nil else { return }
        closingOutageId = outage.id
        outageError = nil
        defer { closingOutageId = nil }
        do {
            _ = try await services.communityOutages.close(outageId: outage.id)
            onOutageChanged?()
        } catch {
            if !error.isCancellation { outageError = OutageWriteError.message(for: error) }
        }
        await loadOutages()
    }

    /// Les deux lectures EN PARALLÈLE, jamais l'une après l'autre.
    ///
    /// Elles n'ont ni la même source (PostgreSQL contre CSV d'opérateurs), ni la même durée, ni
    /// la même autorité. Les enchaîner ferait attendre les signalements de la communauté qu'un
    /// fichier d'opérateur veuille bien répondre — et un flux en erreur suffirait à vider un bloc
    /// que rien ne menaçait. Chacune échoue seule, en silence : un bandeau rouge sur une fiche
    /// par ailleurs saine coûterait plus qu'il n'informe.
    private func loadOutages() async {
        let siteId = site.siteId ?? site.id
        // Pannes de la communauté : lues sous la clé où elles s'écrivent (SEC-31).
        let outageSiteId = site.writeSiteId
        let kind = outageTargetKind
        let market = market
        let operatorKey = selectedOperator
        let latitude = site.latitude
        let longitude = site.longitude
        let outageService = services.communityOutages
        let mapService = services.map

        // `nil` = lecture ratée : on garde alors ce qui est affiché plutôt que de le vider, sinon
        // une panne en cours disparaîtrait de la fiche (et l'invitation à la signaler
        // réapparaîtrait) sur un simple accroc réseau.
        async let community: [CommunityOutage]? = try? await outageService.outages(
            forSiteId: outageSiteId,
            targetKind: kind,
            marketCode: market,
            operatorKey: operatorKey
        )
        async let operatorSide: [SiteOperatorIncident]? = {
            // La route exige la position du site : c'est la seule chose qui rapproche vraiment le
            // référentiel de l'opérateur de celui de l'ANFR (les codes de site ne concordent pas).
            guard let latitude, let longitude else { return [] }
            return (try? await mapService.operatorIncidents(
                forSiteId: siteId,
                market: market,
                operatorName: operatorKey,
                latitude: latitude,
                longitude: longitude,
                territory: nil
            ))?.incidents
        }()

        if let loaded = await community { outages = loaded }
        if let loaded = await operatorSide { operatorIncidents = loaded }
    }

    /// Le registre du marché, pour nommer l'opérateur d'un incident.
    ///
    /// `registry()` ne lève jamais et sert son cache mémoire dès le deuxième appel : la charger
    /// ici ne coûte un aller-retour qu'à la toute première fiche ouverte de la session.
    private func loadMarketEntry() async {
        guard marketEntry == nil else { return }
        marketEntry = await services.markets.registry().market(forCode: market)
    }

    /// Un site relevé par un membre n'a pas la même autorité qu'un site publié
    /// par un régulateur : la fiche le dit, avec qui l'a posé et s'il a été
    /// confirmé sur le terrain.
    @ViewBuilder
    private var contributionBanner: some View {
        if isCustomSite {
            let validated = model.details?.core?.validationStatus?.caseInsensitiveCompare("validated") == .orderedSame
                || customSite?.isValidated == true
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: validated ? "checkmark.seal.fill" : "clock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(validated ? SQColor.success : SQColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(validated
                         ? "Site relevé par un membre, confirmé sur le terrain"
                         : "Site relevé par un membre, pas encore confirmé")
                        .font(SQFont.body(13.5, .semibold))
                        .foregroundStyle(SQColor.label)
                    if let credit = contributionCredit {
                        Text(credit)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (validated ? SQColor.success : SQColor.warning).opacity(0.12),
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
        }
    }

    /// « Ajouté par X le 22 juillet 2026 » — l'un ou l'autre suffit.
    private var contributionCredit: String? {
        let author = customSite?.createdByDisplayName
        let date = customSite?.createdAt.map { SignalFormatters.date($0) }
        switch (author, date) {
        case let (author?, date?): return String(localized: "Ajouté par \(author) le \(date)")
        case let (author?, nil): return String(localized: "Ajouté par \(author)")
        case let (nil, date?): return String(localized: "Ajouté le \(date)")
        default: return nil
        }
    }

    /// Vrai dès que l'une des deux sources le dit : le marqueur le sait tout de
    /// suite, la fiche seulement une fois chargée.
    private var isCustomSite: Bool {
        customSite != nil || model.details?.core?.isCustomSite == true
    }

    /// Un site relevé porte un nom donné par son auteur ; un site officiel n'en
    /// a pas : son adresse le désigne mieux que le numéro du registre, qui reste
    /// dans le détail (UI-10).
    private var headerTitle: String {
        siteName ?? locationLine ?? String(localized: "Site \(site.siteId ?? site.id)")
    }

    private var siteName: String? {
        model.details?.core?.displayName ?? customSite?.name
    }

    /// Sous le titre : l'adresse quand le titre est un nom ; sinon ce qu'est le
    /// site, en mots.
    private var headerSubtitle: String? {
        if siteName != nil { return locationLine }
        if locationLine != nil {
            return site.operators.count > 1
                ? String(localized: "Antenne partagée par \(site.operators.count) opérateurs")
                : nil
        }
        return site.owner ?? String(localized: "Opérateurs inconnus")
    }

    /// Adresse lisible : celle de la fiche détaillée si elle est chargée, sinon
    /// celle portée par le marqueur.
    private var locationLine: String? {
        let candidate = model.details?.core?.fullAddress ?? site.address
        guard let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return candidate
    }

    /// Un pylône qui relaie en hertzien n'est pas un pylône comme un autre :
    /// c'est un nœud du réseau, pas seulement un point de desserte. L'info
    /// existait déjà, mais en « Oui » au fond de la section Technique repliée —
    /// autant dire nulle part. En pastille neutre : elle se lit avec les autres
    /// attributs du site sans se faire passer pour une technologie mobile.
    @ViewBuilder
    private var fhTag: some View {
        if model.details?.core?.hasFhLink == true {
            SQEditorialTag(text: String(localized: "Relais hertzien"), color: SQColor.labelSecondary)
        }
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

    /// Le repérage tient en une ligne (boussole, distance, cap, verdict de vue)
    /// et ouvre son propre écran : c'est la première question qu'on se pose
    /// devant un pylône, mais le détail n'intéresse que sur le terrain.
    private var sightCard: some View {
        NavigationLink {
            sightView(.screen)
        } label: {
            sightView(.summary)
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityHint("Ouvre l'écran de repérage")
        .accessibilityIdentifier("antenna.sight.open")
    }

    private func sightView(_ style: AntennaSightCard.Style) -> AntennaSightCard {
        AntennaSightCard(
            site: site,
            details: model.details,
            fallbackAzimuths: operatorAzimuths,
            location: services.location,
            origin: sightOrigin,
            tint: operatorColor,
            terrain: services.terrain,
            style: style,
            subtitle: headerTitle,
            onRoute: siteCoordinate.map { coordinate in { openRoute(to: coordinate) } }
        )
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
            .accessibilityLabel("Carte du site")
            .frame(height: 150)
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
            .overlay(alignment: .bottomTrailing) {
                if let originCoordinate = sightOrigin.coordinate(deviceLocation: services.location.cachedLocation()) {
                    let originLocation = CLLocation(latitude: originCoordinate.latitude, longitude: originCoordinate.longitude)
                    let siteLocation = CLLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                    let distance = originLocation.distance(from: siteLocation)
                    Text(SQUnits.distance(meters: distance))
                        .font(SQFont.archivo(12, .bold))
                        .foregroundStyle(SQColor.label)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, SQSpace.xs)
                        .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
                        .padding(SQSpace.sm)
                        .accessibilityLabel(sightOrigin.label + ". " + SQUnits.distance(meters: distance))
                }
            }
        }
    }

    private var siteCoordinate: CLLocationCoordinate2D? {
        if let core = model.details?.core, core.lat != 0 || core.lng != 0 {
            return CLLocationCoordinate2D(latitude: core.lat, longitude: core.lng)
        }
        guard site.hasValidCoordinate, let latitude = site.latitude, let longitude = site.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Secteurs de l'opérateur affiché. Le repli n'est PAS `site.azimuths` : sur
    /// un support partagé, la tuile n'y met que ceux du premier opérateur
    /// fusionné, et la fiche montrait donc les secteurs de SFR sous l'étiquette
    /// d'Orange le temps que le détail réponde — à chaque bascule.
    private var displayedAzimuths: [Double] {
        let core = model.details?.core?.azimuts ?? []
        return core.isEmpty ? operatorAzimuths : core
    }

    private var operatorAzimuths: [Double] {
        site.azimuths(for: selectedOperator)
    }

    /// Technologies de l'opérateur affiché.
    ///
    /// `site.technologies` est la FUSION du support : sur un site partagé, la
    /// fiche de Bouygues (5G seule ici) affichait « 5G 4G » parce qu'un voisin a
    /// de la 4G sur le même pylône. Le détail, lui, est déjà scopé opérateur ;
    /// tant qu'il n'a pas répondu, `operators5G` permet au moins de ne pas
    /// prêter la 5G d'un opérateur à un autre.
    private var displayedTechnologies: [String] {
        let core = model.details?.core?.technologies ?? []
        if !core.isEmpty { return core }
        guard !site.operators5G.isEmpty else { return site.technologies }
        let has5G = site.operators5G.contains { $0.caseInsensitiveCompare(selectedOperator) == .orderedSame }
        return has5G ? site.technologies : site.technologies.filter { $0 != "5G" }
    }

    // MARK: Secteurs & azimuts

    /// Le rayonnement du site : technologies, bandes, et — seulement quand les
    /// secteurs diffèrent réellement — la grille qui montre où est l'écart.
    private func sectorContent(_ details: AntennaDetails) -> some View {
        AntennaSectorGridView(
            azimuths: displayedAzimuths,
            siteBands: (details.core?.frequencyBands ?? []).isEmpty ? details.bands : (details.core?.frequencyBands ?? []),
            sectorSystems: details.core?.sectorSystems ?? [],
            fhBeams: details.core?.fhBeams ?? [],
            technologies: (details.core?.technologies ?? []).isEmpty ? details.technologies : (details.core?.technologies ?? []),
            projectBands: details.core?.technologiesInProject ?? [],
            antennaHeightMeters: details.core?.siteInfo.radiatingHeightMeters,
            tint: operatorColor
        )
        .foregroundStyle(SQColor.label)
    }

    // MARK: Identifiants

    /// Le registre : identité radio par secteur, faits du site, porteuses.
    @ViewBuilder
    private func identifiersTab(_ details: AntennaDetails) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if let core = details.core {
                section("Identifiants radio") {
                    factCard { radioIdentifiersContent(core) }
                }
                section("Site") {
                    factCard { siteContent(core) }
                }
                section("Technique") {
                    factCard { technicalContent(core) }
                }
                if !core.radioCarriers.isEmpty {
                    NavigationLink {
                        carriersPage(core)
                    } label: {
                        HStack(spacing: SQSpace.sm2) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(SQColor.labelSecondary)
                                .frame(width: 22)
                            Text("Porteuses (\(core.radioCarriers.count))")
                                .font(SQType.callout(.semibold))
                                .foregroundStyle(SQColor.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SQColor.labelTertiary)
                        }
                        .frame(minHeight: 48)
                        .padding(.horizontal, SQSpace.md)
                        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .accessibilityIdentifier("antenna.detail.carriers")
                }
            } else {
                SQNotice(message: "Aucun identifiant publié pour ce site.")
            }
        }
    }

    /// Les porteuses intéressent peu de monde et allongeaient la fiche : elles
    /// ont leur propre page.
    private func carriersPage(_ core: AntennaCoreDetails) -> some View {
        ScrollView {
            factCard { carriersContent(core) }
                .padding(SQSpace.lg)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .navigationTitle(Text("Porteuses"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func factCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    // MARK: Mesures

    private func measuresTab(_ details: AntennaDetails) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            communityContent(details)
            if !details.nearbySpeedtests.isEmpty {
                section("Speedtests proches") {
                    speedtestsContent(details)
                }
            }
            SQNotice(message: "Ces données radio viennent des mesures faites avec l’app Android et de sources publiques : un iPhone ne peut pas les relever.")
        }
    }

    private func communityContent(_ details: AntennaDetails) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            LazyVGrid(columns: columns, spacing: SQSpace.sm) {
                measureTile("Validations",
                            (details.validationsCount ?? (site.validationCount > 0 ? site.validationCount : nil)).map(String.init),
                            ink: true)
                measureTile("Mesures", details.signalStats.map { "\($0.measurementCount)" })
                measureTile("RSRP moyen", details.signalStats?.avgRsrp.map { "\(Int($0.rounded()))" }, unit: "dBm")
                measureTile("Speedtests", details.speedtestsCount.map(String.init))
            }
            if let stats = details.signalStats {
                factCard {
                    VStack(spacing: SQSpace.sm) {
                        detailRow("RSRQ moyen", SignalFormatters.db(stats.avgRsrq))
                        detailRow("SNR moyen", SignalFormatters.db(stats.avgSnr))
                        detailRow("TAC", stats.tac)
                        detailRow("Dernière mesure", SignalFormatters.date(stats.lastMeasurement, includingTime: true, relative: true))
                    }
                }
            }
        }
        .foregroundStyle(SQColor.label)
    }

    /// Tuile chiffrée ; la première (`ink`) est en encre, comme sur le web.
    private func measureTile(_ label: String, _ value: String?, unit: String? = nil, ink: Bool = false) -> some View {
        SQStatTile(label: label, value: value ?? "—", unit: value == nil ? nil : unit)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(SQSpace.sm2)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, ink ? (colorScheme == .dark ? .light : .dark) : colorScheme)
            .sqSurface(ink ? SQColor.label : SQColor.surface,
                       in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func siteContent(_ core: AntennaCoreDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                detailRow("Numéro du support", core.supId)
                // Le libellé suit le régulateur du marché : « Code ANFR » devant un
                // identifiant ISED ou OFCOM serait faux.
                detailRow(core.registryLabel, core.anfrCode.isEmpty ? nil : core.anfrCode,
                          term: !core.isCustomSite && ["FR", "DROM"].contains(core.market?.uppercased() ?? "") ? .anfr : nil)
                // « France » plutôt que « FR ».
                detailRow("Marché", core.market.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 })
                detailRow(core.localityLabel, [core.postalCode, core.commune].compactMap { $0 }.joined(separator: " "))
                detailRow("Adresse", core.address)
                detailRow("Partage", sharingDescription(core), term: .siteSharing)
                if leaderReport != nil {
                    // Demande d'Alexandre : l'opérateur porteur d'un site partagé se
                    // corrige depuis la fiche même, sans chercher le bon type.
                    Button {
                        Haptics.light()
                        reportInitialType = .incorrectLeader
                        showReportSheet = true
                    } label: {
                        Label("Opérateur porteur erroné ? Le signaler", systemImage: "exclamationmark.bubble")
                            .font(SQType.caption)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .tint(SQColor.accentInk)
                    .accessibilityIdentifier("antenna.report.leader")
                }
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
                detailRow("Technologies", core.technologies.joined(separator: " / "))
                if !core.technologiesInProject.isEmpty {
                    // Déclaré à l'ANFR mais pas allumé : la distinction n'était
                    // visible que sur le site web.
                    detailRow("En projet", core.technologiesInProject.joined(separator: " · "))
                }
                detailRow("Bandes", core.frequencyBands.joined(separator: " / "), term: .band)
                detailRow("Azimuts", core.azimuts.prefix(12).map { "\(Int($0.rounded()))°" }.joined(separator: " · "), term: .azimuth)
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
                detailRow("Secteurs", core.siteInfo.sectorCount.map(String.init), term: .sector)
                // « Oui » ne disait rien : ni combien, ni où. Quand le registre
                // publie les directions, on les donne ; sinon on garde le seul
                // fait connu, mais formulé — pas en booléen.
                detailRow(
                    "Faisceau hertzien",
                    core.fhBeams.isEmpty
                        ? core.technical.hasFh.map { $0 ? String(localized: "Oui, direction non publiée") : String(localized: "Aucun") }
                        : core.fhBeams.prefix(12).map { "\(Int($0.azimuth.rounded()))°" }.joined(separator: " · ")
                )
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
        // Un site relevé sur le terrain n'a pas de registre derrière lui : parler
        // du régulateur local ici serait faux.
        if core.isCustomSite || customSite != nil {
            return String(localized: "Site relevé sur le terrain par un membre : sa position et ses identifiants viennent d'un relevé, pas d'un registre. Hauteur, secteurs et azimuts ne sont donc pas connus.")
        }
        let registry: String
        switch core.market?.uppercased() {
        case "BE": registry = String(localized: "Le registre belge (BIPT)")
        case "CH": registry = String(localized: "Le registre suisse (OFCOM)")
        case "CA": registry = String(localized: "Le registre canadien (ISED)")
        default: registry = String(localized: "Le registre de ce pays")
        }
        return String(localized: "\(registry) publie la position et l'exploitant, mais ni hauteur, ni secteurs, ni azimuts : ces lignes resteront vides tant que la source ne les donnera pas.")
    }

    private func radioIdentifiersContent(_ core: AntennaCoreDetails) -> some View {
        AntennaRadioIdentifiersView(
            identifiers: core.cellIdentifiers,
            azimuths: displayedAzimuths,
            tint: operatorColor,
            operatorName: selectedOperator
        )
        .foregroundStyle(SQColor.label)
    }

    private func carriersContent(_ core: AntennaCoreDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                        ForEach(core.radioCarriers.prefix(10)) { carrier in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    SQEditorialTag(text: carrier.bandLabel ?? carrier.technology ?? String(localized: "Radio"), color: SQBrand.techColor(carrier.technology ?? ""))
                                    Spacer()
                                    Text(carrier.source ?? String(localized: "Officiel"))
                                        .font(SQType.micro)
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                                detailRow("Fréquences", [carrier.txFrequencyMhz.map { "\($0) MHz TX" }, carrier.rxFrequencyMhz.map { "\($0) MHz RX" }].compactMap { $0 }.joined(separator: " · "))
                                detailRow("Bande passante", carrier.bandwidthMhz.map { "\($0) MHz" })
                                detailRow("Bande passante utile", carrier.effectiveDownlinkBandwidthMhz.map { "\($0) MHz" })
                                detailRow("Part en réception", carrier.downlinkAllocationPercent.map { "\(Int($0.rounded())) %" })
                                detailRow("Puissance", carrier.txPowerDbm.map { "\($0) dBm" })
                                detailRow("Secteur", [carrier.sectorAzimuthDeg.map { "\(Int($0.rounded()))°" }, carrier.sectorBeamwidthDeg.map { "beam \(Int($0.rounded()))°" }, carrier.antennaType].compactMap { $0 }.joined(separator: " · "))
                                detailRow("Identifiants de cellule", carrier.cellIds.prefix(5).joined(separator: " · "), term: .cellIdentifiers)
                                detailRow("Identifiants physiques (PCI)", carrier.physicalIds.prefix(5).joined(separator: " · "))
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

    /// Débit en gras, le reste en dessous, la technologie à droite.
    private func speedtestsContent(_ details: AntennaDetails) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(details.nearbySpeedtests.prefix(5).enumerated()), id: \.element.id) { index, speed in
                HStack(spacing: SQSpace.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(SQUnits.throughputValue(mbps: speed.downloadMbps))
                                .font(SQFont.display(17, .heavy))
                                .monospacedDigit()
                                .foregroundStyle(SQColor.label)
                            Text(SQUnits.throughputUnit(mbps: speed.downloadMbps))
                                .font(SQType.caption(.semibold))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        Text(speedtestCaption(speed))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let tech = speed.tech, !tech.isEmpty {
                        MapTechTag(technology: tech, label: tech)
                    }
                }
                .frame(minHeight: 50)
                .accessibilityElement(children: .combine)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(SQColor.separator).frame(height: 1) }
                }
            }
        }
        .padding(.horizontal, SQSpace.md)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    /// « ↑ 41 Mb/s · 22 ms · hier » sous le débit descendant.
    private func speedtestCaption(_ speed: NearbySpeedtest) -> String {
        var parts: [String] = []
        if speed.uploadMbps != nil { parts.append("↑ " + SignalFormatters.speed(speed.uploadMbps)) }
        if speed.pingMs != nil { parts.append(SignalFormatters.ms(speed.pingMs)) }
        if let date = SignalFormatters.date(speed.timestamp, includingTime: true, relative: true) { parts.append(date) }
        return parts.joined(separator: " · ")
    }

    /// « Ajouter une photo » en tête, puis la galerie en grille de trois.
    private func photosContent(_ details: AntennaDetails) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: SQSpace.xs2), count: 3)
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            addPhotoContent
            if details.photos.isEmpty {
                SQNotice(message: "Aucune photo de ce site pour l’instant. La tienne sera la première.")
            } else {
                LazyVGrid(columns: columns, spacing: SQSpace.xs2) {
                    ForEach(details.photos) { photo in
                        Button {
                            Haptics.light()
                            viewerPhoto = photo
                        } label: {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    RemoteImage(url: photo.thumbnailUrl ?? photo.imageUrl, maxDimension: 240, contentMode: .fill, showsFailureUI: true) {
                                        SQColor.surfaceMuted
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Photo du site, toucher pour agrandir")
                    }
                }
            }
        }
        .foregroundStyle(SQColor.label)
    }

    /// « single », « crozon » et « zb » s'affichaient tels que le serveur les
    /// envoie (TRX-26).
    private func sharingDescription(_ core: AntennaCoreDetails) -> String? {
        switch core.sharingKind?.lowercased() {
        case "single":
            return String(localized: "Non partagé")
        case "crozon":
            guard let leader = core.crozonLeader else { return String(localized: "Réseau partagé SFR et Bouygues (Crozon)") }
            return String(localized: "Réseau partagé SFR et Bouygues (Crozon), opéré par \(photoOperatorLabel(leader))")
        case "zb":
            guard let leader = core.zbLeader else { return String(localized: "Zone blanche partagée") }
            return String(localized: "Zone blanche partagée, opérée par \(photoOperatorLabel(leader))")
        case "mutualise":
            // Métro, tunnels, gares : une antenne pour plusieurs opérateurs,
            // chacun avec son propre eNB.
            let names = core.mutualiseOperators.map(photoOperatorLabel)
            guard !names.isEmpty else { return String(localized: "Antenne mutualisée entre opérateurs") }
            return String(localized: "Mutualisée : \(names.formatted(.list(type: .and)))")
        case nil, "":
            return nil
        default:
            return core.sharingKind
        }
    }

    /// Ligne à points de conduite ; une valeur vide masque la ligne. `term` :
    /// ⓘ du glossaire à côté du libellé.
    @ViewBuilder
    private func detailRow(_ label: String, _ value: String?, term: SQTerm? = nil) -> some View {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalized.isEmpty, normalized != "—" {
            if let term {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    SQFactRow(label: label, value: normalized)
                    SQInfoButton(term: term)
                }
            } else {
                SQFactRow(label: label, value: normalized)
            }
        }
    }
}

/// Éventail des azimuts dessiné en Canvas : chaque secteur est un cône
/// orienté selon son azimut (0° = nord), coloré avec la couleur opérateur.
struct AzimuthFanView: View {
    let azimuths: [Double]
    /// Faisceaux hertziens : mêmes directions, tout autre métier. Un secteur
    /// arrose un quartier, un FH vise une seule antenne à des kilomètres. Les
    /// dessiner en cône coloré comme les autres laisserait croire à de la
    /// couverture ; les taire laissait un pylône dont on ne comprend pas la
    /// moitié des paraboles.
    var fhAzimuths: [Double] = []
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

            // Faisceaux hertziens : une aiguille, pas un cône. Un trait fin qui
            // part du centre, franchit le cercle — le lien continue bien au-delà
            // du site — et se termine par une courte barre perpendiculaire : la
            // parabole vue de côté. Aucune icône, juste la géométrie du bond.
            for azimuth in fhAzimuths.prefix(8) {
                let radians = (azimuth - 90) * .pi / 180
                let dx = CGFloat(cos(radians))
                let dy = CGFloat(sin(radians))
                let tip = CGPoint(x: center.x + dx * (radius + 7), y: center.y + dy * (radius + 7))

                var needle = Path()
                needle.move(to: CGPoint(x: center.x + dx * 5, y: center.y + dy * 5))
                needle.addLine(to: tip)
                context.stroke(
                    needle,
                    with: .color(color.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 2.5])
                )

                // La barre du bout, perpendiculaire à l'axe : elle donne
                // l'échelle du trait et le distingue au premier coup d'œil.
                var dish = Path()
                dish.move(to: CGPoint(x: tip.x - dy * 4.5, y: tip.y + dx * 4.5))
                dish.addLine(to: CGPoint(x: tip.x + dy * 4.5, y: tip.y - dx * 4.5))
                context.stroke(
                    dish,
                    with: .color(color.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )
            }

            // Point central (le support)
            let dot = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
            context.fill(dot, with: .color(color))
        }
        .accessibilityLabel(fhAzimuths.isEmpty
            ? Text("Éventail des azimuts des secteurs")
            : Text("Éventail des azimuts : \(azimuths.count) secteurs et \(fhAzimuths.count) faisceaux hertziens"))
    }
}

/// Les quatre onglets de la fiche antenne.
private enum AntennaDetailTab: Hashable, CaseIterable {
    case essential, identifiers, measures, photos
}
