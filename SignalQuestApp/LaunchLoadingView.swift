import SwiftUI

/// Écran de chargement au lancement (restauration de session).
/// Son premier cadre reprend exactement l'écran de lancement statique
/// (`UILaunchScreen` : fond `BackgroundPrimary`, `LaunchLogo` centré sur tout
/// l'écran à sa taille naturelle) : le relais entre les deux ne se voit pas
/// (UI-13). Si la restauration dure, des ondes discrètes apparaissent autour
/// du logo ; aucun indicateur n'annonce d'attente.
struct LaunchLoadingView: View {
    @State private var showsWaves = false

    /// En deçà, l'écran passe inaperçu : pas d'animation lancée pour être
    /// aussitôt interrompue.
    private static let wavesDelay: Duration = .milliseconds(600)

    var body: some View {
        ZStack {
            // L'asset lui-même et non `SQColor.bg` : en « Noir intense », le fond
            // aurait changé sous le logo au passage de l'écran statique.
            Color("BackgroundPrimary")
            if showsWaves {
                LaunchWaves()
                    .transition(.opacity)
            }
            Image("LaunchLogo")
                .resizable()
                .frame(width: 120, height: 120)
        }
        // Comme l'écran statique : centré sur l'écran entier, pas sur la zone sûre.
        .ignoresSafeArea()
        .task {
            try? await Task.sleep(for: Self.wavesDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { showsWaves = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chargement de SignalQuest")
    }
}

/// Trois ondes radio qui s'étendent et s'estompent autour du logo, décalées
/// d'un tiers de période. Rien sous « Réduire les animations ».
private struct LaunchWaves: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<3, id: \.self) { wave in
                    Circle()
                        .stroke(SQColor.brandRed.opacity(0.30), lineWidth: 1.5)
                        .frame(width: 132, height: 132)
                        .scaleEffect(animating ? 2.05 : 0.92)
                        .opacity(animating ? 0 : 0.9)
                        .animation(
                            SQMotion.repeating(
                                .easeOut(duration: 2.4),
                                autoreverses: false,
                                delay: Double(wave) * 0.8,
                                active: animating,
                                reduceMotion: reduceMotion
                            ),
                            value: animating
                        )
                }
            }
        }
        .onAppear { animating = true }
    }
}
