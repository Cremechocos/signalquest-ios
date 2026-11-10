import MapKit
import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

/// La fiche d'un site du journal : où on l'a capté, avec quel signal, et de quoi
/// il est fait.
///
/// Elle remplace le dépliage de la ligne : la carte des relevés et les cellules
/// avec leur RSRP n'avaient pas la place de s'y afficher, et ouvrir une ligne
/// allongeait toute la liste. Tout ce qu'elle montre vient du journal déjà
/// synchronisé sur l'appareil ; la seule lecture réseau est la position du
/// support identifié, une fois.
struct RadioLogSiteDetailView: View {
    let site: RadioLogSite
    let state: RadioLogSiteState
    let siteName: String?
    let proposal: RadioLogSiteHypothesis?
    let isMine: Bool
    let service: RadioLogsServicing
    let antennas: AntennasServicing
    /// Ouvre la feuille d'identification (ou de correction) une fois la fiche fermée.
    let onIdentify: () -> Void
    /// Confirme la proposition du serveur, après la confirmation de cette fiche.
    let onConfirmProposal: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var readings: [Reading] = []
    @State private var supportCoordinate: CLLocationCoordinate2D?
    @State private var region: MKCoordinateRegion
    @State private var showsConfirmation = false

    /// Au-delà, la carte n'apprend plus rien et MapKit ralentit : on garde les
    /// relevés les plus récents.
    static let maxMapReadings = 200

    struct Reading: Identifiable, Equatable, Sendable {
        let id: String
        let latitude: Double
        let longitude: Double
        let rsrp: Int?
    }

    init(
        site: RadioLogSite,
        state: RadioLogSiteState,
        siteName: String?,
        proposal: RadioLogSiteHypothesis?,
        isMine: Bool,
        service: RadioLogsServicing,
        antennas: AntennasServicing,
        onIdentify: @escaping () -> Void,
        onConfirmProposal: @escaping () -> Void
    ) {
        self.site = site
        self.state = state
        self.siteName = siteName
        self.proposal = proposal
        self.isMine = isMine
        self.service = service
        self.antennas = antennas
        self.onIdentify = onIdentify
        self.onConfirmProposal = onConfirmProposal
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: site.latitude ?? 46.6, longitude: site.longitude ?? 2.5),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    MapSheetHeader(title: String(localized: "Fiche du site"), closeIdentifier: "radioLogs.detail.close") { dismiss() }
                    header
                    if site.hasCoordinate { mapCard }
                    statsGrid
                    cellsSection
                    actions
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.bottom, SQSpace.xxl)
                .sqReadableWidth()
            }
            .background(SQColor.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
        .alert("Confirmer ce site ?", isPresented: $showsConfirmation, presenting: proposal) { _ in
            Button("Annuler", role: .cancel) {}
            Button("Confirmer") {
                onConfirmProposal()
                dismiss()
            }
        } message: { proposal in
            Text(RadioLogIdentifyPicker.confirmationMessage(
                nodeLabel: site.nodeLabel,
                siteId: proposal.siteId,
                address: proposal.placeLabel
            ))
        }
        .accessibilityIdentifier("radioLogs.detail")
    }

    // MARK: En-tête

    private var title: String {
        if let siteName, let commune = siteName.components(separatedBy: " — ").first, !commune.isEmpty {
            return commune
        }
        return site.nodeLabel
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                if let operatorName = site.operatorName {
                    Circle()
                        .fill(SQBrand.operatorColor(operatorName))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(operatorName)
                        .font(SQType.caption)
                        .foregroundStyle(P.muted)
                }
                RadioLogTechBadge(label: site.techLabel)
            }
            Text(title)
                .font(SQFont.display(28, .heavy, relativeTo: .largeTitle))
                .foregroundStyle(P.ink)
                .fixedSize(horizontal: false, vertical: true)
                .sqHeader()
            if title != site.nodeLabel {
                Text(site.nodeLabel)
                    .font(.sqTechnical(14))
                    .foregroundStyle(P.muted)
            }
            if let siteName, siteName.contains(" — ") {
                Text(siteName.components(separatedBy: " — ").dropFirst().joined(separator: " — "))
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: SQSpace.sm) {
                if let siteId = state.siteId, !siteId.isEmpty {
                    statusPill(Text("Identifié · site \(siteId)"), symbol: "checkmark", ink: P.okInk, fill: P.okSoft)
                    if isMine {
                        statusPill(Text("Par toi"), symbol: nil, ink: P.chipInk, fill: P.chip)
                    }
                } else {
                    RadioLogStatePill(state: state, checkable: site.isCheckable)
                }
            }
            .padding(.top, SQSpace.xs)
        }
    }

    private func statusPill(_ text: Text, symbol: String?, ink: Color, fill: Color) -> some View {
        HStack(spacing: SQSpace.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
            }
            text.font(SQFont.body(12, .bold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, SQSpace.md)
        .frame(minHeight: 28)
        .background(fill, in: Capsule(style: .continuous))
    }

    // MARK: Carte des relevés

    private enum MapItem: Identifiable {
        case reading(Reading)
        case median(CLLocationCoordinate2D)
        case support(CLLocationCoordinate2D, proposed: Bool)

        var id: String {
            switch self {
            case let .reading(reading): return "r-\(reading.id)"
            case .median: return "median"
            case .support: return "support"
            }
        }

        var coordinate: CLLocationCoordinate2D {
            switch self {
            case let .reading(reading): return CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
            case let .median(coordinate), let .support(coordinate, _): return coordinate
            }
        }
    }

    private var mapItems: [MapItem] {
        var items = readings.map(MapItem.reading)
        if let latitude = site.latitude, let longitude = site.longitude {
            items.append(.median(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        }
        if let supportCoordinate {
            items.append(.support(supportCoordinate, proposed: !state.isIdentified))
        }
        return items
    }

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SQRegionMap(region: $region, items: mapItems) { item in
                MapAnnotation(coordinate: item.coordinate) {
                    mapMarker(item)
                }
            }
            .frame(height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(mapAccessibilityLabel)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                signalLegend
                Text("Le cercle pointillé est la position médiane des relevés, pas celle de l’antenne.")
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let distance = supportDistanceMeters {
                    Text(state.isIdentified
                         ? String(localized: "Support identifié à \(SQUnits.distance(meters: distance)) de la position médiane.")
                         : String(localized: "Support proposé à \(SQUnits.distance(meters: distance)) de la position médiane."))
                        .font(SQType.caption)
                        .foregroundStyle(P.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(SQSpace.md)
        }
        .background(P.card, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func mapMarker(_ item: MapItem) -> some View {
        switch item {
        case let .reading(reading):
            Circle()
                .fill(SQQualityScale.Signal(rsrp: reading.rsrp.map(Double.init)).color)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
        case .median:
            Circle()
                .strokeBorder(P.muted, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .background(Circle().fill(P.card.opacity(0.6)))
                .frame(width: 24, height: 24)
        case let .support(_, proposed):
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(proposed ? P.onAccent : SQColor.onAccent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(proposed ? P.accent : P.okInk))
                .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                .sqShadowSoft()
        }
    }

    /// Les paliers de l'échelle commune présents sur la carte, et eux seuls : la
    /// légende nomme toutes les couleurs dessinées, sans en promettre d'autres.
    private var signalLegend: some View {
        let present = Set(readings.map { SQQualityScale.Signal(rsrp: $0.rsrp.map(Double.init)) })
        let levels = SQQualityScale.Signal.allCases.filter { present.contains($0) }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.md) { legendItems(levels) }
            VStack(alignment: .leading, spacing: SQSpace.xs) { legendItems(levels) }
        }
    }

    @ViewBuilder
    private func legendItems(_ levels: [SQQualityScale.Signal]) -> some View {
        ForEach(levels, id: \.self) { level in
            HStack(spacing: SQSpace.xs) {
                Circle().fill(level.color).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(level.label)
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
            }
        }
    }

    private var supportDistanceMeters: Double? {
        guard let supportCoordinate, let latitude = site.latitude, let longitude = site.longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: supportCoordinate.latitude, longitude: supportCoordinate.longitude))
    }

    private var mapAccessibilityLabel: String {
        var text = String(localized: "Carte : \(readings.count) relevés autour de la position médiane.")
        if let distance = supportDistanceMeters {
            text += " " + String(localized: "Support à \(SQUnits.distance(meters: distance)).")
        }
        return text
    }

    // MARK: Chiffres clés

    private var bestRsrp: Int? { site.cells.compactMap(\.bestRsrp).max() }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: SQSpace.sm), GridItem(.flexible(), spacing: SQSpace.sm)],
                  spacing: SQSpace.sm) {
            if let bestRsrp {
                stat(
                    value: "\(bestRsrp) dBm",
                    label: String(localized: "meilleur RSRP · \(SQQualityScale.Signal(rsrp: Double(bestRsrp)).label.lowercased())")
                )
            }
            stat(value: site.logCount.formatted(), label: String(localized: "relevés enregistrés"))
            stat(value: site.cells.count.formatted(), label: cellsStatLabel)
            stat(
                value: site.firstSeenAt.formatted(.dateTime.day().month(.abbreviated)),
                label: String(localized: "première capture · dernière \(site.lastSeenAt.formatted(.relative(presentation: .named)))")
            )
        }
    }

    /// « cellules · 2 PCI » sous le nombre de cellules, sans le répéter.
    private var cellsStatLabel: String {
        // Un site a toujours au moins une cellule : pas de cas « 0 ».
        let cells = site.cells.count == 1
            ? String(localized: "radioLogs.detail.cellsNoun.one")
            : String(localized: "radioLogs.detail.cellsNoun.other")
        let pciCount = site.distinctPciCount
        return pciCount > 0 ? "\(cells) · \(pciCount) PCI" : cells
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(SQFont.display(20, .heavy, relativeTo: .title3))
                .monospacedDigit()
                .foregroundStyle(P.ink)
                .sqSingleLine()
            Text(verbatim: label)
                .font(SQType.caption)
                .foregroundStyle(P.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(SQSpace.md)
        .background(P.card, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Cellules

    private var sortedCells: [RadioLogCell] { site.cells.sorted { $0.logCount > $1.logCount } }

    private var cellsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Cellules captées")
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(sortedCells.enumerated()), id: \.element.id) { index, cell in
                    cellRow(cell)
                    if index < sortedCells.count - 1 {
                        Rectangle().fill(P.hair).frame(height: 1).padding(.leading, 72)
                    }
                }
            }
            .background(P.card, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
    }

    private func cellRow(_ cell: RadioLogCell) -> some View {
        HStack(alignment: .center, spacing: SQSpace.md) {
            VStack(spacing: 0) {
                Text(verbatim: "PCI")
                    .font(SQFont.body(10, .bold))
                    .foregroundStyle(P.muted)
                Text(cell.pci.map(String.init) ?? "—")
                    .font(.sqTechnical(17, .bold))
                    .foregroundStyle(P.ink)
            }
            .frame(width: 52, height: 52)
            .background(P.chip, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: cell.bandLabel ?? site.techLabel)
                        .font(SQFont.body(14, .bold))
                        .foregroundStyle(P.ink)
                        .sqSingleLine()
                    Spacer(minLength: SQSpace.sm)
                    Text(String(localized: "\(cell.logCount) relevé"))
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(P.muted)
                }
                if let identity = cell.identityLabel {
                    Text(verbatim: identity)
                        .font(.sqTechnical(12))
                        .foregroundStyle(P.muted)
                        .sqSingleLine()
                }
                if let rsrp = cell.bestRsrp {
                    rsrpBar(rsrp)
                }
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .combine)
    }

    /// Barre de −140 à −44 dBm, à la couleur de l'échelle commune.
    private func rsrpBar(_ rsrp: Int) -> some View {
        let level = SQQualityScale.Signal(rsrp: Double(rsrp))
        let fraction = min(1, max(0.04, Double(rsrp + 140) / 96))
        return HStack(spacing: SQSpace.sm) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(P.barTrack)
                    Capsule().fill(level.color).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(verbatim: "\(rsrp) dBm")
                .font(.sqTechnical(12))
                .foregroundStyle(P.ink)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Meilleur RSRP \(rsrp) dBm, \(level.label)"))
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: SQSpace.sm) {
            if state.isUnidentified, proposal != nil {
                primaryButton(Text("C’est le site proposé"), identifier: "radioLogs.detail.confirmProposal") {
                    showsConfirmation = true
                }
                secondaryButton(Text("Choisir un autre site"), identifier: "radioLogs.detail.identify") {
                    dismiss(); onIdentify()
                }
            } else if state.isUnidentified {
                primaryButton(Text("Identifier"), identifier: "radioLogs.detail.identify") {
                    dismiss(); onIdentify()
                }
            } else if state.isIdentified, isMine {
                secondaryButton(Text("Corriger l’identification"), identifier: "radioLogs.detail.correct") {
                    dismiss(); onIdentify()
                }
            }
        }
        .padding(.top, SQSpace.xs)
    }

    private func primaryButton(_ label: Text, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(SQFont.body(15, .bold))
                .foregroundStyle(P.onAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(P.accent, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func secondaryButton(_ label: Text, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(SQFont.body(15, .bold))
                .foregroundStyle(P.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(P.card, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Chargement

    private func load() async {
        let kind = site.kind
        let node = site.node
        let service = self.service
        let loaded = await Task.detached(priority: .userInitiated) { () -> [Reading] in
            Self.readings(from: service.cachedSnapshot().entries, kind: kind, node: node)
        }.value
        readings = loaded

        if let proposal, !state.isIdentified, let latitude = proposal.latitude, let longitude = proposal.longitude {
            supportCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else if let siteId = state.siteId, !siteId.isEmpty, let market = site.resolvedMarketCode,
                  let details = try? await antennas.details(id: siteId, market: market,
                                                           operatorName: site.resolvedOperatorKey ?? "ALL"),
                  let core = details.core {
            supportCoordinate = CLLocationCoordinate2D(latitude: core.lat, longitude: core.lng)
        }
        fitRegion()
    }

    /// Relevés positionnés du nœud, les plus récents d'abord, bornés.
    nonisolated static func readings(from entries: [RadioLogEntry], kind: RadioLogNodeKind, node: String) -> [Reading] {
        entries
            .filter { entry in
                switch kind {
                case .enb: return entry.enb == node
                case .gnb: return entry.gnb == node
                }
            }
            .sorted { $0.observedAt > $1.observedAt }
            .compactMap { entry -> Reading? in
                guard let latitude = entry.latitude, let longitude = entry.longitude else { return nil }
                return Reading(id: entry.id, latitude: latitude, longitude: longitude, rsrp: entry.rsrp)
            }
            .prefix(maxMapReadings)
            .map { $0 }
    }

    /// Cadre la carte sur les relevés, la médiane et le support.
    private func fitRegion() {
        let coordinates = mapItems.map(\.coordinate)
        guard let minLat = coordinates.map(\.latitude).min(), let maxLat = coordinates.map(\.latitude).max(),
              let minLng = coordinates.map(\.longitude).min(), let maxLng = coordinates.map(\.longitude).max()
        else { return }
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.006, (maxLat - minLat) * 1.4),
                longitudeDelta: max(0.006, (maxLng - minLng) * 1.4)
            )
        )
    }
}
