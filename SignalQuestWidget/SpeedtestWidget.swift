import WidgetKit
import SwiftUI
import UIKit

struct SpeedtestEntry: TimelineEntry {
    let date: Date
    let snapshot: SpeedtestWidgetSnapshot?
}

struct SpeedtestProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpeedtestEntry {
        SpeedtestEntry(date: Date(), snapshot: SpeedtestWidgetSnapshot(
            downloadMbps: 412, uploadMbps: 64, pingMs: 18, jitterMs: 3, network: "5G", label: "Dernier test", date: Date()
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (SpeedtestEntry) -> Void) {
        completion(SpeedtestEntry(date: Date(), snapshot: WidgetSharedStore.lastSpeedtest() ?? placeholder(in: context).snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpeedtestEntry>) -> Void) {
        let entry = SpeedtestEntry(date: Date(), snapshot: WidgetSharedStore.lastSpeedtest())
        // L'app rafraîchit explicitement via WidgetCenter après chaque test.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - Échelle de couleur (identique au cadran de l'app : SignatureSpeedDial)

/// Couleurs du cadran (mêmes hex que `gaugeColors` côté app) : du « nul » (rouge)
/// au « très bon » (vert foncé).
let sqGaugeColors: [Color] = [
    Color(hex: 0xEF4444), // Nul
    Color(hex: 0xF97316), // Bof
    Color(hex: 0xFDE047), // Moyen
    Color(hex: 0x22C55E), // Bon
    Color(hex: 0x15803D)  // Très bon
]

/// Position 0…1 d'un débit sur l'échelle log (1→1000 Mbps), comme l'app.
func speedRatio(_ mbps: Double) -> Double {
    guard mbps > 0 else { return 0 }
    return max(0, min(1, log10(mbps) / 3))
}

/// Couleur de qualité d'un débit — interpolation continue des `sqGaugeColors`,
/// reproduisant exactement `colorForRatio(normalized)` du cadran de l'app
/// (vert si très bon, rouge si faible). Utilisée par tous les widgets + la
/// Live Activity pour une teinte strictement identique à l'app.
func speedColor(_ mbps: Double) -> Color {
    let v = speedRatio(mbps)
    let count = sqGaugeColors.count
    let segment = 1.0 / Double(count - 1)
    let index = Int(v / segment)
    if index >= count - 1 { return sqGaugeColors[count - 1] }
    let t = (v - Double(index) * segment) / segment
    return sqLerp(sqGaugeColors[index], sqGaugeColors[index + 1], t)
}

/// Libellé qualitatif court affiché sous le cadran.
func speedQualityLabel(_ mbps: Double) -> String {
    switch mbps {
    case 600...: return "Excellent"
    case 300..<600: return "Très bon"
    case 100..<300: return "Rapide"
    case 30..<100: return "Correct"
    case 10..<30: return "Lent"
    default: return "Faible"
    }
}

/// Deep-link ouvrant l'app sur l'onglet Speedtest (géré par `onOpenURL`).
let speedtestWidgetURL = SQSharedConfiguration.deepLink("speedtest")

/// Normalise un débit (Mbps) en 0…1 sur une échelle log (jauge accessoire).
func speedNormalized(_ mbps: Double) -> Double {
    guard mbps > 0 else { return 0 }
    return max(0.02, min(1, log10(mbps) / 3))
}

/// Interpolation linéaire de deux couleurs en sRGB (comme `lerpColor` de l'app).
private func sqLerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let ua = UIColor(a), ub = UIColor(b)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    let f = CGFloat(max(0, min(1, t)))
    return Color(.sRGB,
                 red: Double(r1 + (r2 - r1) * f),
                 green: Double(g1 + (g2 - g1) * f),
                 blue: Double(b1 + (b2 - b1) * f),
                 opacity: 1)
}

// MARK: - Palette (couleurs EXACTES de l'app — le widget n'a pas l'asset catalog)

private extension Color {
    /// Couleur fixe depuis un hex 0xRRGGBB.
    init(hex: UInt) { self = Color(uiColor: UIColor(hex: hex)) }

    /// Couleur dynamique reproduisant un Color Asset (clair/sombre).
    init(lightHex: UInt, darkHex: UInt) {
        self = Color(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? darkHex : lightHex)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum WidgetPalette {
    // Textes (DA chaude — SQColor.label / labelSecondary / labelTertiary).
    static let label = Color(lightHex: 0x18150F, darkHex: 0xF3EFE3)
    static let labelSecondary = Color(lightHex: 0x3A352B, darkHex: 0xCFC7B5)
    static let labelTertiary = Color(lightHex: 0x6B6457, darkHex: 0xAA9F89)
    static let separator = Color(lightHex: 0xC4BCA6, darkHex: 0x4C4636)
    static let fill = Color(lightHex: 0xECE7D8, darkHex: 0x2E2A20)
    // Marque.
    static let brand = Color(lightHex: 0xE2001A, darkHex: 0xFF414F)       // BrandRed
    static let brandDeep = Color(lightHex: 0xC00017, darkHex: 0xFF2438)   // BrandRedDeep (= envoi)
    // Latence / gigue (cyan codé en dur dans l'app).
    static let cyan = Color(hex: 0x06B6D4)
    // Fond (SurfaceElevated → BackgroundPrimary).
    static let surfaceTop = Color(lightHex: 0xFBF9F3, darkHex: 0x26221A)
    static let surfaceBottom = Color(lightHex: 0xF4F0E6, darkHex: 0x100E0A)
}

// MARK: - Fond du widget (dégradé chaud de la DA + halo de qualité)

private struct WidgetBackdrop: View {
    let tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WidgetPalette.surfaceTop, WidgetPalette.surfaceBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [tint.opacity(scheme == .dark ? 0.24 : 0.13), .clear],
                center: .topLeading,
                startRadius: 4,
                endRadius: 260
            )
        }
    }
}

extension View {
    @ViewBuilder
    func sqWidgetBackground(tint: Color) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { WidgetBackdrop(tint: tint) }
        } else {
            self.padding(14).background(WidgetBackdrop(tint: tint))
        }
    }
}

// MARK: - Cadran (arc de jauge + chiffre central) — calque du SignatureSpeedDial

struct SpeedDialView: View {
    let value: Double
    let diameter: CGFloat
    let lineWidth: CGFloat
    var numberSize: CGFloat
    var showQuality: Bool = true

    @Environment(\.colorScheme) private var scheme

    private let arcSpan: Double = 0.75 // 270°
    private var ratio: Double { speedRatio(value) }
    private var tint: Color { speedColor(value) }

    private var numberString: String {
        guard value > 0, value.isFinite else { return "—" }
        if value >= 100 { return "\(Int(value.rounded()))" }
        return String(format: "%.1f", value)
    }

    var body: some View {
        ZStack {
            // Halo de profondeur teinté par la qualité.
            Circle()
                .fill(RadialGradient(
                    colors: [tint.opacity(scheme == .dark ? 0.30 : 0.16), .clear],
                    center: .center,
                    startRadius: 1,
                    endRadius: diameter * 0.55
                ))
                .blur(radius: 9)

            // Rail de fond (SQColor.fill, comme la jauge vide de l'app).
            Circle()
                .trim(from: 0, to: arcSpan)
                .stroke(WidgetPalette.fill,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))

            // Arc actif : dégradé angulaire des gaugeColors (identique à l'app).
            Circle()
                .trim(from: 0, to: arcSpan * max(0.02, ratio))
                .stroke(
                    AngularGradient(
                        colors: sqGaugeColors,
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * arcSpan)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(135))
                .shadow(color: tint.opacity(0.35), radius: 4)

            VStack(spacing: 0) {
                Text(numberString)
                    .font(.system(size: numberSize, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("Mbps")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.labelSecondary)
                    .lineLimit(1)
                if showQuality, value > 0 {
                    Text(speedQualityLabel(value).uppercased())
                        .font(.system(size: 9.5, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, lineWidth)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Débit \(numberString) mégabits par seconde, \(speedQualityLabel(value))")
    }
}

// MARK: - Petits composants

/// Pastille réseau (5G / Wi-Fi / 4G…).
struct NetworkChip: View {
    let network: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: networkSymbol(network))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(WidgetPalette.brand)
            Text(networkShort(network))
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(WidgetPalette.labelSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(WidgetPalette.fill.opacity(0.7), in: Capsule())
        .fixedSize()
    }
}

/// En-tête de marque : glyphe rouge + wordmark optionnel.
struct BrandMark: View {
    var showWordmark = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WidgetPalette.brand)
            if showWordmark {
                Text("SIGNALQUEST")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(WidgetPalette.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .fixedSize()
    }
}

/// Ligne de métrique (medium) : icône teintée + libellé + valeur.
private struct MetricRow: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WidgetPalette.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetPalette.label)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WidgetPalette.labelSecondary)
            }
            .fixedSize()
        }
    }
}

/// Métrique compacte (footer du small).
private struct CompactMetric: View {
    let icon: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WidgetPalette.label)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

func networkSymbol(_ network: String) -> String {
    let lower = network.lowercased()
    if lower.contains("wifi") || lower.contains("wi-fi") { return "wifi" }
    if lower.contains("5g") || lower.contains("4g") || lower.contains("lte") || lower.contains("cellular") { return "antenna.radiowaves.left.and.right" }
    if lower.contains("ether") || lower.contains("wired") { return "cable.connector" }
    return "network"
}

private func networkShort(_ network: String) -> String {
    let lower = network.lowercased()
    if lower.contains("wi-fi") || lower.contains("wifi") { return "Wi-Fi" }
    if lower.contains("5g") { return "5G" }
    if lower.contains("4g") || lower.contains("lte") { return "4G" }
    let trimmed = network.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Réseau" : String(trimmed.prefix(8))
}

// MARK: - Vue principale

struct SpeedtestWidgetEntryView: View {
    var entry: SpeedtestEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: accessoryCircular
        case .accessoryRectangular: accessoryRectangular
        case .accessoryInline: accessoryInline
        default: homeContent
        }
    }

    // MARK: Home (small / medium)

    private var tint: Color { speedColor(entry.snapshot?.downloadMbps ?? 0) }

    @ViewBuilder
    private var homeContent: some View {
        Group {
            if let s = entry.snapshot {
                if family == .systemSmall {
                    homeSmall(s)
                } else {
                    homeMedium(s)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sqWidgetBackground(tint: tint)
        .widgetURL(speedtestWidgetURL)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "speedometer")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(WidgetPalette.brand)
            Text("Aucun test")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WidgetPalette.label)
                .lineLimit(1)
            Text("Lance un speedtest")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WidgetPalette.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func homeSmall(_ s: SpeedtestWidgetSnapshot) -> some View {
        // Layout proportionnel : le cadran se dimensionne selon la place réelle,
        // pour garantir un vrai espacement entre la pastille réseau et la jauge.
        GeometryReader { geo in
            let dial = min(geo.size.width, geo.size.height * 0.62)
            VStack(spacing: 0) {
                HStack {
                    BrandMark(showWordmark: false)
                    Spacer(minLength: 4)
                    NetworkChip(network: s.network)
                }
                Spacer(minLength: 8)
                SpeedDialView(value: s.downloadMbps, diameter: dial, lineWidth: max(8, dial * 0.115), numberSize: dial * 0.38, showQuality: false)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 6)
                HStack(spacing: 14) {
                    CompactMetric(icon: "arrow.up", value: s.uploadMbps.map { "\(Int($0.rounded()))" } ?? "—", tint: WidgetPalette.brandDeep)
                    CompactMetric(icon: "bolt.fill", value: s.pingMs.map { "\(Int($0.rounded())) ms" } ?? "—", tint: WidgetPalette.cyan)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func homeMedium(_ s: SpeedtestWidgetSnapshot) -> some View {
        HStack(spacing: 16) {
            SpeedDialView(value: s.downloadMbps, diameter: 118, lineWidth: 12, numberSize: 34, showQuality: true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    BrandMark()
                    Spacer(minLength: 4)
                    Text(s.date, style: .relative)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(WidgetPalette.labelTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 6)
                VStack(spacing: 7) {
                    MetricRow(icon: "arrow.up", label: "Envoi",
                              value: s.uploadMbps.map { "\(Int($0.rounded()))" } ?? "—",
                              unit: "Mbps", tint: WidgetPalette.brandDeep)
                    MetricRow(icon: "bolt.fill", label: "Latence",
                              value: s.pingMs.map { "\(Int($0.rounded()))" } ?? "—",
                              unit: "ms", tint: WidgetPalette.cyan)
                    if let jitter = s.jitterMs {
                        MetricRow(icon: "waveform.path", label: "Gigue",
                                  value: "\(Int(jitter.rounded()))", unit: "ms", tint: WidgetPalette.cyan)
                    }
                }
                Spacer(minLength: 6)
                NetworkChip(network: s.network)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Accessory (lock screen)

    private var accessoryCircular: some View {
        let dl = entry.snapshot?.downloadMbps ?? 0
        return Gauge(value: speedNormalized(dl)) {
            Image(systemName: "speedometer")
        } currentValueLabel: {
            Text("\(Int(dl.rounded()))")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(speedtestWidgetURL)
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let s = entry.snapshot {
                HStack(spacing: 5) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 13, weight: .bold))
                    Text("\(Int(s.downloadMbps.rounded()))")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("Mbps")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                HStack(spacing: 8) {
                    Label(s.uploadMbps.map { "\(Int($0.rounded()))" } ?? "—", systemImage: "arrow.up")
                    Label(s.pingMs.map { "\(Int($0.rounded())) ms" } ?? "—", systemImage: "bolt.fill")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(s.date, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Label("Aucun test", systemImage: "speedometer").font(.headline)
            }
        }
        .widgetURL(speedtestWidgetURL)
    }

    private var accessoryInline: some View {
        Label(
            entry.snapshot.map { "\(Int($0.downloadMbps.rounded())) Mbps ↓" } ?? "Speedtest",
            systemImage: "speedometer"
        )
        .widgetURL(speedtestWidgetURL)
    }
}

struct SpeedtestWidget: Widget {
    let kind = "SignalQuestSpeedtestWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpeedtestProvider()) { entry in
            SpeedtestWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Dernier Speedtest")
        .description("Affiche ton dernier test de débit SignalQuest.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
