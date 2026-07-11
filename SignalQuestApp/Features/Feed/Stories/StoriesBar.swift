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

    /// « Ta story » : cercle 60 SurfaceMuted, initiale (ou +) en encre
    /// secondaire, badge « + » brique 21 pt cerclé de la couleur du fond.
    private var composeBubble: some View {
        Button {
            Haptics.light()
            onCompose()
        } label: {
            VStack(spacing: SQSpace.sm - 1) {
                ZStack {
                    Circle().fill(SQColor.surfaceMuted)
                    if let initial = currentUser?.displayName.first {
                        Text(String(initial).uppercased())
                            .font(SQFont.display(23, .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .frame(width: 60, height: 60)
                .padding(3)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(SQColor.brandRed)
                        .frame(width: 21, height: 21)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(SQColor.onAccent)
                        )
                        .overlay(Circle().stroke(SQColor.bg, lineWidth: 2))
                }
                Text("Ta story")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.label)
                    .frame(width: 70)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ajouter à ta story")
    }
}
