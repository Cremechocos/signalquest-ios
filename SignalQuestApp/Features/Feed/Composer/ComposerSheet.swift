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
        case .friends: return String(localized: "Amis")
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
    /// Option de sondage avec identité stable. Éditer les options par position
    /// (`ForEach(indices)` + binding par index) plantait sur « Index out of
    /// range » quand on supprimait une option pendant sa saisie : SwiftUI
    /// réévalue encore le champ supprimé (SOC-01). Même modèle que `NewPollView`.
    struct PollOptionDraft: Identifiable, Equatable {
        let id = UUID()
        var text = ""
    }

    /// Sondage en cours de composition. Vide = pas de sondage.
    @Published var pollQuestion = ""
    @Published var pollOptions: [PollOptionDraft] = [PollOptionDraft(), PollOptionDraft()]
    @Published var pollAllowMultiple = false
    @Published var pollEnabled = false

    /// Sondage prêt à l'envoi, ou `nil`. La validation est faite AVANT l'appel :
    /// un 400 sur le sondage coûterait tout le post, pièce jointe comprise.
    var preparedPoll: CreatePostPoll? {
        guard pollEnabled else { return nil }
        return CreatePostPoll.make(
            question: pollQuestion, options: pollOptions.map(\.text), allowMultiple: pollAllowMultiple
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
    /// Envoi resté dans la file après un échec temporaire : il partira tout seul
    /// au prochain chargement du fil, il ne faut donc pas le republier.
    @Published var isQueued = false

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

    /// N'écrit que ce qui change : chaque écriture dans `UserDefaults` notifie
    /// SwiftUI, et réécrire le brouillon qu'on vient de lire relançait la vue
    /// parente en boucle.
    private func saveDraft() {
        guard !isEditing else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: draftTextKey) != text {
            defaults.set(text, forKey: draftTextKey)
        }
        if defaults.string(forKey: draftVisibilityKey) != visibility.rawValue {
            defaults.set(visibility.rawValue, forKey: draftVisibilityKey)
        }
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
        // Un sondage seul suffit, comme dans `publish()` : le bouton restait
        // désactivé alors que l'envoi l'acceptait (SOC-18).
        let hasContent = !body.isEmpty || previewImage != nil || attachedSpeedtest != nil || preparedPoll != nil
        // En modification, seuls le texte et la visibilité partent (`saveEdit`) :
        // une photo ajoutée ne rendait pas « Enregistrer » utile (AF-FIL-05).
        if isEditing { return !body.isEmpty && !isTextTooLong && !isBusy }
        return hasContent && !isTextTooLong && !isBusy && !isQueued
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
                name: String(localized: "Toi"),
                handle: "toi",
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
            // Aperçu décodé réduit : une photo de 48 Mpx pleine taille pour une
            // vignette coûtait des centaines de Mo et figeait l'écran (SOC-36).
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = ImagePipeline.downsample(data: data, maxPixel: 1600) else {
                errorMessage = String(localized: "Photo illisible")
                return
            }
            previewImage = image
            pickedImageData = data
        } catch {
            errorMessage = error.userFacingMessage
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
                errorMessage = String(localized: "Aucun speedtest enregistré pour le moment.")
            }
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func detachSpeedtest() {
        attachedSpeedtest = nil
        Haptics.selection()
    }

    /// Le service d'upload applique le contrat commun : orientation rendue dans
    /// les pixels, downscale et suppression EXIF avant tout envoi réseau.
    /// Rien sans aperçu : une photo retirée partait encore avec la publication.
    var imageDataForUpload: Data? {
        previewImage == nil ? nil : pickedImageData
    }

    func removeImage() {
        previewImage = nil
        selectedItem = nil
        pickedImageData = nil
    }

    /// Photo floutée avant publication (plan 3, vague 1) : elle remplace
    /// l'originale, et c'est elle qui part.
    func applyBlurredImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        previewImage = image
        pickedImageData = data
    }

    /// Prépare le composer pour une ÉDITION.
    ///
    /// Le brouillon n'est volontairement pas touché : éditer un post existant ne
    /// doit pas écraser ce que l'utilisateur avait commencé à rédiger ailleurs.
    /// `editingPost` est posé AVANT le texte, et `saveDraft()` ne sauve rien
    /// pendant une édition : le `didSet` de `text` écrasait le brouillon (SOC-18).
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
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }

    /// Texte envoyé quand le post n'en a pas (le serveur en exige un) : la
    /// question d'un sondage seul, sinon une légende traduite. Un sondage seul
    /// partait sous « Photo SignalQuest », en français quelle que soit la
    /// langue (SOC-18).
    var fallbackBody: String {
        if let question = preparedPoll?.question?.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty {
            return question
        }
        if preparedPoll != nil { return String(localized: "Sondage") }
        if attachedSpeedtest != nil { return String(localized: "Mon dernier speedtest SignalQuest") }
        return String(localized: "Photo SignalQuest")
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
            // Le service ré-encode, réduit et retire les EXIF hors du main thread,
            // puis conserve le brouillon dans son outbox jusqu'à l'accusé serveur.
            let imageData = imageDataForUpload
            let safeBody = body.isEmpty ? fallbackBody : body
            _ = try await service.publishPost(
                text: safeBody,
                visibility: visibility.rawValue,
                imageData: imageData,
                imageMimeType: "image/jpeg",
                targetType: attachedSpeedtest != nil ? "speedtest" : nil,
                targetId: attachedSpeedtest?.id,
                extraMetadata: attachedSpeedtest.map { ["speedtestId": .string($0.id)] },
                poll: preparedPoll
            )
            didPublish = true
            clearDraft()
            Haptics.success()
        } catch where Self.staysQueued(error) {
            // Le post attend dans la file d'envoi : on le dit et on vide le
            // brouillon, sinon un second « Publier » le doublerait.
            isQueued = true
            errorMessage = nil
            clearDraft()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }

    /// Réseau absent ou serveur momentanément indisponible : le post reste dans
    /// la file. Un refus définitif l'en retire, et l'erreur reste affichée.
    static func staysQueued(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard error is APIError else { return false }
        return !error.isPermanentRequestFailure
    }
}

/// Pièce jointe choisie avant d'ouvrir le composer (ligne « Quoi de neuf ? »
/// du fil).
enum ComposerStartAttachment: String {
    case photo
    case speedtest
}

struct ComposerSheet: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: ComposerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: ComposerMode = .edit
    /// Éditeur « Flouter » de la photo jointe (plan 3, vague 1).
    @State private var showBlurEditor = false
    @FocusState private var isInputFocused: Bool
    private let startingWith: ComposerStartAttachment?
    /// Photothèque ouverte d'emblée quand on arrive par le bouton Photo du fil.
    @State private var showStartPhotoPicker = false

    /// `editing` bascule le composer en édition et précharge le post.
    init(
        service: SocialFeedServicing,
        userService: UserServicing? = nil,
        editing: UnifiedSocialFeedItem? = nil,
        startingWith: ComposerStartAttachment? = nil
    ) {
        self.startingWith = editing == nil ? startingWith : nil
        // Créé une seule fois, dans l'autoclosure : la vue parente réévalue
        // cet init à chaque rendu, et un modèle neuf relit puis réécrit le
        // brouillon à chaque fois.
        _model = StateObject(wrappedValue: {
            let model = ComposerViewModel(service: service, userService: userService)
            if let editing { model.beginEditing(editing) }
            return model
        }())
    }

    /// Saisie du sondage.
    private var pollEditor: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            TextField("Ta question (optionnel)", text: $model.pollQuestion)
                .font(SQType.body(.medium))
                .submitLabel(.next)
                .padding(.trailing, 36)

            ForEach($model.pollOptions) { $option in
                let position = (model.pollOptions.firstIndex { $0.id == option.id } ?? 0) + 1
                HStack(spacing: SQSpace.sm) {
                    TextField("Choix \(position)", text: $option.text)
                        .font(SQType.body)
                    // Le retrait n'est offert qu'au-dessus du minimum : le
                    // proposer puis refuser l'action serait pire que l'absence.
                    if model.pollOptions.count > CreatePostPoll.minimumOptions {
                        Button {
                            model.pollOptions.removeAll { $0.id == option.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(SQColor.labelTertiary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Supprimer l'option \(position)"))
                    }
                }
                .padding(.vertical, SQSpace.xs)
            }

            if model.pollOptions.count < CreatePostPoll.maximumOptions {
                Button {
                    model.pollOptions.append(ComposerViewModel.PollOptionDraft())
                } label: {
                    Label("Ajouter une option", systemImage: "plus.circle")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }

            Toggle("Choix multiples", isOn: $model.pollAllowMultiple)
                .font(SQType.subhead(.regular))
                .tint(SQColor.brandRed)
        }
        .padding(SQSpace.md)
        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
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
                                .font(SQType.subhead)
                                .sqSingleLine()
                        }
                        .padding(.horizontal, SQSpace.sm2)
                        .padding(.vertical, SQSpace.xs2)
                        .sqSurface(SQColor.surfaceMuted, in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Mentionner ") + Text(user.displayName))
                }
            }
        }
        .frame(maxHeight: 44)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                topBar
                if selectedMode == .edit { authorRow }
                if selectedMode == .edit {
                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        TextField("Quoi de neuf sur le réseau ?", text: $model.text, axis: .vertical)
                            .lineLimit(4...20)
                            .font(SQFont.body(17, .regular, relativeTo: .body))
                            .textFieldStyle(.plain)
                            .focused($isInputFocused)
                            .accessibilityIdentifier("feed.composer.text")

                        if !model.mentionSuggestions.isEmpty {
                            mentionSuggestions
                        }

                        if model.pollEnabled {
                            pollEditor
                                .overlay(alignment: .topTrailing) {
                                    removeButton(label: "Retirer le sondage") {
                                        Haptics.selection()
                                        model.pollEnabled = false
                                    }
                                }
                        }

                        if let image = model.previewImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    removeButton(label: "Retirer l’image") {
                                        model.removeImage()
                                        Haptics.medium()
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    PhotoBlurButton { showBlurEditor = true }
                                        .accessibilityIdentifier("composer.blur")
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }

                        // Même bloc de mesure que dans le fil, avec sa croix.
                        if let speedtest = model.attachedSpeedtest {
                            FeedMeasureBlock(speedtest: speedtest)
                                .overlay(alignment: .topTrailing) {
                                    removeButton(label: "Retirer le speedtest") { model.detachSpeedtest() }
                                }
                        }

                        quickHashtagsBar
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    PostPreviewCard(
                        author: model.previewAuthor,
                        text: model.text,
                        image: model.previewImage,
                        speedtest: model.attachedSpeedtest,
                        visibility: model.visibility,
                        poll: model.preparedPoll
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if model.isQueued {
                    Label("Envoi en attente : ta publication partira automatiquement dès que possible.",
                          systemImage: "clock.arrow.circlepath")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityIdentifier("composer.queued")
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md)
            .padding(.bottom, SQSpace.xxl)
            .sqAnimation(SQMotion.smooth, value: selectedMode)
            .sqAnimation(SQMotion.snappy, value: model.errorMessage)
        }
        .safeAreaInset(edge: .bottom) {
            if selectedMode == .edit {
                bottomToolbar
            }
        }
        .task {
            await model.loadUserProfile()
        }
        .task {
            if startingWith == .speedtest { await model.attachLatestSpeedtest() }
        }
        .onAppear {
            if startingWith == .photo {
                showStartPhotoPicker = true
            } else {
                isInputFocused = true
            }
        }
        .photosPicker(isPresented: $showStartPhotoPicker, selection: $model.selectedItem, matching: .images)
        .onChangeCompat(of: model.selectedItem) { _, _ in
            Task { await model.loadPickerImage() }
        }
        .sheet(isPresented: $showBlurEditor) {
            if let image = model.previewImage {
                PhotoBlurEditor(image: image) { blurred, _ in model.applyBlurredImage(blurred) }
            }
        }
        .sqSheet()
    }

    /// Fermer à gauche ; « Aperçu » et « Publier » à droite.
    private var topBar: some View {
        HStack(spacing: SQSpace.sm) {
            MapChipIconButton(systemImage: "xmark", label: model.isQueued ? "Fermer" : "Annuler",
                              identifier: "composer.close") {
                dismiss()
            }
            if !model.text.isEmpty {
                MapChipIconButton(systemImage: "trash", label: "Supprimer le brouillon",
                                  identifier: "composer.clearDraft") {
                    model.clearDraft()
                    Haptics.medium()
                }
            }
            Spacer(minLength: 0)
            Button {
                Haptics.selection()
                isInputFocused = false
                selectedMode = selectedMode == .edit ? .preview : .edit
            } label: {
                Text(selectedMode == .edit ? "Aperçu" : "Rédiger")
                    .font(SQType.subhead(.bold))
                    .foregroundStyle(SQColor.ink2)
                    .padding(.horizontal, SQSpace.sm)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.preview")
            publishButton
        }
    }

    /// Encre pleine, grisé tant qu'il n'y a rien à publier.
    private var publishButton: some View {
        Button {
            isInputFocused = false
            Task {
                // Même bouton pour les deux modes : l'action change,
                // pas la place ni le geste.
                let isNewPost = !model.isEditing
                if model.isEditing { await model.saveEdit() } else { await model.publish() }
                guard model.didPublish else { return }
                dismiss()
                // Premier post : proposer d'être prévenu des réactions
                // (TRX-01) ; la feuille attend la fermeture du compositeur.
                if isNewPost {
                    Task { await services.notificationPriming.considerPriming(after: .postPublished) }
                }
            }
        } label: {
            Group {
                if model.isBusy {
                    SQSpinner().controlSize(.mini).tint(SQColor.onInk)
                } else {
                    Text(model.isEditing ? "Enregistrer" : "Publier")
                        .font(SQType.subhead(.bold))
                }
            }
            .foregroundStyle(model.canPublish ? SQColor.onInk : SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.lg)
            .frame(minHeight: 36)
            .background(model.canPublish ? SQColor.label : SQColor.chip, in: Capsule(style: .continuous))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .sqAnimation(SQMotion.fast, value: model.canPublish)
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(!model.canPublish)
        .accessibilityIdentifier("composer.publish")
    }

    /// Ton nom et l'audience, avant d'écrire : on sait qui lira.
    private var authorRow: some View {
        let author = model.previewAuthor
        return HStack(spacing: SQSpace.sm2) {
            SQAvatar(url: author.avatarUrl, name: author.displayName, size: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(author.displayName)
                    .font(SQType.subhead(.bold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                Menu {
                    Picker("Visibilité", selection: $model.visibility) {
                        ForEach(SocialVisibility.allCases) { value in
                            Label(value.label, systemImage: value.icon).tag(value)
                        }
                    }
                } label: {
                    HStack(spacing: SQSpace.xs) {
                        Image(systemName: model.visibility.icon)
                            .font(.system(size: 11, weight: .bold))
                        Text(model.visibility.label)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(SQType.caption(.bold))
                    .foregroundStyle(SQColor.chipInk)
                    .padding(.horizontal, SQSpace.sm2)
                    .padding(.vertical, SQSpace.xs)
                    .background(SQColor.chip, in: Capsule(style: .continuous))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Visibilité")
                .accessibilityValue(model.visibility.label)
                .accessibilityIdentifier("composer.visibility")
            }
            Spacer(minLength: 0)
        }
    }

    /// Croix ronde posée sur une pièce jointe (cible de 44 pt).
    private func removeButton(label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SQColor.label)
                .frame(width: 28, height: 28)
                .sqSurface(SQColor.chip, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
    }

    private var bottomToolbar: some View {
        HStack(spacing: SQSpace.sm) {
            // Modifier un post ne change que son texte et sa visibilité : ces
            // ajouts étaient proposés puis ignorés (AF-FIL-05).
            if !model.isEditing {
                // Libellés tant qu'ils tiennent ; icônes seules sinon.
                ViewThatFits(in: .horizontal) {
                    attachmentTools(showsLabels: true)
                    attachmentTools(showsLabels: false)
                }
                .layoutPriority(1)
            }
            Spacer(minLength: 0)
            characterCounter
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.xs)
        .background(SQColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(SQColor.separator).frame(height: 1 / UIScreen.main.scale)
        }
    }

    /// Photo, Speedtest et Sondage, avec leur nom ; plein encre quand actifs.
    private func attachmentTools(showsLabels: Bool) -> some View {
        HStack(spacing: SQSpace.xs2) {
            PhotosPicker(selection: $model.selectedItem, matching: .images) {
                ComposerToolChip(title: "Photo", systemImage: "photo", isOn: model.previewImage != nil, showsLabel: showsLabels)
            }
            .accessibilityLabel("Ajouter une photo")

            Button {
                if model.attachedSpeedtest == nil {
                    Task { await model.attachLatestSpeedtest() }
                } else {
                    model.detachSpeedtest()
                }
            } label: {
                ComposerToolChip(title: "Speedtest", systemImage: "speedometer", isOn: model.attachedSpeedtest != nil,
                                 showsLabel: showsLabels, isLoading: model.isLoadingSpeedtest)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.attachedSpeedtest == nil ? "Joindre un speedtest" : "Retirer le speedtest")
            .disabled(model.isLoadingSpeedtest)

            Button {
                Haptics.selection()
                model.pollEnabled.toggle()
            } label: {
                ComposerToolChip(title: "Sondage", systemImage: "chart.bar.xaxis", isOn: model.pollEnabled, showsLabel: showsLabels)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sondage")
            .accessibilityAddTraits(model.pollEnabled ? [.isButton, .isSelected] : .isButton)
        }
    }

    /// Caractères restants, à l'encre secondaire ; ambre puis rouge à l'approche de la limite.
    private var characterCounter: some View {
        let limit = 500
        let remaining = limit - model.text.count
        return Text(verbatim: remaining.formatted())
            .font(SQType.caption(.semibold))
            .monospacedDigit()
            .foregroundStyle(remaining < 0 ? SQColor.dangerInk : (remaining <= 100 ? SQColor.warning : SQColor.labelSecondary))
            .contentTransition(.numericText())
            .sqAnimation(SQMotion.snappy, value: remaining)
            .accessibilityLabel(Text("\(remaining) caractères restants"))
            .accessibilityIdentifier("composer.remaining")
    }

    /// Suggestions de hashtags en petites pastilles discrètes.
    private var quickHashtagsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.xs2) {
                ForEach(["#speedtest", "#5G", "#4G", "#signalquest", "#coverage", "#anfr"], id: \.self) { tag in
                    Button {
                        let space = model.text.isEmpty || model.text.hasSuffix(" ") ? "" : " "
                        model.text += "\(space)\(tag) "
                        Haptics.light()
                    } label: {
                        Text(verbatim: tag)
                            .font(SQType.caption(.semibold))
                            .foregroundStyle(SQColor.chipInk)
                            .padding(.horizontal, SQSpace.sm2)
                            .frame(minHeight: 30)
                            .background(SQColor.chip, in: Capsule(style: .continuous))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Ajouter \(tag)"))
                }
            }
        }
    }
}

struct PostPreviewCard: View {
    let author: SocialFeedAuthor
    let text: String
    let image: UIImage?
    let speedtest: SocialShareableSpeedtest?
    let visibility: SocialVisibility
    /// Sondage prêt à l'envoi : l'aperçu le montre, il part avec la publication.
    var poll: CreatePostPoll? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md2) {
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
            }

            // Body text
            let bodyTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Même repli que `ComposerViewModel.fallbackBody` : question du sondage, sinon légende.
            let fallbackText: String = {
                if let question = poll?.question, !question.isEmpty { return question }
                if poll != nil { return String(localized: "Sondage") }
                if speedtest != nil { return String(localized: "Mon dernier speedtest SignalQuest") }
                return String(localized: "Photo SignalQuest")
            }()
            let hasAttachment = image != nil || speedtest != nil || poll != nil
            let displayText = bodyTrimmed.isEmpty
                ? (hasAttachment ? fallbackText : String(localized: "Quoi de neuf sur le réseau ?"))
                : bodyTrimmed

            Text(displayText)
                .font(SQType.body)
                .foregroundStyle(bodyTrimmed.isEmpty && !hasAttachment ? SQColor.labelSecondary : SQColor.label)
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

            // Même bloc de mesure que dans le fil.
            if let speedtest {
                FeedMeasureBlock(speedtest: speedtest)
            }

            // Sondage : question et choix, sans vote possible dans l'aperçu.
            if let poll {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    if let question = poll.question, !question.isEmpty {
                        Text(verbatim: question)
                            .font(SQType.body(.semibold))
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(poll.options.enumerated()), id: \.offset) { _, option in
                        Text(verbatim: option)
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.label)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(.horizontal, SQSpace.md)
                            .overlay(
                                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                                    .stroke(SQColor.separator, lineWidth: 1)
                            )
                    }
                }
                .padding(SQSpace.md)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
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

/// Outil de la barre du compositeur : nom visible, plein encre quand actif.
private struct ComposerToolChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    let showsLabel: Bool
    var isLoading = false

    var body: some View {
        HStack(spacing: SQSpace.xs2) {
            if isLoading {
                SQSpinner().controlSize(.mini).tint(SQColor.label)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            if showsLabel {
                Text(title)
                    .font(SQType.subhead(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(isOn ? SQColor.onInk : SQColor.label)
        .padding(.horizontal, SQSpace.sm2)
        .frame(minHeight: 36)
        .background(isOn ? SQColor.label : SQColor.surface, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).strokeBorder(isOn ? Color.clear : SQColor.separator, lineWidth: 1)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
