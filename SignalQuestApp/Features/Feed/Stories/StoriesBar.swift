import SwiftUI

struct StoriesBar: View {
    let stories: [SocialStory]
    let currentUser: AuthUser?
    var onCompose: () -> Void
    var onSelect: (SocialStory) -> Void
    /// Masquer les stories d'un membre, sans le bloquer (appui long sur sa bulle).
    var onHide: ((SocialStory) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // LazyHStack : ne matérialise que les bulles visibles du rail (les stories
            // hors écran ne sont pas construites) — cf. PERF-RING-01.
            // Alignés en haut : un prénom sur deux lignes ne décale pas les cercles.
            LazyHStack(alignment: .top, spacing: SQSpace.md2) {
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
                    .accessibilityValue(story.viewedByMe == true ? "Déjà vue" : "Pas encore vue")
                    .contextMenu {
                        if story.isMine != true, let onHide {
                            Button {
                                onHide(story)
                            } label: {
                                Label("Masquer les stories de \(story.author.displayName)", systemImage: "eye.slash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, SQSpace.xs2)
        }
        // Le rail garde des cercles et des prénoms lisibles : au-delà de cette
        // taille, les prénoms ne tenaient plus sous leur cercle (UI-15).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// « Ta story » : avatar 60 sur la puce, initiale (ou +) en encre de puce,
    /// badge « + » carmin 21 pt cerclé de la couleur du fond.
    private var composeBubble: some View {
        Button {
            Haptics.light()
            onCompose()
        } label: {
            VStack(spacing: SQSpace.sm - 1) {
                ZStack {
                    SQAvatarShape().fill(SQColor.chip)
                    if let initial = currentUser?.displayName.first {
                        Text(String(initial).uppercased())
                            .font(SQFont.display(22, .bold, relativeTo: .title2))
                            .foregroundStyle(SQColor.chipInk)
                            .accessibilityHidden(true)
                            .accessibilityIdentifier("feed.avatar.initial")
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(SQColor.chipInk)
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
                    .font(.footnote)
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 72)
                    .accessibilityIdentifier("feed.story.name")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ajouter à ta story")
    }
}

struct StoryBubble: View {
    let story: SocialStory
    var viewed: Bool? = nil

    var body: some View {
        let isViewed = viewed ?? (story.viewedByMe == true)
        VStack(spacing: SQSpace.sm - 1) {
            // Anneau décollé de 3 pt : carmin 3 pt (non vue) / encre 25 % 1,5 pt (vue).
            SQAvatar(url: story.author.avatarUrl, name: story.author.displayName, size: 60)
                .padding(3)
                .overlay {
                    if isViewed {
                        SQAvatarShape().strokeBorder(SQColor.label.opacity(0.25), lineWidth: 1.5)
                    } else {
                        SQStoryRing(lineWidth: 3)
                    }
                }
            // Largeur du cercle : en très grand texte, les prénoms débordaient et
            // se chevauchaient (UI-15). Deux lignes centrées et une réduction
            // modérée plutôt qu'une troncature ; VoiceOver lit le nom entier.
            Text(story.author.displayName)
                .font(.footnote)
                .foregroundStyle(SQColor.label)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 72)
                .accessibilityIdentifier("feed.story.name")
        }
        .accessibilityElement(children: .combine)
    }
}
