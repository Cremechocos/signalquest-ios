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
/// Comme depuis la carte et la file, l'envoi passe par une confirmation qui dit
/// sur quel site, et que c'est public et retirable.
struct RadioLogIdentifySheet: View {
    let site: RadioLogSite
    @StateObject private var picker: RadioLogIdentifyPicker
    @Environment(\.dismiss) private var dismiss
    @State private var region: MKCoordinateRegion
    @State private var showsMapPicker = false
    @State private var showsConfirmation = false
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
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    header
                    if let identifiedSiteId {
                        resultCard(siteId: identifiedSiteId)
                    } else if let blocking = RadioLogIdentifyPicker.blockingReason(for: site) {
                        noticeBanner(blocking, systemImage: "exclamationmark.triangle.fill", tint: SQColor.warning, soft: SQColor.warningSoft)
                    } else {
                        map
                        candidateList
                    }
                    if identifiedSiteId == nil, let errorMessage = picker.errorMessage {
                        noticeBanner(errorMessage, systemImage: "exclamationmark.circle.fill", tint: SQColor.dangerInk, soft: SQColor.dangerSoft)
                        if picker.searchFailed {
                            Button("Réessayer") { Task { await picker.load(for: site) } }
                                .font(SQFont.body(14, .semibold))
                                .foregroundStyle(SQColor.accentInk)
                                .frame(minHeight: 44)
                        }
                    }
                    if identifiedSiteId == nil, RadioLogIdentifyPicker.blockingReason(for: site) == nil {
                        submitBlock
                    }
                }
                .padding(.horizontal, M.sheetPaddingH)
                .padding(.top, SQSpace.sm)
                .padding(.bottom, M.sheetPaddingBottom)
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle(identifiedSiteId == nil ? String(localized: "Identifier ce site") : String(localized: "Site identifié"))
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(identifiedSiteId == nil ? String(localized: "Fermer") : String(localized: "Terminé")) { dismiss() }
                }
            }
            .task { await picker.load(for: site) }
            .onChangeCompat(of: identifiedSiteId) { _, siteId in
                guard siteId != nil else { return }
                DispatchQueue.main.async {
                    resultFocused = true
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "Site identifié"))
                }
            }
            .alert("Identifier ce site ?", isPresented: $showsConfirmation, presenting: picker.selectedCandidate) { _ in
                Button("Annuler", role: .cancel) {}
                Button("Identifier") {
                    Task {
                        if let siteId = await picker.submit(site: site) {
                            identifiedSiteId = siteId
                            onIdentified(siteId)
                        }
                    }
                }
            } message: { candidate in
                Text(RadioLogIdentifyPicker.confirmationMessage(
                    nodeLabel: site.nodeLabel,
                    siteId: candidate.siteId,
                    address: candidate.address,
                    needsVerification: candidate.needsVerification
                ))
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

    /// Le bouton d'envoi, en bas comme sur les autres formulaires, avec ce qu'il
    /// engage écrit dessous.
    private var submitBlock: some View {
        VStack(spacing: SQSpace.sm) {
            GradientButton(
                primaryTitle,
                isBusy: picker.isSubmitting
            ) {
                showsConfirmation = true
            }
            .disabled(picker.selectedCandidate == nil || picker.isSubmitting)
            .accessibilityIdentifier("radioLogs.identify.submit")
            Text("Publique et attribuée à ton compte. Tu pourras la retirer dans « Mes identifications ».")
                .font(SQType.caption)
                .foregroundStyle(P.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, SQSpace.xs)
    }

    /// Une antenne retenue pour sa seule proximité n'« identifie » pas : le bouton
    /// invite à la vérifier, la confirmation qui suit le redit.
    private var primaryTitle: String {
        guard let candidate = picker.selectedCandidate else { return String(localized: "Identifier") }
        return candidate.needsVerification
            ? String(localized: "Vérifier le site \(candidate.siteId)")
            : String(localized: "Identifier sur le site \(candidate.siteId)")
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
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityElement(children: .combine)
        .accessibilityFocused($resultFocused)
        .accessibilityIdentifier("radioLogs.identify.result")
    }

    // MARK: Sous-vues

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
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

            let pciLabels = site.distinctPciLabels
            if !pciLabels.isEmpty {
                FlowLayoutCompat(spacing: M.pillsGap) {
                    ForEach(pciLabels.prefix(6), id: \.self) { label in
                        RadioLogPill(label: label)
                    }
                }
            }
        }
    }

    private var metaLine: String {
        [site.operatorName ?? String(localized: "Opérateur inconnu"),
         site.compositionLabel,
         String(localized: "\(site.logCount) relevé")]
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
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .accessibilityHidden(true)
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
                SQSpinner()
                Text("Recherche des antennes voisines…")
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
            }
            .padding(.vertical, SQSpace.lg)
        } else {
            RadioLogCandidateCard(
                candidates: picker.candidates,
                selectedId: picker.selectedId,
                mapLabel: "Choisir une autre antenne sur la carte",
                hypothesisFailed: picker.hypothesisFailed,
                onRetryHypothesis: { Task { await picker.load(for: site) } },
                onSelect: { candidate in
                    picker.selectedId = candidate.id
                    if let latitude = candidate.latitude, let longitude = candidate.longitude {
                        region.center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    }
                },
                onOpenMap: { showsMapPicker = true }
            )
        }
    }

    private func noticeBanner(_ message: String, systemImage: String, tint: Color, soft: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(SQType.caption)
            .foregroundStyle(tint)
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(soft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }
}

/// « Quelle antenne as-tu captée ? » — les candidats dans une seule carte, puis
/// l'échappatoire vers la carte : les propositions du serveur ne couvrent pas
/// tout, et forcer un choix dans une liste fausse serait pire que de ne rien
/// proposer.
struct RadioLogCandidateCard: View {
    let candidates: [RadioLogCandidate]
    let selectedId: String?
    let mapLabel: LocalizedStringKey
    /// La piste du serveur n'a pas pu être demandée : on le dit, avec un nouvel essai.
    var hypothesisFailed = false
    var onRetryHypothesis: (() -> Void)?
    let onSelect: (RadioLogCandidate) -> Void
    let onOpenMap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Quelle antenne as-tu captée ?")
                .font(SQFont.display(17, .bold, relativeTo: .headline))
                .foregroundStyle(P.ink)
                .sqHeader()
            if hypothesisFailed {
                HStack(spacing: SQSpace.sm) {
                    Text("Piste du serveur indisponible.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let onRetryHypothesis {
                        Button("Réessayer", action: onRetryHypothesis)
                            .font(SQFont.body(14, .semibold))
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("radioLogs.identify.retryHypothesis")
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    RadioLogCandidateRow(candidate: candidate, isSelected: selectedId == candidate.id) {
                        onSelect(candidate)
                        Haptics.selection()
                    }
                    Rectangle().fill(SQColor.separator).frame(height: 1)
                        .padding(.leading, candidates.last?.id == candidate.id ? SQSpace.md : 48)
                }
                Button {
                    onOpenMap()
                    Haptics.selection()
                } label: {
                    HStack(spacing: SQSpace.md) {
                        SQIconPastille(systemImage: "map", size: 30, tint: SQColor.accentInk, fill: SQColor.accentSoft)
                            .accessibilityHidden(true)
                        Text(mapLabel)
                            .font(SQFont.body(15, .semibold))
                            .foregroundStyle(P.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(P.muted)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("radioLogs.identify.mapChoice")
            }
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        }
    }
}

/// Une antenne candidate. La piste du serveur porte « Proposé » et dit sa
/// confiance ; les autres sont de simples voisines classées par distance.
struct RadioLogCandidateRow: View {
    let candidate: RadioLogCandidate
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? P.accent : P.hairStrong, lineWidth: 2)
                    if isSelected {
                        Circle().fill(P.accent).frame(width: 10, height: 10)
                    }
                }
                .frame(width: 22, height: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: SQSpace.sm) {
                        Text("Site \(candidate.siteId)")
                            .font(.sqTechnical(14, .semibold))
                            .foregroundStyle(P.ink)
                            .sqSingleLine()
                        if candidate.isServerHypothesis {
                            Text("Proposé")
                                .font(SQFont.body(11, .bold))
                                .foregroundStyle(P.accentInk)
                                .padding(.horizontal, M.techPaddingH)
                                .padding(.vertical, M.techPaddingV)
                                .background(P.accentSoft, in: Capsule(style: .continuous))
                        } else if isSelected, candidate.needsVerification {
                            // Texte réel, pas une icône : VoiceOver le lit avec la rangée.
                            Text("Proximité, à vérifier")
                                .font(SQFont.body(11, .bold))
                                .foregroundStyle(OutageTint.degradedInk)
                                .padding(.horizontal, M.techPaddingH)
                                .padding(.vertical, M.techPaddingV)
                                .background(SQColor.warningSoft, in: Capsule(style: .continuous))
                                .accessibilityIdentifier("radioLogs.identify.proximityBadge")
                        }
                        Spacer(minLength: 0)
                    }
                    if let address = candidate.address, !address.isEmpty {
                        Text(address)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let meta = metaLine {
                        Text(meta)
                            .font(SQType.caption)
                            .monospacedDigit()
                            .foregroundStyle(P.muted)
                            .sqSingleLine()
                    }
                }
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(isSelected ? P.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("radioLogs.identify.candidate.\(candidate.siteId)")
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let distanceLabel = candidate.distanceLabel { parts.append(String(localized: "à \(distanceLabel)")) }
        if let confidenceScore = candidate.confidenceScore { parts.append(String(localized: "confiance \(confidenceScore) %")) }
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
