import SwiftUI

// MARK: - Viewer plein écran des photos de conversation
//
// Ouvert au tap sur une photo d'un message : fond noir, zoom pincé + double-tap,
// glisser verticalement pour fermer, bouton fermer 44 pt. Réutilise le pipeline
// d'images de l'app (RemoteImage → ImagePipeline) : la photo déjà décodée en
// vignette sert de cache chaud pour la version pleine résolution.
// Noir/blanc volontaires : superposés à la photo, ils sont indépendants du thème.

/// Cible de présentation du viewer (`fullScreenCover(item:)`).
struct MessageImageTarget: Identifiable, Equatable {
    let id: String
    let url: URL
}

struct MessageImageViewer: View {
    let target: MessageImageTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Zoom (pincement / double-tap) + panoramique une fois zoomé.
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    /// Glisser-pour-fermer (image non zoomée) : translation verticale + fondu du fond.
    @State private var dismissOffset: CGFloat = 0

    /// Le fond s'éclaircit à mesure que l'on tire l'image vers le bord.
    private var backgroundOpacity: Double {
        1 - min(Double(abs(dismissOffset)) / 600, 0.55)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            GeometryReader { geo in
                RemoteImage(url: target.url, maxDimension: 1600, contentMode: .fit) {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .scaleEffect(scale)
                .offset(x: panOffset.width, y: panOffset.height + dismissOffset)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(magnification)
                .simultaneousGesture(dragGesture)
                .onTapGesture(count: 2) { toggleZoom() }
                .accessibilityLabel("Photo en plein écran")
                .accessibilityAddTraits(.isImage)
                .accessibilityHint("Balayer vers le bas avec deux doigts pour fermer")
            }

            closeButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .preferredColorScheme(.dark)
        // VoiceOver : le geste d'échappement (Z à deux doigts) ferme le viewer.
        .accessibilityAction(.escape) { dismiss() }
    }

    // MARK: Commandes

    private var closeButton: some View {
        Button {
            Haptics.light()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fermer")
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
    }

    // MARK: Gestes

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { resetZoom() }
                }
            }
    }

    /// Zoomé : panoramique. Non zoomé : glisser verticalement pour fermer
    /// (seuil 130 pt, sinon retour élastique).
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    panOffset = CGSize(
                        width: lastPanOffset.width + value.translation.width,
                        height: lastPanOffset.height + value.translation.height
                    )
                } else {
                    dismissOffset = value.translation.height
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastPanOffset = panOffset
                } else if abs(value.translation.height) > 130 {
                    dismiss()
                } else {
                    withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { dismissOffset = 0 }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
            if scale > 1 {
                resetZoom()
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        panOffset = .zero
        lastPanOffset = .zero
    }
}
