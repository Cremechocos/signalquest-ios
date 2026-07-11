import SwiftUI

/// Écran de chargement au lancement (restauration de session, ~1-2 s).
/// Prend le relais du launch screen statique (même fond crème, même logo
/// centré) sans à-coup : le logo « respire » doucement pendant que des ondes
/// radio concentriques s'étendent — clin d'œil réseau, calme et signé.
/// Marque en Bricolage (DA « Crème & Terre cuite »), tagline de la connexion.
struct LaunchLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        ZStack {
            SQColor.bg.ignoresSafeArea()

            VStack(spacing: SQSpace.xxl) {
                ZStack {
                    // Ondes concentriques : trois cercles qui s'étendent et
                    // s'estompent en boucle, décalés d'un tiers de période.
                    if !reduceMotion {
                        ForEach(0..<3, id: \.self) { wave in
                            Circle()
                                .stroke(SQColor.brandRed.opacity(0.30), lineWidth: 1.5)
                                .frame(width: 132, height: 132)
                                .scaleEffect(animating ? 2.05 : 0.92)
                                .opacity(animating ? 0 : 0.9)
                                .animation(
                                    .easeOut(duration: 2.4)
                                        .repeatForever(autoreverses: false)
                                        .delay(Double(wave) * 0.8),
                                    value: animating
                                )
                        }
                    }

                    Image("SQLogoMark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                        .sqShadowAccent()
                        .scaleEffect(animating && !reduceMotion ? 1.045 : 1)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 1.7).repeatForever(autoreverses: true),
                            value: animating
                        )
                }
                .frame(width: 280, height: 200)

                VStack(spacing: SQSpace.sm) {
                    Text("SignalQuest")
                        .font(SQFont.display(30, .bold))
                        .foregroundStyle(SQColor.label)
                    Text("Mesure, comprends et partage ton réseau")
                        .font(SQFont.body(14.5))
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            // Léger décalage vers le haut : le bloc paraît optiquement centré
            // et laisse la respiration au spinner du bas.
            .offset(y: -SQSpace.xl)

            VStack {
                Spacer()
                ProgressView()
                    .tint(SQColor.brandRed)
                    .padding(.bottom, 56)
            }
        }
        .onAppear { animating = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chargement de SignalQuest")
    }
}
