import SwiftUI

struct StoriesBar: View {
    let stories: [SocialStory]
    let currentUser: AuthUser?
    var onCompose: () -> Void
    var onSelect: (SocialStory) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // LazyHStack : ne matérialise que les bulles visibles du rail (les stories
            // hors écran ne sont pas construites) — cf. PERF-RING-01.
            LazyHStack(spacing: SQSpace.md + 2) {
                composeBubble
                ForEach(stories) { story in
                    Button {
                        Haptics.light()
                        onSelect(story)
                    } label: {
                        StoryBubble(story: story)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Story de \(story.author.displayName)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, SQSpace.xs + 2)
        }
    }

    private var composeBubble: some View {
        Button {
            Haptics.light()
            onCompose()
        } label: {
            VStack(spacing: SQSpace.sm) {
                SQAvatar(url: currentUser?.avatarUrl, name: currentUser?.displayName ?? "+", size: 62)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(SQColor.brandRed)
                            .frame(width: 22, height: 22)
                            .overlay(Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(.white))
                            .overlay(Circle().stroke(SQColor.bg, lineWidth: 2))
                    }
                Text("Ta story")
                    .font(.caption)
                    .foregroundStyle(SQColor.label)
                    .frame(width: 74)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ajouter à ta story")
    }
}
