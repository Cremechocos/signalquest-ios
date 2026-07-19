import SwiftUI

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
    var onSendReply: (SocialStory, String) -> Void = { _, _ in }
    /// Suppression d'une story (auteur) — le parent supprime côté serveur + rafraîchit.
    var onDelete: (SocialStory) -> Void = { _ in }
    /// Fournit la liste « Vu par » d'une story (auteur uniquement).
    var viewersProvider: (SocialStory) async -> [StoryViewerEntry] = { _ in [] }

    @State private var replyText = ""
    @FocusState private var replyFocused: Bool
    @State private var sentConfirmation = false
    @State private var showViewers = false
    @State private var viewers: [StoryViewerEntry] = []
    @State private var loadingViewers = false
    @State private var showDeleteConfirm = false

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
            // Bottom scrim for caption + reply affordance legibility.
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
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
                if currentStory?.isMine == true {
                    ownerFooter
                } else {
                    replyAffordance
                }
            }
        }
        .sheet(isPresented: $showViewers) {
            StoryViewersSheet(viewers: viewers, isLoading: loadingViewers)
        }
        .confirmationDialog("Supprimer cette story ?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let story = currentStory { onDelete(story); dismiss() }
            }
            Button("Annuler", role: .cancel) {}
        }
        .onTapGesture(coordinateSpace: .local) { location in
            let half = UIScreen.main.bounds.width / 2
            if location.x < half { back() } else { forward() }
        }
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
        .onChange(of: index) { _ in startStory() }
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
            RemoteImage(url: url, maxDimension: 1400, contentMode: .fill) {
                Color.black
            }
            .ignoresSafeArea()
            // A11Y-04 : le média n'avait aucun label VoiceOver.
            .accessibilityElement()
            .accessibilityLabel(mediaLabel(for: story))
        } else {
            // Story texte : canevas crème uni (nuit en sombre), typo display encre.
            ZStack {
                SQColor.bg.ignoresSafeArea()
                VStack(spacing: SQSpace.lg) {
                    SQAvatar(url: story.author.avatarUrl, name: story.author.displayName, size: 88)
                    Text(story.text ?? "Story")
                        .font(SQFont.display(28, .bold))
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SQSpace.xxl + 4)
                }
            }
        }
    }

    private func progressBars(now: Date) -> some View {
        HStack(spacing: SQSpace.xs) {
            ForEach(stories.indices, id: \.self) { i in
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(0.30))
                        .overlay(alignment: .leading) {
                            // Jauge au langage Crème : remplissage brique uni.
                            Capsule().fill(SQColor.brandRed)
                                .frame(width: proxy.size.width * fillRatio(for: i, now: now))
                        }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, SQSpace.md + 2)
        .padding(.top, SQSpace.sm + 2)
    }

    private var header: some View {
        HStack(spacing: SQSpace.sm + 2) {
            if let story = currentStory {
                Button {
                    Haptics.light()
                    dismiss()
                    onAuthorTap(story)
                } label: {
                    HStack(spacing: SQSpace.sm + 2) {
                        SQAvatar(url: story.author.avatarUrl, name: story.author.displayName, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(story.author.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            if let date = story.createdAt {
                                Text(date, format: .relative(presentation: .named))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.78))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voir le profil de \(story.author.displayName)")
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(SQSpace.sm + 2)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Fermer")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.xs + 2)
    }

    private let quickReactions = ["❤️", "🔥", "👏", "😮", "😢", "🙌"]

    private var replyAffordance: some View {
        VStack(spacing: SQSpace.sm + 2) {
            if sentConfirmation {
                Label("Envoyé", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale))
            }
            // Réactions rapides — envoyées comme message privé à l'auteur.
            HStack(spacing: SQSpace.md) {
                ForEach(quickReactions, id: \.self) { emoji in
                    Button {
                        Haptics.light()
                        if let story = currentStory { onSendReply(story, emoji) }
                        confirmSent()
                    } label: {
                        Text(emoji).font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Réagir avec \(emoji)")
                }
            }
            // Champ de réponse texte.
            HStack(spacing: SQSpace.sm) {
                TextField("", text: $replyText, prompt: Text("Répondre…").foregroundColor(.white.opacity(0.7)))
                    .focused($replyFocused)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .submitLabel(.send)
                    .onSubmit(sendReply)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm + 2)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
                if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendReply) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SQColor.onAccent)
                            .frame(width: 44, height: 44)
                            .background(SQColor.brandRed, in: Circle())
                    }
                    .accessibilityLabel("Envoyer")
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.bottom, SQSpace.lg)
        .sqAnimation(SQMotion.snappy, value: replyText.isEmpty)
        .sqAnimation(SQMotion.snappy, value: sentConfirmation)
    }

    /// Pied affiché sur ses PROPRES stories : « Vu par… » + suppression.
    private var ownerFooter: some View {
        HStack(spacing: SQSpace.md) {
            Button {
                Task { await loadViewers() }
                showViewers = true
            } label: {
                Label("Vu par…", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel("Voir qui a vu la story")
            Spacer()
            Button {
                Haptics.medium()
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Supprimer la story")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.bottom, SQSpace.lg)
    }

    private func loadViewers() async {
        guard let story = currentStory else { return }
        loadingViewers = true
        viewers = await viewersProvider(story)
        loadingViewers = false
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let story = currentStory else { return }
        onSendReply(story, text)
        replyText = ""
        replyFocused = false
        confirmSent()
    }

    private func confirmSent() {
        sentConfirmation = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { sentConfirmation = false }
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
        replyFocused || showViewers || showDeleteConfirm || voiceOverOn
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
            return "Story de \(story.author.displayName) : \(text)"
        }
        return "Story de \(story.author.displayName)"
    }

    private func forward() {
        if index < stories.count - 1 { index += 1 } else { dismiss() }
    }
    private func back() {
        if index > 0 { index -= 1 }
    }
}

/// Feuille « Vu par N » (façon Instagram) : liste des utilisateurs + instant de vue.
private struct StoryViewersSheet: View {
    let viewers: [StoryViewerEntry]
    let isLoading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().tint(SQColor.brandRed)
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
                                    Text(viewedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelTertiary)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .signalQuestBackground()
            .navigationTitle("Vu par \(viewers.count)")
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
