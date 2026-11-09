import SwiftUI

/// Action du menu d'un message (appui long). Une seule liste nourrit le panneau
/// façon iMessage et les actions VoiceOver de la bulle.
struct MessageMenuAction: Identifiable {
    let id: String
    let title: Text
    let systemImage: String
    var destructive = false
    /// Première action d'un nouveau groupe : un intervalle plus marqué la sépare des précédentes.
    var startsSection = false
    let perform: () -> Void
}

/// Cadres des bulles visibles, en coordonnées globales. Pas observé : on le lit
/// seulement à l'appui long, sans redessiner la conversation à chaque défilement.
@MainActor
final class BubbleFrameRegistry {
    var frames: [String: CGRect] = [:]
}

/// Bulle choisie par un appui long, avec ce qu'il faut pour la redessiner soulevée.
struct FocusedMessage: Identifiable {
    let message: MessageItem
    let mine: Bool
    let frame: CGRect
    let isGroupStart: Bool
    let showsTime: Bool
    let photoOnly: Bool
    var id: String { message.id }
}

/// Appui long sur une bulle : léger enfoncement pendant l'appui, puis ouverture.
/// L'état d'appui vit ici pour ne pas redessiner toute la conversation.
struct MessageLongPress: ViewModifier {
    let isEnabled: Bool
    let onOpen: () -> Void
    @State private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .scaleEffect(pressing && !reduceMotion ? 0.96 : 1)
                .animation(SQMotion.resolve(SQMotion.snappy, reduceMotion), value: pressing)
                .onLongPressGesture(minimumDuration: 0.32, maximumDistance: 12) {
                    pressing = false
                    onOpen()
                } onPressingChanged: { isPressing in
                    pressing = isPressing
                }
        } else {
            content
        }
    }
}

/// Présentation façon iMessage : fond flouté, bulle soulevée à sa place, barre
/// de réactions au-dessus et panneau d'actions en dessous. Tout reste à l'écran :
/// la bulle glisse (et rétrécit si elle est trop haute) pour laisser la place.
struct MessageFocusOverlay<Bubble: View>: View {
    let focus: FocusedMessage
    let bubble: Bubble
    /// Emojis de la barre ; vide quand les réactions ne sont pas permises.
    let quickReactions: [String]
    let myReactions: Set<String>
    let actions: [MessageMenuAction]
    /// Hauteur des réactions déjà posées qui dépassent au-dessus de la bulle.
    var chipsOverhang: CGFloat = 0
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
    let onDismissed: () -> Void

    @State private var shown = false
    @State private var closing = false
    @State private var menuHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let margin: CGFloat = 12
    private let gap: CGFloat = 10
    private let barHeight: CGFloat = 52
    private let menuWidth: CGFloat = 250

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let layout = layout(in: proxy.size, origin: origin)
            ZStack(alignment: .topLeading) {
                backdrop

                bubble
                    .frame(width: focus.frame.width, height: focus.frame.height)
                    .scaleEffect(shown ? layout.scale : 1, anchor: focus.mine ? .topTrailing : .topLeading)
                    .shadow(color: .black.opacity(shown ? 0.14 : 0), radius: 18, y: 8)
                    .padding(.leading, layout.bubbleX)
                    .padding(.top, shown ? layout.bubbleY : layout.originY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if !quickReactions.isEmpty {
                    reactionBar
                        .scaleEffect(shown || reduceMotion ? 1 : 0.4, anchor: focus.mine ? .bottomTrailing : .bottomLeading)
                        .opacity(shown ? 1 : 0)
                        .frame(width: proxy.size.width - 2 * margin, alignment: focus.mine ? .trailing : .leading)
                        .padding(.leading, margin)
                        .padding(.top, (shown ? layout.bubbleY : layout.originY) - layout.barOffset)
                }

                actionPanel(maxHeight: layout.menuMaxHeight)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.5, anchor: focus.mine ? .topTrailing : .topLeading)
                    .opacity(shown ? 1 : 0)
                    .frame(width: proxy.size.width - 2 * margin, alignment: focus.mine ? .trailing : .leading)
                    .padding(.leading, margin)
                    .padding(.top, (shown ? layout.bubbleY : layout.originY) + layout.menuOffset)
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
        .onAppear {
            Haptics.medium()
            withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion) ?? SQMotion.fast) { shown = true }
        }
    }

    // MARK: Fond

    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            SQColor.scrim.opacity(0.18)
        }
        .opacity(shown ? 1 : 0)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .accessibilityElement()
        .accessibilityLabel(Text("Fermer"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { dismiss() }
    }

    // MARK: Réactions

    private var reactionBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(quickReactions.enumerated()), id: \.element) { index, emoji in
                let picked = myReactions.contains(emoji)
                Button {
                    Haptics.light()
                    dismiss { onReact(emoji) }
                } label: {
                    // Chaque emoji joue son geste juste après son entrée.
                    AnimatedReactionEmoji(emoji: emoji, size: 26, autoplayDelay: 0.18 + Double(index) * 0.06)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(picked ? SQColor.brandRed.opacity(0.18) : .clear))
                        .contentShape(Circle())
                }
                .buttonStyle(ReactionPressStyle())
                .scaleEffect(shown || reduceMotion ? 1 : 0.2)
                .animation(
                    SQMotion.resolve(SQMotion.bouncy, reduceMotion)?.delay(shown ? Double(index) * 0.03 : 0),
                    value: shown
                )
                .accessibilityLabel(Text("Réagir avec \(emoji)"))
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
            Button {
                dismiss { onMoreReactions() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(SQColor.label.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(ReactionPressStyle())
            .scaleEffect(shown || reduceMotion ? 1 : 0.2)
            .animation(
                SQMotion.resolve(SQMotion.bouncy, reduceMotion)?.delay(shown ? Double(quickReactions.count) * 0.03 : 0),
                value: shown
            )
            .accessibilityLabel(Text("Plus d’emojis"))
        }
        .padding(.horizontal, 5)
        .frame(height: barHeight)
        .background(Capsule(style: .continuous).fill(SQColor.surface))
        .sqShadowCard()
    }

    // MARK: Actions

    private func actionPanel(maxHeight: CGFloat) -> some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 {
                    if action.startsSection {
                        SQColor.label.opacity(0.06).frame(height: 7)
                    } else {
                        SQColor.label.opacity(0.1).frame(height: 1 / 3)
                    }
                }
                Button {
                    dismiss { action.perform() }
                } label: {
                    HStack(spacing: SQSpace.sm) {
                        action.title
                            .font(SQType.body)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: SQSpace.sm)
                        Image(systemName: action.systemImage)
                            .font(.system(size: 17))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(action.destructive ? SQColor.dangerInk : SQColor.label)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }

        return Group {
            if menuHeight > maxHeight {
                ScrollView { rows }.frame(height: maxHeight)
            } else {
                rows
            }
        }
        .frame(width: menuWidth)
        .background(SQColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sqShadowCard()
    }

    // MARK: Placement

    private struct Layout {
        var scale: CGFloat
        var bubbleX: CGFloat
        var originY: CGFloat
        var bubbleY: CGFloat
        /// Écarts à la bulle : la barre et le panneau voyagent avec elle.
        var barOffset: CGFloat
        var menuOffset: CGFloat
        var menuMaxHeight: CGFloat
    }

    private func layout(in size: CGSize, origin: CGPoint) -> Layout {
        let frame = focus.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        let hasBar = !quickReactions.isEmpty
        let barSpace = hasBar ? barHeight + gap + chipsOverhang : chipsOverhang
        // Le panneau garde au moins la moitié de l'écran ; il défile s'il est plus long.
        let menuMaxHeight = max(140, min(size.height * 0.5, size.height - 2 * margin - barSpace - gap - 80))
        let menuSpace = (menuHeight > 0 ? min(menuHeight, menuMaxHeight) : min(CGFloat(actions.count) * 45, menuMaxHeight)) + gap
        let roomForBubble = size.height - 2 * margin - barSpace - menuSpace
        let scale = min(1, max(0.35, roomForBubble / max(frame.height, 1)))
        let bubbleHeight = frame.height * scale
        let minY = margin + barSpace
        let maxY = size.height - margin - menuSpace - bubbleHeight
        let bubbleY = min(max(frame.minY, minY), max(minY, maxY))
        return Layout(
            scale: scale,
            bubbleX: frame.minX,
            originY: frame.minY,
            bubbleY: bubbleY,
            barOffset: barSpace,
            menuOffset: bubbleHeight + gap,
            menuMaxHeight: menuMaxHeight
        )
    }

    // MARK: Fermeture

    /// Referme puis lance l'action : la bulle redescend à sa place pendant que la feuille
    /// ou l'alerte éventuelle s'ouvre.
    private func dismiss(then action: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        action?()
        withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion) ?? SQMotion.fast) { shown = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 170_000_000 : 280_000_000)
            onDismissed()
        }
    }
}

/// Emoji qui grossit sous le doigt, comme les tapbacks.
private struct ReactionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.25 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Rangée du panneau : fond grisé pendant l'appui.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(SQColor.label.opacity(configuration.isPressed ? 0.08 : 0))
    }
}
