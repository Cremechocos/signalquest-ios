import SwiftUI
import CoreLocation

/// Fiche détaillée d'un ami vivant, ouverte au tap sur son marqueur. Présence,
/// snapshot radio (RSRP/RSRQ/SNR pour les amis Android ; techno/opérateur pour
/// iOS), distance, fraîcheur, et raccourcis Message / Profil. Style DA « Crème ».
struct FriendLiveSheet: View {
    let friend: SocialFriendLive
    /// Position de l'utilisateur, pour calculer la distance à l'ami (optionnelle).
    let userLocation: CLLocation?

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var openingConversation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                if let radio = friend.radio, radio.hasDisplayableContent {
                    radioCard(radio)
                }
                metaRow
                actions
            }
            .padding(SQSpace.lg)
            .padding(.top, SQSpace.sm)
        }
        .background(SQColor.bg)
    }

    // MARK: En-tête

    private var header: some View {
        HStack(spacing: SQSpace.md) {
            SQAvatar(url: friend.avatarUrl, name: friend.name ?? "Ami", size: 60)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(presenceColor)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(SQColor.bg, lineWidth: 2.5))
                }
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(friend.name ?? "Ami")
                    .font(SQFont.display(22, .bold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                Text(statusLine)
                    .font(SQFont.body(14))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let technology = friend.radio?.technology, !technology.isEmpty {
                Text(technology.uppercased())
                    .font(SQFont.archivo(12, .bold))
                    .foregroundStyle(SQColor.onAccent)
                    .padding(.horizontal, SQSpace.sm + 1)
                    .padding(.vertical, SQSpace.xs + 1)
                    .background(SQColor.brandRed, in: Capsule())
            }
        }
    }

    private var statusLine: String {
        if let custom = friend.presence?.customStatus, !custom.isEmpty {
            return custom
        }
        return friend.presenceStatus.label
    }

    // MARK: Carte radio

    private func radioCard(_ radio: SocialRadioSnapshot) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Réseau")
                .font(SQFont.archivo(13, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
            let tiles = radioTiles(radio)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SQSpace.sm) {
                ForEach(tiles, id: \.label) { tile in
                    VStack(alignment: .leading, spacing: SQSpace.xxs) {
                        Text(tile.label)
                            .font(SQFont.archivo(11, .semibold))
                            .foregroundStyle(SQColor.labelTertiary)
                        Text(tile.value)
                            .font(SQFont.display(17, .bold))
                            .foregroundStyle(SQColor.label)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SQSpace.md)
                    .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                }
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .shadow(color: SQColor.shadowCard, radius: 10, x: 0, y: 4)
    }

    private struct RadioTile { let label: String; let value: String }

    private func radioTiles(_ radio: SocialRadioSnapshot) -> [RadioTile] {
        var tiles: [RadioTile] = []
        if let operatorName = radio.operator, !operatorName.isEmpty {
            tiles.append(RadioTile(label: "Opérateur", value: operatorName))
        }
        if let city = radio.city, !city.isEmpty {
            tiles.append(RadioTile(label: "Ville", value: city))
        }
        if let rsrp = radio.rsrp {
            tiles.append(RadioTile(label: "RSRP", value: "\(Int(rsrp)) dBm"))
        }
        if let rsrq = radio.rsrq {
            tiles.append(RadioTile(label: "RSRQ", value: "\(Int(rsrq)) dB"))
        }
        if let snr = radio.snr {
            tiles.append(RadioTile(label: "SNR", value: "\(Int(snr)) dB"))
        }
        if let band = radio.band {
            tiles.append(RadioTile(label: "Bande", value: "B\(band)"))
        }
        return tiles
    }

    // MARK: Distance + fraîcheur

    private var metaRow: some View {
        HStack(spacing: SQSpace.sm) {
            if let distance = distanceText {
                metaChip(icon: "location.fill", text: distance)
            }
            if let freshness = freshnessText {
                metaChip(icon: "clock", text: freshness)
            }
            Spacer(minLength: 0)
        }
    }

    private func metaChip(icon: String, text: String) -> some View {
        HStack(spacing: SQSpace.xs + 1) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(SQFont.archivo(13, .semibold))
        }
        .foregroundStyle(SQColor.labelSecondary)
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .background(SQColor.surface, in: Capsule())
        .shadow(color: SQColor.shadowSoft, radius: 6, x: 0, y: 2)
    }

    private var distanceText: String? {
        guard let userLocation, let location = friend.location else { return nil }
        let target = CLLocation(latitude: location.lat, longitude: location.lng)
        let meters = userLocation.distance(from: target)
        if meters < 1000 { return "à \(Int(meters.rounded())) m" }
        return "à " + String(format: "%.1f", meters / 1000).replacingOccurrences(of: ".", with: ",") + " km"
    }

    private var freshnessText: String? {
        guard let updatedAt = friend.location?.updatedAt else { return nil }
        // Position très fraîche (ou léger décalage d'horloge) : « à l'instant »
        // plutôt qu'un « dans 0 s » qui suggère à tort le futur.
        if Date().timeIntervalSince(updatedAt) < 15 { return "à l'instant" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: updatedAt, relativeTo: Date())
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: SQSpace.md) {
            Button {
                Task { await openConversation() }
            } label: {
                actionLabel(icon: "bubble.left.and.bubble.right.fill", title: "Message", filled: true)
            }
            .disabled(openingConversation)

            Button {
                dismiss()
                services.router.route(toUserProfile: friend.id)
            } label: {
                actionLabel(icon: "person.crop.circle", title: "Profil", filled: false)
            }
        }
        .padding(.top, SQSpace.xs)
    }

    private func actionLabel(icon: String, title: String, filled: Bool) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
            Text(title)
                .font(SQFont.archivo(16, .semibold))
        }
        .foregroundStyle(filled ? SQColor.onAccent : SQColor.label)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
            filled ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
            in: Capsule()
        )
        .shadow(color: filled ? SQColor.shadowAccent : SQColor.shadowSoft, radius: filled ? 10 : 6, x: 0, y: filled ? 6 : 2)
    }

    private func openConversation() async {
        guard !openingConversation else { return }
        openingConversation = true
        defer { openingConversation = false }
        guard let response = try? await services.messages.createConversation(
            participantIds: [friend.id], title: nil, e2ee: true
        ) else { return }
        dismiss()
        services.router.route(toConversation: response.conversationId)
    }

    // MARK: Présence

    private var presenceColor: Color {
        switch friend.presenceStatus {
        case .online: return SQColor.success
        case .away: return SQColor.warning
        case .dnd: return SQColor.danger
        case .offline, .invisible: return SQColor.labelTertiary
        }
    }
}

private extension SocialRadioSnapshot {
    /// Vrai si au moins un champ radio est affichable (évite une carte vide).
    var hasDisplayableContent: Bool {
        (`operator`?.isEmpty == false) || (city?.isEmpty == false)
            || rsrp != nil || rsrq != nil || snr != nil || band != nil
    }
}
