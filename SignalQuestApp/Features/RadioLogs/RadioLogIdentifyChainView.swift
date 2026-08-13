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
            .navigationTitle(current == nil ? "Terminé" : "\(index + 1) sur \(sites.count)")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    // MARK: La carte de file

    private func card(for site: RadioLogSite) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                progressHeader

                VStack(alignment: .leading, spacing: 0) {
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
                        .clipShape(RoundedRectangle(cornerRadius: M.chainMapRadius, style: .continuous))
                        .accessibilityHidden(true)
                        .padding(.bottom, M.cardInnerGap)
                    }

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
                        .padding(.top, 5)

                    let pciLabels = site.distinctPciLabels
                    if !pciLabels.isEmpty {
                        FlowLayoutCompat(spacing: M.pillsGap) {
                            ForEach(pciLabels.prefix(5), id: \.self) { label in
                                RadioLogPill(label: label)
                            }
                            if let bandLabel = site.band.map({ "B\($0)" }) {
                                RadioLogPill(label: bandLabel)
                            }
                        }
                        .padding(.top, M.pillsTop)
                    }

                    candidateSection(for: site)

                    Button {
                        showsMapPicker = true
                        Haptics.selection()
                    } label: {
                        HStack(spacing: SQSpace.sm) {
                            Image(systemName: "map").font(.system(size: 13, weight: .semibold))
                            Text("Choisir une autre antenne sur la carte")
                                .font(SQFont.body(M.siteMetaSize, .semibold))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(P.accentInk)
                        .padding(.horizontal, M.buttonPaddingH)
                        .padding(.vertical, M.buttonPaddingV)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(P.accentSoft, in: RoundedRectangle(cornerRadius: M.buttonRadius, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, M.ctaTop)

                    HStack(spacing: M.ctaGap) {
                        RadioLogActionButton(label: picker.isSubmitting ? "…" : "Identifier ici") {
                            Task { await identifyCurrent(site) }
                        }
                        RadioLogActionButton(label: "Passer", ghost: true) { advance(skipped: true) }
                    }
                    .padding(.top, M.ctaGap)
                    .disabled(picker.isSubmitting)
                }
                .padding(M.chainCardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(P.card, in: RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous))
                .sqShadowCard()

                dots
            }
            .padding(.horizontal, M.sheetPaddingH)
            .padding(.bottom, M.sheetPaddingBottom)
        }
        .task(id: site.id) {
            recenter(on: site)
            await picker.load(for: site)
            recenterOnSelection()
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

    private var progressHeader: some View {
        HStack(spacing: SQSpace.md) {
            Text("\(index + 1) sur \(sites.count)")
                .font(SQFont.body(M.chainCountSize, .bold))
                .monospacedDigit()
                .foregroundStyle(P.accentInk)
                .padding(.horizontal, M.chainCountPaddingH)
                .padding(.vertical, M.chainCountPaddingV)
                .background(P.accentSoft, in: Capsule(style: .continuous))
            if identifiedCount > 0 {
                Text(identifiedCount <= 1 ? "\(identifiedCount) identifié" : "\(identifiedCount) identifiés")
                    .font(SQType.caption)
                    .monospacedDigit()
                    .foregroundStyle(P.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, M.cardSpacing)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func candidateSection(for site: RadioLogSite) -> some View {
        if let blocking = RadioLogIdentifyPicker.blockingReason(for: site) {
            noticeBanner(blocking, tint: SQColor.warning, soft: SQColor.warningSoft)
        } else if picker.isLoading {
            HStack(spacing: SQSpace.sm) {
                ProgressView()
                Text("Recherche des antennes voisines…")
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
            }
            .padding(.top, SQSpace.lg)
        } else if picker.candidates.isEmpty {
            noticeBanner(
                picker.errorMessage ?? String(localized: "Aucune antenne connue à proximité."),
                tint: P.muted,
                soft: P.chip
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Quelle antenne as-tu relevée ?")
                    .font(SQFont.body(M.groupHeaderSize, .bold))
                    .foregroundStyle(P.muted)
                    .padding(.top, SQSpace.lg)
                    .padding(.bottom, M.groupHeaderBottom)
                VStack(spacing: M.cardSpacing) {
                    // Trois candidats au plus : au-delà, on ne choisit plus, on
                    // parcourt — et la file perd son intérêt. La feuille unitaire
                    // reste là pour qui veut la liste complète.
                    ForEach(picker.candidates.prefix(3)) { candidate in
                        RadioLogCandidateRow(
                            candidate: candidate,
                            isSelected: picker.selectedId == candidate.id
                        ) {
                            picker.selectedId = candidate.id
                            recenterOnSelection()
                            Haptics.selection()
                        }
                    }
                }
            }
            if let errorMessage = picker.errorMessage {
                noticeBanner(errorMessage, tint: SQColor.dangerInk, soft: SQColor.dangerSoft)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: M.chainDotGap) {
            Spacer(minLength: 0)
            // Une pastille par site, plafonnée : au-delà d'une vingtaine, la
            // rangée devient un trait indéchiffrable et le compteur fait le travail.
            ForEach(0..<min(sites.count, 20), id: \.self) { position in
                Capsule()
                    .fill(position == index ? P.accent : P.hairStrong)
                    .frame(width: position == index ? 16 : M.chainDot, height: M.chainDot)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SQSpace.md)
        .accessibilityHidden(true)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SQSpace.lg)
    }

    private var summaryMessage: String {
        var parts: [String] = []
        parts.append(identifiedCount <= 1 ? "\(identifiedCount) site identifié" : "\(identifiedCount) sites identifiés")
        if !skippedIds.isEmpty {
            parts.append(skippedIds.count <= 1 ? "\(skippedIds.count) passé" : "\(skippedIds.count) passés")
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
         site.logCount <= 1 ? "\(site.logCount) relevé" : "\(site.logCount) relevés"]
            .joined(separator: " · ")
    }

    private func noticeBanner(_ message: String, tint: Color, soft: Color) -> some View {
        Text(message)
            .font(SQType.caption)
            .foregroundStyle(tint)
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(soft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .padding(.top, SQSpace.md)
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
