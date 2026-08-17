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
        case .privateOnly: return String(localized: "Privé")
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
            refreshMentionToken()
        }
    }
    /// Sondage en cours de composition. Vide = pas de sondage.
    @Published var pollQuestion = ""
    @Published var pollOptions: [String] = ["", ""]
    @Published var pollAllowMultiple = false
    @Published var pollEnabled = false

    /// Sondage prêt à l'envoi, ou `nil`. La validation est faite AVANT l'appel :
    /// un 400 sur le sondage coûterait tout le post, pièce jointe comprise.
    var preparedPoll: CreatePostPoll? {
        guard pollEnabled else { return nil }
        return CreatePostPoll.make(
            question: pollQuestion, options: pollOptions, allowMultiple: pollAllowMultiple
        )
    }

    /// Post en cours d'édition. `nil` = création.
    ///
    /// Le composer sert les deux cas plutôt qu'un second écran : la saisie, la
    /// visibilité, les mentions et la limite de longueur sont identiques, et
    /// deux écrans divergeraient dès la première évolution.
    private(set) var editingPost: UnifiedSocialFeedItem?
    var isEditing: Bool { editingPost != nil }

    /// Jeton `@…` en cours de frappe et suggestions associées.
    @Published private(set) var mentionToken: MentionAutocomplete.Token?
    @Published private(set) var mentionSuggestions: [SocialUserSearchResult] = []
    private var suggestionTask: Task<Void, Never>?
    @Published var visibility: SocialVisibility = .friends {
        didSet {
            saveDraft()
        }
    }
    @Published var selectedItem: PhotosPickerItem?
    @Published var previewImage: UIImage?
    /// Données brutes de la photo choisie, conservées pour l'encodage/downscale
    /// hors du main thread au moment de publier (PERF-COMP-01).
    private var pickedImageData: Data?
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

    /// Recalcule le jeton actif et relance les suggestions.
    ///
    /// Le curseur d'un `TextField` SwiftUI n'est pas exposé : on suppose la
    /// frappe en fin de texte, ce qui couvre le cas courant. Éditer au milieu
    /// ne propose simplement rien, plutôt que de proposer à tort.
    private func refreshMentionToken() {
        mentionToken = MentionAutocomplete.activeToken(in: text, cursor: text.endIndex)
        scheduleMentionSuggestions()
    }

    /// Débounce 250 ms. Sans lui, « @nora » produirait cinq requêtes dont
    /// quatre inutiles. Seules les MENTIONS interrogent le serveur : les
    /// hashtags viendront des tendances déjà chargées.
    private func scheduleMentionSuggestions() {
        suggestionTask?.cancel()
        guard let token = mentionToken, token.kind == .mention,
              token.query.count >= MentionAutocomplete.minimumQueryLength else {
            mentionSuggestions = []
            return
        }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let found = (try? await self.service.searchUsers(query: token.query, limit: 6)) ?? []
            guard !Task.isCancelled else { return }
            self.mentionSuggestions = found
        }
    }

    /// Applique une suggestion. Le jeton est remplacé ENTIER, préfixe compris —
    /// sinon on obtient « @@nora ».
    func applyMention(_ handle: String) {
        guard let token = mentionToken else { return }
        text = MentionAutocomplete.apply(handle, to: text, token: token).text
        mentionToken = nil
        mentionSuggestions = []
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
            sqDebugLog("Error loading user profile: \(error)")
        }
    }

    private func saveDraft() {
        UserDefaults.standard.set(text, forKey: draftTextKey)
        UserDefaults.standard.set(visibility.rawValue, forKey: draftVisibilityKey)
    }

    private func loadDraft() {
        if let savedText = UserDefaults.standard.string(forKey: draftTextKey) {
            self.text = savedText
        }
        if let savedVisibilityRaw = UserDefaults.standard.string(forKey: draftVisibilityKey),
           let savedVisibility = SocialVisibility(rawValue: savedVisibilityRaw) {
            self.visibility = savedVisibility
        }
    }

    func clearDraft() {
        UserDefaults.standard.removeObject(forKey: draftTextKey)
        UserDefaults.standard.removeObject(forKey: draftVisibilityKey)
        self.text = ""
        self.visibility = .friends
    }

    private var draftTextKey: String {
        "ComposerSheet.draftText.\(LocalAccountScope.storageNamespace)"
    }

    private var draftVisibilityKey: String {
        "ComposerSheet.draftVisibility.\(LocalAccountScope.storageNamespace)"
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
                pickedImageData = data
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

    /// Encode/redimensionne la photo choisie (≤1600 px) hors du main thread, sur
    /// le même patron que les autres uploads (messages/photos). Renvoie nil s'il
    /// n'y a pas de photo.
    private func preparedImageData() async -> Data? {
        guard let data = pickedImageData else { return nil }
        return await Task.detached(priority: .userInitiated) {
            PhotoUploadPreparation.downscaledJPEG(from: data, maxSide: 1600, quality: 0.84)
        }.value
    }

    /// Prépare le composer pour une ÉDITION.

    ///

    /// Le brouillon n'est volontairement pas touché : éditer un post existant ne

    /// doit pas écraser ce que l'utilisateur avait commencé à rédiger ailleurs.

    func beginEditing(_ post: UnifiedSocialFeedItem) {

        editingPost = post

        text = post.text

        if let raw = post.visibility, let parsed = SocialVisibility(rawValue: raw) {

            visibility = parsed

        }

    }


    /// Enregistre les modifications.

    ///

    /// Le serveur valide la propriété et répond 403 : on ne s'appuie pas sur le

    /// seul masquage de l'UI. Le schéma est `.strict()`, donc on n'envoie que

    /// texte et visibilité — une clé inconnue ferait échouer tout le patch.

    func saveEdit() async {

        guard let post = editingPost else { return }

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty, !isTextTooLong else { return }

        isBusy = true

        defer { isBusy = false }

        do {

            _ = try await service.editPost(

                postId: post.id, text: body, visibility: visibility.rawValue

            )

            didPublish = true

            Haptics.success()

        } catch {

            errorMessage = error.localizedDescription

            Haptics.error()

        }

    }


    func publish() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Un sondage seul suffit : la question porte le message, exiger un
        // texte en plus obligerait à se répéter.
        guard !body.isEmpty || previewImage != nil || attachedSpeedtest != nil || preparedPoll != nil else { return }
        guard !isTextTooLong else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var attachments: [CreatePostAttachment] = []
            // Encodage + downscale (≤1600 px) HORS du main thread pour ne pas geler
            // l'UI au tap « Publier » avec une photo pleine résolution (PERF-COMP-01).
            if let imageData = await preparedImageData() {
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
                extraMetadata: attachedSpeedtest.map { ["speedtestId": .string($0.id)] },
                poll: preparedPoll
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

    /// `editing` bascule le composer en édition et précharge le post.
    init(
        service: SocialFeedServicing,
        userService: UserServicing? = nil,
        editing: UnifiedSocialFeedItem? = nil
    ) {
        let model = ComposerViewModel(service: service, userService: userService)
        if let editing { model.beginEditing(editing) }
        _model = StateObject(wrappedValue: model)
    }

    /// Saisie du sondage.
    private var pollEditor: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            TextField("Ta question (optionnel)", text: $model.pollQuestion)
                .font(SQFont.body(15, .medium))
                .submitLabel(.next)

            ForEach(model.pollOptions.indices, id: \.self) { index in
                HStack(spacing: SQSpace.sm) {
                    TextField("Choix \(index + 1)", text: $model.pollOptions[index])
                        .font(SQType.body)
                    // Le retrait n'est offert qu'au-dessus du minimum : le
                    // proposer puis refuser l'action serait pire que l'absence.
                    if model.pollOptions.count > CreatePostPoll.minimumOptions {
                        Button {
                            model.pollOptions.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(SQColor.labelTertiary)
                        }
                        .accessibilityLabel(Text("Supprimer l'option \(index + 1)"))
                    }
                }
                .padding(.vertical, SQSpace.xs)
            }

            if model.pollOptions.count < CreatePostPoll.maximumOptions {
                Button {
                    model.pollOptions.append("")
                } label: {
                    Label("Ajouter une option", systemImage: "plus.circle")
                        .font(SQFont.body(13, .semibold))
                        .foregroundStyle(SQColor.accentInk)
                }
            }

            Toggle("Choix multiples", isOn: $model.pollAllowMultiple)
                .font(SQFont.body(13))
                .tint(SQColor.brandRed)
        }
        .padding(SQSpace.md)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// Suggestions de mention. Liste courte et scrollable horizontalement : sous
    /// le champ de saisie, une liste verticale repousserait le clavier et
    /// masquerait ce qu'on est en train d'écrire.
    private var mentionSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(model.mentionSuggestions) { user in
                    Button {
                        Haptics.selection()
                        model.applyMention(user.handle ?? user.displayName)
                    } label: {
                        HStack(spacing: SQSpace.xs + 1) {
                            SQAvatar(url: user.avatarUrl, name: user.displayName, size: 22)
                            Text(user.handle.map { "@\($0)" } ?? user.displayName)
                                .font(SQFont.body(13, .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, SQSpace.sm + 2)
                        .padding(.vertical, SQSpace.xs + 2)
                        .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Mentionner ") + Text(user.displayName))
                }
            }
        }
        .frame(maxHeight: 44)
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

                            if !model.mentionSuggestions.isEmpty {
                                mentionSuggestions
                            }

                            if model.pollEnabled { pollEditor }
                            
                            if let image = model.previewImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxHeight: 260)
                                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
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
                    // Capsule accent compacte : l'unique surface brique de l'écran.
                    Button {
                        isInputFocused = false
                        Task {
                            // Même bouton pour les deux modes : l'action change,
                            // pas la place ni le geste.
                            if model.isEditing { await model.saveEdit() } else { await model.publish() }
                            if model.didPublish { dismiss() }
                        }
                    } label: {
                        Group {
                            if model.isBusy {
                                ProgressView().controlSize(.mini).tint(SQColor.onAccent)
                            } else {
                                Text(model.isEditing ? "Enregistrer" : "Publier")
                                    .font(SQFont.body(14, .semibold))
                            }
                        }
                        .foregroundStyle(SQColor.onAccent)
                        .padding(.horizontal, SQSpace.lg - 2)
                        .padding(.vertical, SQSpace.sm - 1)
                        .background(SQColor.brandRed, in: Capsule(style: .continuous))
                        .opacity(model.canPublish ? 1 : 0.45)
                    }
                    .buttonStyle(SQPressButtonStyle())
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
        HStack(spacing: SQSpace.md) {
            // Bascule sondage : même gabarit que les autres actions de la barre.
            Button {
                Haptics.selection()
                model.pollEnabled.toggle()
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(model.pollEnabled ? SQColor.onAccent : SQColor.brandRed)
                    .frame(width: 40, height: 40)
                    .background(model.pollEnabled ? SQColor.brandRed : SQColor.surface, in: Circle())
                    .sqShadowSoft()
            }
            .accessibilityLabel("Sondage")
            .accessibilityAddTraits(model.pollEnabled ? [.isButton, .isSelected] : .isButton)

            // Photos Picker — bouton circulaire 40, surface + ombre repos.
            PhotosPicker(selection: $model.selectedItem, matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 40, height: 40)
                    .background(SQColor.surface, in: Circle())
                    .sqShadowSoft()
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
                    Group {
                        if model.isLoadingSpeedtest {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(SQColor.brandRed)
                        } else {
                            Image(systemName: "speedometer")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(SQColor.brandRed)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .background(SQColor.surface, in: Circle())
                    .sqShadowSoft()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Joindre un speedtest")
                .disabled(model.isLoadingSpeedtest)
            }

            // Visibility button — capsule surface + ombre repos, sans bordure.
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
                        .font(SQFont.body(13, .semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, 10)
                .background(SQColor.surface, in: Capsule(style: .continuous))
                .sqShadowSoft()
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
        .background(SQColor.surfaceGlass)
        .background(.ultraThinMaterial)
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
                        .font(SQFont.body(11, .semibold))
                        .foregroundStyle(isOver ? SQColor.danger : SQColor.warning)
                        .contentTransition(.numericText())
                }

                Circle()
                    .stroke(SQColor.surfaceMuted, lineWidth: 2.5)
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
                            .font(SQFont.body(13, .semibold))
                            .foregroundStyle(SQColor.brandRed)
                            .padding(.horizontal, SQSpace.md)
                            .padding(.vertical, SQSpace.sm)
                            .background(SQColor.surface, in: Capsule(style: .continuous))
                            .sqShadowSoft()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, SQSpace.xs)
        }
    }

    private func attachedSpeedtestChip(_ speedtest: SocialShareableSpeedtest) -> some View {
        HStack(spacing: SQSpace.md) {
            // Pastille circulaire teintée : icône brique sur accentSoft.
            Image(systemName: "speedometer")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 40, height: 40)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speedtest joint")
                    .font(SQFont.body(13, .semibold))
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
                .font(SQType.caption)
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
                    .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer()
                SQEditorialTag(
                    text: speedtest != nil ? "Speedtest" : "Post",
                    color: speedtest != nil ? SQColor.brandRed : SQColor.label
                )
            }

            // Body text
            let bodyTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackText = speedtest != nil ? "Mon dernier speedtest SignalQuest" : "Photo SignalQuest"
            let displayText = bodyTrimmed.isEmpty ? ((image != nil || speedtest != nil) ? fallbackText : "Quoi de neuf sur le réseau ?") : bodyTrimmed

            Text(displayText)
                .font(SQType.body)
                .foregroundStyle(bodyTrimmed.isEmpty && image == nil && speedtest == nil ? SQColor.labelSecondary : SQColor.label)
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
            }

            // Speedtest metrics
            if let speedtest {
                HStack(spacing: SQSpace.sm) {
                    if let down = speedtest.downloadSpeed {
                        CardMetricTile(
                            label: "Download",
                            value: SignalFormatters.speed(down),
                            highlight: true,
                            accent: SQColor.brandRed
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
                    .foregroundStyle(SQColor.labelSecondary)
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
