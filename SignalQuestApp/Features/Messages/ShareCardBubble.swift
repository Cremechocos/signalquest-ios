import SwiftUI

// MARK: - Cartes de partage & localisation (parité Android)
//
// Rendu, dans une bulle, des messages que l'app Android peut envoyer :
//  - partage générique (speedtest / session / post social) → ShareCardBubble
//  - mesure de signal enrichie (RSRP/score/bande/site)      → SignalCardBubble
//  - localisation                                            → LocationBubble
// Toutes adaptent leurs couleurs selon `mine` (bulle envoyée = fond brique,
// textes en crème `onAccent`).

// MARK: Carte de partage générique

struct ShareCardBubble: View {
    let card: ShareCardData
    let mine: Bool
    @Environment(\.openURL) private var openURL

    private var badge: String {
        switch card.kind.lowercased() {
        case "speedtest": return "Speedtest"
        case "session": return "Session"
        case "signal_rating", "signal": return "Signal"
        case "social_post": return "Publication"
        default: return "Partage"
        }
    }

    private var icon: String {
        switch card.kind.lowercased() {
        case "speedtest": return "speedometer"
        case "session": return "map"
        case "signal_rating", "signal": return "antenna.radiowaves.left.and.right"
        case "social_post": return "bubble.left.and.text.bubble.right"
        default: return "square.and.arrow.up"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mine ? SQColor.onAccent : SQColor.brandRed)
                    .frame(width: 32, height: 32)
                    .background(mine ? SQColor.onAccent.opacity(0.16) : SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(badge)
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onAccent.opacity(0.75) : SQColor.labelTertiary)
                    Text(card.title)
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SQType.micro)
                    .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelSecondary)
                    .lineLimit(2)
            }
            if !card.rows.isEmpty {
                VStack(spacing: SQSpace.xs + 1) {
                    ForEach(card.rows) { row in
                        HStack {
                            Text(row.label)
                                .font(SQType.micro)
                                .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelSecondary)
                            Spacer(minLength: SQSpace.sm)
                            Text(row.value)
                                .font(SQType.caption.weight(.medium))
                                .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.top, 1)
            }
            if let url = card.openURL {
                ShareCardOpenButton(mine: mine) { openURL(url) }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }
}

// MARK: Carte « Mesure de signal » dédiée

struct SignalCardBubble: View {
    let card: ShareCardData
    let signal: SignalShareData
    let mine: Bool
    @Environment(\.openURL) private var openURL

    private var scoreColor: Color {
        switch signal.resolvedScore ?? 0 {
        case 67...: return SQColor.success
        case 34...: return SQColor.warning
        default: return SQColor.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            // En-tête : pastille + titre + opérateur·techno
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(mine ? SQColor.onAccent : SQColor.brandRed)
                    .frame(width: 34, height: 34)
                    .background(mine ? SQColor.onAccent.opacity(0.16) : SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                        .lineLimit(1)
                    if let sub = signal.subtitleLine ?? card.subtitle {
                        Text(sub)
                            .font(SQType.micro)
                            .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            // Grand RSRP + badge score
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                if let rsrp = signal.rsrp {
                    Text("\(rsrp)")
                        .font(SQFont.display(30, .bold))
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                    Text("dBm · RSRP")
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelSecondary)
                } else {
                    Text("RSRP indisponible")
                        .font(SQType.caption)
                        .foregroundStyle(mine ? SQColor.onAccent.opacity(0.8) : SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                if let score = signal.resolvedScore {
                    Text("\(score)/100")
                        .font(SQType.caption.weight(.bold))
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 3)
                        .background(mine ? SQColor.onAccent.opacity(0.22) : scoreColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(mine ? SQColor.onAccent : scoreColor)
                }
            }

            // Puces bande / site
            let chips: [String] = [
                signal.band.map { "Bande \($0)" },
                signal.site.map { "Site \($0)" }
            ].compactMap { $0 }
            if !chips.isEmpty {
                HStack(spacing: SQSpace.xs + 2) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(SQType.micro)
                            .padding(.horizontal, SQSpace.sm)
                            .padding(.vertical, 3)
                            .background(mine ? SQColor.onAccent.opacity(0.14) : SQColor.surfaceMuted, in: Capsule())
                            .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
                    }
                }
            }

            if let url = card.openURL {
                ShareCardOpenButton(mine: mine) { openURL(url) }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }
}

// MARK: Carte de publication partagée (kind « social_post »)

/// Rendu fidèle d'une publication partagée : en-tête auteur, texte, vignette OU
/// bandeau mesure, pied « Voir la publication ». Parité design A Android.
struct SharedPostCardBubble: View {
    let card: ShareCardData
    let mine: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            header
            if let text = card.text, !text.isEmpty {
                Text(text)
                    .font(SQType.caption)
                    .foregroundStyle(mine ? SQColor.onAccent.opacity(0.92) : SQColor.labelSecondary)
                    .lineLimit(4)
            }
            media
            if let url = card.openURL {
                Rectangle()
                    .fill(mine ? SQColor.onAccent.opacity(0.22) : SQColor.separator)
                    .frame(height: 0.5)
                Button {
                    Haptics.selection()
                    openURL(url)
                } label: {
                    HStack(spacing: SQSpace.xs) {
                        Text("Voir la publication")
                            .font(SQType.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(mine ? SQColor.onAccent : SQColor.brandRed)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voir la publication")
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            SQAvatar(url: card.author?.avatarUrl, name: card.author?.displayName ?? "SignalQuest", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.author?.displayName ?? card.title)
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                    .lineLimit(1)
                Text(sourceLine)
                    .font(SQType.micro)
                    .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var sourceLine: String {
        if let handle = card.author?.handleLine { return "\(handle) · Fil réseau" }
        return "Fil réseau"
    }

    /// Vignette image en priorité ; sinon bandeau de mesure selon ce que porte la
    /// publication (signal → speedtest → session).
    @ViewBuilder
    private var media: some View {
        if let image = card.imageUrl {
            RemoteImage(url: image, maxDimension: 600, contentMode: .fill) {
                Rectangle()
                    .fill(mine ? SQColor.onAccent.opacity(0.12) : SQColor.surfaceMuted)
                    .sqShimmer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
        } else if let signal = card.signal, let rsrp = signal.rsrp {
            measurementBanner(
                primary: "\(rsrp)",
                unit: "dBm",
                tint: rsrpColor(rsrp),
                chips: [signal.operatorName, signal.technology,
                        signal.band.map { "Bande \($0)" }, signal.site.map { "Site \($0)" }]
            )
        } else if let speedtest = card.speedtest, speedtest.downloadMbps != nil {
            measurementBanner(
                primary: formatMbps(speedtest.downloadMbps),
                unit: "Mb/s",
                tint: mine ? SQColor.onAccent : SQColor.brandRed,
                chips: [speedtest.uploadMbps.map { "↑ \(formatMbps($0)) Mb/s" },
                        speedtest.pingMs.map { "\(Int($0.rounded())) ms" },
                        speedtest.operatorName, speedtest.technology]
            )
        } else if let session = card.session, session.points != nil || session.distanceKm != nil {
            measurementBanner(
                primary: session.points.map { "\($0)" } ?? "—",
                unit: "points",
                tint: mine ? SQColor.onAccent : SQColor.brandRed,
                chips: [session.distanceKm.map { String(format: "%.1f km", $0) },
                        session.durationSeconds.map { formatDuration($0) }, session.technologies]
            )
        }
    }

    private func measurementBanner(primary: String, unit: String, tint: Color, chips: [String?]) -> some View {
        let visibleChips = chips.compactMap { chip -> String? in
            guard let value = chip?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }.prefix(3)
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(primary)
                    .font(SQFont.display(20, .bold))
                    .foregroundStyle(mine ? SQColor.onAccent : tint)
                Text(unit)
                    .font(SQType.micro)
                    .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelTertiary)
            }
            if !visibleChips.isEmpty {
                Text(visibleChips.joined(separator: " · "))
                    .font(SQType.micro)
                    .foregroundStyle(mine ? SQColor.onAccent.opacity(0.75) : SQColor.labelSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SQSpace.sm + 2)
        .padding(.vertical, SQSpace.sm)
        .background(mine ? SQColor.onAccent.opacity(0.12) : SQColor.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// Seuils qualité RSRP alignés sur Android : ≥−85 vert, ≥−100 ambre, sinon rouge.
    private func rsrpColor(_ rsrp: Int) -> Color {
        switch rsrp {
        case (-85)...: return SQColor.success
        case (-100)...: return SQColor.warning
        default: return SQColor.danger
        }
    }

    private func formatMbps(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return minutes > 0 ? "\(minutes) min" : "\(seconds) s"
    }
}

// MARK: Carte de localisation

struct LocationBubble: View {
    let location: MessageLocationData
    let mine: Bool
    @Environment(\.openURL) private var openURL

    private var coordinateText: String {
        String(format: "%.4f, %.4f", location.latitude, location.longitude)
    }

    var body: some View {
        Button {
            if let url = location.appleMapsURL {
                Haptics.selection()
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Vignette « carte » stylisée + épingle (aplat SurfaceMuted, sans dégradé)
                ZStack {
                    Rectangle()
                        .fill(mine ? SQColor.onAccent.opacity(0.14) : SQColor.surfaceMuted)
                    // Lignes discrètes évoquant une carte
                    GeometryReader { geo in
                        Path { path in
                            let step: CGFloat = 26
                            var x: CGFloat = 0
                            while x < geo.size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geo.size.height)); x += step }
                            var y: CGFloat = 0
                            while y < geo.size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geo.size.width, y: y)); y += step }
                        }
                        .stroke(mine ? SQColor.onAccent.opacity(0.10) : SQColor.separator.opacity(0.5), lineWidth: 0.5)
                    }
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.brandRed)
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))

                HStack(spacing: SQSpace.xs + 2) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(mine ? SQColor.onAccent.opacity(0.85) : SQColor.brandRed)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.place ?? "Position partagée")
                            .font(SQType.caption.weight(.semibold))
                            .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                            .lineLimit(1)
                        Text("Ouvrir dans Plans · \(coordinateText)")
                            .font(SQType.micro)
                            .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.top, SQSpace.xs + 2)
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position : \(location.place ?? coordinateText). Toucher pour ouvrir dans Plans.")
    }
}

// MARK: Bouton « Ouvrir » partagé

/// CTA d'ouverture harmonisé avec la carte de publication : hairline puis
/// rangée pleine largeur « Ouvrir » + chevron (teinte onAccent/brandRed).
private struct ShareCardOpenButton: View {
    let mine: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
            Rectangle()
                .fill(mine ? SQColor.onAccent.opacity(0.22) : SQColor.separator)
                .frame(height: 0.5)
            Button {
                Haptics.selection()
                action()
            } label: {
                HStack(spacing: SQSpace.xs) {
                    Text("Ouvrir")
                        .font(SQType.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(mine ? SQColor.onAccent : SQColor.brandRed)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ouvrir le partage")
        }
        .padding(.top, 1)
    }
}
