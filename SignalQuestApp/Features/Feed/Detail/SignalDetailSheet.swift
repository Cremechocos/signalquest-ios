import SwiftUI
import MapKit

/// Bottom sheet displayed when the user taps a feed card. Mirrors the Android
/// `SignalDetailBottomSheet`: rich header, every available metric, a mini map,
/// and quick actions.
struct SignalDetailSheet: View {
    let item: UnifiedSocialFeedItem
    var onLike: () -> Void = {}
    var onRepost: () -> Void = {}
    var onFavorite: () -> Void = {}
    var onComment: () -> Void = {}
    var onShare: () -> Void = {}
    var onMute: () -> Void = {}
    var onReport: () -> Void = {}
    /// Tap sur l'auteur — le parent ferme le sheet et pousse le profil.
    var onAuthorTap: (() -> Void)? = nil

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var speedtestDetail: SpeedtestDetail?
    @State private var detailError: String?

    private var signal: SocialSignalSummary? { item.signal }
    private var accent: Color { TechAccent.color(for: signal?.technology) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg + 2) {
                    SQSheetHandle()
                    header
                    if let signal {
                        metricsGrid(for: signal)
                        extraMetrics(for: signal)
                    }
                    map
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SQSpace.lg)
                            .sqEditorialCard()
                    }
                    actionsRow
                    if !item.hashtags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: SQSpace.sm) {
                                ForEach(item.hashtags, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(SQType.micro)
                                        .foregroundStyle(SQColor.brandRed)
                                }
                            }
                        }
                    }
                    Spacer(minLength: SQSpace.xxl)
                }
                .padding(SQSpace.xl)
            }
            .signalQuestBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.brandRed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { onReport(); dismiss() } label: {
                            Label("Signaler", systemImage: "flag")
                        }
                        Button { onMute() } label: {
                            Label(
                                item.notificationsMutedByMe == true ? "Réactiver les notifications" : "Couper les notifications",
                                systemImage: item.notificationsMutedByMe == true ? "bell" : "bell.slash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .tint(SQColor.brandRed)
                    }
                    .accessibilityLabel("Plus d’options")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: SQSpace.md + 2) {
            if let onAuthorTap {
                Button {
                    Haptics.light()
                    dismiss()
                    onAuthorTap()
                } label: {
                    authorBlock
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voir le profil de \(item.author.displayName)")
            } else {
                authorBlock
            }
            Spacer()
            SQEditorialTag(text: signal?.technology ?? item.kind.uppercased(), color: accent)
        }
    }

    private var authorBlock: some View {
        HStack(spacing: SQSpace.md + 2) {
            SQAvatar(url: item.author.avatarUrl, name: item.author.displayName, size: 56)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(item.author.displayName)
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                HStack(spacing: 6) {
                    if let place = signal?.city ?? item.placeLabel {
                        Image(systemName: "mappin")
                            .accessibilityHidden(true)
                        Text(place)
                    }
                    if let date = item.createdAt {
                        Text("·")
                        Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                    }
                }
                .font(.caption)
                .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    // MARK: Metrics

    private func metricsGrid(for signal: SocialSignalSummary) -> some View {
        let tiles = metricTiles(for: signal)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                tile
            }
        }
    }

    private func metricTiles(for signal: SocialSignalSummary) -> [CardMetricTile] {
        var tiles: [CardMetricTile] = []
        let kind = item.kind.lowercased()

        switch kind {
        case "speedtest":
            let detail = speedtestDetail
            tiles.append(.init(label: "Download", value: SignalFormatters.speed(detail?.averageSpeed ?? detail?.downloadAvg ?? signal.downloadMbps), highlight: true, accent: accent))
            tiles.append(.init(label: "Upload", value: SignalFormatters.speed(detail?.uploadAvg ?? signal.uploadMbps)))
            tiles.append(.init(label: "Ping min", value: SignalFormatters.ms(detail?.pingMin ?? detail?.ping ?? signal.pingMs)))
            tiles.append(.init(label: "Jitter", value: SignalFormatters.ms(detail?.jitter ?? signal.jitterMs)))
            tiles.append(.init(label: "Serveur", value: detail?.downloadServerName ?? detail?.server ?? signal.serverName ?? "—"))
        case "validation":
            tiles.append(.init(label: "Identifiant", value: signal.identifierValue ?? "—", highlight: true, accent: accent))
            tiles.append(.init(label: "Type", value: signal.identifierType?.uppercased() ?? "—"))
            tiles.append(.init(label: "PCI", value: signal.pci.map(String.init) ?? "—"))
            tiles.append(.init(label: "Cell", value: signal.cellId ?? "—"))
            tiles.append(.init(label: "Bande", value: signal.band ?? "—"))
            tiles.append(.init(label: "Fréquence", value: signal.frequency ?? "—"))
        case "coverage", "session", "drive_test":
            tiles.append(.init(label: "Distance", value: SignalFormatters.meters(signal.distanceMeters), highlight: true, accent: accent))
            tiles.append(.init(label: "Durée", value: SignalFormatters.duration(signal.durationSeconds)))
            tiles.append(.init(label: "Points", value: signal.pointsCount.map(String.init) ?? "—"))
            tiles.append(.init(label: "Signal moy.", value: SignalFormatters.dbm(signal.averageSignalDbm)))
            tiles.append(.init(label: "Min / Max", value: rangeText(signal: signal)))
            tiles.append(.init(label: "Techs", value: signal.detectedTechs.prefix(3).joined(separator: " / ").nonEmptyOrDash))
        default:
            tiles.append(.init(label: "RSRP", value: SignalFormatters.dbm(signal.rsrp), highlight: true, accent: accent))
            tiles.append(.init(label: "RSRQ", value: SignalFormatters.db(signal.rsrq)))
            tiles.append(.init(label: "SINR", value: SignalFormatters.db(signal.sinr)))
            tiles.append(.init(label: "Bande", value: signal.band ?? "—"))
            tiles.append(.init(label: "Opérateur", value: signal.operator ?? "—"))
            tiles.append(.init(label: "Cell", value: signal.cellId ?? "—"))
        }
        return tiles
    }

    private func rangeText(signal: SocialSignalSummary) -> String {
        switch (signal.minSignalDbm, signal.maxSignalDbm) {
        case (let min?, let max?):
            return "\(Int(min)) / \(Int(max)) dBm"
        case (let min?, nil):
            return SignalFormatters.dbm(min)
        case (nil, let max?):
            return SignalFormatters.dbm(max)
        default:
            return "—"
        }
    }

    @ViewBuilder
    private func extraMetrics(for signal: SocialSignalSummary) -> some View {
        let speedtestPairs: [(String, String)] = speedtestDetail.map { detail in
            [
                ("Réseau", [detail.connectionType, detail.networkType].compactMap { $0 }.joined(separator: " / ")),
                ("Opérateur", detail.mobileOperator ?? ""),
                ("Appareil", [detail.deviceType, detail.deviceModel].compactMap { $0 }.joined(separator: " ")),
                ("Durée", SignalFormatters.duration(detail.testDuration)),
                ("Ping moyen", SignalFormatters.ms(detail.pingAvg)),
                ("Ping médian", SignalFormatters.ms(detail.pingMedian)),
                ("Ping max", SignalFormatters.ms(detail.pingMax)),
                ("Position", coordinatesText(lat: detail.latitude, lon: detail.longitude))
            ].filter { !$0.1.isEmpty && $0.1 != "—" }
        } ?? []
        let pairs: [(String, String)] = speedtestPairs + [
            ("EARFCN", signal.earfcn.map(String.init) ?? ""),
            ("ARFCN", signal.arfcn.map(String.init) ?? ""),
            ("Secteurs", signal.sectors?.prefix(4).map(String.init).joined(separator: " · ") ?? ""),
            ("Appareil", signal.deviceModel ?? "")
        ].filter { !$0.1.isEmpty }
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Détails techniques")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack {
                        Text(pair.0).foregroundStyle(SQColor.labelSecondary)
                        Spacer()
                        Text(pair.1).foregroundStyle(SQColor.label)
                    }
                    .font(SQType.caption)
                }
            }
            .padding(SQSpace.lg)
            .sqEditorialCard()
        }
        if let detailError {
            Label(detailError, systemImage: "exclamationmark.triangle")
                .font(SQType.caption)
                .foregroundStyle(SQColor.danger)
                .padding(SQSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqEditorialCard()
        }
    }

    // MARK: Map

    @ViewBuilder
    private var map: some View {
        if let lat = item.latitude ?? signal?.latitude ?? speedtestDetail?.latitude,
           let lng = item.longitude ?? signal?.longitude ?? speedtestDetail?.longitude {
            let center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
            SQRegionMap(region: .constant(region), items: [SQMapPin(coordinate: center)]) { pin in
                MapMarker(coordinate: pin.coordinate, tint: accent)
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                    .stroke(SQColor.separator, lineWidth: 1.5)
            }
        } else if item.kind.lowercased() == "speedtest" {
            Label("Localisation non partagée", systemImage: "location.slash")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
                .padding(SQSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqEditorialCard()
        }
    }

    private var speedtestBackendId: String? {
        guard item.kind.lowercased() == "speedtest" else { return nil }
        return item.targetId ?? item.sourceId
    }

    private func coordinatesText(lat: Double?, lon: Double?) -> String {
        guard let lat, let lon else { return "" }
        return String(format: "%.5f, %.5f", lat, lon)
    }

    // MARK: Actions row

    private var actionsRow: some View {
        HStack(spacing: SQSpace.sm) {
            actionButton(systemImage: item.likedByMe ? "heart.fill" : "heart", tint: item.likedByMe ? SQColor.like : SQColor.label, active: item.likedByMe, pop: item.likedByMe) { onLike() }
                .accessibilityLabel("J’aime")
                .accessibilityAddTraits(item.likedByMe ? .isSelected : [])
            actionButton(systemImage: "bubble.right", tint: SQColor.label, active: false) { onComment(); dismiss() }
                .accessibilityLabel("Commenter")
            actionButton(systemImage: item.repostedByMe ? "arrow.2.squarepath.circle.fill" : "arrow.2.squarepath", tint: item.repostedByMe ? SQColor.success : SQColor.label, active: item.repostedByMe) { onRepost() }
                .accessibilityLabel("Repartager")
                .accessibilityAddTraits(item.repostedByMe ? .isSelected : [])
            actionButton(systemImage: item.favoritedByMe ? "bookmark.fill" : "bookmark", tint: item.favoritedByMe ? SQColor.brandRed : SQColor.label, active: item.favoritedByMe) { onFavorite() }
                .accessibilityLabel(item.favoritedByMe ? "Retirer des favoris" : "Ajouter aux favoris")
                .accessibilityAddTraits(item.favoritedByMe ? .isSelected : [])
            actionButton(systemImage: "paperplane", tint: SQColor.label, active: false) { onShare() }
                .accessibilityLabel("Partager")
        }
        .frame(maxWidth: .infinity)
    }

    /// Bouton d'action éditorial : tuile nette bordée, teinte active (rouge like,
    /// vert repost, rouge bookmark) qui colore aussi le filet. `pop` déclenche le
    /// rebond élastique du like quand l'état change.
    private func actionButton(systemImage: String, tint: Color, active: Bool, pop: Bool = false, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
        return Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .sqLikePop(trigger: pop)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SQSpace.md)
                .background(active ? tint.opacity(0.10) : SQColor.surface, in: shape)
                .overlay { shape.stroke(active ? tint.opacity(0.45) : SQColor.separator, lineWidth: 1.5) }
                .sqAnimation(SQMotion.fast, value: active)
        }
        .buttonStyle(SQPressButtonStyle())
    }
}

private extension String {
    var nonEmptyOrDash: String { isEmpty ? "—" : self }
}
