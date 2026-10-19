import SwiftUI

struct PendingUnencryptedStoryReply: Equatable {
    let storyID: String
    let text: String
    let clearDraftOnSuccess: Bool
}

struct StoryReplyChannelConsent {
    private var acceptedStoryIDs: Set<String> = []
    private(set) var pending: PendingUnencryptedStoryReply?

    mutating func request(storyID: String, text: String, clearDraftOnSuccess: Bool) -> Bool {
        guard pending == nil else { return false }
        if acceptedStoryIDs.contains(storyID) { return true }
        pending = PendingUnencryptedStoryReply(
            storyID: storyID, text: text, clearDraftOnSuccess: clearDraftOnSuccess
        )
        return false
    }

    mutating func confirm(currentStoryID: String?) -> PendingUnencryptedStoryReply? {
        guard let pending, pending.storyID == currentStoryID else {
            self.pending = nil
            return nil
        }
        acceptedStoryIDs.insert(pending.storyID)
        self.pending = nil
        return pending
    }

    mutating func cancelPending() { pending = nil }
}

struct StoryViewer: View {
    let stories: [SocialStory]
    @State private var index: Int = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn

    /// Instant d'auto-avancement de la story courante (nil = minuteur suspendu :
    /// clavier/feuille ouverts ou VoiceOver actif). Source de vérité unique pour la
    /// barre de progression (via TimelineView) et l'auto-avancement (via .task),
    /// en remplacement de l'ancien polling `while` + `Task.sleep(50ms)` (PERF-STORY-01).
    @State private var deadline: Date? = nil
    /// Secondes restantes gelées pendant une pause (valide quand `deadline == nil`).
    @State private var pausedRemaining: Double? = nil

    var onMarkViewed: (SocialStory) -> Void = { _ in }
    /// Tap sur l'auteur dans le header — le parent ferme le viewer et pousse le profil.
    var onAuthorTap: (SocialStory) -> Void = { _ in }
    /// Réponse / réaction à une story = message privé à l'auteur (façon Instagram).
    /// Le parent résout/crée la conversation DM et envoie le texte/emoji.
    var onSendReply: (SocialStory, String, String) async throws -> Void = { _, _, _ in
        throw StoryReplyDeliveryError.unavailable
    }
    /// Suppression d'une story (auteur) — le parent supprime côté serveur + rafraîchit.
    var onDelete: (SocialStory) -> Void = { _ in }
    /// Fournit la liste « Vu par » d'une story (auteur uniquement).
    /// Lève en cas d'échec : un échec réseau n'est pas « personne n'a vu ».
    var viewersProvider: (SocialStory) async throws -> [StoryViewerEntry] = { _ in [] }
    /// Signalement des stories des autres (règle 1.2, SOC-12).
    var reports: ReportsServicing? = nil
    /// Masquer les stories de l'auteur sur cet appareil, sans le bloquer.
    var onHideAuthor: ((SocialStory) -> Void)? = nil

    @StateObject private var replySubmission = StoryReplySubmission()
    @FocusState private var replyFocused: Bool
    @State private var showViewers = false
    @State private var viewers: [StoryViewerEntry] = []
    @State private var viewersError: String?
    @State private var loadingViewers = false
    /// Nombre de vues de ta story, chargé à l'ouverture (« Vu par N »).
    @State private var viewersCount: Int?
    @State private var showUnencryptedConfirm = false
    @State private var channelConsent = StoryReplyChannelConsent()
    @State private var reportedStory: SocialStory?
    @State private var showStoryActions = false
    /// Doigt posé sur la story : le minuteur s'arrête, comme partout ailleurs
    /// (SOC-34). Un simple tap ne pause pas : le délai filtre les touchers brefs.
    @State private var isHolding = false
    @State private var holdTask: Task<Void, Never>?
    /// Largeur réelle de la vue : les zones de tap se calculaient sur l'écran
    /// entier, faux en Split View ou Stage Manager sur iPad (SOC-27).
    @State private var viewWidth: CGFloat = 0

    /// Durée d'affichage dérivée du choix de l'auteur (5/10/15 s côté backend),
    /// bornée 5...15 (STORY-BUG-01 : la constante 6 s ignorait `durationSeconds`).
    private var duration: Double {
        Double(min(15, max(5, currentStory?.durationSeconds ?? 10)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let story = currentStory {
                content(for: story)
                    .transition(.opacity)
                    .id(story.id)
            }
            // Voiles haut et bas : barres, auteur, légende et réponse restent
            // lisibles sur toute photo.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 180)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 300)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack {
                // PERF-STORY-01 : la barre se remplit via TimelineView (recalcul
                // scopé aux seules barres, pas de mutation @State réévaluant tout
                // le body). `paused` fige le rendu pendant les pauses.
                TimelineView(.animation(minimumInterval: nil, paused: timerPaused)) { context in
                    progressBars(now: context.date)
                }
                header
                Spacer()
                if let story = currentStory {
                    storyDetails(for: story)
                }
                if currentStory?.isMine == true {
                    ownerFooter
                } else {
                    replyAffordance
                }
            }
        }
        .sheet(isPresented: $showViewers) {
            StoryViewersSheet(viewers: viewers, isLoading: loadingViewers, errorMessage: viewersError) {
                Task { await loadViewers() }
            }
        }
        .sheet(item: $reportedStory) { story in
            if let reports {
                ReportSheet(target: .story(story.id), service: reports)
            }
        }
        .alert("Réponse privée sans chiffrement de bout en bout", isPresented: $showUnencryptedConfirm) {
            Button("Envoyer sans chiffrement de bout en bout") { confirmUnencryptedReply() }
            Button("Annuler", role: .cancel) { channelConsent.cancelPending() }
        } message: {
            Text("Cette réponse sera envoyée dans une conversation privée non chiffrée de bout en bout.")
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewWidth = proxy.size.width }
                    .onChangeCompat(of: proxy.size.width) { _, width in viewWidth = width }
            }
        }
        .onTapGesture(coordinateSpace: .local) { location in
            if viewWidth > 0, location.x < viewWidth / 2 { back() } else { forward() }
        }
        // Doigt posé : pause après un court délai, reprise au relâchement.
        // Geste simultané, pour que le tap garde la navigation.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard holdTask == nil, !isHolding else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        isHolding = true
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel()
                    holdTask = nil
                    isHolding = false
                }
        )
        .gesture(
            DragGesture(minimumDistance: 22)
                .onEnded { value in
                    if value.translation.height > 80 { dismiss() }
                }
        )
        // A11Y-04 : la navigation repose sur des zones de tap invisibles pour
        // VoiceOver ; on l'expose en actions personnalisées « précédent/suivant ».
        .accessibilityAction(named: Text("Story suivante")) { forward() }
        .accessibilityAction(named: Text("Story précédente")) { back() }
        .onAppear { startStory() }
        .task(id: currentStory?.id) { await loadViewersCount() }
        .onChange(of: index) { _ in
            channelConsent.cancelPending()
            showUnencryptedConfirm = false
            replySubmission.clearFeedback()
            startStory()
        }
        // Pause/reprise du minuteur : saisie clavier, feuille « Vu par… », dialogue
        // de suppression, ou VoiceOver actif (auto-avancement suspendu, cf. A11Y-04).
        .onChange(of: shouldPause) { paused in
            if paused { pause() } else { resume() }
        }
        // Auto-avancement : un unique sleep jusqu'à `deadline` (aucun polling 20 Hz).
        .task(id: deadline) {
            guard let deadline else { return }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64((remaining * 1_000_000_000).rounded()))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { forward() }
        }
    }

    @ViewBuilder
    private func content(for story: SocialStory) -> some View {
        if let url = story.mediaUrl {
            if story.mediaKind?.lowercased().contains("video") == true {
                // Pas de lecteur vidéo ici : la vignette, avec une pastille qui
                // dit qu'il s'agit d'une vidéo, plutôt qu'un chargeur d'image
                // qui échouerait sur le fichier vidéo.
                ZStack {
                    Color.black
                    if let thumbnail = story.thumbnailUrl {
                        RemoteImage(url: thumbnail, maxDimension: 1400, contentMode: .fill, showsFailureUI: true) {
                            Color.black
                        }
                    }
                    Label("Vidéo", systemImage: "play.fill")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, SQSpace.lg)
                        .frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityHidden(true)
                }
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel(mediaLabel(for: story))
                .accessibilityValue(Text("Vidéo"))
            } else {
                RemoteImage(url: url, maxDimension: 1400, contentMode: .fill, showsFailureUI: true) {
                    Color.black
                }
                .ignoresSafeArea()
                // A11Y-04 : le média n'avait aucun label VoiceOver.
                .accessibilityElement()
                .accessibilityLabel(mediaLabel(for: story))
            }
        } else {
            // Story texte : canevas « nuit » de la charte, typo display crème.
            // Le crème du mode clair rendait illisibles le nom, l'heure et les
            // boutons du lecteur, écrits en blanc pour les photos. Une couleur
            // de fond choisie par l'auteur (hex) prend la place du canevas.
            let custom = Self.backgroundColor(story.background)
            ZStack {
                (custom?.color ?? SQColor.bg).ignoresSafeArea()
                VStack(spacing: SQSpace.lg) {
                    SQAvatar(url: story.author.avatarUrl, name: story.author.displayName, size: 88)
                    Text(story.text ?? String(localized: "Story"))
                        .font(SQFont.display(28, .bold))
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SQSpace.xxl + 4)
                }
            }
            .environment(\.colorScheme, custom?.isLight == true ? .light : .dark)
        }
    }

    /// Couleur de fond d'une story texte, quand le serveur en porte une au
    /// format `#RRGGBB`. Tout autre format est ignoré : le canevas de la charte reste.
    /// `isLight` choisit l'encre du texte (sombre sur fond clair).
    static func backgroundColor(_ raw: String?) -> (color: Color, isLight: Bool)? {
        guard var hex = raw?.trimmingCharacters(in: .whitespacesAndNewlines), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return (Color(hex: value), luminance > 0.6)
    }

    private func progressBars(now: Date) -> some View {
        HStack(spacing: SQSpace.xs) {
            ForEach(stories.indices, id: \.self) { i in
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(0.30))
                        .overlay(alignment: .leading) {
                            // Jauge crème, comme sur le web.
                            Capsule().fill(Color(red: 0.957, green: 0.949, blue: 0.925))
                                .frame(width: proxy.size.width * fillRatio(for: i, now: now))
                        }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.top, SQSpace.sm2)
    }

    private var header: some View {
        HStack(spacing: SQSpace.sm2) {
            if let story = currentStory {
                Button {
                    Haptics.light()
                    dismiss()
                    onAuthorTap(story)
                } label: {
                    HStack(spacing: SQSpace.sm2) {
                        SQAvatar(url: story.author.avatarUrl, name: story.author.displayName, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(story.isMine == true ? String(localized: "Ta story") : story.author.displayName)
                                .font(SQFont.body(14, .bold, relativeTo: .subheadline))
                                .foregroundStyle(.white)
                            if let date = story.createdAt {
                                Text(date, format: .relative(presentation: .named))
                                    .font(SQFont.body(12, .regular, relativeTo: .caption))
                                    .foregroundStyle(.white.opacity(0.78))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voir le profil de \(story.author.displayName)")
            }
            Spacer()
            // Feuille d'actions plutôt qu'un menu : son ouverture se voit, et la
            // story reste en pause pendant le choix.
            if let story = currentStory, story.isMine == true || reports != nil || onHideAuthor != nil {
                Button {
                    showStoryActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Plus d’options")
                .accessibilityIdentifier("story.more")
                .confirmationDialog("Story de \(story.author.displayName)", isPresented: $showStoryActions, titleVisibility: .hidden) {
                    if story.isMine == true {
                        // La feuille d'actions vaut confirmation, comme dans Photos.
                        Button("Supprimer la story", role: .destructive) {
                            Haptics.medium()
                            onDelete(story)
                            dismiss()
                        }
                    }
                    if story.isMine != true, let onHideAuthor {
                        Button("Masquer les stories de \(story.author.displayName)") { onHideAuthor(story) }
                    }
                    if story.isMine != true, reports != nil {
                        Button("Signaler la story", role: .destructive) { reportedStory = story }
                    }
                    Button("Annuler", role: .cancel) {}
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Fermer")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.xs2)
    }

    private let quickReactions = ["❤️", "🔥", "👏"]

    /// Légende d'une story photo, puis le relevé réseau joint en pastilles.
    @ViewBuilder
    private func storyDetails(for story: SocialStory) -> some View {
        let caption = story.mediaUrl == nil ? nil : story.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pills = StorySignalSummary(metadata: story.metadata)?.pills ?? []
        if (caption?.isEmpty == false) || !pills.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(SQFont.body(16, .semibold, relativeTo: .body))
                        .lineSpacing(3)
                        .foregroundStyle(.white)
                        .lineLimit(4)
                }
                if !pills.isEmpty {
                    HStack(spacing: SQSpace.xs2) {
                        ForEach(pills, id: \.self) { pill in
                            Text(verbatim: pill)
                                .font(SQType.caption(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, SQSpace.sm2)
                                .frame(minHeight: 26)
                                .background(.white.opacity(0.16), in: Capsule(style: .continuous))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("story.signal")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SQSpace.lg)
            .padding(.bottom, SQSpace.md)
            .allowsHitTesting(false)
        }
    }

    private var replyAffordance: some View {
        VStack(spacing: SQSpace.sm) {
            if replySubmission.sentStoryID == currentStory?.id {
                Label("Envoyé", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale))
            }
            if replySubmission.failedStoryID == currentStory?.id {
                Label("Échec de l'envoi. Réessaie.", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityIdentifier("story.reply.error")
            }
            if replySubmission.isSending {
                ProgressView("Envoi…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("story.reply.sending")
            }
            // Réponse et réactions sur une ligne : message privé à l'auteur.
            HStack(spacing: SQSpace.sm) {
                TextField("", text: $replySubmission.draft, prompt: Text(replyPrompt).foregroundColor(.white.opacity(0.75)))
                    .focused($replyFocused)
                    .accessibilityIdentifier("story.reply.input")
                    .disabled(replySubmission.isSending)
                    .font(SQFont.body(14, .regular, relativeTo: .body))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .submitLabel(.send)
                    .onSubmit(sendReply)
                    .padding(.horizontal, SQSpace.lg)
                    .frame(minHeight: 44)
                    .overlay {
                        Capsule(style: .continuous).strokeBorder(.white.opacity(0.32), lineWidth: 1)
                    }
                if replySubmission.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(quickReactions, id: \.self) { emoji in
                        Button {
                            Haptics.light()
                            submitReply(emoji, clearDraftOnSuccess: false)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(width: 36, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Réagir avec \(emoji)")
                        .disabled(replySubmission.isSending)
                    }
                } else {
                    Button(action: sendReply) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SQColor.onAccent)
                            .frame(width: 44, height: 44)
                            .background(SQColor.brandRed, in: Circle())
                    }
                    .accessibilityLabel("Envoyer")
                    .accessibilityIdentifier("story.reply.send")
                    .disabled(replySubmission.isSending)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            Text("Réponse privée sans chiffrement de bout en bout")
                .font(SQFont.body(11, .regular, relativeTo: .caption2))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("story.reply.channel")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.bottom, SQSpace.lg)
        .sqAnimation(SQMotion.snappy, value: replySubmission.draft.isEmpty)
        .sqAnimation(SQMotion.snappy, value: replySubmission.sentStoryID)
    }

    private var replyPrompt: String {
        guard let name = currentStory?.author.displayName, !name.isEmpty else { return String(localized: "Répondre…") }
        return String(localized: "Répondre à \(name)…")
    }

    /// Pied de ta propre story : « Vu par N » ; la suppression passe par ⋯.
    private var ownerFooter: some View {
        HStack {
            Button {
                Task { await loadViewers() }
                showViewers = true
            } label: {
                Label {
                    if let viewersCount {
                        Text("Vu par \(viewersCount)")
                    } else {
                        Text("Vu par…")
                    }
                } icon: {
                    Image(systemName: "eye")
                }
                .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(.white)
                .padding(.horizontal, SQSpace.lg)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel("Voir qui a vu la story")
            .accessibilityIdentifier("story.viewers")
            Spacer()
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.bottom, SQSpace.lg)
    }

    /// Nombre de vues de ta story ; un échec laisse « Vu par… ».
    private func loadViewersCount() async {
        viewersCount = nil
        guard let story = currentStory, story.isMine == true else { return }
        if let entries = try? await viewersProvider(story), !Task.isCancelled {
            viewersCount = entries.count
        }
    }

    private func loadViewers() async {
        guard let story = currentStory else { return }
        loadingViewers = true
        viewersError = nil
        do {
            viewers = try await viewersProvider(story)
            viewersCount = viewers.count
        } catch {
            if !error.isCancellation { viewersError = error.userFacingMessage }
        }
        loadingViewers = false
    }

    private func sendReply() {
        submitReply(replySubmission.draft, clearDraftOnSuccess: true)
    }

    private func submitReply(_ rawText: String, clearDraftOnSuccess: Bool) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let story = currentStory, !replySubmission.isSending else { return }
        if !channelConsent.request(storyID: story.id, text: text, clearDraftOnSuccess: clearDraftOnSuccess) {
            showUnencryptedConfirm = true
            return
        }
        performReply(story, text: text, clearDraftOnSuccess: clearDraftOnSuccess)
    }

    private func confirmUnencryptedReply() {
        guard let story = currentStory,
              let pending = channelConsent.confirm(currentStoryID: story.id) else { return }
        performReply(story, text: pending.text, clearDraftOnSuccess: pending.clearDraftOnSuccess)
    }

    private func performReply(_ story: SocialStory, text: String, clearDraftOnSuccess: Bool) {
        Task {
            let delivered = await replySubmission.submit(storyID: story.id, text: text) { requestID in
                try await onSendReply(story, text, requestID)
            }
            guard delivered else { return }
            if clearDraftOnSuccess, currentStory?.id == story.id {
                replySubmission.draft = ""
                replyFocused = false
            }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            replySubmission.clearSuccess(storyID: story.id)
        }
    }

    private var currentStory: SocialStory? {
        guard index >= 0, index < stories.count else { return nil }
        return stories[index]
    }

    // MARK: - Minuteur de progression (sans polling)

    /// Le minuteur est suspendu (barre figée) dès que `deadline` est nil.
    private var timerPaused: Bool { deadline == nil }

    /// Conditions qui suspendent le minuteur : saisie clavier, feuilles/dialogues
    /// ouverts, ou VoiceOver actif (l'utilisateur avance manuellement, cf. A11Y-04).
    private var shouldPause: Bool {
        replyFocused || replySubmission.isSending
            || replySubmission.failedStoryID == currentStory?.id
            || showViewers || showUnencryptedConfirm || voiceOverOn
            || isHolding || reportedStory != nil || showStoryActions
    }

    /// Secondes écoulées sur la story courante à l'instant `now`.
    private func currentElapsed(now: Date) -> Double {
        if let deadline {
            return min(duration, max(0, duration - deadline.timeIntervalSince(now)))
        }
        if let pausedRemaining {
            return min(duration, max(0, duration - pausedRemaining))
        }
        return 0
    }

    private func fillRatio(for i: Int, now: Date) -> Double {
        if i < index { return 1 }
        if i > index { return 0 }
        // Sous VoiceOver, aucun minuteur : la barre active est montrée pleine.
        if voiceOverOn { return 1 }
        return currentElapsed(now: now) / duration
    }

    /// Démarre (ou redémarre) la story courante : marque « vue » puis arme le
    /// minuteur — sauf si une pause est déjà active (clavier/feuille/VoiceOver).
    private func startStory() {
        guard let story = currentStory else { return }
        onMarkViewed(story)
        if shouldPause {
            pausedRemaining = duration
            deadline = nil
        } else {
            pausedRemaining = nil
            deadline = Date().addingTimeInterval(duration)
        }
    }

    /// Gèle le temps restant et suspend l'auto-avancement.
    private func pause() {
        guard let deadline else { return }
        pausedRemaining = max(0, deadline.timeIntervalSinceNow)
        self.deadline = nil
    }

    /// Reprend le décompte à partir du temps restant gelé.
    private func resume() {
        guard let pausedRemaining else { return }
        deadline = Date().addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
    }

    /// Label VoiceOver du média d'une story (aucun n'existait auparavant, A11Y-04).
    private func mediaLabel(for story: SocialStory) -> String {
        if let text = story.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return String(localized: "Story de \(story.author.displayName) : \(text)")
        }
        return String(localized: "Story de \(story.author.displayName)")
    }

    private func forward() {
        if index < stories.count - 1 { index += 1 } else { dismiss() }
    }
    private func back() {
        if index > 0 { index -= 1 }
    }
}

/// Relevé réseau joint à une story (`metadata.signal`, sinon à plat), en
/// pastilles : « SFR · 5G », puis la qualité du signal.
struct StorySignalSummary: Equatable {
    let operatorName: String?
    let technology: String?
    let rsrp: Double?

    init?(metadata: [String: JSONValue]?) {
        guard let metadata else { return nil }
        var fields = metadata
        if case .object(let nested)? = metadata["signal"] { fields = nested }
        else if case .object(let nested)? = metadata["radioSnapshot"] { fields = nested }
        func string(_ key: String) -> String? {
            guard case .string(let value)? = fields[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        operatorName = string("operator")
        technology = (string("technology") ?? string("networkType"))?.uppercased()
        if case .number(let value)? = fields["rsrp"] { rsrp = value } else { rsrp = nil }
        if operatorName == nil, technology == nil, rsrp == nil { return nil }
    }

    var pills: [String] {
        var result: [String] = []
        let network = [operatorName, technology].compactMap { $0 }.joined(separator: " · ")
        if !network.isEmpty { result.append(network) }
        if let quality { result.append(quality) }
        return result
    }

    private var quality: String? {
        switch SQQualityScale.Signal(dbm: rsrp, technology: technology) {
        case .excellent: return String(localized: "Signal excellent")
        case .good: return String(localized: "Signal bon")
        case .fair: return String(localized: "Signal moyen")
        case .weak: return String(localized: "Signal faible")
        case .poor: return String(localized: "Signal très faible")
        case .noService: return String(localized: "Sans réseau")
        case .unknown: return nil
        }
    }
}

/// Feuille « Vu par N » (façon Instagram) : liste des utilisateurs + instant de vue.
private struct StoryViewersSheet: View {
    let viewers: [StoryViewerEntry]
    let isLoading: Bool
    var errorMessage: String?
    var retry: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    SQSpinner().tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, viewers.isEmpty {
                    ErrorStateView(title: "Vues indisponibles", message: errorMessage, retry: retry)
                        .padding(SQSpace.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewers.isEmpty {
                    EmptyStateView(title: "Personne pour l'instant", message: "Les vues apparaîtront ici.", systemImage: "eye")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewers) { entry in
                            HStack(spacing: SQSpace.md) {
                                SQAvatar(url: entry.user.avatarUrl, name: entry.user.displayName, size: 36)
                                Text(entry.user.displayName).foregroundStyle(SQColor.label)
                                Spacer()
                                if let viewedAt = entry.viewedAt {
                                    Text(viewedAt, format: .sqRelative)
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .signalQuestBackground()
            // « Vu par 0 » serait faux pendant le chargement ou après un échec.
            .navigationTitle(isLoading || (errorMessage != nil && viewers.isEmpty)
                ? Text("Vu par…") : Text("Vu par \(viewers.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

enum StoryReplyDeliveryError: Error {
    case unavailable
    case conversationUnavailable
}

enum StoryReplyChannelPolicy {
    static func accepts(_ conversation: MessageConversation, authorID: String, currentUserID: String) -> Bool {
        guard authorID != currentUserID,
              !conversation.isGroup,
              conversation.e2eeEnabled == false else { return false }
        let participants = Set(conversation.participants.map(\.userId))
        return participants == Set([authorID, currentUserID])
    }
}

/// Garde le même identifiant lors d'un réessai si le serveur a pu accepter le
/// message avant qu'une réponse réseau soit perdue. « Envoyé » exige un ACK.
@MainActor
final class StoryReplySubmission: ObservableObject {
    @Published var draft = ""
    @Published private(set) var isSending = false
    @Published private(set) var sentStoryID: String?
    @Published private(set) var failedStoryID: String?

    private var pending: (storyID: String, text: String, requestID: String)?

    func submit(
        storyID: String,
        text: String,
        send: @MainActor (String) async throws -> Void
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return false }
        let requestID: String
        if let pending, pending.storyID == storyID, pending.text == trimmed {
            requestID = pending.requestID
        } else {
            requestID = "ios-story-reply-\(UUID().uuidString.lowercased())"
        }
        pending = (storyID, trimmed, requestID)
        isSending = true
        sentStoryID = nil
        failedStoryID = nil
        defer { isSending = false }

        do {
            try await send(requestID)
            pending = nil
            sentStoryID = storyID
            return true
        } catch {
            failedStoryID = storyID
            return false
        }
    }

    func clearSuccess(storyID: String) {
        if sentStoryID == storyID { sentStoryID = nil }
    }

    func clearFeedback() {
        sentStoryID = nil
        failedStoryID = nil
    }
}
