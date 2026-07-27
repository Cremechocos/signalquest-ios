import SwiftUI

/// Carte du bilan hebdomadaire — affichée dans l'app ET exportée en image.
///
/// Une seule vue pour les deux usages : deux rendus séparés finiraient par
/// diverger, et c'est l'image partagée — celle que voient des gens qui n'ont pas
/// l'app — qui en pâtirait.
struct WeeklyRecapCard: View {
    let stats: WeeklyRecapStats
    /// `true` à l'export : force le thème sombre et la marque, indépendamment de
    /// l'apparence de l'appareil.
    var forExport = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            header
            headline
            metrics
            if forExport { footer }
        }
        .padding(SQSpace.xl)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ma semaine")
                .font(SQFont.display(26, .bold))
                .foregroundStyle(forExport ? SQColor.onAccent : SQColor.label)
            Text(weekRange)
                .font(SQFont.body(13))
                .foregroundStyle(forExport ? SQColor.onAccent : SQColor.labelSecondary)
        }
    }

    private var weekRange: String {
        let start = stats.weekStart.formatted(.dateTime.day().month(.abbreviated))
        let end = stats.weekEnd.formatted(.dateTime.day().month(.abbreviated))
        return "\(start) – \(end)"
    }

    @ViewBuilder
    private var headline: some View {
        switch stats.headline {
        case .topSpeed(let mbps):
            hero(value: "\(Int(mbps.rounded()))", unit: "Mbps", caption: topSpeedCaption)
        case .coverage(let points):
            hero(value: "\(points)", unit: "points", caption: "de couverture enregistrés")
        case .validations(let count):
            hero(value: "\(count)", unit: "validations", caption: "d'antennes confirmées")
        case .photos(let count):
            hero(value: "\(count)", unit: "photos", caption: "de sites partagées")
        case .none:
            EmptyView()
        }
    }

    private var topSpeedCaption: String {
        // Techno et opérateur ne sont pas toujours connus : on compose ce qu'on
        // a plutôt que d'afficher « nil » ou un tiret.
        let parts = [stats.topDownloadTech, stats.topDownloadOperator, stats.topCity]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? "en pic cette semaine" : parts.joined(separator: " · ")
    }

    private func hero(value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                Text(value)
                    .font(SQFont.display(52, .bold))
                    .monospacedDigit()
                Text(LocalizedStringKey(unit))
                    .font(SQFont.display(20, .semibold))
            }
            .foregroundStyle(forExport ? SQColor.onAccent : SQColor.brandRed)
            Text(LocalizedStringKey(caption))
                .font(SQFont.body(14))
                .foregroundStyle(forExport ? SQColor.onAccent : SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metrics: some View {
        // Seules les métriques NON NULLES sont montrées : une grille de zéros
        // donne l'impression d'une semaine ratée, alors qu'elle est simplement
        // spécialisée.
        let tiles: [(String, String)] = [
            (stats.speedtestCount > 0 ? "\(stats.speedtestCount)" : "", "Speedtests"),
            (stats.validationCount > 0 ? "\(stats.validationCount)" : "", "Validations"),
            (stats.photoCount > 0 ? "\(stats.photoCount)" : "", "Photos"),
            (stats.badgeCount > 0 ? "\(stats.badgeCount)" : "", "Badges")
        ].filter { !$0.0.isEmpty }

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SQSpace.sm) {
            ForEach(tiles, id: \.1) { value, label in
                VStack(alignment: .leading, spacing: 1) {
                    Text(value)
                        .font(SQFont.display(20, .bold))
                        .monospacedDigit()
                        .foregroundStyle(forExport ? SQColor.onAccent : SQColor.label)
                    Text(LocalizedStringKey(label))
                        .font(SQFont.body(12))
                        .foregroundStyle(forExport ? SQColor.onAccent : SQColor.labelSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SQSpace.md)
                .background(
                    forExport ? AnyShapeStyle(SQColor.onAccent.opacity(0.12))
                              : AnyShapeStyle(SQColor.surfaceMuted),
                    in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: SQSpace.xs) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
            Text("SignalQuest")
                .font(SQFont.archivo(13, .bold))
            Spacer()
            Text("signalquest.fr")
                .font(SQFont.body(12))
        }
        .foregroundStyle(SQColor.onAccent)
    }

    private var background: some ShapeStyle {
        // À l'export, le fond est porté par la toile (cf. renderer) : le
        // dupliquer ici masquerait le problème sans le régler.
        forExport ? AnyShapeStyle(Color.clear) : AnyShapeStyle(SQColor.surface)
    }
}

/// Rend la carte en PNG partageable.
enum WeeklyRecapImageRenderer {
    private static let cardSize = CGSize(width: 420, height: 520)
    private static let exportScale: CGFloat = 3

    @MainActor
    static func renderImage(_ stats: WeeklyRecapStats) -> UIImage? {
        // Taille Dynamic Type FIGÉE : sans cela l'image exportée varierait avec
        // le réglage d'accessibilité de l'appareil, et deux utilisateurs
        // partageraient deux mises en page différentes.
        // Le fond doit remplir TOUTE la toile, pas seulement la carte : appliqué
        // à l'intérieur, il laissait le bas de l'image transparent, que le
        // renderer opaque peignait en NOIR. Invisible dans l'app — c'est le seul
        // livrable qu'on ne voit qu'une fois partagé.
        let content = ZStack {
            SQColor.brandRed
            WeeklyRecapCard(stats: stats, forExport: true)
        }
            .frame(width: cardSize.width, height: cardSize.height)
            .environment(\.displayScale, exportScale)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = exportScale
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(cardSize)
        return renderer.uiImage
    }

    static func render(_ stats: WeeklyRecapStats) async -> URL? {
        let image = await MainActor.run { renderImage(stats) }
        guard let image, let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("signalquest-recap-\(Int(stats.weekStart.timeIntervalSince1970)).png")
        try? data.write(to: url, options: [.atomic])
        return url
    }
}
