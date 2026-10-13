import SwiftUI
import MapKit

/// Publication ouverte depuis une carte du fil : en-tête de la carte, texte,
/// bloc de mesure, toutes les valeurs connues en lignes clé-valeur, mini-carte,
/// actions, puis le premier commentaire.
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
    var actionError: String? = nil
    var actionBusy = false

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var speedtestDetail: SpeedtestDetail?
    @State private var detailError: String?
    /// Premier commentaire, montré sous les actions : la conversation se lit
    /// sans ouvrir une deuxième feuille.
    @State private var firstComment: SocialComment?

    private var signal: SocialSignalSummary? { item.signal }
    private var accent: Color { TechAccent.color(for: signal?.technology) }
    private var isSpeedtest: Bool { item.kind.lowercased() == "speedtest" }
    private var place: String? { signal?.city ?? item.placeLabel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                topBar
                CardHeader(
                    author: item.author,
                    place: place,
                    createdAt: item.createdAt,
                    kindBadge: kindTag,
                    kindColor: accent,
                    onAuthorTap: onAuthorTap.map { tap in { dismiss(); tap() } }
                )
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("signal.detail.actionError")
                }
                if actionBusy {
                    ProgressView("En cours")
                        .tint(SQColor.brandRed)
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(SQFont.body(16, .regular, relativeTo: .body))
                        .lineSpacing(4)
                        .foregroundStyle(SQColor.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !item.hashtags.isEmpty {
                    CardHashtags(tags: item.hashtags)
                }
                if isSpeedtest {
                    FeedMeasureBlock(signal: signal)
                }
                detailsSection
                map
                CardActionsBar(
                    item: item,
                    onLike: onLike,
                    onRepost: onRepost,
                    onComment: onComment,
                    onFavorite: onFavorite,
                    onShare: onShare
                )
                commentsPreview
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .task(id: item.sourceId) { await loadSpeedtestDetailIfNeeded() }
        .task(id: item.id) { await loadFirstCommentIfNeeded() }
        .presentationDetents([.medium, .large])
        .sqSheet()
    }

    // MARK: Header

    /// Fermer à gauche, ⋯ à droite, sans titre : l'auteur ouvre la feuille.
    private var topBar: some View {
        HStack {
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "signal.detail.close") {
                dismiss()
            }
            Spacer(minLength: 0)
            Menu {
                // Pas de `dismiss()` ici : le parent remplace la fiche par
                // le signalement ; fermer en plus annulait cette présentation (AF-FIL-02).
                Button(role: .destructive) { onReport() } label: {
                    Label("Signaler", systemImage: "flag")
                }
                Button { onMute() } label: {
                    Label(
                        item.notificationsMutedByMe == true ? "Réactiver les notifications" : "Couper les notifications",
                        systemImage: item.notificationsMutedByMe == true ? "bell" : "bell.slash"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .sqSurface(SQColor.chip, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Plus d’options")
            .accessibilityIdentifier("signal.detail.more")
        }
    }

    /// Badge réservé aux photos d'antenne et aux pannes, comme sur les cartes
    /// du fil ; jamais le type brut (« DRIVE_TEST », TRX-26).
    private var kindTag: String? {
        switch item.kind.lowercased() {
        case "outage": return String(localized: "Panne")
        case "photo", "antenna_photo": return String(localized: "Photo d’antenne")
        default: return nil
        }
    }

    // MARK: Details

    /// Toutes les valeurs connues en lignes clé-valeur sur une seule carte.
    @ViewBuilder
    private var detailsSection: some View {
        let pairs = detailPairs
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Détails")
                    .sqKicker()
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: SQSpace.sm2) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        SQFactRow(label: pair.0, value: pair.1)
                    }
                }
                .padding(SQSpace.lg)
                .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .accessibilityIdentifier("signal.detail.facts")
            }
        }
        if let detailError {
            Label(detailError, systemImage: "exclamationmark.triangle")
                .font(SQType.caption)
                .foregroundStyle(SQColor.dangerInk)
        }
    }

    private var detailPairs: [(String, String)] {
        var pairs: [(String, String)] = []
        if let signal {
            pairs += metricPairs(for: signal)
            pairs += [
                ("EARFCN", signal.earfcn.map(String.init) ?? ""),
                ("ARFCN", signal.arfcn.map(String.init) ?? ""),
                ("Secteurs", signal.sectors?.prefix(4).map(String.init).joined(separator: " · ") ?? ""),
                ("Appareil", signal.deviceModel ?? "")
            ]
        }
        pairs += speedtestPairs
        pairs.append(("Lieu", place ?? ""))
        // Une clé n'apparaît qu'une fois : le détail serveur et le résumé du
        // post se recoupent (appareil, opérateur).
        var seen = Set<String>()
        return pairs.filter { pair in
            guard !pair.1.isEmpty, pair.1 != "—", !seen.contains(pair.0) else { return false }
            seen.insert(pair.0)
            return true
        }
    }

    private func metricPairs(for signal: SocialSignalSummary) -> [(String, String)] {
        switch item.kind.lowercased() {
        case "speedtest":
            let detail = speedtestDetail
            return [
                // Le bloc de mesure affiche la réception du résumé ; le détail
                // serveur la complète quand le résumé ne l'a pas.
                ("Réception", signal.downloadMbps == nil
                    ? SignalFormatters.speed(detail?.averageSpeed ?? detail?.downloadAvg) : ""),
                ("Opérateur", signal.servingOperator ?? signal.operator ?? detail?.mobileOperator ?? ""),
                ("SIM", signal.isRoaming == true ? signal.simOperator ?? "" : ""),
                ("Technologie", signal.technology ?? detail?.networkType ?? ""),
                ("Latence min", SignalFormatters.ms(detail?.pingMin ?? detail?.ping ?? signal.pingMs)),
                ("Gigue", SignalFormatters.ms(detail?.jitter ?? signal.jitterMs))
            ]
        case "validation":
            return [
                ("Identifiant", signal.identifierValue ?? ""),
                ("Type", signal.identifierType?.uppercased() ?? ""),
                ("PCI", signal.pci.map(String.init) ?? ""),
                ("Cell", signal.cellId ?? ""),
                ("Bande", signal.band ?? ""),
                ("Fréquence", signal.frequency ?? "")
            ]
        case "coverage", "session", "drive_test":
            return [
                ("Distance", SignalFormatters.meters(signal.distanceMeters)),
                ("Durée", SignalFormatters.duration(signal.durationSeconds)),
                ("Points", signal.pointsCount.map(String.init) ?? ""),
                ("Signal moy.", SignalFormatters.dbm(signal.averageSignalDbm)),
                ("Min / Max", rangeText(signal: signal)),
                ("Techs", signal.detectedTechs.prefix(3).joined(separator: " / "))
            ]
        default:
            return [
                ("Opérateur", signal.operator ?? ""),
                ("RSRP", SignalFormatters.dbm(signal.rsrp)),
                ("RSRQ", SignalFormatters.db(signal.rsrq)),
                ("SINR", SignalFormatters.db(signal.sinr)),
                ("Bande", signal.band ?? ""),
                ("Cell", signal.cellId ?? "")
            ]
        }
    }

    private var speedtestPairs: [(String, String)] {
        guard let detail = speedtestDetail else { return [] }
        let uploadSource = SpeedtestDetailContent.resultByteSource(
            detail.measurementTrace?.phases.first(where: { $0.phase == "upload" }), fallback: detail.uploadMeasurementSource)
        return [
            ("Réseau", [detail.connectionType, detail.networkType].compactMap { $0 }.joined(separator: " / ")),
            ("Appareil", [detail.deviceType, detail.deviceModel].compactMap { $0 }.joined(separator: " ")),
            ("Durée", SignalFormatters.duration(detail.testDuration)),
            ("Latence moyenne", SignalFormatters.ms(detail.pingAvg)),
            ("Latence médiane", SignalFormatters.ms(detail.pingMedian)),
            ("Latence max", SignalFormatters.ms(detail.pingMax)),
            ("Octets envoi", uploadSource == "tcp-acknowledged"
                ? SpeedtestDetailContent.byteSourceLabel("tcp-acknowledged") : ""),
            ("Position", coordinatesText(lat: detail.latitude, lon: detail.longitude))
        ]
    }

    // MARK: Comments

    /// Premier commentaire et lien vers la conversation, ou une invitation à
    /// commenter quand il n'y en a pas encore.
    private var commentsPreview: some View {
        let count = item.commentsCount
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            Divider().overlay(SQColor.separator)
            Button {
                Haptics.light()
                onComment()
            } label: {
                VStack(alignment: .leading, spacing: SQSpace.sm2) {
                    if let comment = firstComment {
                        HStack(alignment: .top, spacing: SQSpace.sm2) {
                            SQAvatar(url: comment.author.avatarUrl, name: comment.author.displayName, size: 30)
                            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                                HStack(spacing: SQSpace.xs) {
                                    Text(comment.author.displayName)
                                        .font(SQType.caption(.bold))
                                        .foregroundStyle(SQColor.label)
                                    if let created = comment.createdAt {
                                        Text(verbatim: "·").accessibilityHidden(true)
                                        Text(created, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                    }
                                }
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                Text(comment.text)
                                    .font(SQType.subhead)
                                    .foregroundStyle(SQColor.label)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                    Text(count > 0 ? "Voir les \(count) commentaires" : "Ajouter un commentaire")
                        .font(SQType.subhead(.bold))
                        .foregroundStyle(SQColor.accentInk)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("signal.detail.comments")
        }
    }

    private func loadFirstCommentIfNeeded() async {
        guard item.commentsCount > 0 else { return }
        // Silencieux en cas d'échec : le lien vers les commentaires reste.
        firstComment = try? await services.comments.list(postId: item.backendPostId, cursor: nil).comments.first
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
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        } else if item.kind.lowercased() == "speedtest" {
            Label("Localisation non partagée", systemImage: "location.slash")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func coordinatesText(lat: Double?, lon: Double?) -> String {
        guard let lat, let lon else { return "" }
        return String(format: "%.5f, %.5f", lat, lon)
    }

    private func loadSpeedtestDetailIfNeeded() async {
        guard item.kind.lowercased() == "speedtest",
              let sourceId = item.sourceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceId.isEmpty else { return }
        do {
            speedtestDetail = try await services.speedtest.details(id: sourceId)
            detailError = nil
        } catch {
            // Le résumé du post reste une source valide : l'échec du détail ne
            // doit pas transformer une publication lisible en écran d'erreur.
            if signal == nil {
                detailError = String(localized: "Détails momentanément indisponibles")
            }
        }
    }
}

