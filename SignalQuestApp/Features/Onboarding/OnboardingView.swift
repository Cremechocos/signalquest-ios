import SwiftUI

/// Première ouverture : porte la proposition de valeur (mission télécom) AVANT le
/// mur de connexion, pour améliorer l'activation (cf. audit UX-02 / PRODUCT-04).
/// Affichée tant que `sq.hasCompletedOnboarding` est faux.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Page: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(
            icon: "antenna.radiowaves.left.and.right",
            title: "Comprends ton réseau",
            body: "Explore la couverture mobile autour de toi : antennes, opérateurs et qualité réelle mesurée par la communauté."
        ),
        Page(
            icon: "speedometer",
            title: "Mesure et partage",
            body: "Lance un speedtest fiable en quelques secondes, garde ton historique et contribue à la carte — uniquement si tu le décides."
        ),
        Page(
            icon: "map",
            title: "Cartographie la couverture",
            body: "Tes contributions, et celles des autres, dessinent une carte vivante de la 4G/5G partout en France."
        ),
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            Color.clear.signalQuestHeroBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Passer") { onFinish() }
                        .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                        .tint(SQColor.labelSecondary)
                        .padding(SQSpace.md)
                }

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                        pageView(item).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))

                GradientButton(isLastPage ? "Commencer" : "Suivant", systemImage: isLastPage ? "arrow.right.circle.fill" : "arrow.right") {
                    if isLastPage {
                        onFinish()
                    } else {
                        withAnimation(reduceMotion ? nil : SQMotion.smooth) { page += 1 }
                    }
                }
                .padding(.horizontal, SQSpace.xl)
                .padding(.bottom, SQSpace.xl)
            }
        }
    }

    private func pageView(_ item: Page) -> some View {
        VStack(spacing: SQSpace.xl) {
            Spacer()
            Image(systemName: item.icon)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 128, height: 128)
                .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous))
                .shadow(color: SQColor.brandRed.opacity(0.35), radius: 18, x: 0, y: 8)
                .accessibilityHidden(true)

            VStack(spacing: SQSpace.md) {
                Text(item.title)
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.center)
                Text(item.body)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SQSpace.xl)
            Spacer()
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.body)")
    }
}
