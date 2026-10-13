import SwiftUI

/// Jauge Halo du Speedtest : demi-cercle posé sur le fond, comme « Débits
/// mesurés » du web. Échelle log 1 → 1 G, étendue à 10 G dès qu'une mesure
/// dépasse le gigabit ; échelle inversée 120 → 0 ms pendant la latence.
struct SignatureSpeedDial: View {
    let value: Double
    let unit: String
    let phaseTitle: String
    let phase: SpeedtestPhase
    /// Badge affiché sous la valeur une fois le test terminé
    /// (« publié sur la carte ✓ »…). nil tant qu'aucun résultat n'est acquis.
    let completionLabel: String?
    /// Échelle étendue à 10 G : posée par l'écran dès qu'une mesure du test a
    /// dépassé 1 Gbit/s, pour que l'arc ne change pas d'échelle à chaque creux.
    var extendsToTenGigabits: Bool = false

    let lineWidth: CGFloat = 16
    let width: CGFloat = 340
    let height: CGFloat = 176
    /// Rayon de la ligne médiane de l'arc.
    var arcRadius: CGFloat { 124 }
    var labelRadius: CGFloat { arcRadius + lineWidth / 2 + 16 }
    /// Centre du demi-cercle : les extrémités de l'arc sont à sa hauteur.
    var center: CGPoint { CGPoint(x: width / 2, y: height - 14) }

    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var isLatency: Bool { unit == "ms" }

    /// Décades de l'échelle de débit : 3 (1 → 1 G) ou 4 (1 → 10 G). Une valeur
    /// au-delà du gigabit étend l'échelle même sans l'indication de l'écran.
    var decades: Int {
        guard !isLatency else { return 3 }
        return extendsToTenGigabits || value > 1_000 ? 4 : 3
    }

    /// Fraction de remplissage de l'arc : échelle log pour les débits,
    /// inverse pour la latence (0 ms = plein).
    var normalized: Double {
        guard value > 0 else { return 0 }
        if isLatency {
            return max(0, min(1, (Self.latencyScaleMax - value) / Self.latencyScaleMax))
        }
        return max(0, min(1, log10(value) / Double(decades)))
    }

    /// Latence : 0 ms = plein, 120 ms = vide.
    static let latencyScaleMax: Double = 120

    /// Libellés de l'échelle : décades 1/10/100/1 G (10 G une fois étendue) en
    /// débit, 120/60/0 ms en latence. Sans eux, l'arc n'est pas lisible.
    struct DialTick {
        let fraction: Double
        let label: String
    }

    var ticks: [DialTick] {
        if isLatency {
            return stride(from: 0.0, through: 120.0, by: 60.0).map { ms in
                DialTick(fraction: (Self.latencyScaleMax - ms) / Self.latencyScaleMax, label: "\(Int(ms))")
            }
        }
        return (0...decades).map { decade in
            DialTick(fraction: Double(decade) / Double(decades), label: Self.speedLabel(pow(10.0, Double(decade))))
        }
    }

    static func speedLabel(_ value: Double) -> String {
        if value >= 10_000 { return "10 G" }
        return value >= 1_000 ? "1 G" : "\(Int(value))"
    }

    /// Point de l'arc pour une fraction (0 = gauche, 1 = droite, par le haut).
    func point(fraction: Double, radius: CGFloat) -> CGPoint {
        let radians = (180 + 180 * fraction) * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    /// Couleur de l'échelle de qualité commune : paliers de débit de la carte,
    /// des tuiles et du widget ; latence sur l'échelle inversée de la carte de
    /// partage (vert sous 20 ms, rouge au-delà de 150 ms).
    var qualityColor: Color {
        if isLatency {
            let theme = SQShareCardTheme.resolve(isDark: colorScheme == .dark, isPureBlack: false)
            return Color(uiColor: theme.latencyColor(ms: value))
        }
        return SQNetworkColors.speedColor(value)
    }

    /// Halo de l'arc : coupé en « Noir intense », où il éclaire le noir autour.
    var arcGlowOpacity: Double {
        guard colorScheme == .dark else { return 0.25 }
        return SQOledPalette.isEnabled ? 0 : 0.4
    }

    /// Mesure en cours (latence/téléchargement/envoi/synchro) : badge pulsé.
    var isRunning: Bool {
        switch phase {
        case .ping, .download, .upload, .saving: return true
        default: return false
        }
    }

    /// Avant toute mesure, le centre dit « Prêt à mesurer » au lieu d'un tiret.
    var isIdle: Bool { phase == .idle && value <= 0 }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.md) {
                    dialArtwork
                        .frame(width: width, height: height)
                    readout
                        .frame(maxWidth: .infinity)
                }
            } else {
                ZStack(alignment: .bottom) {
                    dialArtwork
                    readout
                        .frame(maxWidth: (arcRadius - lineWidth / 2 - 10) * 2)
                        .padding(.bottom, height - center.y - 4)
                }
                .frame(width: width, height: height)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        // La jauge change en continu pendant la mesure : VoiceOver doit relire la
        // valeur au lieu de la lire une seule fois (A11Y-11).
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var dialArtwork: some View {
        ZStack(alignment: .topLeading) {
            // Piste : assez contrastée pour qu'on lise la part restante.
            HalfArc(center: center, radius: arcRadius)
                .stroke(SQColor.labelTertiary.opacity(0.28), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Arc actif teinté par l'échelle de qualité commune. À zéro, on ne
            // dessine RIEN : un epsilon avec lineCap rond créait un point isolé.
            if normalized > 0 {
                HalfArc(center: center, radius: arcRadius)
                    .trim(from: 0, to: normalized)
                    .stroke(qualityColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .shadow(color: qualityColor.opacity(arcGlowOpacity), radius: 10, x: 0, y: 0)
                    .sqAnimation(.snappy(duration: 0.32), value: normalized)
            }

            arcTip
            scaleLabels
        }
        .frame(width: width, height: height)
    }

    private var readout: some View {
        VStack(spacing: SQSpace.xxs) {
            if isIdle {
                Text(phaseTitle)
                    .font(SQFont.display(24, .bold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(phaseTitle)
                    .font(SQFont.body(12, .bold))
                    .tracking(12 * 0.16)
                    .textCase(.uppercase)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    // Sans valeur encore, le tiret reste discret : à 54 pt il se
                    // lisait comme une barre.
                    Text(formattedValue)
                        .font(SQFont.display(hasValue ? (dynamicTypeSize.isAccessibilitySize ? 38 : 54) : 32, .bold))
                        .monospacedDigit()
                        .foregroundStyle(hasValue ? SQColor.label : SQColor.labelTertiary)
                        .contentTransition(.numericText())
                    Text(displayUnit)
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            if isRunning {
                runningBadge
            } else if let completionLabel {
                Text(completionLabel)
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(SQColor.success)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// Libellés de décade autour de l'arc : rendent l'échelle log lisible.
    var scaleLabels: some View {
        ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
            Text(verbatim: tick.label)
                .font(SQFont.body(11, .semibold))
                // Libellés courts : l'encre principale garde la marge de contraste
                // que l'anticrénelage retire aux petites tailles.
                .foregroundStyle(SQColor.label)
                .monospacedDigit()
                .fixedSize()
                .position(point(fraction: tick.fraction, radius: labelRadius))
        }
        .accessibilityHidden(true)
    }

    /// Pointe de l'arc : petit repère crème posé sur le bout. Masqué sous 2 % —
    /// un point isolé au départ de chaque phase se lisait comme une anomalie.
    @ViewBuilder
    var arcTip: some View {
        if normalized > 0.02 {
            Circle()
                .fill(SQColor.onAccent)
                .frame(width: 6, height: 6)
                .position(point(fraction: normalized, radius: arcRadius))
                .sqAnimation(.snappy(duration: 0.32), value: normalized)
                .accessibilityHidden(true)
        }
    }

    /// Mesure en cours : point pulsé teinté qualité. Le libellé reste sobre —
    /// le teinter virait au rouge au démarrage de chaque phase (débit encore
    /// bas) et annonçait « mauvais » à tort.
    var runningBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(qualityColor)
                .frame(width: 6, height: 6)
                .opacity(pulsing && !reduceMotion ? 0.25 : 1)
                .animation(
                    SQMotion.repeating(
                        .easeInOut(duration: 0.7),
                        active: pulsing,
                        reduceMotion: reduceMotion
                    ),
                    value: pulsing
                )
            Text("en cours")
                .font(SQFont.body(12, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
        }
        .onAppear { pulsing = true }
        .onDisappear { pulsing = false }
    }

    var accessibilityText: String {
        if isIdle { return phaseTitle }
        var parts = ["\(phaseTitle) \(formattedValue) \(displayUnit)"]
        if isRunning {
            parts.append(String(localized: "mesure en cours"))
        } else if let completionLabel {
            parts.append(completionLabel)
        }
        return parts.joined(separator: ", ")
    }

    var hasValue: Bool { value > 0 && value.isFinite }

    /// Au-delà du gigabit, la valeur passe en Gbit/s avec deux décimales.
    var formattedValue: String {
        guard value > 0, value.isFinite else { return "—" }
        if !isLatency, value >= 1_000 {
            return (value / 1_000).formatted(.number.precision(.fractionLength(2)))
        }
        if isLatency || value >= 100 {
            return "\(Int(value.rounded()))"
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    var displayUnit: String {
        guard !isLatency, value >= 1_000 else { return unit }
        return SQUnits.throughputUnit(mbps: value)
    }
}

/// Demi-cercle supérieur, de gauche à droite : la piste et l'arc de la jauge.
private struct HalfArc: Shape {
    let center: CGPoint
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        return path
    }
}
