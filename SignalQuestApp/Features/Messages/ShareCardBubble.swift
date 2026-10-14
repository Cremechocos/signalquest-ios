import SwiftUI

// MARK: - Cartes de partage & localisation (parité Android)
//
// Rendu, dans une bulle, des messages que l'app Android peut envoyer :
//  - partage générique (speedtest / session / post social) → ShareCardBubble
//  - mesure de signal enrichie (RSRP/score/bande/site)      → SignalCardBubble
//  - localisation                                            → LocationBubble
// Toutes adaptent leurs couleurs selon `mine` (bulle envoyée = fond encre,
// textes en `onInk`).

// MARK: Carte de partage générique

struct ShareCardBubble: View {
    let card: ShareCardData
    let mine: Bool
    @Environment(\.openURL) private var openURL
    @State private var externalURL: URL?

    private func open(_ url: URL) {
        if ShareCardData.isSignalQuestURL(url) { openURL(url) } else { externalURL = url }
    }

    private var badge: String {
        switch card.kind.lowercased() {
        case "speedtest": return "Speedtest"
        case "session": return "Session"
        case "signal_rating", "signal": return "Signal"
        case "social_post": return String(localized: "Publication")
        default: return String(localized: "Partage")
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
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                    .frame(width: 32, height: 32)
                    .background(mine ? SQColor.onInk.opacity(0.16) : SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(badge)
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                    Text(card.title)
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(SQType.micro)
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                    .lineLimit(2)
            }
            // Débit en grand quand la carte porte une mesure ; les lignes
            // détaillées restent dessous.
            if let down = card.speedtest?.downloadMbps {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: SQUnits.throughputValue(mbps: down))
                        .font(SQType.metricSmall)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                    Text(verbatim: SQUnits.throughputUnit(mbps: down))
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            if !card.rows.isEmpty {
                VStack(spacing: SQSpace.xs + 1) {
                    ForEach(card.rows) { row in
                        HStack {
                            Text(row.label)
                                .font(SQType.micro)
                                .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                            Spacer(minLength: SQSpace.sm)
                            Text(row.value)
                                .font(SQType.caption.weight(.medium))
                                .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.top, 1)
            }
            if let url = card.openURL {
                ShareCardOpenButton(mine: mine) { open(url) }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .confirmsExternalLink($externalURL)
    }
}

// MARK: Carte « Mesure de signal » dédiée

struct SignalCardBubble: View {
    let card: ShareCardData
    let signal: SignalShareData
    let mine: Bool
    @Environment(\.openURL) private var openURL
    @State private var externalURL: URL?

    private func open(_ url: URL) {
        if ShareCardData.isSignalQuestURL(url) { openURL(url) } else { externalURL = url }
    }

    private var scoreColor: Color {
        switch signal.resolvedScore ?? 0 {
        case 67...: return SQColor.success
        case 34...: return SQColor.warning
        default: return SQColor.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            // En-tête : pastille + titre + opérateur·techno
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                    .frame(width: 34, height: 34)
                    .background(mine ? SQColor.onInk.opacity(0.16) : SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                        .lineLimit(2)
                    if let sub = signal.subtitleLine ?? card.subtitle {
                        Text(sub)
                            .font(SQType.micro)
                            .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            // Grand RSRP + badge score
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                if let rsrp = signal.rsrp {
                    Text("\(rsrp)")
                        .font(SQType.metricMedium)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                    Text("dBm · RSRP")
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onInk.opacity(0.7) : SQColor.labelSecondary)
                } else {
                    Text("RSRP indisponible")
                        .font(SQType.caption)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                if let score = signal.resolvedScore {
                    Text("\(score)/100")
                        .font(SQType.caption.weight(.bold))
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 3)
                        .background(mine ? SQColor.onInk.opacity(0.22) : scoreColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(mine ? SQColor.onInk : scoreColor)
                }
            }

            // Puces bande / site
            let chips: [String] = [
                signal.band.map { String(localized: "Bande \($0)") },
                signal.site.map { String(localized: "Site \($0)") }
            ].compactMap { $0 }
            if !chips.isEmpty {
                HStack(spacing: SQSpace.xs2) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(SQType.micro)
                            .padding(.horizontal, SQSpace.sm)
                            .padding(.vertical, 3)
                            .background(mine ? SQColor.onInk.opacity(0.14) : SQColor.surfaceMuted, in: Capsule())
                            .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                    }
                }
            }

            if let url = card.openURL {
                ShareCardOpenButton(mine: mine) { open(url) }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .confirmsExternalLink($externalURL)
    }
}

// MARK: Carte de publication partagée (kind « social_post »)

/// Rendu fidèle d'une publication partagée : en-tête auteur, texte, vignette OU
/// bandeau mesure, pied « Voir la publication ». Parité design A Android.
struct SharedPostCardBubble: View {
    let card: ShareCardData
    let mine: Bool
    @Environment(\.openURL) private var openURL
    @State private var externalURL: URL?

    private func open(_ url: URL) {
        if ShareCardData.isSignalQuestURL(url) { openURL(url) } else { externalURL = url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            header
            if let text = card.text, !text.isEmpty {
                Text(text)
                    .font(SQType.caption)
                    .foregroundStyle(mine ? SQColor.onInk.opacity(0.92) : SQColor.labelSecondary)
                    .lineLimit(4)
            }
            media
            if let url = card.openURL {
                Rectangle()
                    .fill(mine ? SQColor.onInk.opacity(0.22) : SQColor.separator)
                    .frame(height: 0.5)
                Button {
                    Haptics.selection()
                    open(url)
                } label: {
                    HStack(spacing: SQSpace.xs) {
                        Text("Voir la publication")
                            .font(SQType.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                    .frame(minHeight: 28)
                    // Zone tactile de 44 pt sans agrandir la rangée.
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .padding(.vertical, -8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voir la publication")
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .confirmsExternalLink($externalURL)
    }

    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            SQAvatar(url: card.author?.avatarUrl, name: card.author?.displayName ?? "SignalQuest", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.author?.displayName ?? card.title)
                    .font(SQType.callout(.semibold))
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                    .sqSingleLine()
                Text(sourceLine)
                    .font(SQType.micro)
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var sourceLine: String {
        if let handle = card.author?.handleLine { return String(localized: "\(handle) · Fil réseau") }
        return String(localized: "Fil réseau")
    }

    /// Vignette image en priorité ; sinon bandeau de mesure selon ce que porte la
    /// publication (signal → speedtest → session).
    @ViewBuilder
    private var media: some View {
        if let image = card.imageUrl {
            RemoteImage(url: image, maxDimension: 600, contentMode: .fill, showsFailureUI: true) {
                Rectangle()
                    .fill(mine ? SQColor.onInk.opacity(0.12) : SQColor.surfaceMuted)
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
                        signal.band.map { String(localized: "Bande \($0)") }, signal.site.map { String(localized: "Site \($0)") }]
            )
        } else if let speedtest = card.speedtest, speedtest.downloadMbps != nil {
            measurementBanner(
                primary: formatMbps(speedtest.downloadMbps),
                unit: SQUnits.throughputUnit(mbps: speedtest.downloadMbps ?? 0),
                tint: mine ? SQColor.onInk : SQColor.brandRed,
                chips: [speedtest.uploadMbps.map { "↑ \(SQUnits.throughput(mbps: $0))" },
                        speedtest.pingMs.map { "\(Int($0.rounded())) ms" },
                        speedtest.operatorName, speedtest.technology]
            )
        } else if let session = card.session, session.points != nil || session.distanceKm != nil {
            measurementBanner(
                primary: session.points.map { "\($0)" } ?? "—",
                unit: "points",
                tint: mine ? SQColor.onInk : SQColor.brandRed,
                chips: [session.distanceKm.map { SQUnits.distance(kilometers: $0) },
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
                    .font(SQType.metricSmall)
                    .foregroundStyle(mine ? SQColor.onInk : tint)
                Text(unit)
                    .font(SQType.micro)
                    .foregroundStyle(mine ? SQColor.onInk.opacity(0.7) : SQColor.labelSecondary)
            }
            if !visibleChips.isEmpty {
                Text(visibleChips.joined(separator: " · "))
                    .font(SQType.micro)
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SQSpace.sm2)
        .padding(.vertical, SQSpace.sm)
        .background(mine ? SQColor.onInk.opacity(0.12) : SQColor.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// Échelle RSRP canonique unique (SQNetworkColors) — mêmes couleurs que la
    /// carte et les fiches.
    private func rsrpColor(_ rsrp: Int) -> Color {
        SQNetworkColors.rsrpColor(Double(rsrp))
    }

    private func formatMbps(_ value: Double?) -> String {
        guard let value else { return "—" }
        return SQUnits.throughputValue(mbps: value)
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

    private var observedAtText: String? {
        guard let observedAt = location.observedAt else { return nil }
        return "\(String(localized: "Mesurée à")) \(observedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var accuracyText: String? {
        guard let accuracy = location.accuracyMeters else { return nil }
        return "\(String(localized: "Précision")) ±\(SQUnits.distance(meters: accuracy))"
    }

    private var measurementAccessibilityValue: String {
        [observedAtText, accuracyText].compactMap { $0 }.joined(separator: ". ")
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
                        .fill(mine ? SQColor.onInk.opacity(0.14) : SQColor.surfaceMuted)
                    // Lignes discrètes évoquant une carte
                    GeometryReader { geo in
                        Path { path in
                            let step: CGFloat = 26
                            var x: CGFloat = 0
                            while x < geo.size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geo.size.height)); x += step }
                            var y: CGFloat = 0
                            while y < geo.size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geo.size.width, y: y)); y += step }
                        }
                        .stroke(mine ? SQColor.onInk.opacity(0.10) : SQColor.separator.opacity(0.5), lineWidth: 0.5)
                    }
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))

                HStack(spacing: SQSpace.xs2) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(mine ? SQColor.onInk.opacity(0.85) : SQColor.brandRed)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.place ?? String(localized: "Position partagée"))
                            .font(SQType.caption.weight(.semibold))
                            .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                            .lineLimit(2)
                        Text("Ouvrir dans Plans · \(coordinateText)")
                            .font(SQType.micro)
                            .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                            .lineLimit(2)
                        if let observedAtText {
                            Text(observedAtText)
                                .font(SQType.caption)
                                .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let accuracyText {
                            Text(accuracyText)
                                .font(SQType.caption)
                                .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(mine ? SQColor.onInk.opacity(0.7) : SQColor.labelTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.top, SQSpace.xs2)
            }
            .frame(maxWidth: 260, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position : \(location.place ?? coordinateText). Toucher pour ouvrir dans Plans.")
        .accessibilityValue(measurementAccessibilityValue)
    }
}

// MARK: Bouton « Ouvrir » partagé

/// Un lien de carte hors de SignalQuest n'est ouvert qu'après avoir montré
/// son domaine : l'expéditeur choisit l'URL, le titre de la carte peut mentir.
private struct ExternalLinkConfirmation: ViewModifier {
    @Binding var url: URL?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Ouvrir un lien externe ?",
            isPresented: Binding(get: { url != nil }, set: { if !$0 { url = nil } }),
            titleVisibility: .visible,
            presenting: url
        ) { target in
            Button("Ouvrir") { openURL(target) }
            Button("Annuler", role: .cancel) {}
        } message: { target in
            Text("Ce lien mène hors de SignalQuest, vers \(target.host ?? "").")
        }
    }
}

private extension View {
    func confirmsExternalLink(_ url: Binding<URL?>) -> some View {
        modifier(ExternalLinkConfirmation(url: url))
    }
}

/// CTA d'ouverture harmonisé avec la carte de publication : hairline puis
/// rangée pleine largeur « Ouvrir » + chevron (teinte onInk/brandRed).
private struct ShareCardOpenButton: View {
    let mine: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            Rectangle()
                .fill(mine ? SQColor.onInk.opacity(0.22) : SQColor.separator)
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
                .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                .frame(minHeight: 28)
                // Zone tactile de 44 pt sans agrandir la rangée.
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .padding(.vertical, -8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ouvrir le partage")
        }
        .padding(.top, 1)
    }
}
