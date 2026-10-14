import MapKit
import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

/// Identification EN CHAÎNE — « identifier les 12 sites de cette liste ».
///
/// Le bouton n'ouvre pas douze fois le même écran : il ouvre UNE file. On
/// identifie, on passe au suivant, et la position dans la file est visible en
/// permanence — on sait toujours combien il en reste, et on sort quand on veut.
struct RadioLogIdentifyChainView: View {
    let sites: [RadioLogSite]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var picker: RadioLogIdentifyPicker
    @State private var index = 0
    @State private var identifiedCount = 0
    @State private var skippedIds: Set<String> = []
    @State private var showsMapPicker = false
    @State private var showsConfirmation = false
    private let antennas: AntennasServicing
    private let customSites: CustomSitesServicing?
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.5),
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
    )
    let onIdentified: (RadioLogSite, String) -> Void

    init(
        sites: [RadioLogSite],
        service: RadioLogsServicing,
        identify: IdentifyServicing,
        antennas: AntennasServicing,
        customSites: CustomSitesServicing? = nil,
        onIdentified: @escaping (RadioLogSite, String) -> Void
    ) {
        self.sites = sites
        self.antennas = antennas
        self.customSites = customSites
        self.onIdentified = onIdentified
        _picker = StateObject(
            wrappedValue: RadioLogIdentifyPicker(service: service, identify: identify, antennas: antennas)
        )
    }

    private var current: RadioLogSite? {
        guard index >= 0, index < sites.count else { return nil }
        return sites[index]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let current {
                    card(for: current)
                } else {
                    completionState
                }
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle(current == nil ? String(localized: "Terminé") : String(localized: "\(index + 1) sur \(sites.count)"))
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                if identifiedCount > 0 {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Text(String(localized: "\(identifiedCount) identifié"))
                            .font(SQFont.body(12, .bold))
                            .monospacedDigit()
                            .foregroundStyle(P.okInk)
                            .accessibilityIdentifier("radioLogs.chain.identified")
                    }
                }
            }
        }
    }

    // MARK: La carte de file

    private func card(for site: RadioLogSite) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                progressBar

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    HStack(spacing: SQSpace.sm) {
                        Text(site.nodeLabel)
                            .font(.sqTechnical(M.siteIdSize, .semibold))
                            .tracking(M.siteIdTracking)
                            .foregroundStyle(P.ink)
                        RadioLogTechBadge(label: site.techLabel)
                        Spacer(minLength: 0)
                    }
                    Text(metaLine(for: site))
                        .font(SQFont.body(M.siteMetaSize))
                        .monospacedDigit()
                        .foregroundStyle(P.muted)

                    let pciLabels = site.distinctPciLabels
                    if !pciLabels.isEmpty {
                        FlowLayoutCompat(spacing: M.pillsGap) {
                            ForEach(pciLabels.prefix(5), id: \.self) { label in
                                RadioLogPill(label: label)
                            }
                            if let bandLabel = site.band.map({ SQUnits.band($0, technology: site.techLabel) }) {
                                RadioLogPill(label: bandLabel)
                            }
                        }
                    }
                }

                if site.hasCoordinate {
                    SQRegionMap(region: $region, items: pins(for: site)) { pin in
                        MapAnnotation(coordinate: pin.coordinate) {
                            Image(systemName: pin.isOrigin ? "dot.scope" : "antenna.radiowaves.left.and.right")
                                .font(.system(size: pin.isOrigin ? 18 : 14, weight: .bold))
                                .foregroundStyle(pin.isSelected ? P.onAccent : (pin.isOrigin ? P.ink : P.accentInk))
                                .padding(6)
                                .background(
                                    pin.isSelected ? AnyShapeStyle(P.accent) : AnyShapeStyle(P.card),
                                    in: Circle()
                                )
                                .sqShadowSoft()
                        }
                    }
                    .frame(height: M.chainMapHeight)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    .accessibilityHidden(true)
                }

                candidateSection(for: site)

                HStack(spacing: M.ctaGap) {
                    GradientButton(String(localized: "Passer"), style: .secondary) { advance(skipped: true) }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("radioLogs.chain.skip")
                    GradientButton(String(localized: "Identifier ici"), isBusy: picker.isSubmitting) {
                        // Sans choix, l'envoi dit lui-même qu'il manque une antenne.
                        if picker.selectedCandidate == nil {
                            Task { await identifyCurrent(site) }
                        } else {
                            showsConfirmation = true
                        }
                    }
                    // Rien à identifier tant que les antennes de CE site arrivent.
                    .disabled(picker.isLoading)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("radioLogs.chain.identify")
                }
                .disabled(picker.isSubmitting)
            }
            .padding(.horizontal, M.sheetPaddingH)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, M.sheetPaddingBottom)
        }
        .task(id: site.id) {
            recenter(on: site)
            await picker.load(for: site)
            recenterOnSelection()
        }
        .alert("Identifier ce site ?", isPresented: $showsConfirmation, presenting: picker.selectedCandidate) { _ in
            Button("Annuler", role: .cancel) {}
            Button("Identifier") { Task { await identifyCurrent(site) } }
        } message: { candidate in
            Text(RadioLogIdentifyPicker.confirmationMessage(nodeLabel: site.nodeLabel, siteId: candidate.siteId, address: candidate.address))
        }
        .sheet(isPresented: $showsMapPicker) {
            RadioLogSiteMapPicker(site: site, picker: picker, antennas: antennas, customSites: customSites) { siteId in
                // Dans la file, on enchaîne : le site suivant est ce qu'on attend.
                onIdentified(site, siteId)
                identifiedCount += 1
                advance(skipped: false)
            }
        }
    }

    /// L'avancement : un segment par site, vert une fois identifié, gris foncé
    /// s'il a été passé, en accent pour le site en cours. Au-delà d'une vingtaine, des segments deviendraient un
    /// trait indéchiffrable : une barre continue prend le relais.
    private var progressBar: some View {
        Group {
            if sites.count <= 20 {
                HStack(spacing: 4) {
                    ForEach(0..<sites.count, id: \.self) { position in
                        Capsule()
                            .fill(segmentColor(at: position))
                            .frame(height: 6)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(P.barTrack)
                        Capsule()
                            .fill(P.accent)
                            .frame(width: proxy.size.width * CGFloat(index + 1) / CGFloat(max(sites.count, 1)))
                    }
                }
                .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index + 1) sur \(sites.count)")
    }

    private func segmentColor(at position: Int) -> Color {
        if position == index { return P.accent }
        guard position < index else { return P.barTrack }
        return skippedIds.contains(sites[position].id) ? P.muted.opacity(0.55) : P.okInk
    }

    @ViewBuilder
    private func candidateSection(for site: RadioLogSite) -> some View {
        if let blocking = RadioLogIdentifyPicker.blockingReason(for: site) {
            noticeBanner(blocking, tint: SQColor.warning, soft: SQColor.warningSoft)
        } else if picker.isLoading {
            HStack(spacing: SQSpace.sm) {
                SQSpinner()
                Text("Recherche des antennes voisines…")
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
            }
            .padding(.vertical, SQSpace.sm)
        } else {
            if picker.candidates.isEmpty {
                noticeBanner(
                    picker.errorMessage ?? String(localized: "Aucune antenne connue à proximité."),
                    tint: picker.searchFailed ? SQColor.dangerInk : P.muted,
                    soft: picker.searchFailed ? SQColor.dangerSoft : P.chip
                )
                if picker.searchFailed {
                    Button("Réessayer") { Task { await picker.load(for: site) } }
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                }
            }
            // Trois candidats au plus : au-delà, on ne choisit plus, on parcourt —
            // et la file perd son intérêt. La feuille unitaire reste là pour qui
            // veut la liste complète.
            RadioLogCandidateCard(
                candidates: Array(picker.candidates.prefix(3)),
                selectedId: picker.selectedId,
                mapLabel: "Choisir sur la carte",
                onSelect: { candidate in
                    picker.selectedId = candidate.id
                    recenterOnSelection()
                },
                onOpenMap: { showsMapPicker = true }
            )
            if !picker.candidates.isEmpty, let errorMessage = picker.errorMessage {
                noticeBanner(errorMessage, tint: SQColor.dangerInk, soft: SQColor.dangerSoft)
            }
        }
    }

    private var completionState: some View {
        VStack(spacing: SQSpace.lg) {
            EmptyStateView(
                title: identifiedCount > 0 ? "File terminée" : "Rien d'identifié",
                message: summaryMessage,
                systemImage: identifiedCount > 0 ? "checkmark.seal.fill" : "list.bullet"
            )
            Button("Fermer") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(P.accent)
                .foregroundStyle(P.onAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SQSpace.lg)
    }

    private var summaryMessage: String {
        var parts: [String] = []
        parts.append(String(localized: "\(identifiedCount) site identifié"))
        if !skippedIds.isEmpty {
            parts.append(String(localized: "\(skippedIds.count) passé"))
        }
        return parts.joined(separator: " · ") + "."
    }

    // MARK: Actions

    private func identifyCurrent(_ site: RadioLogSite) async {
        // Un échec laisse la file EN PLACE, avec son message : passer au suivant
        // masquerait l'erreur et l'utilisateur croirait avoir identifié.
        guard let siteId = await picker.submit(site: site) else { return }
        onIdentified(site, siteId)
        identifiedCount += 1
        advance(skipped: false)
    }

    private func advance(skipped: Bool) {
        if skipped, let current { skippedIds.insert(current.id) }
        picker.selectedId = nil
        picker.errorMessage = nil
        index += 1
        Haptics.selection()
    }

    private func metaLine(for site: RadioLogSite) -> String {
        [site.operatorName ?? String(localized: "Opérateur inconnu"),
         site.compositionLabel,
         String(localized: "\(site.logCount) relevé")]
            .joined(separator: " · ")
    }

    private func noticeBanner(_ message: String, tint: Color, soft: Color) -> some View {
        Text(message)
            .font(SQType.caption)
            .foregroundStyle(tint)
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(soft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    // MARK: Carte

    private struct ChainPin: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let isOrigin: Bool
        let isSelected: Bool
    }

    private func pins(for site: RadioLogSite) -> [ChainPin] {
        var pins: [ChainPin] = []
        if let latitude = site.latitude, let longitude = site.longitude {
            pins.append(
                ChainPin(
                    id: "origin",
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: true,
                    isSelected: false
                )
            )
        }
        for candidate in picker.candidates.prefix(3) {
            guard let latitude = candidate.latitude, let longitude = candidate.longitude else { continue }
            pins.append(
                ChainPin(
                    id: candidate.id,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: false,
                    isSelected: candidate.id == picker.selectedId
                )
            )
        }
        return pins
    }

    private func recenter(on site: RadioLogSite) {
        guard let latitude = site.latitude, let longitude = site.longitude else { return }
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
    }

    private func recenterOnSelection() {
        guard let selectedId = picker.selectedId,
              let candidate = picker.candidates.first(where: { $0.id == selectedId }),
              let latitude = candidate.latitude,
              let longitude = candidate.longitude
        else { return }
        region.center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
