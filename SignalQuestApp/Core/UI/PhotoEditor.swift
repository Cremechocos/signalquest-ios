import SwiftUI

/// Proportions proposées par « Recadrer », en largeur / hauteur de pixels.
enum PhotoCropRatio: CaseIterable, Identifiable {
    case free, original, square, fourFive, sixteenNine

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .free: return "Libre"
        case .original: return "Original"
        case .square: return "Carré"
        case .fourFive: return "4:5"
        case .sixteenNine: return "16:9"
        }
    }

    /// Libre et Carré n'ont pas d'orientation à inverser.
    var canFlip: Bool { self == .fourFive || self == .sixteenNine }

    /// `nil` pour Libre. `base` : taille de la photo après ses quarts de tour.
    func aspect(base: CGSize, flipped: Bool) -> CGFloat? {
        let value: CGFloat
        switch self {
        case .free: return nil
        case .original: return base.height > 0 ? base.width / base.height : nil
        case .square: return 1
        case .fourFive: value = 4 / 5
        case .sixteenNine: value = 16 / 9
        }
        return flipped ? 1 / value : value
    }
}

/// Éditeur « Modifier » avant publication (E1) : Recadrer, puis Flouter.
///
/// Les retouches restent non destructives : `onDone` reçoit l'aperçu retouché et
/// les retouches, que l'écran garde pour rouvrir l'éditeur ou cuire l'envoi.
struct PhotoEditorView: View {
    enum Tool: CaseIterable, Identifiable {
        case crop, blur
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .crop: return "Recadrer"
            case .blur: return "Flouter"
            }
        }

        var symbol: String {
            switch self {
            case .crop: return "crop.rotate"
            case .blur: return "eye.slash"
            }
        }
    }

    let image: UIImage
    /// Proportions imposées (story en 9:16) : les ratios ne sont pas proposés.
    let fixedAspect: CGFloat?
    let confirmTitle: LocalizedStringKey
    /// Titre de validation quand des zones sont floutées (« Flouter et envoyer »).
    let blurConfirmTitle: LocalizedStringKey?
    let onDone: (UIImage, PhotoEdits) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var edits: PhotoEdits
    /// Référence de « rien n'a changé » : les visages trouvés d'office n'en sont pas un.
    @State private var baseline: PhotoEdits
    @State private var tool: Tool
    @State private var ratio: PhotoCropRatio = .free
    @State private var ratioFlipped = false
    /// Photo recadrée sans flou, sous l'outil Flouter.
    @State private var croppedPreview: UIImage?
    @State private var isDetecting = false
    @State private var confirmDiscard = false
    @State private var gestureStart: CGRect?

    init(
        image: UIImage,
        edits: PhotoEdits = PhotoEdits(),
        fixedAspect: CGFloat? = nil,
        initialTool: Tool = .crop,
        confirmTitle: LocalizedStringKey = "photoEditor.done",
        blurConfirmTitle: LocalizedStringKey? = nil,
        onDone: @escaping (UIImage, PhotoEdits) -> Void
    ) {
        self.image = image
        self.fixedAspect = fixedAspect
        self.confirmTitle = confirmTitle
        self.blurConfirmTitle = blurConfirmTitle
        self.onDone = onDone
        var start = edits
        if let fixedAspect, start.crop == PhotoEdits.fullFrame {
            start.crop = PhotoEdits.largestCrop(aspect: fixedAspect, in: start.baseSize(for: image.size))
        }
        _edits = State(initialValue: start)
        _baseline = State(initialValue: start)
        _tool = State(initialValue: initialTool)
    }

    private var isWide: Bool { horizontalSizeClass == .regular || verticalSizeClass == .compact }
    private var baseSize: CGSize { edits.baseSize(for: image.size) }
    private var hasChanges: Bool { edits != baseline }

    var body: some View {
        NavigationStack {
            Group {
                if isWide {
                    HStack(spacing: 0) {
                        canvas
                        VStack(spacing: 0) {
                            panel.frame(maxHeight: .infinity, alignment: .top)
                            toolBar
                        }
                        .frame(width: 320)
                        .background(SQColor.surface)
                    }
                } else {
                    VStack(spacing: 0) {
                        canvas
                        panel.frame(height: 120)
                        toolBar
                    }
                }
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle("Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                    .accessibilityIdentifier("photoEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onDone(PhotoEditRenderer.render(image, edits: edits), edits)
                        dismiss()
                    } label: {
                        Text(edits.hasBlur ? (blurConfirmTitle ?? confirmTitle) : confirmTitle).bold()
                    }
                    .accessibilityIdentifier("photoEditor.done")
                }
            }
            // Alerte plutôt que feuille d'actions : les iOS récents y masquent le bouton
            // d'annulation, et « Continuer » doit toujours se lire à côté de « Abandonner ».
            .alert("Abandonner les modifications ?", isPresented: $confirmDiscard) {
                Button("Abandonner", role: .destructive) { dismiss() }
                Button("photoEditor.keepEditing", role: .cancel) {}
            }
            .interactiveDismissDisabled(hasChanges)
            .task(id: tool) {
                if tool == .blur { await prepareBlurTool() }
            }
        }
    }

    // MARK: Photo

    @ViewBuilder
    private var canvas: some View {
        switch tool {
        case .crop:
            GeometryReader { proxy in
                cropCanvas(in: proxy.size)
            }
            .padding(SQSpace.lg)
        case .blur:
            if let croppedPreview {
                PhotoBlurCanvas(image: croppedPreview, regions: cropSpaceRegions)
                    .padding(SQSpace.lg)
            } else {
                SQSpinner().tint(SQColor.brandRed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func cropCanvas(in container: CGSize) -> some View {
        let frame = PhotoBlurCanvas.fittedFrame(for: baseSize, in: container)
        let upright = edits.quarterTurns % 2 == 0 ? frame.size : CGSize(width: frame.height, height: frame.width)
        let crop = CGRect(x: frame.minX + edits.crop.minX * frame.width, y: frame.minY + edits.crop.minY * frame.height,
                          width: edits.crop.width * frame.width, height: edits.crop.height * frame.height)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: upright.width, height: upright.height)
                .rotationEffect(.degrees(-90 * Double(edits.quarterTurns) + edits.straighten))
                .scaleEffect(PhotoEdits.straightenScale(for: frame.size, degrees: edits.straighten))
                .frame(width: frame.width, height: frame.height)
                .clipped()
                .position(x: frame.midX, y: frame.midY)
                .accessibilityHidden(true)
            // Hors du cadre, la photo est voilée.
            Path { path in
                path.addRect(frame)
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            cropFrame(crop)
                .gesture(moveGesture(frame: frame).simultaneously(with: zoomGesture()))
            ForEach(Corner.allCases) { corner in
                cornerHandle(corner, crop: crop, frame: frame)
            }
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func cropFrame(_ crop: CGRect) -> some View {
        ZStack {
            Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
            // Tiers : aide à composer.
            Path { path in
                for i in 1...2 {
                    let x = crop.width * CGFloat(i) / 3, y = crop.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: crop.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: crop.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
        }
        .frame(width: crop.width, height: crop.height)
        .contentShape(Rectangle())
        .position(x: crop.midX, y: crop.midY)
        .accessibilityElement()
        .accessibilityLabel(Text("Cadre"))
        .accessibilityIdentifier("photoEditor.cropFrame")
    }

    enum Corner: CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: Self { self }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    private func cornerHandle(_ corner: Corner, crop: CGRect, frame: CGRect) -> some View {
        let point = CGPoint(x: corner.isLeft ? crop.minX : crop.maxX, y: corner.isTop ? crop.minY : crop.maxY)
        return Path { path in
            let arm: CGFloat = 16
            let dx: CGFloat = corner.isLeft ? 1 : -1, dy: CGFloat = corner.isTop ? 1 : -1
            path.move(to: CGPoint(x: 22 + dx * arm, y: 22))
            path.addLine(to: CGPoint(x: 22, y: 22))
            path.addLine(to: CGPoint(x: 22, y: 22 + dy * arm))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .position(point)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let start = gestureStart ?? edits.crop
                    if gestureStart == nil { gestureStart = start }
                    let location = CGPoint(x: point.x + value.translation.width, y: point.y + value.translation.height)
                    let normalized = CGPoint(x: (location.x - frame.minX) / frame.width, y: (location.y - frame.minY) / frame.height)
                    edits.crop = Self.resized(start, corner: corner, to: normalized, aspect: normalizedAspect)
                }
                .onEnded { _ in gestureStart = nil }
        )
        .accessibilityHidden(true)
    }

    /// Glisser le cadre le déplace sur la photo.
    private func moveGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = gestureStart ?? edits.crop
                if gestureStart == nil { gestureStart = start }
                edits.crop = PhotoEdits.clampedInside(start.offsetBy(dx: value.translation.width / frame.width,
                                                                     dy: value.translation.height / frame.height))
            }
            .onEnded { _ in gestureStart = nil }
    }

    /// Pincer agrandit ou resserre le cadre autour de son centre.
    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let start = gestureStart ?? edits.crop
                if gestureStart == nil { gestureStart = start }
                edits.crop = Self.zoomed(start, by: scale)
            }
            .onEnded { _ in gestureStart = nil }
    }

    /// Proportions du cadre en coordonnées normalisées (`nil` : libre).
    private var normalizedAspect: CGFloat? {
        let pixelAspect = fixedAspect ?? ratio.aspect(base: baseSize, flipped: ratioFlipped)
        guard let pixelAspect, baseSize.width > 0 else { return nil }
        return pixelAspect * baseSize.height / baseSize.width
    }

    static let minimumCropSide: CGFloat = 0.08

    /// Coin tiré vers `point` (normalisé), le coin opposé fixe ; proportions gardées si `aspect`.
    static func resized(_ start: CGRect, corner: Corner, to point: CGPoint, aspect: CGFloat?) -> CGRect {
        let anchor = CGPoint(x: corner.isLeft ? start.maxX : start.minX, y: corner.isTop ? start.maxY : start.minY)
        let maxWidth = corner.isLeft ? anchor.x : 1 - anchor.x
        let maxHeight = corner.isTop ? anchor.y : 1 - anchor.y
        var width = min(max(abs(anchor.x - point.x), minimumCropSide), maxWidth)
        var height = min(max(abs(anchor.y - point.y), minimumCropSide), maxHeight)
        if let aspect, aspect > 0 {
            height = width / aspect
            if height > maxHeight {
                height = maxHeight
                width = height * aspect
            }
        }
        return CGRect(x: corner.isLeft ? anchor.x - width : anchor.x, y: corner.isTop ? anchor.y - height : anchor.y,
                      width: width, height: height)
    }

    /// Cadre resserré d'un facteur `scale` (pincer pour agrandir la photo), proportions gardées.
    static func zoomed(_ start: CGRect, by scale: CGFloat) -> CGRect {
        guard scale > 0, start.width > 0, start.height > 0 else { return start }
        let largest = min(1 / start.width, 1 / start.height)
        let smallest = minimumCropSide / min(start.width, start.height)
        let factor = min(max(1 / scale, smallest), largest)
        let size = CGSize(width: start.width * factor, height: start.height * factor)
        return PhotoEdits.clampedInside(CGRect(x: start.midX - size.width / 2, y: start.midY - size.height / 2,
                                               width: size.width, height: size.height))
    }

    // MARK: Panneau

    @ViewBuilder
    private var panel: some View {
        switch tool {
        case .crop: cropPanel
        case .blur: blurPanel
        }
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            if fixedAspect == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SQSpace.sm) {
                        ForEach(PhotoCropRatio.allCases) { option in
                            ratioChip(option)
                        }
                        Button {
                            ratioFlipped.toggle()
                            applyRatio()
                        } label: {
                            Image(systemName: "rectangle.portrait.rotate")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(!ratio.canFlip)
                        .accessibilityLabel(Text("Portrait ou paysage"))
                        .accessibilityIdentifier("photoEditor.ratio.flip")
                    }
                    .padding(.horizontal, SQSpace.lg)
                }
            }
            HStack(spacing: SQSpace.md) {
                Button {
                    rotateLeft()
                } label: {
                    Image(systemName: "rotate.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Pivoter à gauche"))
                .accessibilityIdentifier("photoEditor.rotate")
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Redresser").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                        Spacer()
                        Text(verbatim: Self.angleText(edits.straighten))
                            .font(SQType.caption.monospacedDigit())
                            .foregroundStyle(SQColor.label)
                    }
                    Slider(value: straightenBinding, in: -PhotoEdits.straightenLimit...PhotoEdits.straightenLimit, step: 0.5)
                        .tint(SQColor.brandRed)
                        .accessibilityLabel(Text("Redresser"))
                        .accessibilityValue(Text(Self.spokenAngle(edits.straighten)))
                        .accessibilityIdentifier("photoEditor.straighten")
                }
                if edits.hasGeometryChanges && !(fixedAspect != nil && onlyFixedCrop) {
                    Button("Réinitialiser") { resetGeometry() }
                        .font(SQType.subhead)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("photoEditor.reset")
                }
            }
            .padding(.horizontal, SQSpace.lg)
        }
        .padding(.vertical, SQSpace.sm)
        .foregroundStyle(SQColor.label)
    }

    /// Story : le cadre 9:16 d'office n'est pas une modification à réinitialiser.
    private var onlyFixedCrop: Bool {
        guard let fixedAspect else { return false }
        return edits.quarterTurns == 0 && edits.straighten == 0
            && edits.crop == PhotoEdits.largestCrop(aspect: fixedAspect, in: baseSize)
    }

    private func ratioChip(_ option: PhotoCropRatio) -> some View {
        let selected = ratio == option
        return Button {
            Haptics.selection()
            ratio = option
            if !option.canFlip { ratioFlipped = false }
            applyRatio()
        } label: {
            Text(option.title)
                .font(SQType.micro)
                .padding(.horizontal, SQSpace.md)
                .frame(minHeight: 44)
                .foregroundStyle(selected ? SQColor.onInk : SQColor.label)
                .background(selected ? SQColor.label : SQColor.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("photoEditor.ratio.\(String(describing: option))")
    }

    private var blurPanel: some View {
        Text(blurStatus)
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SQSpace.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("blur.status")
    }

    private var blurStatus: String {
        if isDetecting { return String(localized: "Recherche des visages…") }
        if edits.blurRegions.isEmpty { return String(localized: "Aucun visage repéré. Glisse le doigt sur la photo pour flouter une zone.") }
        return String(localized: "Zones à flouter : \(edits.blurRegions.count). Glisse le doigt pour en ajouter, touche la croix pour en retirer.")
    }

    // MARK: Outils

    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases) { item in
                let selected = tool == item
                let modified = item == .crop ? (edits.hasGeometryChanges && !onlyFixedCrop) : edits.hasBlur
                Button {
                    Haptics.selection()
                    tool = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold))
                        Text(item.title).font(SQType.micro)
                        // Point d'accent : l'outil contient une modification.
                        Circle().fill(modified ? SQColor.brandRed : .clear).frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(selected ? SQColor.label : SQColor.labelSecondary)
                    .overlay(alignment: .top) {
                        Rectangle().fill(selected ? SQColor.brandRed : .clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(modified ? Text("Modifié") : Text(""))
                .accessibilityIdentifier("photoEditor.tool.\(String(describing: item))")
            }
        }
        .padding(.bottom, SQSpace.xs)
        .background(SQColor.surface)
    }

    // MARK: Actions

    private var straightenBinding: Binding<Double> {
        Binding(
            get: { edits.straighten },
            set: { value in
                // Aimanté à 0 : un redressement nul se retrouve sans viser.
                let snapped = abs(value) < 1 ? 0 : value
                if snapped == 0, edits.straighten != 0 { Haptics.selection() }
                edits.straighten = snapped
            }
        )
    }

    private func applyRatio() {
        guard let aspect = fixedAspect ?? ratio.aspect(base: baseSize, flipped: ratioFlipped) else { return }
        let update = { edits.crop = PhotoEdits.largestCrop(aspect: aspect, in: baseSize, centeredOn: CGPoint(x: edits.crop.midX, y: edits.crop.midY)) }
        if reduceMotion { update() } else { withAnimation(.easeOut(duration: 0.2), update) }
    }

    private func rotateLeft() {
        Haptics.light()
        edits.rotateLeft()
        if fixedAspect != nil {
            applyRatio()
        } else if ratio.canFlip {
            // Le cadre a tourné avec la photo : son format s'est inversé.
            ratioFlipped.toggle()
        }
    }

    private func resetGeometry() {
        Haptics.light()
        // Les zones de flou tournent avec la photo : on défait les quarts de tour un à un.
        while edits.quarterTurns != 0 { edits.rotateLeft() }
        edits.straighten = 0
        edits.crop = fixedAspect.map { PhotoEdits.largestCrop(aspect: $0, in: baseSize) } ?? PhotoEdits.fullFrame
        ratio = .free
        ratioFlipped = false
    }

    /// Photo recadrée sous l'outil Flouter, et visages cherchés une seule fois.
    private func prepareBlurTool() async {
        var geometry = edits
        geometry.blurRegions = []
        let preview = PhotoEditRenderer.render(image, edits: geometry)
        croppedPreview = preview
        guard !edits.facesChecked else { return }
        isDetecting = true
        let faces = await PhotoBlur.detectFaces(in: preview).map { Self.toBase($0, crop: edits.crop) }
        isDetecting = false
        edits.blurRegions.append(contentsOf: faces)
        edits.facesChecked = true
        baseline.blurRegions.append(contentsOf: faces)
        baseline.facesChecked = true
    }

    /// Les zones sont gardées dans la base ; l'outil Flouter les montre dans le cadre.
    private var cropSpaceRegions: Binding<[CGRect]> {
        Binding(
            get: { edits.blurRegions.map { Self.toCrop($0, crop: edits.crop) } },
            set: { edits.blurRegions = $0.map { Self.toBase($0, crop: edits.crop) } }
        )
    }

    static func toCrop(_ rect: CGRect, crop: CGRect) -> CGRect {
        guard crop.width > 0, crop.height > 0 else { return rect }
        return CGRect(x: (rect.minX - crop.minX) / crop.width, y: (rect.minY - crop.minY) / crop.height,
                      width: rect.width / crop.width, height: rect.height / crop.height)
    }

    static func toBase(_ rect: CGRect, crop: CGRect) -> CGRect {
        CGRect(x: crop.minX + rect.minX * crop.width, y: crop.minY + rect.minY * crop.height,
               width: rect.width * crop.width, height: rect.height * crop.height)
    }

    static func angleText(_ degrees: Double) -> String {
        "\(degrees.formatted(.number.precision(.fractionLength(0...1))))°"
    }

    static func spokenAngle(_ degrees: Double) -> String {
        let value = abs(degrees).formatted(.number.precision(.fractionLength(0...1)))
        if degrees > 0 { return String(localized: "plus \(value) degrés") }
        if degrees < 0 { return String(localized: "moins \(value) degrés") }
        return String(localized: "0 degré")
    }
}

/// Bouton « Modifier » posé sur l'aperçu d'une photo avant publication, au
/// même style que la croix qui la retire.
struct PhotoEditButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Modifier", systemImage: "slider.horizontal.3")
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
