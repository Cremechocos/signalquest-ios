import SwiftUI

struct StoriesBar: View {
    let stories: [SocialStory]
    let currentUser: AuthUser?
    var onCompose: () -> Void
    var onSelect: (SocialStory) -> Void
    /// Masquer les stories d'un membre, sans le bloquer (appui long sur sa bulle).
    var onHide: ((SocialStory) -> Void)? = nil
    /// Stories ouvertes depuis le chargement du rail (anneau gris sans recharger).
    var viewedIds: Set<String> = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // LazyHStack : ne matérialise que les bulles visibles du rail (les stories
            // hors écran ne sont pas construites) — cf. PERF-RING-01.
            // Alignés en haut : un prénom sur deux lignes ne décale pas les cercles.
            LazyHStack(alignment: .top, spacing: SQSpace.sm) {
                composeBubble
                ForEach(stories) { story in
                    Button {
                        Haptics.light()
                        onSelect(story)
                    } label: {
                        StoryBubble(story: story, viewed: isViewed(story))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Story de \(story.author.displayName)")
                    .accessibilityValue(isViewed(story) ? "Déjà vue" : "Pas encore vue")
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

    private func isViewed(_ story: SocialStory) -> Bool {
        story.viewedByMe == true || viewedIds.contains(story.id)
    }

    /// « Ta story » : anneau pointillé et « + » encre, comme une place libre
    /// dans le rail plutôt qu'une story de plus.
    private var composeBubble: some View {
        Button {
            Haptics.light()
            onCompose()
        } label: {
            VStack(spacing: SQSpace.xs2) {
                ZStack {
                    // Ton avatar (photo ou initiale) : la bulle te représente, comme
                    // les autres bulles représentent leur auteur.
                    if let currentUser, !currentUser.displayName.isEmpty {
                        SQAvatar(url: currentUser.avatarUrl, name: currentUser.displayName, size: StoryBubble.avatarSize)
                    } else {
                        SQAvatarShape().fill(SQColor.chip)
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SQColor.chipInk)
                    }
                }
                .frame(width: StoryBubble.avatarSize, height: StoryBubble.avatarSize)
                .padding(StoryBubble.ringGap)
                .overlay {
                    SQAvatarShape().strokeBorder(SQColor.dots, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(SQColor.label)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(SQColor.onInk)
                        )
                        .overlay(Circle().stroke(SQColor.bg, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
                Text("Ta story")
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 68)
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

    /// Avatar 52 pt dans un anneau décollé de 4 pt : 60 pt de bulle.
    static let avatarSize: CGFloat = 52
    static let ringGap: CGFloat = 4

    var body: some View {
        let isViewed = viewed ?? (story.viewedByMe == true)
        VStack(spacing: SQSpace.xs2) {
            // Carmin 2,5 pt tant qu'elle n'est pas vue, filet gris ensuite.
            SQAvatar(url: story.author.avatarUrl, name: story.author.displayName, size: Self.avatarSize)
                .padding(Self.ringGap)
                .overlay {
                    if isViewed {
                        SQAvatarShape().strokeBorder(SQColor.separator, lineWidth: 2)
                    } else {
                        SQStoryRing(lineWidth: 2.5)
                    }
                }
            // Largeur du cercle : en très grand texte, les prénoms débordaient et
            // se chevauchaient (UI-15). Deux lignes centrées et une réduction
            // modérée plutôt qu'une troncature ; VoiceOver lit le nom entier.
            Text(story.author.displayName)
                .font(SQType.caption(.semibold))
                .foregroundStyle(isViewed ? SQColor.labelSecondary : SQColor.label)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 68)
                .accessibilityIdentifier("feed.story.name")
        }
        .accessibilityElement(children: .combine)
    }
}
