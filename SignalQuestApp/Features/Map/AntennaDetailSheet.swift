import SwiftUI
import PhotosUI
import UIKit

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
            // Recompression hors du main thread pour ne pas geler l'UI à l'upload.
            guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
                Self.preparedJPEG(from: raw)
            }).value else {
                photoUploadMessage = "Image illisible."
                return
            }
            _ = try await photos.uploadPhoto(
                data: jpeg,
                siteId: siteId,
                description: nil,
                anfrCode: anfrCode,
                operatorName: operatorName == "ALL" ? nil : operatorName
            )
            Haptics.success()
            photoUploadMessage = "Photo envoyée — merci ! Elle apparaîtra après validation."
            await load(id: siteId, market: market, operatorName: operatorName, anfrCode: anfrCode)
        } catch {
            Haptics.error()
            photoUploadMessage = error.localizedDescription
        }
    }

    /// Recompresse en JPEG ≤ 1600 px qualité 0,85 (HEIC converti d'office).
    nonisolated private static func preparedJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let largest = max(image.size.width, image.size.height)
        let scale = largest > maxSide ? maxSide / largest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.85)
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
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let details = model.details {
                        techGrid(details)
                        let sectors = sectorInfos(details)
                        if !sectors.isEmpty {
                            sectorFanCard(sectors)
                        }
                        validationsSection(details)
                        androidParitySections(details)
                    } else if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(SQColor.danger)
                    } else {
                        ProgressView().tint(SQColor.brandRed).frame(maxWidth: .infinity)
                    }
                    if let address = site.address {
                        Label(address, systemImage: "mappin")
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.label)
                            .sqSheetCard()
                    }
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

    /// Carte « Ajouter une photo » : disponible quelle que soit la présence de
    /// photos existantes. Réutilise `PhotoService.uploadPhoto` (siteId/anfr/opérateur).
    private var addPhotoCard: some View {
        let uploading = model.isUploadingPhoto
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            AntennaSectionHeader(kicker: "Contribuer", title: "Ajouter une photo", systemImage: "camera")
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                HStack(spacing: SQSpace.sm) {
                    if uploading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "camera.fill").font(.system(size: 15, weight: .bold))
                    }
                    Text(uploading ? "Envoi…" : "Choisir une photo du site")
                        .font(SQType.button)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SQSpace.md)
                .foregroundStyle(.white)
                .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            }
            .disabled(model.isUploadingPhoto)
            if let message = model.photoUploadMessage {
                Text(message)
                    .font(SQType.caption)
                    .foregroundStyle(message.contains("merci") ? SQColor.success : SQColor.danger)
            }
        }
        .foregroundStyle(SQColor.label)
        .sqSheetCard()
    }

    /// Couleur de l'opérateur affiché (utilisée par l'éventail d'azimuts).
    private var operatorColor: Color {
        SQBrand.operatorColor(selectedOperator)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 44, height: 44)
                    .background(SQColor.brandRed.opacity(0.10), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .stroke(SQColor.brandRed.opacity(0.32), lineWidth: 1.5)
                    }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Fiche site").sqKicker()
                    Text("Site \(site.siteId ?? site.id)")
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                    Text(site.owner ?? "Opérateurs inconnus")
                        .font(SQFont.archivo(13, .medium))
                        .foregroundStyle(SQColor.labelSecondary)
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
                }
                .padding(.vertical, 1)
            }
        }
    }

    /// Tag opérateur. Sur un site partagé, il devient un bouton de bascule :
    /// l'opérateur actif est en plein (fond couleur, texte blanc), les autres en
    /// version atténuée. Sur un site mono-opérateur, simple tag éditorial.
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
                    .font(SQType.micro)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .padding(.horizontal, SQSpace.sm)
                    .padding(.vertical, SQSpace.xs + 1)
                    .foregroundStyle(isActive ? Color.white : color)
                    .background(
                        (isActive ? color : color.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                            .stroke(color.opacity(isActive ? 0 : 0.45), lineWidth: 1)
                    }
                    .opacity(isActive ? 1 : 0.85)
            }
            .buttonStyle(SQPressButtonStyle())
        } else {
            SQEditorialTag(text: op, color: color)
        }
    }

    private func techGrid(_ details: AntennaDetails) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            CardMetricTile(label: "Validations", value: details.validationsCount.map(String.init) ?? "—", highlight: true)
            CardMetricTile(label: "Photos", value: details.photosCount.map(String.init) ?? "—")
            CardMetricTile(label: "Speedtests", value: details.speedtestsCount.map(String.init) ?? "—")
            CardMetricTile(label: "Hauteur", value: details.height.map { "\(Int($0)) m" } ?? "—")
            CardMetricTile(label: "Bandes", value: details.bands.prefix(4).joined(separator: " / ").isEmpty ? "—" : details.bands.prefix(4).joined(separator: " / "))
            CardMetricTile(label: "Secteurs", value: details.sectors.prefix(4).map(String.init).joined(separator: " · ").isEmpty ? "—" : details.sectors.prefix(4).map(String.init).joined(separator: " · "))
        }
    }

    // MARK: Secteurs & azimuts

    /// Construit la liste des secteurs : porteuses radio groupées par azimut
    /// quand elles existent, sinon azimuts bruts avec les technos/bandes du site.
    private func sectorInfos(_ details: AntennaDetails) -> [SectorDisplayInfo] {
        let carriers = (details.core?.radioCarriers ?? []).filter { $0.sectorAzimuthDeg != nil }
        if !carriers.isEmpty {
            let grouped = Dictionary(grouping: carriers) { Int(($0.sectorAzimuthDeg ?? 0).rounded()) }
            return grouped.keys.sorted().map { azimuth in
                let items = grouped[azimuth] ?? []
                var techs: [String] = []
                var bands: [String] = []
                for item in items {
                    if let tech = item.technology, !techs.contains(tech) {
                        techs.append(tech)
                    }
                    if let band = item.bandLabel ?? item.band.map({ "B\($0)" }), !bands.contains(band) {
                        bands.append(band)
                    }
                }
                return SectorDisplayInfo(
                    id: "sector-\(azimuth)",
                    azimuth: Double(azimuth),
                    technologies: techs,
                    bands: bands
                )
            }
        }
        let coreAzimuts = details.core?.azimuts ?? []
        let azimuths = coreAzimuts.isEmpty ? site.azimuths : coreAzimuts
        guard !azimuths.isEmpty else { return [] }
        return azimuths.enumerated().map { index, azimuth in
            SectorDisplayInfo(
                id: "sector-\(index)-\(Int(azimuth.rounded()))",
                azimuth: azimuth,
                technologies: details.technologies,
                bands: Array(details.bands.prefix(4))
            )
        }
    }

    private func sectorFanCard(_ sectors: [SectorDisplayInfo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AntennaSectionHeader(kicker: "Rayonnement", title: "Secteurs & azimuts", systemImage: "safari")
            AzimuthFanView(azimuths: sectors.map(\.azimuth), color: operatorColor)
                .frame(height: 190)
                .frame(maxWidth: .infinity)
            ForEach(sectors.prefix(8)) { sector in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(operatorColor)
                            .frame(width: 7, height: 7)
                        Text("Secteur \(Int(sector.azimuth.rounded()))°")
                            .font(SQFont.archivo(12, .bold))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    if !sector.technologies.isEmpty || !sector.bands.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: SQSpace.xs + 2) {
                                ForEach(sector.technologies, id: \.self) { tech in
                                    SQEditorialTag(text: tech, color: SQBrand.techColor(tech))
                                }
                                ForEach(sector.bands, id: \.self) { band in
                                    SQEditorialTag(text: band, color: SQColor.labelSecondary)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
        .foregroundStyle(SQColor.label)
        .sqSheetCard()
    }

    // MARK: Validations

    private func validationsSection(_ details: AntennaDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AntennaSectionHeader(kicker: "Communauté", title: "Validations communautaires", systemImage: "checkmark.seal")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                CardMetricTile(label: "Validations", value: details.validationsCount.map(String.init) ?? "—", highlight: true)
                CardMetricTile(label: "Mesures", value: details.signalStats.map { "\($0.measurementCount)" } ?? "—")
            }
            detailRow("Dernière activité", details.signalStats?.lastMeasurement)
        }
        .foregroundStyle(SQColor.label)
        .sqSheetCard(strong: true)
    }

    @ViewBuilder
    private func androidParitySections(_ details: AntennaDetails) -> some View {
        if let core = details.core {
            VStack(alignment: .leading, spacing: 12) {
                AntennaSectionHeader(kicker: "Localisation", title: "Site", systemImage: "mappin.and.ellipse")
                detailRow("SUP ID", core.supId)
                detailRow("ANFR / source", core.anfrCode.isEmpty ? nil : core.anfrCode)
                detailRow("Marché", core.market)
                detailRow("Commune", [core.postalCode, core.commune].compactMap { $0 }.joined(separator: " "))
                detailRow("Adresse", core.address)
                detailRow("Partage", [core.sharingKind, core.crozonLeader.map { "Crozon \($0)" }, core.zbLeader.map { "ZB \($0)" }].compactMap { $0 }.joined(separator: " · "))
                detailRow("Coordonnées", String(format: "%.5f, %.5f", core.lat, core.lng))
            }
            .foregroundStyle(SQColor.label)
            .sqSheetCard()

            VStack(alignment: .leading, spacing: 12) {
                AntennaSectionHeader(kicker: "Technique", title: "Technique", systemImage: "antenna.radiowaves.left.and.right")
                detailRow("Technos", core.technologies.joined(separator: " / "))
                detailRow("Bandes", core.frequencyBands.joined(separator: " / "))
                detailRow("Azimuts", core.azimuts.prefix(12).map { "\(Int($0.rounded()))°" }.joined(separator: " · "))
                detailRow("Support", core.siteInfo.supportType ?? core.technical.supportType)
                detailRow("Hauteur support", core.siteInfo.supportHeight)
                detailRow("Propriétaire", core.siteInfo.supportOwner ?? core.rawLicenseeName)
                detailRow("Secteurs", core.siteInfo.sectorCount.map(String.init))
                detailRow("FH", core.technical.hasFh.map { $0 ? "Oui" : "Non" })
                detailRow("Première activation", core.siteInfo.firstActivation)
                detailRow("Dernière mise en service", core.siteInfo.lastCommissioned)
            }
            .foregroundStyle(SQColor.label)
            .sqSheetCard()

            if !core.cellIdentifiers.enb.isEmpty || !core.cellIdentifiers.gnb.isEmpty || !core.cellIdentifiers.pci.isEmpty || !core.cellIdentifiers.cellId.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                        AntennaSectionHeader(kicker: "Réseau", title: "Identifiants serveur", systemImage: "number")
                        detailRow("eNB", core.cellIdentifiers.enb.prefix(8).joined(separator: " · "))
                        detailRow("gNB", core.cellIdentifiers.gnb.prefix(8).joined(separator: " · "))
                        if !core.cellIdentifiers.pci.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("PCI")
                                    .font(SQType.micro)
                                    .tracking(0.6)
                                    .textCase(.uppercase)
                                    .foregroundStyle(SQColor.labelTertiary)
                                ForEach(core.cellIdentifiers.pci.prefix(8)) { pci in
                                    detailRow(
                                        pci.value,
                                        [pci.tech, pci.band.map { "B\($0)" }, pci.sector.map { "secteur \($0)" }, pci.frequency].compactMap { $0 }.joined(separator: " · ")
                                    )
                                }
                            }
                        }
                        if !core.cellIdentifiers.cellId.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Cell ID")
                                    .font(SQType.micro)
                                    .tracking(0.6)
                                    .textCase(.uppercase)
                                    .foregroundStyle(SQColor.labelTertiary)
                                ForEach(core.cellIdentifiers.cellId.prefix(8)) { cell in
                                    detailRow(
                                        cell.value,
                                        [cell.tech, cell.band.map { "B\($0)" }, cell.pci.map { "PCI \($0)" }, cell.earfcn.map { "EARFCN \($0)" }, cell.arfcn.map { "ARFCN \($0)" }].compactMap { $0 }.joined(separator: " · ")
                                    )
                                }
                            }
                        }
                    }
                    .foregroundStyle(SQColor.label)
                .sqSheetCard()
            }

            if !core.radioCarriers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                        AntennaSectionHeader(kicker: "Spectre", title: "Porteuses radio", systemImage: "dot.radiowaves.left.and.right")
                        ForEach(core.radioCarriers.prefix(10)) { carrier in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    SQEditorialTag(text: carrier.bandLabel ?? carrier.technology ?? "Radio", color: SQBrand.techColor(carrier.technology ?? ""))
                                    Spacer()
                                    Text(carrier.source ?? "Backend")
                                        .font(SQType.micro)
                                        .tracking(0.6)
                                        .textCase(.uppercase)
                                        .foregroundStyle(SQColor.labelTertiary)
                                }
                                detailRow("Fréquences", [carrier.txFrequencyMhz.map { "\($0) MHz TX" }, carrier.rxFrequencyMhz.map { "\($0) MHz RX" }].compactMap { $0 }.joined(separator: " · "))
                                detailRow("Bande passante", carrier.bandwidthMhz.map { "\($0) MHz" })
                                detailRow("DL effectif", carrier.effectiveDownlinkBandwidthMhz.map { "\($0) MHz" })
                                detailRow("Allocation DL", carrier.downlinkAllocationPercent.map { "\(Int($0.rounded())) %" })
                                detailRow("Puissance", carrier.txPowerDbm.map { "\($0) dBm" })
                                detailRow("Secteur", [carrier.sectorAzimuthDeg.map { "\(Int($0.rounded()))°" }, carrier.sectorBeamwidthDeg.map { "beam \(Int($0.rounded()))°" }, carrier.antennaType].compactMap { $0 }.joined(separator: " · "))
                                detailRow("Cell IDs", carrier.cellIds.prefix(5).joined(separator: " · "))
                                detailRow("Physical IDs", carrier.physicalIds.prefix(5).joined(separator: " · "))
                                detailRow("Mise à jour", carrier.dateLastChanged)
                            }
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(SQColor.separator).frame(height: 1).opacity(0.5)
                            }
                        }
                    }
                    .foregroundStyle(SQColor.label)
                .sqSheetCard()
            }
        }

        if let stats = details.signalStats {
            VStack(alignment: .leading, spacing: 12) {
                AntennaSectionHeader(kicker: "Mesures", title: "Mesures communautaires", systemImage: "waveform.path.ecg")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    CardMetricTile(label: "RSRP moy.", value: SignalFormatters.dbm(stats.avgRsrp), highlight: true)
                    CardMetricTile(label: "RSRQ moy.", value: SignalFormatters.db(stats.avgRsrq))
                    CardMetricTile(label: "SNR moy.", value: SignalFormatters.db(stats.avgSnr))
                    CardMetricTile(label: "Mesures", value: "\(stats.measurementCount)")
                }
                detailRow("TAC", stats.tac)
                detailRow("Dernière mesure", stats.lastMeasurement)
            }
            .foregroundStyle(SQColor.label)
            .sqSheetCard()
        }

        if !details.nearbySpeedtests.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AntennaSectionHeader(kicker: "Débits", title: "Speedtests proches", systemImage: "speedometer")
                ForEach(details.nearbySpeedtests.prefix(5)) { speed in
                    detailRow(
                        SignalFormatters.speed(speed.downloadMbps),
                        [
                            SignalFormatters.speed(speed.uploadMbps),
                            SignalFormatters.ms(speed.pingMs),
                            speed.tech,
                            speed.timestamp
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                }
            }
            .foregroundStyle(SQColor.label)
            .sqSheetCard()
        }

        if !details.photos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AntennaSectionHeader(kicker: "Galerie", title: "Photos du site", systemImage: "photo.on.rectangle")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(details.photos.prefix(8)) { photo in
                            Button {
                                Haptics.light()
                                viewerPhoto = photo
                            } label: {
                                AsyncImage(url: photo.thumbnailUrl ?? photo.imageUrl) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        SQColor.fill
                                    }
                                }
                                .frame(width: 110, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                                        .stroke(SQColor.separator, lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Photo du site, toucher pour agrandir")
                        }
                    }
                }
            }
            .foregroundStyle(SQColor.label)
            .sqSheetCard()
        }

        // Toujours proposer la contribution d'une photo (avec ou sans galerie).
        addPhotoCard

        Text("Les données radio affichées ici viennent du backend SignalQuest, d’Android ou de sources publiques. iOS ne collecte pas ces métriques.")
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
    }

    private func detailRow(_ label: String, _ value: String?) -> some View {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(SQType.micro)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelTertiary)
            Spacer(minLength: SQSpace.md)
            Text((normalized?.isEmpty == false ? normalized : "—") ?? "—")
                .font(SQFont.archivo(13, .semibold))
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, SQSpace.sm - 1)
        .padding(.horizontal, SQSpace.sm + 2)
        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
    }
}

/// Carte éditoriale de la fiche antenne : surface à plat, coins nets, bordure
/// fine encre (module imprimé). Remplace l'ancien GlassCard glassmorphique.
/// Entrée fondu-translation douce au scroll (`sqFadeUp`, respecte Reduce Motion).
private extension View {
    func sqSheetCard(strong: Bool = false) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.lg)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .stroke(strong ? SQColor.label : SQColor.separator, lineWidth: strong ? 2 : 1.5)
            }
            .sqFadeUp()
    }
}

/// En-tête de section de la fiche antenne : kicker rouge + titre Archivo
/// SemiBold, icône rouge — remplace les `Label(...).font(.headline)`.
private struct AntennaSectionHeader: View {
    let kicker: String
    let title: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text(kicker).sqKicker()
            Label(title, systemImage: systemImage)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Secteur affiché dans la fiche : azimut + technologies/bandes associées.
private struct SectorDisplayInfo: Identifiable {
    let id: String
    let azimuth: Double
    let technologies: [String]
    let bands: [String]
}

/// Éventail des azimuts dessiné en Canvas : chaque secteur est un cône
/// orienté selon son azimut (0° = nord), coloré avec la couleur opérateur.
private struct AzimuthFanView: View {
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
                    AsyncImage(url: photo.imageUrl ?? photo.thumbnailUrl) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFit()
                        } else if phase.error != nil {
                            Label("Photo indisponible", systemImage: "photo.badge.exclamationmark")
                                .foregroundStyle(.white.opacity(0.7))
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
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
