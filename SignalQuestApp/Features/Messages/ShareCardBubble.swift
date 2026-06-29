import SwiftUI

// MARK: - Cartes de partage & localisation (parité Android)
//
// Rendu, dans une bulle, des messages que l'app Android peut envoyer :
//  - partage générique (speedtest / session / post social) → ShareCardBubble
//  - mesure de signal enrichie (RSRP/score/bande/site)      → SignalCardBubble
//  - localisation                                            → LocationBubble
// Toutes adaptent leurs couleurs selon `mine` (bulle envoyée = fond dégradé).

// MARK: Carte de partage générique

struct ShareCardBubble: View {
    let card: ShareCardData
    let mine: Bool
    @Environment(\.openURL) private var openURL

    private var badge: String {
        switch card.kind.lowercased() {
        case "speedtest": return "SPEEDTEST"
        case "session": return "SESSION"
        case "signal_rating", "signal": return "SIGNAL"
        case "social_post": return "PUBLICATION"
        default: return "PARTAGE"
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
                    .foregroundStyle(mine ? .white : SQColor.brandRed)
                    .frame(width: 32, height: 32)
                    .background(mine ? Color.white.opacity(0.16) : SQColor.brandRed.opacity(0.12), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(badge)
                        .font(SQType.micro)
                        .foregroundStyle(mine ? .white.opacity(0.75) : SQColor.labelTertiary)
                    Text(card.title)
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(mine ? .white : SQColor.label)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SQType.micro)
                    .foregroundStyle(mine ? .white.opacity(0.7) : SQColor.labelSecondary)
                    .lineLimit(2)
            }
            if !card.rows.isEmpty {
                VStack(spacing: SQSpace.xs + 1) {
                    ForEach(card.rows) { row in
                        HStack {
                            Text(row.label)
                                .font(SQType.micro)
                                .foregroundStyle(mine ? .white.opacity(0.7) : SQColor.labelSecondary)
                            Spacer(minLength: SQSpace.sm)
                            Text(row.value)
                                .font(SQType.caption.weight(.medium))
                                .foregroundStyle(mine ? .white : SQColor.label)
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
                    .foregroundStyle(mine ? .white : SQColor.brandRed)
                    .frame(width: 34, height: 34)
                    .background(mine ? Color.white.opacity(0.16) : SQColor.brandRed.opacity(0.12), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(mine ? .white : SQColor.label)
                        .lineLimit(1)
                    if let sub = signal.subtitleLine ?? card.subtitle {
                        Text(sub)
                            .font(SQType.micro)
                            .foregroundStyle(mine ? .white.opacity(0.7) : SQColor.labelSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            // Grand RSRP + badge score
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                if let rsrp = signal.rsrp {
                    Text("\(rsrp)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(mine ? .white : SQColor.label)
                    Text("dBm · RSRP")
                        .font(SQType.micro)
                        .foregroundStyle(mine ? .white.opacity(0.7) : SQColor.labelSecondary)
                } else {
                    Text("RSRP indisponible")
                        .font(SQType.caption)
                        .foregroundStyle(mine ? .white.opacity(0.8) : SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                if let score = signal.resolvedScore {
                    Text("\(score)/100")
                        .font(SQType.caption.weight(.bold))
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 3)
                        .background(mine ? Color.white.opacity(0.22) : scoreColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(mine ? .white : scoreColor)
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
                            .background(mine ? Color.white.opacity(0.14) : SQColor.surfaceMuted, in: Capsule())
                            .foregroundStyle(mine ? .white : SQColor.labelSecondary)
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
                // Vignette « carte » stylisée + épingle
                ZStack {
                    LinearGradient(
                        colors: mine
                            ? [Color.white.opacity(0.22), Color.white.opacity(0.08)]
                            : [SQColor.brandRed.opacity(0.16), SQColor.brandOrange.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    // Lignes discrètes évoquant une carte
                    GeometryReader { geo in
                        Path { path in
                            let step: CGFloat = 26
                            var x: CGFloat = 0
                            while x < geo.size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geo.size.height)); x += step }
                            var y: CGFloat = 0
                            while y < geo.size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geo.size.width, y: y)); y += step }
                        }
                        .stroke(mine ? Color.white.opacity(0.10) : SQColor.separator.opacity(0.5), lineWidth: 0.5)
                    }
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(mine ? .white : SQColor.brandRed)
                        .shadow(radius: 2, y: 1)
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))

                HStack(spacing: SQSpace.xs + 2) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(mine ? .white.opacity(0.85) : SQColor.brandRed)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.place ?? "Position partagée")
                            .font(SQType.caption.weight(.semibold))
                            .foregroundStyle(mine ? .white : SQColor.label)
                            .lineLimit(1)
                        Text("Ouvrir dans Plans · \(coordinateText)")
                            .font(SQType.micro)
                            .foregroundStyle(mine ? .white.opacity(0.7) : SQColor.labelTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(mine ? .white.opacity(0.7) : SQColor.labelTertiary)
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

private struct ShareCardOpenButton: View {
    let mine: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SQSpace.xs) {
                Text("Ouvrir")
                    .font(SQType.caption.weight(.semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(mine ? .white : SQColor.brandRed)
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
    }
}
