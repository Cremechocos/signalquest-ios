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
    /// Session exacte ayant ouvert la pièce jointe. Le pipeline refusera sa
    /// réponse si l'utilisateur se déconnecte ou change de compte entre-temps.
    /// Absente pour une image publique (photo d'une publication du fil).
    let accountSession: LocalAccountSession?
}

struct MessageImageViewer: View {
    let targets: [MessageImageTarget]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentIndex: Int
    /// Fond partagé entre les pages : le glisser-pour-fermer l'éclaircit.
    @State private var dismissOffset: CGFloat = 0
    /// Image de la page courante, chargée pour le partage (même cache que l'affichage).
    @State private var shareImage: UIImage?

    /// Une seule photo (appels existants).
    init(target: MessageImageTarget) {
        self.init(targets: [target], initialIndex: 0)
    }

    /// Plusieurs photos de la conversation, balayables ; `initialIndex` est borné.
    init(targets: [MessageImageTarget], initialIndex: Int = 0) {
        self.targets = targets
        _currentIndex = State(initialValue: targets.isEmpty ? 0 : min(max(initialIndex, 0), targets.count - 1))
    }

    private var current: MessageImageTarget? {
        targets.indices.contains(currentIndex) ? targets[currentIndex] : nil
    }

    /// Le fond s'éclaircit à mesure que l'on tire l'image vers le bord.
    private var backgroundOpacity: Double {
        1 - min(Double(abs(dismissOffset)) / 600, 0.55)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            if targets.count > 1 {
                TabView(selection: $currentIndex) {
                    ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                        MessageImagePage(
                            target: target,
                            position: (index + 1, targets.count),
                            dismissOffset: $dismissOffset
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            } else if let target = targets.first {
                MessageImagePage(target: target, position: nil, dismissOffset: $dismissOffset)
            }

            controls
        }
        .preferredColorScheme(.dark)
        // VoiceOver : le geste d'échappement (Z à deux doigts) ferme le viewer.
        .accessibilityAction(.escape) { dismiss() }
        .task(id: current?.id) { await loadShareImage() }
    }

    // MARK: Commandes

    private var controls: some View {
        HStack(alignment: .top) {
            closeButton
            Spacer(minLength: 0)
            if targets.count > 1 {
                Text("\(currentIndex + 1) / \(targets.count)")
                    .font(SQType.subhead)
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 44)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            shareButton
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var shareButton: some View {
        if let shareImage {
            ShareLink(
                item: Image(uiImage: shareImage),
                preview: SharePreview("Photo en plein écran", image: Image(uiImage: shareImage))
            ) {
                shareIcon
            }
            .accessibilityLabel("Partager la photo")
        } else {
            // Image pas encore chargée (ou en échec) : rien à partager.
            shareIcon
                .opacity(0.4)
                .accessibilityLabel("Partager la photo")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Indisponible tant que la photo n'est pas chargée")
                .accessibilityElement(children: .ignore)
        }
    }

    private var shareIcon: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 44, height: 44)
            .background(Color.white.opacity(0.16), in: Circle())
            .contentShape(Circle())
    }

    private func loadShareImage() async {
        shareImage = nil
        guard let target = current else { return }
        // Mêmes paramètres que l'affichage (RemoteImage) pour retomber sur le cache.
        let scale = UITraitCollection.current.displayScale
        shareImage = try? await ImagePipeline.shared.image(
            for: target.url,
            maxPixel: 1600 * max(scale, 1),
            scope: target.accountSession.map(ImageCacheScope.privateAccount) ?? .publicContent
        )
    }

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
    }
}

/// Une page du visionneur : image + zoom/panoramique/fermeture au glisser.
private struct MessageImagePage: View {
    let target: MessageImageTarget
    /// (rang, total) quand plusieurs photos, pour VoiceOver.
    let position: (Int, Int)?
    @Binding var dismissOffset: CGFloat

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Zoom (pincement / double-tap) + panoramique une fois zoomé.
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            RemoteImage(
                url: target.url,
                maxDimension: 1600,
                contentMode: .fit,
                cacheScope: target.accountSession.map(ImageCacheScope.privateAccount) ?? .publicContent,
                showsFailureUI: true
            ) {
                SQSpinner()
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
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint("Balayer vers le bas avec deux doigts pour fermer")
            .accessibilityAction(named: Text("Agrandir")) { zoomIn() }
            .accessibilityAction(named: Text("Réduire")) { zoomOut() }
            .accessibilityAction(named: Text("Taille adaptée")) {
                withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) { resetZoom() }
            }
        }
    }

    private var accessibilityValueText: Text {
        let zoom = scale > 1 ? Text("Zoom \(Int((scale * 100).rounded())) %") : Text("Taille adaptée")
        guard let position else { return zoom }
        return Text("Photo \(position.0) sur \(position.1)") + Text(verbatim: ", ") + zoom
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
                    // Balayage horizontal = changement de photo, pas fermeture.
                    dismissOffset = abs(value.translation.height) > abs(value.translation.width) ? value.translation.height : 0
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastPanOffset = panOffset
                } else if abs(value.translation.height) > 130, abs(value.translation.height) > abs(value.translation.width) {
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

    private func zoomIn() {
        withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
            scale = min(4, max(2, scale + 0.5))
            lastScale = scale
        }
    }

    private func zoomOut() {
        withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
            scale = max(1, scale - 0.5)
            lastScale = scale
            if scale == 1 { resetZoom() }
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        panOffset = .zero
        lastPanOffset = .zero
    }
}
