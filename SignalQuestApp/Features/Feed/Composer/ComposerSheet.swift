import SwiftUI
import PhotosUI

enum SocialVisibility: String, CaseIterable, Identifiable {
    case publicWorld = "public"
    case friends
    case privateOnly = "private"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .publicWorld: return "Public"
        case .friends: return "Amis"
        case .privateOnly: return "Privé"
        }
    }
    var icon: String {
        switch self {
        case .publicWorld: return "globe"
        case .friends: return "person.2.fill"
        case .privateOnly: return "lock.fill"
        }
    }
}

enum ComposerMode {
    case edit
    case preview
}

@MainActor
final class ComposerViewModel: ObservableObject {
    @Published var text: String = "" {
        didSet {
            saveDraft()
        }
    }
    @Published var visibility: SocialVisibility = .friends {
        didSet {
            saveDraft()
        }
    }
    @Published var selectedItem: PhotosPickerItem?
    @Published var previewImage: UIImage?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var didPublish = false

    // Speedtest joint au post (targetType=speedtest côté backend).
    @Published var attachedSpeedtest: SocialShareableSpeedtest?
    @Published var isLoadingSpeedtest = false

    // Current user profile loaded for live preview
    @Published var currentUser: AuthUser? = nil

    private let service: SocialFeedServicing
    private let userService: UserServicing?

    init(service: SocialFeedServicing, userService: UserServicing? = nil) {
        self.service = service
        self.userService = userService
        loadDraft()
    }

    func loadUserProfile() async {
        guard let userService else { return }
        if AppEnvironment.usesDemoData {
            currentUser = .mock
            return
        }
        do {
            currentUser = try await userService.profile()
        } catch {
            print("Error loading user profile: \(error)")
        }
    }

    private func saveDraft() {
        UserDefaults.standard.set(text, forKey: "ComposerSheet.draftText")
        UserDefaults.standard.set(visibility.rawValue, forKey: "ComposerSheet.draftVisibility")
    }

    private func loadDraft() {
        if let savedText = UserDefaults.standard.string(forKey: "ComposerSheet.draftText") {
            self.text = savedText
        }
        if let savedVisibilityRaw = UserDefaults.standard.string(forKey: "ComposerSheet.draftVisibility"),
           let savedVisibility = SocialVisibility(rawValue: savedVisibilityRaw) {
            self.visibility = savedVisibility
        }
    }

    func clearDraft() {
        UserDefaults.standard.removeObject(forKey: "ComposerSheet.draftText")
        UserDefaults.standard.removeObject(forKey: "ComposerSheet.draftVisibility")
        self.text = ""
        self.visibility = .friends
    }

    var characterCount: Int {
        text.count
    }

    var isTextTooLong: Bool {
        text.count > 500
    }

    var canPublish: Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !body.isEmpty || previewImage != nil || attachedSpeedtest != nil
        return hasContent && !isTextTooLong && !isBusy
    }

    var previewAuthor: SocialFeedAuthor {
        if let me = currentUser {
            return SocialFeedAuthor(
                id: me.id,
                name: me.name,
                handle: me.handle,
                avatarUrl: me.avatarUrl,
                isFriend: false,
                isFollowing: false,
                liveRadio: nil
            )
        } else {
            return SocialFeedAuthor(
                id: "preview-user",
                name: "Vous",
                handle: "vous",
                avatarUrl: nil,
                isFriend: false,
                isFollowing: false,
                liveRadio: nil
            )
        }
    }

    func loadPickerImage() async {
        guard let item = selectedItem else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                previewImage = image
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attachLatestSpeedtest() async {
        guard attachedSpeedtest == nil, !isLoadingSpeedtest else { return }
        if AppEnvironment.usesDemoData {
            attachedSpeedtest = SocialShareableSpeedtest(
                id: "demo-speedtest",
                downloadSpeed: 412,
                uploadSpeed: 64,
                ping: 18,
                networkType: "5G",
                mobileOperator: "SignalQuest",
                timestamp: Date()
            )
            return
        }
        isLoadingSpeedtest = true
        defer { isLoadingSpeedtest = false }
        do {
            if let latest = try await service.myLatestSpeedtest() {
                attachedSpeedtest = latest
                Haptics.light()
            } else {
                errorMessage = "Aucun speedtest enregistré pour le moment."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func detachSpeedtest() {
        attachedSpeedtest = nil
        Haptics.selection()
    }

    func publish() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || previewImage != nil || attachedSpeedtest != nil else { return }
        guard !isTextTooLong else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var attachments: [CreatePostAttachment] = []
            if let imageData = previewImage?.jpegData(compressionQuality: 0.84) {
                attachments.append(try await service.uploadImage(data: imageData, mimeType: "image/jpeg"))
            }
            let fallback = attachedSpeedtest != nil ? "Mon dernier speedtest SignalQuest" : "Photo SignalQuest"
            let safeBody = body.isEmpty ? fallback : body
            _ = try await service.createPost(
                text: safeBody,
                visibility: visibility.rawValue,
                attachments: attachments,
                targetType: attachedSpeedtest != nil ? "speedtest" : nil,
                targetId: attachedSpeedtest?.id,
                extraMetadata: attachedSpeedtest.map { ["speedtestId": .string($0.id)] }
            )
            didPublish = true
            clearDraft()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}

struct ComposerSheet: View {
    @StateObject private var model: ComposerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: ComposerMode = .edit
    @FocusState private var isInputFocused: Bool

    init(service: SocialFeedServicing, userService: UserServicing? = nil) {
        _model = StateObject(wrappedValue: ComposerViewModel(service: service, userService: userService))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    if selectedMode == .edit {
                        VStack(alignment: .leading, spacing: SQSpace.md) {
                            TextField("Quoi de neuf sur le réseau ?", text: $model.text, axis: .vertical)
                                .lineLimit(6...20)
                                .font(SQType.body)
                                .textFieldStyle(.plain)
                                .focused($isInputFocused)
                            
                            if let image = model.previewImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxHeight: 260)
                                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                                            .stroke(SQColor.separator, lineWidth: 1.5)
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            model.previewImage = nil
                                            model.selectedItem = nil
                                            Haptics.medium()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(.white, .black.opacity(0.55))
                                                .padding(SQSpace.sm)
                                        }
                                        .buttonStyle(SQPressButtonStyle())
                                        .accessibilityLabel("Retirer l’image")
                                    }
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            }
                            
                            if let speedtest = model.attachedSpeedtest {
                                attachedSpeedtestChip(speedtest)
                            }
                            
                            quickHashtagsBar
                        }
                        .padding(.horizontal, SQSpace.lg)
                        .padding(.top, SQSpace.md)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        // Preview Mode
                        let author = model.previewAuthor
                        PostPreviewCard(
                            author: author,
                            text: model.text,
                            image: model.previewImage,
                            speedtest: model.attachedSpeedtest,
                            visibility: model.visibility
                        )
                        .padding(.horizontal, SQSpace.lg)
                        .padding(.top, SQSpace.md)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                            .padding(.horizontal, SQSpace.lg)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.bottom, SQSpace.xxl)
                .sqAnimation(SQMotion.smooth, value: selectedMode)
                .sqAnimation(SQMotion.snappy, value: model.errorMessage)
            }
            .signalQuestBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.brandRed)
                }
                
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $selectedMode) {
                        Text("Rédiger").tag(ComposerMode.edit)
                        Text("Aperçu").tag(ComposerMode.preview)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isInputFocused = false
                        Task {
                            await model.publish()
                            if model.didPublish { dismiss() }
                        }
                    } label: {
                        if model.isBusy {
                            ProgressView().controlSize(.mini).tint(SQColor.brandRed)
                        } else {
                            Text("Publier")
                                .font(SQFont.archivo(14, .bold))
                        }
                    }
                    .tint(SQColor.brandRed)
                    .disabled(!model.canPublish)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selectedMode == .edit {
                    bottomToolbar
                }
            }
            .task {
                await model.loadUserProfile()
            }
            .onAppear {
                isInputFocused = true
            }
        }
    }

    private var bottomToolbar: some View {
        VStack(spacing: 0) {
            Divider().background(SQColor.separator)
            
            HStack(spacing: SQSpace.md) {
                // Photos Picker
                PhotosPicker(selection: $model.selectedItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(SQColor.brandRed)
                        .frame(width: 40, height: 40)
                        .background(SQColor.fill, in: Circle())
                }
                .accessibilityLabel("Ajouter une photo")
                .onChangeCompat(of: model.selectedItem) { _, _ in
                    Task { await model.loadPickerImage() }
                }
                
                // Speedtest attachment
                if model.attachedSpeedtest == nil {
                    Button {
                        Task { await model.attachLatestSpeedtest() }
                    } label: {
                        if model.isLoadingSpeedtest {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(SQColor.brandRed)
                                .frame(width: 40, height: 40)
                                .background(SQColor.fill, in: Circle())
                        } else {
                            Image(systemName: "speedometer")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(SQColor.brandRed)
                                .frame(width: 40, height: 40)
                                .background(SQColor.fill, in: Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Joindre un speedtest")
                    .disabled(model.isLoadingSpeedtest)
                }
                
                // Visibility button
                Menu {
                    Picker("Visibilité", selection: $model.visibility) {
                        ForEach(SocialVisibility.allCases) { value in
                            Label(value.label, systemImage: value.icon).tag(value)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.visibility.icon)
                            .font(.caption)
                        Text(model.visibility.label)
                            .font(SQFont.archivo(12, .bold))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, 8)
                    .background(SQColor.fill, in: Capsule())
                    .overlay {
                        Capsule().stroke(SQColor.separator, lineWidth: 1)
                    }
                }
                
                Spacer()
                
                // Trash draft button
                if !model.text.isEmpty {
                    Button {
                        model.clearDraft()
                        Haptics.medium()
                    } label: {
                        Image(systemName: "trash")
                            .font(.body)
                            .foregroundStyle(SQColor.danger)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Supprimer le brouillon")
                }
                
                // Character counter
                characterCounter
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.surface.opacity(0.95))
            .background(.ultraThinMaterial)
        }
    }

    private var characterCounter: some View {
        let charCount = model.text.count
        let limit = 500
        let progress = min(Double(charCount) / Double(limit), 1.0)
        let isClose = charCount >= 400
        let isOver = charCount > limit
        
        return HStack(spacing: 6) {
            if charCount > 0 {
                if isClose {
                    Text("\(limit - charCount)")
                        .font(SQFont.archivo(11, .bold))
                        .foregroundStyle(isOver ? SQColor.danger : SQColor.warning)
                        .contentTransition(.numericText())
                }

                Circle()
                    .stroke(SQColor.fill, lineWidth: 2.5)
                    .frame(width: 20, height: 20)
                    .overlay {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                isOver ? SQColor.danger : (isClose ? SQColor.warning : SQColor.brandRed),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
            }
        }
        .sqAnimation(SQMotion.snappy, value: charCount)
    }

    private var quickHashtagsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(["#speedtest", "#5G", "#4G", "#signalquest", "#coverage", "#anfr"], id: \.self) { tag in
                    Button {
                        let space = model.text.isEmpty || model.text.hasSuffix(" ") ? "" : " "
                        model.text += "\(space)\(tag) "
                        Haptics.light()
                    } label: {
                        Text(tag)
                            .font(SQFont.archivo(11, .bold))
                            .foregroundStyle(SQColor.brandRed)
                            .padding(.horizontal, SQSpace.md)
                            .padding(.vertical, SQSpace.sm)
                            .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                                    .stroke(SQColor.separator, lineWidth: 1.2)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, SQSpace.xs)
        }
    }

    private func attachedSpeedtestChip(_ speedtest: SocialShareableSpeedtest) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: "speedometer")
                .font(.title3)
                .foregroundStyle(SQGradient.signal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speedtest joint")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                HStack(spacing: SQSpace.sm) {
                    if let down = speedtest.downloadSpeed {
                        Text("↓ \(SignalFormatters.speed(down))")
                    }
                    if let ping = speedtest.ping {
                        Text("\(Int(ping)) ms")
                    }
                    if let tech = speedtest.networkType {
                        Text(tech)
                    }
                }
                .font(.caption)
                .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer()
            Button {
                model.detachSpeedtest()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(SQColor.labelTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer le speedtest")
        }
        .padding(SQSpace.md)
        .sqEditorialCard()
    }
}

struct PostPreviewCard: View {
    let author: SocialFeedAuthor
    let text: String
    let image: UIImage?
    let speedtest: SocialShareableSpeedtest?
    let visibility: SocialVisibility

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md + 2) {
            // Header
            HStack(spacing: SQSpace.md) {
                SQAvatar(url: author.avatarUrl, name: author.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(author.displayName)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    HStack(spacing: 6) {
                        Image(systemName: visibility.icon)
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(visibility.label)
                        Text("·")
                        Text("Maintenant")
                    }
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelTertiary)
                }
                Spacer()
                SQEditorialTag(
                    text: speedtest != nil ? "Speedtest" : "Post",
                    color: speedtest != nil ? SQColor.brandBlue : SQColor.label
                )
            }

            // Body text
            let bodyTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackText = speedtest != nil ? "Mon dernier speedtest SignalQuest" : "Photo SignalQuest"
            let displayText = bodyTrimmed.isEmpty ? ((image != nil || speedtest != nil) ? fallbackText : "Quoi de neuf sur le réseau ?") : bodyTrimmed

            Text(displayText)
                .font(SQType.body)
                .foregroundStyle(bodyTrimmed.isEmpty && image == nil && speedtest == nil ? SQColor.labelTertiary : SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            // Image attachment
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                            .stroke(SQColor.separator, lineWidth: 1)
                    }
            }

            // Speedtest metrics
            if let speedtest {
                HStack(spacing: SQSpace.sm) {
                    if let down = speedtest.downloadSpeed {
                        CardMetricTile(
                            label: "Download",
                            value: SignalFormatters.speed(down),
                            highlight: true,
                            accent: SQColor.brandBlue
                        )
                    }
                    if let ping = speedtest.ping {
                        CardMetricTile(
                            label: "Ping",
                            value: SignalFormatters.ms(ping)
                        )
                    }
                    if let tech = speedtest.networkType {
                        CardMetricTile(
                            label: "Réseau",
                            value: tech
                        )
                    }
                }
                
                if let op = speedtest.mobileOperator {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(op)
                            .font(SQType.caption)
                    }
                    .foregroundStyle(SQColor.labelTertiary)
                    .padding(.top, -2)
                }
            }

            // Actions Bar
            HStack(spacing: SQSpace.xl) {
                HStack(spacing: 5) {
                    Image(systemName: "heart")
                    Text("0")
                }
                HStack(spacing: 5) {
                    Image(systemName: "bubble.right")
                    Text("0")
                }
                HStack(spacing: 5) {
                    Image(systemName: "arrow.2.squarepath")
                    Text("0")
                }
                Spacer()
                Image(systemName: "bookmark")
                Image(systemName: "paperplane")
            }
            .foregroundStyle(SQColor.labelSecondary)
            .font(SQFont.archivo(14, .semibold))
            .padding(.top, SQSpace.xs)
            .accessibilityHidden(true)
        }
        .padding(SQSpace.lg)
        .sqEditorialCard()
    }
}
