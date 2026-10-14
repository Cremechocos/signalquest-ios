import SwiftUI

/// Bilan hebdomadaire, consultable et partageable.
///
/// C'est le seul item du chantier social qui génère de l'ACQUISITION : l'image
/// sort de l'app. D'où deux exigences — un rendu déterministe (indépendant du
/// réglage Dynamic Type de l'appareil) et une carte qui se suffit à elle-même
/// hors contexte, marque comprise.
struct WeeklyRecapSheet: View {
    let service: SocialFeedServicing
    /// Appelé quand une nouvelle story vient d'être créée, pour que le fil l'affiche.
    var onPublished: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var stats: WeeklyRecapStats?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var shareURL: URL?
    @State private var isPublishing = false
    @State private var publishNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "weeklyRecap.close") { dismiss() }

                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Ma semaine")
                        .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                    if let stats {
                        Text(verbatim: Self.weekRange(stats))
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }

                if isLoading {
                    SQSpinner().tint(SQColor.brandRed).frame(maxWidth: .infinity).padding(.top, SQSpace.xxl)
                } else if let stats, stats.hasSomethingToShow {
                    heroCard(stats)
                    metrics(stats)
                    actions(for: stats)
                } else if let message = errorMessage {
                    ErrorStateView(title: "Bilan indisponible", message: message) {
                        Task { await load() }
                    }
                } else {
                    // Une semaine vide n'a rien à raconter : proposer de la
                    // partager donnerait une carte creuse.
                    EmptyStateView(
                        title: "Pas encore de bilan",
                        message: "Lance un speedtest, valide une antenne ou publie une photo : ton bilan de la semaine se remplira.",
                        systemImage: "calendar"
                    )
                }
            }
            .padding(SQSpace.lg)
        }
        .sqSheet(background: SQColor.bg)
        .task { await load() }
        .sheet(item: Binding(
            get: { shareURL.map(ShareItem.init) },
            set: { if $0 == nil { shareURL = nil } }
        )) { item in
            ShareSheet(items: [item.url])
        }
    }

    private static func weekRange(_ stats: WeeklyRecapStats) -> String {
        let start = stats.weekStart.formatted(.dateTime.day().month(.wide))
        let end = stats.weekEnd.formatted(.dateTime.day().month(.wide))
        return String(localized: "Du \(start) au \(end)")
    }

    /// Le chiffre de la semaine, en grand sur l'encre. L'image partagée garde
    /// sa propre carte (`WeeklyRecapCard`), au rendu indépendant de l'appareil.
    @ViewBuilder
    private func heroCard(_ stats: WeeklyRecapStats) -> some View {
        let hero: (kicker: LocalizedStringKey, value: String, unit: String, caption: String)? = {
            switch stats.headline {
            case .topSpeed(let mbps):
                let parts = [stats.topDownloadTech, stats.topDownloadOperator, stats.topCity]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                return ("Meilleur débit", SQUnits.throughputValue(mbps: mbps), SQUnits.throughputUnit(mbps: mbps),
                        parts.isEmpty ? String(localized: "en pic cette semaine") : parts.joined(separator: " · "))
            case .coverage(let points):
                return ("Couverture", "\(points)", String(localized: "points"), String(localized: "de couverture enregistrés"))
            case .validations(let count):
                return ("Validations", "\(count)", String(localized: "validations"), String(localized: "d'antennes confirmées"))
            case .photos(let count):
                return ("Photos", "\(count)", String(localized: "photos"), String(localized: "de sites partagées"))
            case .none:
                return nil
            }
        }()
        if let hero {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                // Pas `sqKicker()` : sa couleur, posée à l'intérieur, l'emporterait
                // sur l'encre claire et le titre deviendrait illisible.
                Text(hero.kicker)
                    .font(SQFont.body(11, .bold, relativeTo: .caption2))
                    .tracking(11 * 0.18)
                    .textCase(.uppercase)
                    .foregroundStyle(SQColor.onInk.opacity(0.85))
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    Text(verbatim: hero.value)
                        .font(SQFont.display(38, .heavy, relativeTo: .largeTitle))
                        .monospacedDigit()
                    Text(verbatim: hero.unit)
                        .font(SQType.body(.bold))
                }
                .foregroundStyle(SQColor.onInk)
                Text(verbatim: hero.caption)
                    .font(SQType.subhead(.medium))
                    .foregroundStyle(SQColor.onInk.opacity(0.9))
            }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SQColor.label, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("weeklyRecap.hero")
        }
    }

    /// Les autres chiffres, seulement ceux qui ne sont pas nuls : une rangée de
    /// zéros ferait passer une semaine spécialisée pour une semaine ratée.
    @ViewBuilder
    private func metrics(_ stats: WeeklyRecapStats) -> some View {
        let tiles: [(Int, LocalizedStringKey)] = [
            (stats.speedtestCount, "speedtests"),
            (stats.photoCount, "photos"),
            (stats.validationCount, "validations"),
            (stats.badgeCount, "badges")
        ].filter { $0.0 > 0 }
        if !tiles.isEmpty {
            HStack(spacing: SQSpace.sm) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    let (value, label) = tile
                    VStack(spacing: 2) {
                        Text(verbatim: "\(value)")
                            .font(SQFont.display(22, .heavy, relativeTo: .title2))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                        Text(label)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.md)
                    .padding(.horizontal, SQSpace.xs)
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    @ViewBuilder
    private func actions(for stats: WeeklyRecapStats) -> some View {
        VStack(spacing: SQSpace.sm) {
            GradientButton(String(localized: "Partager mon bilan"), systemImage: "square.and.arrow.up") {
                Task {
                    // Un rendu raté ne doit pas laisser le bouton sans effet.
                    if let url = await WeeklyRecapImageRenderer.render(stats) {
                        publishNotice = nil
                        shareURL = url
                    } else {
                        publishNotice = String(localized: "Impossible de préparer l’image du bilan. Réessaie.")
                        Haptics.error()
                    }
                }
            }
            GradientButton(String(localized: "Publier en story"), isBusy: isPublishing, style: .secondary) {
                Task { await publish() }
            }
            .disabled(isPublishing)

            if let publishNotice {
                Text(LocalizedStringKey(publishNotice))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        // Données démo : le bilan se lit sans serveur.
        if AppEnvironment.usesDemoData {
            let end = Date()
            stats = WeeklyRecapStats(
                weekStart: end.addingTimeInterval(-6 * 86_400), weekEnd: end,
                speedtestCount: 12, topDownloadMbps: 412, topDownloadTech: "5G", topDownloadOperator: "SFR",
                sessionPoints: 0, sessionDistanceKm: nil, validationCount: 2, photoCount: 3,
                badgeCount: 0, signalMomentsShared: 0, topCity: "Paris"
            )
            return
        }
        do {
            stats = try await service.weeklyRecap()
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    private func publish() async {
        isPublishing = true
        defer { isPublishing = false }
        do {
            let response = try await service.publishWeeklyRecap()
            // Republier ne crée pas de seconde story : le dire plutôt que de
            // feindre un succès neuf, sinon l'utilisateur republie en boucle.
            publishNotice = response.alreadyExisted == true
                ? "Ton bilan de la semaine est déjà en story."
                : "Bilan publié en story."
            if response.alreadyExisted != true { onPublished() }
        } catch {
            if !error.isCancellation { publishNotice = error.userFacingMessage }
        }
    }
}
