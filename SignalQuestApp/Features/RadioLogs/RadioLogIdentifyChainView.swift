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
    /// Envoi différé de 2 s après « Confirmer » : « Annuler » pendant ce délai
    /// n'écrit RIEN (on ne retire pas après coup une identification publique).
    @State private var pending: PendingIdentification?
    @State private var pendingTask: Task<Void, Never>?
    private let antennas: AntennasServicing
    private let customSites: CustomSitesServicing?
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.5),
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
    )
    /// Commune connue de chaque site (« Grenoble — … »), comme dans la liste.
    private let siteNames: [String: String]
    let onIdentified: (RadioLogSite, String) -> Void

    /// Délai entre « Confirmer » et l'envoi réel.
    static let undoDelay: Duration = .seconds(2)

    private struct PendingIdentification: Equatable {
        let siteKey: String
        let nodeLabel: String
        let candidateSiteId: String
    }

    init(
        sites: [RadioLogSite],
        siteNames: [String: String] = [:],
        service: RadioLogsServicing,
        identify: IdentifyServicing,
        antennas: AntennasServicing,
        customSites: CustomSitesServicing? = nil,
        onIdentified: @escaping (RadioLogSite, String) -> Void
    ) {
        self.sites = sites
        self.siteNames = siteNames
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
            .navigationTitle(current == nil ? String(localized: "Terminé") : String(localized: "Site \(index + 1) sur \(sites.count)"))
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                if current != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Passer") { advance(skipped: true) }
                            .disabled(picker.isSubmitting)
                            .accessibilityIdentifier("radioLogs.chain.skip")
                    }
                }
            }
        }
        // Fermer pendant le délai : rien n'est parti, rien ne part.
        .onDisappear { cancelPending() }
    }

    // MARK: La carte de file

    private func card(for site: RadioLogSite) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack(spacing: SQSpace.sm) {
                    progressBar
                    if identifiedCount > 0 {
                        Text(String(localized: "\(identifiedCount) identifié"))
                            .font(SQFont.body(12, .bold))
                            .monospacedDigit()
                            .foregroundStyle(P.okInk)
                            .fixedSize()
                            .accessibilityIdentifier("radioLogs.chain.identified")
                    }
                }

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text(contextLine(for: site))
                        .font(SQFont.body(M.siteMetaSize))
                        .foregroundStyle(P.muted)
                        .accessibilityIdentifier("radioLogs.chain.context")
                    HStack(spacing: SQSpace.sm) {
                        Text(site.nodeLabel)
                            .font(.sqTechnical(M.siteIdSize, .semibold))
                            .tracking(M.siteIdTracking)
                            .foregroundStyle(P.ink)
                        RadioLogTechBadge(label: site.techLabel)
                        Spacer(minLength: 0)
                    }
                    Text([site.compositionLabel, String(localized: "\(site.logCount) relevé")].joined(separator: " · "))
                        .font(SQFont.body(M.siteMetaSize))
                        .monospacedDigit()
                        .foregroundStyle(P.muted)

                    let pciLabels = site.distinctPciLabels
                    if !pciLabels.isEmpty || site.band != nil {
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
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        SQRegionMap(region: $region, items: pins(for: site)) { pin in
                            MapAnnotation(coordinate: pin.coordinate) {
                                pinView(pin)
                            }
                        }
                        .frame(height: M.chainMapHeight)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .accessibilityHidden(true)
                        Text("Cercle pointillé : position médiane des \(site.logCount) relevés, pas celle de l'antenne.")
                            .font(SQType.caption)
                            .foregroundStyle(P.muted)
                    }
                }

                candidateSection(for: site)

                confirmSection(for: site)
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
        .sheet(isPresented: $showsMapPicker) {
            RadioLogSiteMapPicker(site: site, picker: picker, antennas: antennas, customSites: customSites) { siteId in
                // Dans la file, on enchaîne : le site suivant est ce qu'on attend.
                onIdentified(site, siteId)
                identifiedCount += 1
                advance(skipped: false)
            }
        }
    }

    /// « Confirmer le support X » et sa légende, ou, pendant les 2 s qui
    /// précèdent l'envoi, le bandeau avec « Annuler ».
    @ViewBuilder
    private func confirmSection(for site: RadioLogSite) -> some View {
        if let pending, pending.siteKey == site.id {
            HStack(spacing: SQSpace.md) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(P.okInk)
                    .accessibilityHidden(true)
                Text(String(localized: "\(pending.nodeLabel) sur le site \(pending.candidateSiteId) · envoi dans 2 s"))
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(P.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Annuler") { cancelPending() }
                    .font(SQFont.body(15, .bold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("radioLogs.chain.undo")
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs)
            .background(SQColor.successSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("radioLogs.chain.pending")
        } else if RadioLogIdentifyPicker.blockingReason(for: site) == nil {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                if let candidate = picker.selectedCandidate, candidate.needsVerification {
                    noticeBanner(
                        String(localized: "Ce site est seulement le plus proche de tes relevés : le serveur ne l'a pas reconnu. Vérifie-le avant de confirmer."),
                        tint: OutageTint.degradedInk,
                        soft: SQColor.warningSoft
                    )
                }
                GradientButton(
                    picker.selectedCandidate.map { String(localized: "Confirmer le support \($0.siteId)") }
                        ?? String(localized: "Identifier ici"),
                    isBusy: picker.isSubmitting
                ) {
                    // Sans choix, l'envoi dit lui-même qu'il manque une antenne.
                    if picker.selectedCandidate == nil {
                        Task { await identifyCurrent(site) }
                    } else {
                        schedule(site)
                    }
                }
                // Rien à identifier tant que les antennes de CE site arrivent.
                .disabled(picker.isLoading || picker.isSubmitting)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("radioLogs.chain.identify")
                Text("Publique et attribuée à ton compte. Tu pourras la corriger depuis le journal.")
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
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
                mapLabel: "Aucun de ceux-là ? Choisir sur la carte",
                numbered: true,
                hypothesisFailed: picker.hypothesisFailed,
                onRetryHypothesis: { Task { await picker.load(for: site) } },
                onSelect: { candidate in
                    guard pending == nil else { return }
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

    private func schedule(_ site: RadioLogSite) {
        guard pending == nil, let candidate = picker.selectedCandidate else { return }
        pending = PendingIdentification(siteKey: site.id, nodeLabel: site.nodeLabel, candidateSiteId: candidate.siteId)
        Haptics.selection()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: Self.undoDelay)
            guard !Task.isCancelled, pending?.siteKey == site.id else { return }
            pending = nil
            pendingTask = nil
            await identifyCurrent(site)
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
    }

    private func advance(skipped: Bool) {
        cancelPending()
        if skipped, let current { skippedIds.insert(current.id) }
        picker.selectedId = nil
        picker.errorMessage = nil
        index += 1
        Haptics.selection()
    }

    /// « Orange · 4G · Grenoble · vu il y a 2 h » : opérateur, techno, commune
    /// quand elle est connue, dernier relevé.
    private func contextLine(for site: RadioLogSite) -> String {
        let commune = siteNames[site.id]?.components(separatedBy: " — ").first.flatMap { $0.isEmpty ? nil : $0 }
        return [site.operatorName ?? String(localized: "Opérateur inconnu"),
                site.techLabel,
                commune,
                String(localized: "vu \(site.lastSeenAt.formatted(.relative(presentation: .named)))")]
            .compactMap { $0 }
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
        var number: Int?
    }

    /// Le centre des relevés en cercle pointillé (ce n'est pas une antenne), les
    /// candidats par leur numéro, le même que dans la liste.
    @ViewBuilder
    private func pinView(_ pin: ChainPin) -> some View {
        if pin.isOrigin {
            ZStack {
                Circle()
                    .fill(P.accent.opacity(0.10))
                Circle()
                    .strokeBorder(P.accent, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                Circle().fill(P.accent).frame(width: 6, height: 6)
            }
            .frame(width: 44, height: 44)
        } else {
            Text(verbatim: pin.number.map { "\($0)" } ?? "")
                .font(SQFont.body(13, .bold))
                .monospacedDigit()
                .foregroundStyle(pin.isSelected ? P.onAccent : P.ink)
                .frame(width: 28, height: 28)
                .background(pin.isSelected ? AnyShapeStyle(P.accent) : AnyShapeStyle(P.card), in: Circle())
                .overlay(Circle().strokeBorder(pin.isSelected ? P.card : P.hairStrong, lineWidth: 2))
                .sqShadowSoft()
        }
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
        for (position, candidate) in picker.candidates.prefix(3).enumerated() {
            guard let latitude = candidate.latitude, let longitude = candidate.longitude else { continue }
            pins.append(
                ChainPin(
                    id: candidate.id,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    isOrigin: false,
                    isSelected: candidate.id == picker.selectedId,
                    number: position + 1
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
