import SwiftUI

// MARK: - Hôte

/// Présente l'onboarding par-dessus le contenu tant qu'il n'a pas été
/// explicitement terminé. Remplace l'ancien `fullScreenCover(isPresented:)`
/// dont le binding (`set: { if !$0 { hasCompletedOnboarding = true } }`)
/// marquait l'onboarding « complété » dès que la présentation était démontée
/// — y compris sans aucune interaction (kill de l'app, présentation avortée
/// au premier lancement). Ici, seul le geste explicite de l'utilisateur
/// (« Commencer » / « Passer ») écrit le flag.
struct OnboardingHost<Content: View>: View {
    @AppStorage("sq.hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
            if !hasCompletedOnboarding {
                OnboardingView {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : SQMotion.smooth) {
                        hasCompletedOnboarding = true
                    }
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .identity,
                            removal: .opacity.combined(with: .scale(scale: 1.04))
                        )
                )
                .zIndex(1)
            }
        }
    }
}

// MARK: - Écran

/// Première ouverture : porte la proposition de valeur (mission télécom) AVANT
/// le mur de connexion, pour améliorer l'activation (cf. audit UX-02 /
/// PRODUCT-04). Pager custom : `TabView(.page)` n'anime pas les changements de
/// sélection programmatiques (bug « animation tronquée », juil. 2026) — ici le
/// bouton et le swipe passent par le même offset animé au ressort.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    /// Translation du doigt pendant le drag ; ramenée à 0 dans la même
    /// transaction animée que le changement de page pour un mouvement continu.
    @State private var dragX: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages = OnboardingPage.all
    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            Color.clear.signalQuestHeroBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                header

                GeometryReader { geo in
                    let width = geo.size.width
                    HStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                            OnboardingSlideView(page: item, isActive: index == page)
                                .frame(width: width, height: geo.size.height)
                                // Une seule slide dans l'arbre d'accessibilité :
                                // VoiceOver ne doit pas lire les pages hors écran.
                                .accessibilityHidden(index != page)
                        }
                    }
                    .offset(x: -CGFloat(page) * width + dragX)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: width))
                }
                // Le pager est ajustable pour VoiceOver : balayer verticalement
                // change d'étape sans dépendre du swipe horizontal.
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: goTo(page + 1)
                    case .decrement: goTo(page - 1)
                    @unknown default: break
                    }
                }

                footer
            }
        }
        // Rendu stable voulu : l'écran suit la taille de texte de l'utilisateur
        // jusqu'à xxLarge puis plafonne — jamais les tailles accessibilité
        // géantes qui explosaient la composition (choix produit, juil. 2026).
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            // Wordmark : taille fixe — un logotype ne suit pas Dynamic Type.
            Text("SignalQuest")
                .font(SQFont.displayFixed(15, .black))
                .foregroundStyle(SQColor.label)
                .accessibilityHidden(true)
            Spacer()
            Button("Passer") { onFinish() }
                .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                .tint(SQColor.labelSecondary)
                // Sur la dernière slide le CTA « Commencer » fait ce travail :
                // on efface « Passer » plutôt que d'offrir deux sorties.
                .opacity(isLastPage ? 0 : 1)
                .disabled(isLastPage)
                .accessibilityHidden(isLastPage)
                .animation(.easeOut(duration: 0.18), value: isLastPage)
        }
        .padding(.horizontal, SQSpace.xl)
        .padding(.vertical, SQSpace.md)
    }

    // MARK: Footer (indicateur + CTA)

    private var footer: some View {
        VStack(spacing: SQSpace.xl) {
            OnboardingPageIndicator(count: pages.count, current: page) { goTo($0) }
            OnboardingCTA(isLastPage: isLastPage) {
                if isLastPage {
                    onFinish()
                } else {
                    goTo(page + 1)
                }
            }
        }
        .padding(.horizontal, SQSpace.xl)
        .padding(.top, SQSpace.lg)
        .padding(.bottom, SQSpace.xl)
    }

    // MARK: Navigation

    private func goTo(_ target: Int) {
        let clamped = max(0, min(pages.count - 1, target))
        guard clamped != page else { return }
        Haptics.light()
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : SQMotion.smooth) {
            page = clamped
            dragX = 0
        }
        UIAccessibility.post(
            notification: .pageScrolled,
            argument: "Étape \(clamped + 1) sur \(pages.count)"
        )
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                var translation = value.translation.width
                // Résistance aux bords : au-delà de la première/dernière page,
                // le contenu suit le doigt au tiers (rubber band).
                if (page == 0 && translation > 0) || (isLastPage && translation < 0) {
                    translation /= 3
                }
                dragX = translation
            }
            .onEnded { value in
                let distance = value.translation.width
                let projected = value.predictedEndTranslation.width
                var target = page
                if distance < -width * 0.28 || projected < -width * 0.5 { target += 1 }
                if distance > width * 0.28 || projected > width * 0.5 { target -= 1 }
                if target == page {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : SQMotion.smooth) {
                        dragX = 0
                    }
                } else {
                    goTo(target)
                }
            }
    }
}

// MARK: - Modèle

private struct OnboardingPage: Identifiable {
    enum Scene { case radioWaves, speedDial, liveMap }

    let id: Scene
    let scene: Scene
    let title: String
    let body: String

    static let all: [OnboardingPage] = [
        OnboardingPage(
            id: .radioWaves,
            scene: .radioWaves,
            title: "Comprends ton réseau",
            body: "Explore la couverture mobile autour de toi : antennes, opérateurs et qualité réelle mesurée par la communauté."
        ),
        OnboardingPage(
            id: .speedDial,
            scene: .speedDial,
            title: "Mesure et partage",
            body: "Lance un speedtest fiable en quelques secondes, garde ton historique et contribue à la carte — uniquement si tu le décides."
        ),
        OnboardingPage(
            id: .liveMap,
            scene: .liveMap,
            title: "Cartographie la couverture",
            body: "Tes contributions, et celles des autres, dessinent une carte vivante de la 4G/5G partout en France."
        ),
    ]
}

// MARK: - Slide

private struct OnboardingSlideView: View {
    let page: OnboardingPage
    let isActive: Bool

    /// Chorégraphie d'entrée jouée une seule fois, à la première activation :
    /// scène puis titre puis corps. Les visites suivantes montrent la slide posée.
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // À très grande taille Dynamic Type le contenu peut dépasser l'écran :
        // on bascule alors sur un défilement vertical plutôt que de tronquer.
        ViewThatFits(in: .vertical) {
            stack
            ScrollView(showsIndicators: false) { stack }
        }
        .onAppear { if isActive { reveal() } }
        .onChangeCompat(of: isActive) { _, active in
            if active { reveal() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title). \(page.body)")
    }

    private var stack: some View {
        VStack(spacing: 0) {
            Spacer(minLength: SQSpace.lg)

            OnboardingSceneView(scene: page.scene, active: isActive && revealed)
                .frame(height: 240)
                .opacity(revealed ? 1 : 0.35)
                .scaleEffect(revealed ? 1 : 0.96)
                .animation(entrance(delay: 0), value: revealed)
                .accessibilityHidden(true)

            Spacer(minLength: SQSpace.xxl)

            VStack(spacing: SQSpace.md) {
                Text(page.title)
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.center)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed || reduceMotion ? 0 : 12)
                    .animation(entrance(delay: 0.07), value: revealed)
                Text(page.body)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed || reduceMotion ? 0 : 12)
                    .animation(entrance(delay: 0.14), value: revealed)
            }
            .padding(.horizontal, SQSpace.xl)

            Spacer(minLength: SQSpace.lg)
            Spacer(minLength: SQSpace.lg)
        }
    }

    private func reveal() {
        guard !revealed else { return }
        revealed = true
    }

    private func entrance(delay: Double) -> Animation {
        reduceMotion ? .easeOut(duration: 0.18) : SQMotion.smooth.delay(delay)
    }
}

// MARK: - Scènes

/// Trois compositions signature, encre + rouge sur papier, chacune posée sur un
/// halo rouge discret. Les boucles d'ambiance ne tournent que sur la slide
/// active (`active`) et sont pilotées par des animations Core Animation
/// `repeatForever` (render server), jamais par `TimelineView` — cf. PERF-RING-01.
private struct OnboardingSceneView: View {
    let scene: OnboardingPage.Scene
    let active: Bool

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [SQColor.brandRed.opacity(0.14), .clear],
                center: .center,
                startRadius: 8,
                endRadius: 150
            )
            switch scene {
            case .radioWaves: RadioWavesScene(active: active)
            case .speedDial: SpeedDialScene(active: active)
            case .liveMap: LiveMapScene(active: active)
            }
        }
    }
}

/// S1 — l'antenne émet : trois ondes concentriques se propagent en boucle lente.
private struct RadioWavesScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rippling = false

    private let ringDelays: [Double] = [0, 0.9, 1.8]

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                ForEach(ringDelays.indices, id: \.self) { index in
                    Circle()
                        .stroke(SQColor.brandRed.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 96, height: 96)
                        .scaleEffect(rippling ? 2.1 : 1)
                        .opacity(rippling ? 0 : 0.7)
                        .animation(
                            .easeOut(duration: 2.7)
                                .repeatForever(autoreverses: false)
                                .delay(ringDelays[index]),
                            value: rippling
                        )
                }
            }

            Circle()
                .fill(SQColor.brandRed)
                .frame(width: 96, height: 96)
                .shadow(color: SQColor.brandRed.opacity(0.35), radius: 18, x: 0, y: 8)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.white)
        }
        .onChangeCompat(of: active) { _, isOn in
            // (Re)démarre la propagation à chaque activation de la slide.
            rippling = false
            if isOn { DispatchQueue.main.async { rippling = true } }
        }
        .onAppear { if active { rippling = true } }
    }
}

/// S2 — le cadran de speedtest : l'aiguille balaye à l'entrée puis respire
/// autour de sa position de croisière.
private struct SpeedDialScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swept = false
    @State private var idling = false

    private static let restAngle: Double = -104
    private static let cruiseAngle: Double = 52
    private static let tickCount = 25
    /// Angle du tick `i` sur l'arc gradué (-120° → +120°).
    private static func tickAngle(_ index: Int) -> Double {
        -120 + Double(index) * (240 / Double(tickCount - 1))
    }

    private var needleAngle: Double {
        swept ? Self.cruiseAngle + (idling ? 3.5 : -3.5) : Self.restAngle
    }

    var body: some View {
        ZStack {
            // Arc gradué : les ticks parcourus par l'aiguille sont rouges.
            ForEach(0..<Self.tickCount, id: \.self) { index in
                let angle = Self.tickAngle(index)
                // labelTertiary et non fill : sur papier clair, fill est
                // invisible et la graduation disparaissait.
                Capsule()
                    .fill(angle <= Self.cruiseAngle ? SQColor.brandRed : SQColor.labelTertiary.opacity(0.45))
                    .frame(width: 3, height: index % 6 == 0 ? 18 : 10)
                    .offset(y: -86)
                    .rotationEffect(.degrees(angle))
            }

            // Aiguille, pivot au centre du cadran. Les transitions (balayage
            // d'entrée puis oscillation) sont pilotées par `withAnimation`
            // dans `startSweep()`, pas par un `.animation(value:)` — les deux
            // changements demandent des courbes différentes.
            Capsule()
                .fill(SQColor.label)
                .frame(width: 4, height: 74)
                .offset(y: -37)
                .rotationEffect(.degrees(needleAngle))
            Circle()
                .fill(SQColor.brandRed)
                .frame(width: 18, height: 18)

            Text("Mbps")
                .font(SQType.micro)
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .offset(y: 44)
        }
        .offset(y: 24)   // recentre optiquement le demi-cadran dans la scène
        .onChangeCompat(of: active) { _, isOn in
            guard isOn else { return }
            startSweep()
        }
        .onAppear { if active { startSweep() } }
    }

    private func startSweep() {
        guard !swept else { return }
        if reduceMotion {
            swept = true      // aiguille posée en croisière, aucune boucle
            return
        }
        // Balayage repos → croisière : ressort avec léger dépassement, comme
        // une aiguille physique qui se stabilise.
        withAnimation(.spring(response: 0.9, dampingFraction: 0.62)) {
            swept = true
        }
        // Puis respiration d'ambiance ±3,5° autour de la croisière.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                idling = true
            }
        }
    }
}

/// S3 — la carte vivante : une grille de points où les contributions
/// s'allument une à une, puis « pinguent » doucement.
private struct LiveMapScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false
    @State private var pinging = false

    private static let columns = 7
    private static let rows = 5
    /// Points « contribués » (indices rangée-major), dans leur ordre d'allumage.
    private static let contributionOrder: [Int] = [17, 10, 23, 16, 8, 25, 3, 31]
    private static let contributions = Set(contributionOrder)
    /// Deux d'entre eux émettent un ping périodique.
    private static let pings: [Int: Double] = [10: 0, 23: 1.4]
    private static let spacing: CGFloat = 30

    var body: some View {
        VStack(spacing: Self.spacing - 8) {
            ForEach(0..<Self.rows, id: \.self) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        dot(index: row * Self.columns + column)
                    }
                }
            }
        }
        .onAppear { if active { ignite() } }
        .onChangeCompat(of: active) { _, isOn in
            if isOn {
                ignite()
            } else {
                // Coupe les pings hors écran ; ils redémarreront proprement à
                // la prochaine activation (une animation `repeatForever` liée à
                // `value:` ne rejoue pas sans nouveau changement de valeur).
                pinging = false
            }
        }
    }

    private func ignite() {
        lit = true
        guard !reduceMotion else { return }
        pinging = false
        // Les pings partent une fois la vague d'allumage retombée.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            if active { pinging = true }
        }
    }

    @ViewBuilder
    private func dot(index: Int) -> some View {
        let isContribution = Self.contributions.contains(index)
        let rank = Self.contributionOrder.firstIndex(of: index) ?? 0
        ZStack {
            if let pingDelay = Self.pings[index], active, lit, !reduceMotion {
                Circle()
                    .stroke(SQColor.brandRed.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                    .scaleEffect(pinging ? 3.4 : 1)
                    .opacity(pinging ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 2.4)
                            .repeatForever(autoreverses: false)
                            .delay(pingDelay),
                        value: pinging
                    )
            }
            Circle()
                .fill(isContribution ? SQColor.brandRed : SQColor.labelTertiary.opacity(0.4))
                .frame(width: isContribution ? 10 : 6, height: isContribution ? 10 : 6)
                .scaleEffect(isContribution && !lit ? 0.1 : 1)
                .opacity(isContribution && !lit ? 0 : 1)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.18)
                        : SQMotion.snappy.delay(0.35 + 0.09 * Double(rank)),
                    value: lit
                )
        }
        .frame(width: 12, height: 12)
    }
}

// MARK: - Indicateur de pages

private struct OnboardingPageIndicator: View {
    let count: Int
    let current: Int
    let onTap: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: SQSpace.sm) {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    onTap(index)
                } label: {
                    Capsule()
                        .fill(index == current ? SQColor.brandRed : SQColor.labelTertiary.opacity(0.5))
                        .frame(width: index == current ? 24 : 7, height: 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Étape \(index + 1) sur \(count)")
                .accessibilityAddTraits(index == current ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : SQMotion.snappy, value: current)
    }
}

// MARK: - CTA

/// Bouton principal du pager. Mêmes métriques que `GradientButton` (50 pt,
/// coins nets, Archivo Bold, rouge plein) mais le libellé « Suivant » ↔
/// « Commencer » change via une vraie transition — l'ancien morphing dans la
/// transaction du TabView superposait les deux textes en un état illisible.
private struct OnboardingCTA: View {
    let isLastPage: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            ZStack {
                if isLastPage {
                    label("Commencer", systemImage: "arrow.right.circle.fill")
                        .transition(labelTransition(entering: true))
                } else {
                    label("Suivant", systemImage: "arrow.right")
                        .transition(labelTransition(entering: false))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : SQMotion.snappy, value: isLastPage)
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.md + 3)
            .foregroundStyle(.white)
            .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
    }

    private func label(_ title: String, systemImage: String) -> some View {
        HStack(spacing: SQSpace.sm + 2) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
            Text(title)
                .font(SQType.button)
                .lineLimit(1)
        }
    }

    private func labelTransition(entering: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: entering ? 10 : -10))
    }
}
