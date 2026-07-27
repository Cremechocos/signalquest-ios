import SwiftUI

struct SignatureSpeedDial: View {
    let value: Double
    let unit: String
    let phaseTitle: String
    let phase: SpeedtestPhase
    /// Badge affiché sous la valeur une fois le test terminé
    /// (« publié sur la carte ✓ »…). nil tant qu'aucun résultat n'est acquis.
    let completionLabel: String?

    let arcSpan: Double = 0.75   // 270°, départ 135°
    let lineWidth: CGFloat = 18
    let diameter: CGFloat = 288
    /// Rayon de la ligne médiane de l'arc, des graduations et des libellés.
    var arcRadius: CGFloat { 100 }
    var tickInnerRadius: CGFloat { arcRadius + lineWidth / 2 + 5 }
    var labelRadius: CGFloat { arcRadius + lineWidth / 2 + 22 }

    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var isLatency: Bool { unit == "ms" }

    /// Fraction de remplissage de l'arc : échelle log pour les débits
    /// (1 Gbps = plein), inverse pour la latence (0 ms = plein).
    var normalized: Double {
        guard value > 0 else { return 0 }
        if isLatency {
            return max(0, min(1, (Self.latencyScaleMax - value) / Self.latencyScaleMax))
        }
        return max(0, min(1, log10(value) / 3))
    }

    /// Latence : 0 ms = plein, 120 ms = vide.
    static let latencyScaleMax: Double = 120

    /// Graduations de l'échelle : décades 1/10/100/1 G en débit, paliers de
    /// 30 ms en latence. Sans elles, le remplissage de l'arc n'est pas lisible.
    struct DialTick {
        let fraction: Double
        let label: String?
    }

    var ticks: [DialTick] {
        if isLatency {
            // 120 → 0 ms (moins = mieux) ; un libellé sur deux pour aérer.
            return stride(from: 0.0, through: 120.0, by: 30.0).map { ms in
                DialTick(
                    fraction: (Self.latencyScaleMax - ms) / Self.latencyScaleMax,
                    label: ms.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(ms))" : nil
                )
            }
        }
        // Débits : décades libellées + graduations fines 2/5 par décade.
        var result: [DialTick] = []
        for decade in 0...3 {
            let base = pow(10.0, Double(decade))
            result.append(DialTick(fraction: Double(decade) / 3, label: Self.speedLabel(base)))
            guard decade < 3 else { continue }
            for step in [2.0, 5.0] {
                result.append(DialTick(fraction: log10(base * step) / 3, label: nil))
            }
        }
        return result
    }

    static func speedLabel(_ value: Double) -> String {
        value >= 1_000 ? "1 G" : "\(Int(value))"
    }

    /// Position d'une graduation sur l'arc (0° = 3 h, sens horaire).
    func point(fraction: Double, radius: CGFloat) -> CGPoint {
        let degrees = 135 + 270 * fraction
        let radians = degrees * .pi / 180
        return CGPoint(x: cos(radians) * radius, y: sin(radians) * radius)
    }

    /// Couleur de qualité (brique → ambre → olive) selon le ratio de remplissage.
    var qualityColor: Color {
        let theme = SpeedtestShareTheme.resolve(colorScheme)
        return SpeedtestQualityPalette.color(forRatio: normalized, stops: theme.qualityStops)
    }

    /// Mesure en cours (latence/téléchargement/envoi/synchro) : badge pulsé.
    var isRunning: Bool {
        switch phase {
        case .ping, .download, .upload, .saving: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            scaleTicks

            // Piste : assez contrastée pour qu'on lise la part restante
            // (l'ancien surfaceMuted disparaissait sur le fond crème).
            Circle()
                .trim(from: 0, to: arcSpan)
                .stroke(SQColor.labelTertiary.opacity(0.28), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: arcRadius * 2, height: arcRadius * 2)

            // Arc actif teinté par la qualité (brique → ambre → olive).
            // Teinte pleine : le dégradé angulaire laissait une couture visible
            // au départ de l'arc. L'epsilon garde un point quand la valeur est 0.
            Circle()
                .trim(from: 0, to: max(0.0006, arcSpan * normalized))
                .stroke(qualityColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: arcRadius * 2, height: arcRadius * 2)
                .shadow(color: qualityColor.opacity(colorScheme == .dark ? 0.5 : 0.3), radius: 10, x: 0, y: 0)
                .sqAnimation(.snappy(duration: 0.32), value: normalized)

            arcTip

            // Cœur : crème de la DA (le blanc pur tranchait), cerclé et posé —
            // sinon le disque se lit comme un trou dans le fond.
            Circle()
                .fill(SQColor.surface)
                .overlay(Circle().strokeBorder(SQColor.separator.opacity(0.7), lineWidth: 1))
                .sqShadowSoft()
                .frame(width: (arcRadius - lineWidth / 2 - 6) * 2, height: (arcRadius - lineWidth / 2 - 6) * 2)

            VStack(spacing: 1) {
                Text(phaseTitle)
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(formattedValue)
                    .font(SQFont.display(58, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text(unit)
                    .font(SQFont.body(14, .medium))
                    .foregroundStyle(SQColor.labelSecondary)
                if isRunning {
                    runningBadge
                } else if let completionLabel {
                    dialBadge(completionLabel, color: SQColor.success, background: SQColor.successSoft)
                }
            }
            .padding(.horizontal, SQSpace.xxl)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        // Le cadran change en continu pendant la mesure : VoiceOver doit relire la
        // valeur au lieu de la lire une seule fois (A11Y-11).
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Graduations + libellés de décade : rendent l'échelle log lisible.
    var scaleTicks: some View {
        ZStack {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                let isMajor = tick.label != nil
                let reached = normalized >= tick.fraction - 0.001
                Capsule(style: .continuous)
                    .fill(reached ? qualityColor.opacity(0.55) : SQColor.labelTertiary.opacity(0.35))
                    .frame(width: isMajor ? 2 : 1.5, height: isMajor ? 9 : 5)
                    .offset(y: -(tickInnerRadius + (isMajor ? 4.5 : 2.5)))
                    .rotationEffect(.degrees(135 + 270 * tick.fraction + 90))

                if let label = tick.label {
                    let position = point(fraction: tick.fraction, radius: labelRadius)
                    Text(LocalizedStringKey(label))
                        .font(SQFont.body(10, .semibold))
                        .foregroundStyle(reached ? SQColor.labelSecondary : SQColor.labelSecondary)
                        .monospacedDigit()
                        .offset(x: position.x, y: position.y)
                }
            }
        }
        .sqAnimation(.snappy(duration: 0.32), value: normalized)
        .accessibilityHidden(true)
    }

    /// Pointe de l'arc : petit repère crème posé sur le bout, façon point final
    /// du graphe de partage. Masqué sous 2 % — un blob isolé au départ de
    /// chaque phase se lisait comme une anomalie.
    @ViewBuilder
    var arcTip: some View {
        if normalized > 0.02 {
            let position = point(fraction: normalized, radius: arcRadius)
            Circle()
                .fill(SQColor.onAccent)
                .frame(width: 6, height: 6)
                .offset(x: position.x, y: position.y)
                .sqAnimation(.snappy(duration: 0.32), value: normalized)
                .accessibilityHidden(true)
        }
    }

    /// Mesure en cours : point pulsé teinté qualité sur fond neutre. Le libellé
    /// reste sobre — le teinter virait au rouge au démarrage de chaque phase
    /// (débit encore bas) et annonçait « mauvais » à tort.
    var runningBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(qualityColor)
                .frame(width: 5, height: 5)
                .opacity(pulsing && !reduceMotion ? 0.25 : 1)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                    value: pulsing
                )
            Text("en cours")
                .font(SQFont.body(11, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(SQColor.fill, in: Capsule(style: .continuous))
        .padding(.top, 5)
        .onAppear { pulsing = true }
        .onDisappear { pulsing = false }
    }

    func dialBadge(_ text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(SQFont.body(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background, in: Capsule(style: .continuous))
            .padding(.top, 5)
    }

    var accessibilityText: String {
        var parts = ["\(phaseTitle) \(formattedValue) \(unit)"]
        if isRunning {
            parts.append("mesure en cours")
        } else if let completionLabel {
            parts.append(completionLabel)
        }
        return parts.joined(separator: ", ")
    }

    var formattedValue: String {
        guard value > 0, value.isFinite else { return "—" }
        if unit == "ms" || value >= 100 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}
