import SwiftUI

/// Éditeur « Flouter » avant publication (plan 3, vague 1).
///
/// Les visages repérés sur l'appareil sont proposés d'office ; on en retire
/// d'un toucher et on ajoute des zones en glissant le doigt sur la photo.
/// Rien n'est appliqué avant « Flouter », et le flou est alors définitif sur
/// la copie qui part : l'original reste sur l'appareil.
struct PhotoBlurEditor: View {
    let image: UIImage
    /// Titre de validation : « Flouter », ou « Flouter et envoyer » quand
    /// valider envoie aussi la photo.
    var confirmTitle: LocalizedStringKey = "Flouter"
    /// Titre de validation sans aucune zone : un envoi que l'éditeur
    /// interrompt (visages repérés) doit pouvoir repartir sans flou, sinon une
    /// fausse détection le bloquerait. `nil` : il faut au moins une zone.
    var emptyConfirmTitle: LocalizedStringKey? = nil
    /// Image floutée et zones retenues (normalisées), pour les écrans qui
    /// ré-encodent eux-mêmes depuis l'original.
    let onApply: (UIImage, [CGRect]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var regions: [Region] = []
    @State private var draft: CGRect?
    @State private var isDetecting = true

    private struct Region: Identifiable {
        let id = UUID()
        let rect: CGRect
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: SQSpace.md) {
                GeometryReader { proxy in
                    let frame = Self.fittedFrame(for: image.size, in: proxy.size)
                    ZStack(alignment: .topLeading) {
                        // Calque de dessin : glisser sur la photo trace une zone.
                        // `.position` plutôt que `.offset` : un décalage ne déplace
                        // que le dessin, et le cadre lu par VoiceOver restait à l'origine.
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                                .accessibilityHidden(true)
                            ForEach(regions) { region in
                                regionShape(region, in: frame)
                            }
                            if let draft {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(SQColor.brandRed, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: draft.width * frame.width, height: draft.height * frame.height)
                                    .position(x: frame.minX + draft.midX * frame.width, y: frame.minY + draft.midY * frame.height)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .gesture(drawGesture(in: frame))
                        // Croix au-dessus du calque, placées par guides d'alignement.
                        // Dans l'overlay d'une vue passée par `.position`, une croix
                        // prenait pour cadre toute la photo : VoiceOver et les tests
                        // la touchaient en son milieu, à côté de la croix.
                        ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                            let origin = Self.removeButtonOrigin(for: region.rect, in: frame, container: proxy.size)
                            removeButton(region, number: index + 1)
                                .alignmentGuide(.leading) { _ in -origin.x }
                                .alignmentGuide(.top) { _ in -origin.y }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
                Text(statusText)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.lg)
                    .accessibilityIdentifier("blur.status")
            }
            .padding(.vertical, SQSpace.md)
            .background(SQColor.bg)
            .navigationTitle("Flouter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let rects = regions.map(\.rect)
                        onApply(PhotoBlur.render(image, regions: rects), rects)
                        dismiss()
                    } label: {
                        if regions.isEmpty, let emptyConfirmTitle {
                            Text(emptyConfirmTitle)
                        } else {
                            Text(confirmTitle)
                        }
                    }
                    .disabled(regions.isEmpty && emptyConfirmTitle == nil)
                    .accessibilityIdentifier("blur.apply")
                }
            }
            .task {
                let faces = await PhotoBlur.detectFaces(in: image)
                regions.append(contentsOf: faces.map { Region(rect: $0) })
                isDetecting = false
            }
        }
    }

    private var statusText: String {
        if isDetecting { return String(localized: "Recherche des visages…") }
        if regions.isEmpty { return String(localized: "Aucun visage repéré. Glisse le doigt sur la photo pour flouter une zone.") }
        return String(localized: "Zones à flouter : \(regions.count). Glisse le doigt pour en ajouter, touche la croix pour en retirer.")
    }

    private func regionShape(_ region: Region, in frame: CGRect) -> some View {
        let size = CGSize(width: region.rect.width * frame.width, height: region.rect.height * frame.height)
        let shape = RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.2, style: .continuous)
        return shape
            .fill(SQColor.brandRed.opacity(0.18))
            .overlay { shape.strokeBorder(SQColor.brandRed, lineWidth: 2) }
            .frame(width: size.width, height: size.height)
            .position(x: frame.minX + region.rect.midX * frame.width, y: frame.minY + region.rect.midY * frame.height)
            .accessibilityHidden(true)
    }

    private func removeButton(_ region: Region, number: Int) -> some View {
        Button {
            Haptics.light()
            regions.removeAll { $0.id == region.id }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white, SQColor.brandRed)
                .frame(width: Self.removeButtonSide, height: Self.removeButtonSide)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Retirer la zone \(number)"))
        .accessibilityIdentifier("blur.region.remove.\(number)")
    }

    static let removeButtonSide: CGFloat = 44

    /// Coin haut-gauche de la croix : centrée sur le coin haut-droit de la
    /// zone, sans sortir de l'éditeur (elle agrandirait sinon la pile et
    /// décalerait la photo sous le doigt).
    static func removeButtonOrigin(for rect: CGRect, in frame: CGRect, container: CGSize) -> CGPoint {
        let half = removeButtonSide / 2
        let x = frame.minX + rect.maxX * frame.width - half
        let y = frame.minY + rect.minY * frame.height - half
        return CGPoint(
            x: min(max(x, 0), max(container.width - removeButtonSide, 0)),
            y: min(max(y, 0), max(container.height - removeButtonSide, 0))
        )
    }

    /// Glisser trace une zone ; trop petite, elle est ignorée (un toucher
    /// involontaire ne floute rien).
    private func drawGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                draft = Self.normalizedRect(from: value.startLocation, to: value.location, in: frame)
            }
            .onEnded { value in
                defer { draft = nil }
                let rect = Self.normalizedRect(from: value.startLocation, to: value.location, in: frame)
                guard rect.width >= 0.04, rect.height >= 0.04 else { return }
                Haptics.light()
                regions.append(Region(rect: rect))
            }
    }

    static func normalizedRect(from start: CGPoint, to end: CGPoint, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let rect = CGRect(
            x: (min(start.x, end.x) - frame.minX) / frame.width,
            y: (min(start.y, end.y) - frame.minY) / frame.height,
            width: abs(end.x - start.x) / frame.width,
            height: abs(end.y - start.y) / frame.height
        )
        return PhotoBlur.clamped(rect)
    }

    /// Cadre de l'image ajustée (« fit ») et centrée dans l'espace disponible.
    static func fittedFrame(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }
}

/// Bouton « Flouter » posé sur l'aperçu d'une photo avant publication, au
/// même style que la croix qui la retire.
struct PhotoBlurButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Flouter", systemImage: "eye.slash")
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, SQSpace.md)
                .frame(minHeight: 32)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(SQSpace.sm)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
    }
}
