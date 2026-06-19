import SwiftUI

struct ReactionPicker: View {
    let emojis: [String]
    var onPick: (String) -> Void

    init(emojis: [String] = ["❤️", "🔥", "👏", "🚀", "⚡", "📡"], onPick: @escaping (String) -> Void) {
        self.emojis = emojis
        self.onPick = onPick
    }

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: SQSpace.sm + 2) {
            ForEach(Array(emojis.enumerated()), id: \.element) { index, emoji in
                Button {
                    Haptics.light()
                    onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .padding(SQSpace.sm + 2)
                        .background(SQColor.surfaceMuted, in: Circle())
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel("Réagir avec \(emoji)")
                // Entrée en cascade : chaque emoji « pop » avec un léger décalage.
                .scaleEffect(appeared ? 1 : 0.1)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : SQMotion.bouncy.delay(Double(index) * 0.04), value: appeared)
            }
        }
        .padding(SQSpace.sm)
        .background(SQColor.surface, in: Capsule())
        .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1.5) }
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
        .onAppear { appeared = true }
    }
}
