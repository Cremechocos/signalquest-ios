import MapKit
import SwiftUI
import UIKit

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

/// « Identifier ce site » — l'écran qui transforme un eNB/gNB non identifié en
/// identification confirmée.
///
/// L'app ne décide de rien : elle affiche la piste du serveur (quand il en a
/// une) et les antennes voisines, et c'est l'utilisateur qui tranche. Le mot
/// « automatique » n'a rien à faire ici — cette page VÉRIFIE, elle n'attribue pas.
struct RadioLogIdentifySheet: View {
    let site: RadioLogSite
    @StateObject private var picker: RadioLogIdentifyPicker
    @Environment(\.dismiss) private var dismiss
    @State private var region: MKCoordinateRegion
    @State private var showsMapPicker = false
    /// Renseigné dès que le serveur a accepté l'identification : l'écran bascule
    /// alors sur son résultat au lieu de se refermer sèchement. On vient de
    /// contribuer à une base publique, l'écran doit dire QUOI.
    @State private var identifiedSiteId: String?
    @AccessibilityFocusState private var resultFocused: Bool
    private let antennas: AntennasServicing
    private let customSites: CustomSitesServicing?
    let onIdentified: (String) -> Void

    init(
        site: RadioLogSite,
        service: RadioLogsServicing,
        identify: IdentifyServicing,
        antennas: AntennasServicing,
        customSites: CustomSitesServicing? = nil,
        onIdentified: @escaping (String) -> Void
    ) {
        self.site = site
        self.antennas = antennas
        self.customSites = customSites
        self.onIdentified = onIdentified
        _picker = StateObject(
            wrappedValue: RadioLogIdentifyPicker(service: service, identify: identify, antennas: antennas)
        )
        _region = State(
            initialValue: MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: site.latitude ?? 46.6,
                    longitude: site.longitude ?? 2.5
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let identifiedSiteId {
                        resultCard(siteId: identifiedSiteId)
                    } else if let blocking = RadioLogIdentifyPicker.blockingReason(for: site) {
                        noticeBanner(blocking, systemImage: "exclamationmark.triangle.fill", tint: SQColor.warning, soft: SQColor.warningSoft)
                    } else {
                        map
                        candidateList
                        mapPickerButton
                    }
                    if identifiedSiteId == nil, let errorMessage = picker.errorMessage {
                        noticeBanner(errorMessage, systemImage: "exclamationmark.circle.fill", tint: SQColor.dangerInk, soft: SQColor.dangerSoft)
                    }
                }
                .padding(.horizontal, M.sheetPaddingH)
                .padding(.bottom, M.sheetPaddingBottom)
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle(identifiedSiteId == nil ? "Identifier ce site" : "Site identifié")
            .toolbarTitleInlineCompat()
            .toolbar { toolbarContent }
            .task { await picker.load(for: site) }
            .onChangeCompat(of: identifiedSiteId) { _, siteId in
                guard siteId != nil else { return }
                DispatchQueue.main.async {
                    resultFocused = true
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "Site identifié"))
                }
            }
            .sheet(isPresented: $showsMapPicker) {
                RadioLogSiteMapPicker(site: site, picker: picker, antennas: antennas, customSites: customSites) { siteId in
                    // On NE referme PAS : on revient ici pour dire à quel site le
                    // nœud est désormais rattaché. C'est la réponse à la question
                    // que l'écran posait.
                    identifiedSiteId = siteId
                    onIdentified(siteId)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(identifiedSiteId == nil ? "Fermer" : "Terminé") { dismiss() }
        }
        if identifiedSiteId == nil {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        if let siteId = await picker.submit(site: site) {
                            identifiedSiteId = siteId
                            onIdentified(siteId)
                        }
                    }
                } label: {
                    if picker.isSubmitting {
                        ProgressView()
                    } else {
                        Text("Identifier")
                    }
                }
                .disabled(picker.selectedId == nil || picker.isSubmitting)
            }
        }
    }

    /// Le résultat, une fois le serveur d'accord : quel nœud, sur quel site.
    private func resultCard(siteId: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RadioLogStatePill(state: .identified(siteId: siteId))
            Text("\(site.nodeLabel) est identifié sur le site \(siteId).")
                .font(SQFont.body(M.siteNameSize, .semibold))
                .foregroundStyle(P.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SQSpace.md)
            Text("Cette identification est publique et attribuée à ton compte. Tu peux la retirer depuis « Mes identifications ».")
                .font(SQFont.body(M.siteMetaSize))
                .foregroundStyle(P.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.siteMetaTop)
        }
        .padding(M.cardPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.card, in: RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous))
        .sqShadowCard()
        .padding(.top, SQSpace.sm)
        .accessibilityElement(children: .combine)
        .accessibilityFocused($resultFocused)
    }

    /// L'échappatoire : les propositions du serveur ne couvrent pas tout, et
    /// forcer un choix dans une liste fausse serait pire que de ne rien proposer.
    private var mapPickerButton: some View {
        Button {
            showsMapPicker = true
            Haptics.selection()
        } label: {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "map")
                    .font(.system(size: 14, weight: .semibold))
                Text("Choisir une autre antenne sur la carte")
                    .font(SQFont.body(M.buttonSize, .bold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(P.accentInk)
            .padding(.horizontal, M.buttonPaddingH)
            .padding(.vertical, M.buttonPaddingV + 3)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(P.accentSoft, in: RoundedRectangle(cornerRadius: M.buttonRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, M.ctaTop)
    }

    // MARK: Sous-vues

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SQSpace.sm) {
                Text(site.nodeLabel)
                    .font(.sqTechnical(M.siteIdSize, .semibold))
                    .tracking(M.siteIdTracking)
                    .foregroundStyle(P.ink)
                RadioLogTechBadge(label: site.techLabel)
                Spacer(minLength: 0)
            }
            Text(metaLine)
                .font(SQFont.body(M.siteMetaSize))
                .monospacedDigit()
                .foregroundStyle(P.muted)
                .padding(.top, M.siteMetaTop)

            let pciLabels = site.distinctPciLabels
            if !pciLabels.isEmpty {
                FlowLayoutCompat(spacing: M.pillsGap) {
                    ForEach(pciLabels.prefix(6), id: \.self) { label in
                        RadioLogPill(label: label)
                    }
                }
                .padding(.top, M.pillsTop)
            }
        }
        .padding(.bottom, SQSpace.lg)
    }

    private var metaLine: String {
        [site.operatorName ?? String(localized: "Opérateur inconnu"),
         site.compositionLabel,
         site.logCount <= 1 ? "\(site.logCount) relevé" : "\(site.logCount) relevés"]
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var map: some View {
        if site.hasCoordinate {
            SQRegionMap(region: $region, items: mapPins) { pin in
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
            .padding(.bottom, SQSpace.md)
        }
    }

    private struct IdentifyPin: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let isOrigin: Bool
        let isSelected: Bool
    }

    private var mapPins: [IdentifyPin] {
        var pins: [IdentifyPin] = []
        if let latitude = site.latitude, let longitude = site.longitude {
            pins.append(
                IdentifyPin(
                    id: "origin",
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: true,
                    isSelected: false
                )
            )
        }
        for candidate in picker.candidates {
            guard let latitude = candidate.latitude, let longitude = candidate.longitude else { continue }
            pins.append(
                IdentifyPin(
                    id: candidate.id,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: false,
                    isSelected: candidate.id == picker.selectedId
                )
            )
        }
        return pins
    }

    @ViewBuilder
    private var candidateList: some View {
        if picker.isLoading {
            HStack(spacing: SQSpace.sm) {
                ProgressView()
                Text("Recherche des antennes voisines…")
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
            }
            .padding(.vertical, SQSpace.lg)
        } else if !picker.candidates.isEmpty {
            Text("Quelle antenne as-tu relevée ?")
                .font(SQFont.body(M.groupHeaderSize, .bold))
                .foregroundStyle(P.muted)
                .padding(.bottom, M.groupHeaderBottom)

            VStack(spacing: M.cardSpacing) {
                ForEach(picker.candidates) { candidate in
                    RadioLogCandidateRow(
                        candidate: candidate,
                        isSelected: picker.selectedId == candidate.id
                    ) {
                        picker.selectedId = candidate.id
                        if let latitude = candidate.latitude, let longitude = candidate.longitude {
                            region.center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                        }
                        Haptics.selection()
                    }
                }
            }
        }
    }

    private func noticeBanner(_ message: String, systemImage: String, tint: Color, soft: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(SQType.caption)
            .foregroundStyle(tint)
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(soft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .padding(.top, SQSpace.md)
    }
}

/// Une antenne candidate. La piste du serveur porte un liseré d'accent et dit sa
/// confiance ; les autres sont de simples voisines classées par distance.
struct RadioLogCandidateRow: View {
    let candidate: RadioLogCandidate
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: M.cardInnerGap) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isSelected ? P.accent : P.muted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SQSpace.sm) {
                        Text("Site \(candidate.siteId)")
                            .font(.sqTechnical(13, .semibold))
                            .foregroundStyle(P.ink)
                            .lineLimit(1)
                        if candidate.isServerHypothesis {
                            Text("Proposé")
                                .font(SQFont.body(M.techSize, .heavy))
                                .tracking(M.techTracking)
                                .foregroundStyle(P.accentInk)
                                .padding(.horizontal, M.techPaddingH)
                                .padding(.vertical, M.techPaddingV)
                                .background(P.accentSoft, in: RoundedRectangle(cornerRadius: M.techRadius, style: .continuous))
                        }
                        Spacer(minLength: 0)
                    }
                    if let address = candidate.address, !address.isEmpty {
                        Text(address)
                            .font(SQFont.body(M.siteNameSize))
                            .foregroundStyle(P.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let meta = metaLine {
                        Text(meta)
                            .font(SQFont.body(M.siteMetaSize))
                            .monospacedDigit()
                            .foregroundStyle(P.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, M.cardPaddingH)
            .padding(.vertical, M.cardPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous)
                    .fill(P.card)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous)
                                .strokeBorder(P.accent.opacity(0.45), lineWidth: 1.5)
                        }
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let distanceLabel = candidate.distanceLabel { parts.append("à \(distanceLabel)") }
        if let confidenceScore = candidate.confidenceScore { parts.append("confiance \(confidenceScore) %") }
        let operators = candidate.operators.filter { $0.uppercased() != "ALL" }
        if !operators.isEmpty { parts.append(operators.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Aperçu cartographique d'un site du journal — le bouton « Carte » de la carte.
struct RadioLogSiteMapSheet: View {
    let site: RadioLogSite
    @Environment(\.dismiss) private var dismiss
    @State private var region: MKCoordinateRegion

    init(site: RadioLogSite) {
        self.site = site
        _region = State(
            initialValue: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: site.latitude ?? 46.6, longitude: site.longitude ?? 2.5),
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SQRegionMap(region: $region, items: pins) { pin in
                    MapAnnotation(coordinate: pin.coordinate) {
                        Image(systemName: "dot.scope")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(P.accent)
                            .padding(6)
                            .background(P.card, in: Circle())
                            .sqShadowSoft()
                    }
                }
                Text("Position médiane des \(site.logCount) relevés de ce site — ce n'est pas la position de l'antenne.")
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
                    .multilineTextAlignment(.center)
                    .padding(SQSpace.lg)
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle(site.nodeLabel)
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private var pins: [SQMapPin] {
        guard let latitude = site.latitude, let longitude = site.longitude else { return [] }
        return [SQMapPin(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))]
    }
}
