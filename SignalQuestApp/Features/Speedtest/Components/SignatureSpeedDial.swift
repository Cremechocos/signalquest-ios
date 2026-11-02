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

    /// Largeur de la jauge : 340 dans l'onglet, plus petite dans une carte
    /// (fiche d'un test). Hauteur et rayon suivent la même proportion.
    var width: CGFloat = 340

    let lineWidth: CGFloat = 16
    var height: CGFloat { (width * 176 / 340).rounded() }
    /// Rayon de la ligne médiane de l'arc.
    var arcRadius: CGFloat { (width * 124 / 340).rounded() }
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
                        .font(SQFont.display(hasValue ? valueFontSize : 32, .bold))
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

    /// 54 pt à pleine taille, 44 pt dans une jauge réduite, 38 pt en très grand texte.
    var valueFontSize: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 38 }
        return width < 340 ? 44 : 54
    }

    /// Un débit suit la règle commune (`SQUnits`) : au-delà du gigabit la valeur passe en
    /// Gbit/s, avec la même précision que le résultat et l'historique.
    var formattedValue: String {
        guard value > 0, value.isFinite else { return "—" }
        if !isLatency { return SQUnits.throughputValue(mbps: value) }
        return "\(Int(value.rounded()))"
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

// MARK: - Speedtest épuré (piste A, commune avec Android et signalquest.fr/speedtest)

/// Glissement du grand chiffre pendant la mesure, réglé sur le temps et non sur
/// le nombre d'images : `valeur += (cible − valeur) × (1 − e^(−dt / 180 ms))`,
/// comme le web et Android. Repart de 0 à chaque phase (`key`). Seul l'affichage
/// en direct glisse : une valeur enregistrée s'affiche telle quelle.
final class SpeedtestGlide {
    static let timeConstant: TimeInterval = 0.18
    private(set) var value: Double = 0
    private var key: String?
    private var lastStep: Date?

    func step(toward target: Double, key: String, at now: Date) -> Double {
        guard target.isFinite else { return value }
        if key != self.key {
            self.key = key
            value = 0
            lastStep = now
        }
        // Un écart de plus d'une demi-seconde (onglet quitté) ne fait pas sauter la valeur.
        let dt = min(0.5, max(0, now.timeIntervalSince(lastStep ?? now)))
        lastStep = now
        value += (target - value) * (1 - exp(-dt / Self.timeConstant))
        return value
    }
}

/// Bouton GO du repos : disque à l'encre de 150 pt, trois ondes décalées de
/// 1,2 s sur 3,6 s et un libellé qui respire. « Réduire les animations » les retire.
struct SpeedtestGoButton: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .strokeBorder(SQColor.label.opacity(0.22), lineWidth: 1.5)
                        .frame(width: 150, height: 150)
                        .scaleEffect(animating ? 2.1 : 1)
                        .opacity(animating ? 0 : 0.5)
                        .animation(
                            SQMotion.repeating(.timingCurve(0.2, 0.6, 0.3, 1, duration: 3.6), autoreverses: false,
                                               delay: Double(index) * 1.2, active: animating, reduceMotion: reduceMotion),
                            value: animating
                        )
                }
                .accessibilityHidden(true)
            }
            Button {
                Haptics.light()
                action()
            } label: {
                Text(verbatim: "GO")
                    .font(SQFont.displayFixed(32, .heavy))
                    .tracking(32 * 0.04)
                    .foregroundStyle(SQColor.onInk)
                    .scaleEffect(animating ? 1.025 : 1)
                    .animation(SQMotion.repeating(.easeInOut(duration: 1.8), active: animating, reduceMotion: reduceMotion),
                               value: animating)
                    .frame(width: 150, height: 150)
                    .background(SQColor.label, in: Circle())
                    .contentShape(Circle())
                    .shadow(color: SQColor.shadowCard.opacity(0.9), radius: 17, y: 14)
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel(Text("Lancer le test"))
            .accessibilityIdentifier("speedtest.start")
        }
        .frame(width: 300, height: 300)
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

/// Anneau de la mesure : le GO éclate (0,6 → 2, 0,9 s) et l'anneau apparaît
/// (0,55 → 1, 0,6 s). Cercle pointillé, piste, arc carmin de 14 pt qui se
/// remplit pendant la phase, la phase et son chiffre au centre. Une fois le
/// descendant mesuré, sa valeur se range en haut de l'anneau.
struct SpeedtestRunRing: View {
    let label: String
    /// Valeur visée : le chiffre y glisse (débits) ou s'y pose (latence).
    let target: Double?
    let unit: String
    let glides: Bool
    /// Phase courante, pour repartir de 0 à chaque phase.
    let glideKey: String
    /// 0…1 : remplissage de l'arc pendant la phase.
    let progress: Double
    let donePill: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glide = SpeedtestGlide()
    @State private var appeared = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(SQColor.label)
                    .frame(width: 150, height: 150)
                    .scaleEffect(appeared ? 2 : 0.6)
                    .opacity(appeared ? 0 : 0.55)
                    .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.9), value: appeared)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ZStack {
                Circle()
                    .stroke(SQColor.label.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                    .frame(width: 288, height: 288)
                Circle()
                    .stroke(SQColor.chip, lineWidth: 14)
                    .frame(width: 236, height: 236)
                Circle()
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(SQColor.brandRed, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 236, height: 236)
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: progress)
            }
            .accessibilityHidden(true)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.55)
            .opacity(appeared || reduceMotion ? 1 : 0)
            .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.6), value: appeared)

            VStack(spacing: 5) {
                Text(label)
                    .font(SQFont.body(10, .bold))
                    .tracking(10 * 0.18)
                    .textCase(.uppercase)
                    .foregroundStyle(SQColor.labelSecondary)
                figure
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(label), \(target.map { formatted($0) } ?? "—") \(displayUnit(target ?? 0))"))
            .accessibilityAddTraits(.updatesFrequently)

            if let donePill {
                Text(verbatim: donePill)
                    .font(SQFont.body(12.5, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(SQColor.surface, in: Capsule(style: .continuous))
                    .shadow(color: SQColor.shadowSoft, radius: 5, y: 2)
                    .offset(y: -150 + 14 + 16)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(width: 300, height: 300)
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private var figure: some View {
        if let target, glides, !reduceMotion {
            TimelineView(.animation) { context in
                reading(glide.step(toward: target, key: glideKey, at: context.date))
            }
        } else {
            reading(target)
        }
    }

    /// Chiffre et unité ensemble : au passage du gigabit, « Gbit/s » change
    /// dans la même image que le nombre.
    private func reading(_ value: Double?) -> some View {
        VStack(spacing: 5) {
            Text(verbatim: value.map { formatted($0) } ?? " ")
                .font(SQFont.displayFixed(62, .heavy))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: 200)
            Text(verbatim: displayUnit(value ?? 0))
                .font(SQFont.body(14, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    /// En direct, une décimale sous 100 Mbit/s (« 0,0 » au départ d'une phase),
    /// sinon la règle du résultat : le chiffre bouge sans sauter, comme sur le web.
    private func formatted(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if unit == "ms" { return "\(Int(value.rounded()))" }
        if value < 99.95 { return value.formatted(.number.precision(.fractionLength(1))) }
        return SQUnits.throughputValue(mbps: value)
    }

    /// `unit` vaut « ms » pour la latence ; pour un débit, l'unité suit la valeur.
    private func displayUnit(_ value: Double) -> String {
        unit == "ms" ? unit : SQUnits.throughputUnit(mbps: value)
    }
}

/// Les trois étapes sous l'anneau : point carmin pour la phase en cours, encre
/// une fois mesurée (avec sa valeur), creux pour celles qui restent.
struct SpeedtestRunSteps: View {
    struct Step: Identifiable {
        enum State { case pending, active, done }
        let id: Int
        let title: String
        let value: String?
        let state: State
    }

    let steps: [Step]

    var body: some View {
        // Trois étapes sur une ligne, empilées en très grand texte.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { items }
            VStack(alignment: .leading, spacing: SQSpace.xs) { items }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var items: some View {
        ForEach(steps) { step in
            HStack(spacing: 6) {
                Circle()
                    .fill(step.state == .active ? SQColor.brandRed : step.state == .done ? SQColor.label : SQColor.chip)
                    .overlay {
                        if step.state == .pending { Circle().strokeBorder(SQColor.label.opacity(0.22), lineWidth: 1) }
                    }
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(verbatim: step.value.map { "\(step.title) · \($0)" } ?? step.title)
                    .font(SQFont.body(12, .semibold, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(step.state == .pending ? SQColor.labelSecondary : step.state == .done ? SQColor.ink2 : SQColor.label)
                    .fixedSize()
            }
        }
    }
}

/// Tracé de la phase en cours, à l'encre, sur une ligne de base. Chaque point
/// est posé à la progression de la phase (0…1) : le tracé avance avec l'arc au
/// lieu de s'étirer. Sans valeur, seule la ligne de base reste.
struct SpeedtestSparkline: View {
    struct Point: Equatable {
        let progress: Double
        let value: Double
    }

    let points: [Point]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let peak = max(points.map(\.value).max() ?? 0, 1)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                    path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                }
                .stroke(SQColor.separator, lineWidth: 1)
                if points.count > 1 {
                    Path { path in
                        for (index, point) in points.enumerated() {
                            let x = size.width * CGFloat(max(0, min(1, point.progress)))
                            let y = size.height - 2 - CGFloat(min(1, point.value / (peak * 1.1))) * (size.height - 6)
                            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(SQColor.label, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 52)
        .accessibilityHidden(true)
    }
}
