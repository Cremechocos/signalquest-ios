import SwiftUI

struct StoryViewer: View {
    let stories: [SocialStory]
    @State private var index: Int = 0
    @State private var progress: Double = 0
    @Environment(\.dismiss) private var dismiss

    var onMarkViewed: (SocialStory) -> Void = { _ in }
    /// Tap sur l'auteur dans le header — le parent ferme le viewer et pousse le profil.
    var onAuthorTap: (SocialStory) -> Void = { _ in }
    /// Réponse / réaction à une story = message privé à l'auteur (façon Instagram).
    /// Le parent résout/crée la conversation DM et envoie le texte/emoji.
    var onSendReply: (SocialStory, String) -> Void = { _, _ in }

    @State private var replyText = ""
    @FocusState private var replyFocused: Bool
    @State private var sentConfirmation = false

    private let duration: Double = 6

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
                progressBars
                header
                Spacer()
                replyAffordance
            }
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
        .task(id: index) {
            guard !stories.isEmpty else { return }
            if let story = currentStory { onMarkViewed(story) }
            progress = 0
            var elapsed: Double = 0
            while !Task.isCancelled {
                // En pause pendant la saisie d'une réponse (le clavier est ouvert).
                if !replyFocused {
                    elapsed += 0.05
                    progress = min(1, elapsed / duration)
                    if elapsed >= duration {
                        await MainActor.run { forward() }
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    @ViewBuilder
    private func content(for story: SocialStory) -> some View {
        if let url = story.mediaUrl {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().ignoresSafeArea()
                } else {
                    Color.black
                }
            }
        } else {
            ZStack {
                SQGradient.signal.ignoresSafeArea()
                VStack(spacing: SQSpace.lg) {
                    SQAvatar(url: story.author.avatarUrl, name: story.author.displayName, size: 88)
                    Text(story.text ?? "Story")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SQSpace.xxl + 4)
                }
            }
        }
    }

    private var progressBars: some View {
        HStack(spacing: SQSpace.xs) {
            ForEach(stories.indices, id: \.self) { i in
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(0.30))
                        .overlay(alignment: .leading) {
                            Capsule().fill(SQGradient.signal)
                                .frame(width: proxy.size.width * fillRatio(for: i))
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
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(.white.opacity(0.4), lineWidth: 1) }
                if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendReply) {
                        Image(systemName: "paperplane.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(SQColor.brandRed, in: Circle())
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.bottom, SQSpace.lg)
        .sqAnimation(SQMotion.snappy, value: replyText.isEmpty)
        .sqAnimation(SQMotion.snappy, value: sentConfirmation)
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

    private func fillRatio(for i: Int) -> Double {
        if i < index { return 1 }
        if i == index { return progress }
        return 0
    }

    private func forward() {
        if index < stories.count - 1 { index += 1 } else { dismiss() }
    }
    private func back() {
        if index > 0 { index -= 1 }
    }
}
