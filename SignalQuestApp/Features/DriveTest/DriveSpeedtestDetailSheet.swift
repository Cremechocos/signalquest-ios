import SwiftUI

/// Détails d'un point speedtest tapé sur la mini-carte Drive Test. UI soignée :
/// anneau de jauge coloré par débit, tuiles de métriques, sparkline du download et
/// méta (génération, opérateur, serveur, lieu, heure). Lecture seule.
struct DriveSpeedtestDetailSheet: View {
    let point: DriveSpeedtestPoint
    @Environment(\.dismiss) private var dismiss

    private var result: SpeedtestRunResult { point.result }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.lg) {
                    hero
                    metricsGrid
                    if let series = result.downloadSeriesMbps, series.count > 2 {
                        sparkleCard(series: series)
                    }
                    metaCard
                }
                .padding(SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
            }
            .signalQuestBackground()
            .navigationTitle("Détails du test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .accessibilityLabel("Fermer")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Hero — anneau de jauge coloré par débit

    private var hero: some View {
        let download = result.downloadAverageMbps
        let color = Self.speedColor(download)
        return VStack(spacing: SQSpace.md) {
            ZStack {
                Circle()
                    .stroke(SQColor.separator.opacity(0.35), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: Self.gaugeFraction(download))
                    .stroke(
                        AngularGradient(colors: [color.opacity(0.7), color], center: .center),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(Self.format(download))
                        .font(SQFont.display(46, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Text("Mbps").font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
                    Text(Self.speedLabel(download))
                        .font(SQFont.archivo(12, .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.14), in: Capsule())
                        .padding(.top, 2)
                }
            }
            .frame(width: 196, height: 196)
            .padding(.top, SQSpace.sm)

            HStack(spacing: SQSpace.sm) {
                if let gen = generationText {
                    SQEditorialTag(text: gen, color: SQColor.brandRed)
                }
                if let op = operatorText {
                    SQEditorialTag(text: op, color: SQColor.brandOrange)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Tuiles de métriques

    private var metricsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: SQSpace.sm) {
            metricTile("Download", value: Self.format(result.downloadAverageMbps), unit: "Mbps",
                       detail: "max \(Self.format(result.downloadMaxMbps))", color: Self.speedColor(result.downloadAverageMbps), icon: "arrow.down")
            metricTile("Upload", value: Self.format(result.uploadAverageMbps ?? 0), unit: "Mbps",
                       detail: result.uploadMaxMbps.map { "max \(Self.format($0))" } ?? "—", color: SQColor.brandGreen, icon: "arrow.up")
            metricTile("Ping", value: Self.format(result.pingMinMs ?? result.pingMs ?? 0), unit: "ms",
                       detail: pingRange, color: SQColor.brandOrange, icon: "bolt.horizontal")
            metricTile("Gigue", value: Self.format(result.jitterMs ?? 0), unit: "ms",
                       detail: "stabilité", color: Color(hex: 0x8B5CF6), icon: "waveform.path")
        }
    }

    private func metricTile(_ title: String, value: String, unit: String, detail: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(color)
                Text(title).font(SQType.micro).tracking(0.6).textCase(.uppercase).foregroundStyle(SQColor.labelSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(SQFont.display(24, .bold)).monospacedDigit().foregroundStyle(SQColor.label)
                Text(unit).font(.caption2).foregroundStyle(SQColor.labelSecondary)
            }
            Text(detail).font(.caption2).foregroundStyle(SQColor.labelTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous).stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    // MARK: Sparkline du download

    private func sparkleCard(series: [Double]) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Débit pendant le test").font(SQType.micro).tracking(0.6).textCase(.uppercase).foregroundStyle(SQColor.labelSecondary)
            Sparkline(values: series, color: Self.speedColor(result.downloadAverageMbps))
                .frame(height: 56)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous).stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    // MARK: Méta

    private var metaCard: some View {
        VStack(spacing: 0) {
            metaRow("antenna.radiowaves.left.and.right", "Opérateur", operatorText ?? "—")
            metaDivider
            metaRow("cellularbars", "Génération", generationText ?? connectionText)
            if let ssid = result.wifiSSID, !ssid.isEmpty {
                metaDivider
                metaRow("wifi", "Wi-Fi", ssid)
            }
            metaDivider
            metaRow("server.rack", "Serveur", serverText)
            metaDivider
            metaRow("timer", "Durée", "\(Self.format(result.durationSeconds)) s")
            metaDivider
            metaRow("clock", "Heure", result.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let place = placeText {
                metaDivider
                metaRow("mappin.and.ellipse", "Lieu", place)
            }
        }
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous).stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    private func metaRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(SQColor.brandRed).frame(width: 22)
            Text(label).font(SQFont.archivo(14, .medium)).foregroundStyle(SQColor.labelSecondary)
            Spacer()
            Text(value).font(SQFont.archivo(14, .semibold)).foregroundStyle(SQColor.label)
                .multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm + 2)
    }

    private var metaDivider: some View {
        Rectangle().fill(SQColor.separator).frame(height: 1).padding(.leading, SQSpace.md + 22 + SQSpace.md)
    }

    // MARK: Textes dérivés

    private var generationText: String? {
        result.cellularTechnology?.rawValue
    }
    private var operatorText: String? {
        let name = result.networkOperatorName ?? result.operatorKey
        return name?.isEmpty == false ? name : nil
    }
    private var connectionText: String {
        (result.wifiSSID?.isEmpty == false) ? "Wi-Fi" : "Cellulaire"
    }
    private var serverText: String {
        if let dl = result.downloadServerName, let s = result.serverName, dl != s { return "\(s) · \(dl)" }
        return result.serverName ?? result.downloadServerName ?? "—"
    }
    private var pingRange: String {
        guard let mn = result.pingMinMs, let mx = result.pingMaxMs else { return "—" }
        return "\(Self.format(mn))–\(Self.format(mx)) ms"
    }
    private var placeText: String? {
        let parts = [result.address, result.city].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.first
    }

    // MARK: Helpers couleur/format (échelle SpeedBand)

    static func format(_ v: Double) -> String {
        v >= 100 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }

    static func gaugeFraction(_ mbps: Double) -> CGFloat {
        // Échelle « log » douce : 0 → 0, ~50 → 0.5, 1000+ → 1.
        let clamped = max(0, min(mbps, 1000))
        return CGFloat(min(1, log10(clamped + 1) / 3))
    }

    static func speedLabel(_ mbps: Double) -> String {
        switch mbps {
        case 1000...: return "Exceptionnel"
        case 600..<1000: return "Excellent"
        case 300..<600: return "Très bon"
        case 100..<300: return "Bon"
        case 30..<100: return "Correct"
        case 10..<30: return "Lent"
        default: return "Très lent"
        }
    }

    static func speedColor(_ mbps: Double) -> Color {
        switch mbps {
        case 1000...: return Color(hex: 0x3B82F6)
        case 600..<1000: return Color(hex: 0x06B6D4)
        case 300..<600: return Color(hex: 0x22C55E)
        case 100..<300: return Color(hex: 0x84CC16)
        case 30..<100: return Color(hex: 0xEAB308)
        case 10..<30: return Color(hex: 0xF97316)
        default: return Color(hex: 0xEF4444)
        }
    }
}

/// Sparkline minimaliste (courbe normalisée + remplissage dégradé sous la courbe).
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 0.0001)
            let stepX = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX, y: geo.size.height * (1 - CGFloat(v / maxV)))
            }
            ZStack {
                // Remplissage sous la courbe.
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    p.addLine(to: first)
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                    if let last = points.last { p.addLine(to: CGPoint(x: last.x, y: geo.size.height)) }
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                // Courbe.
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
