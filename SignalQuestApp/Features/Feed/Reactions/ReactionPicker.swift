import SwiftUI

struct ReactionPicker: View {
    let emojis: [String]
    var onPick: (String) -> Void

    init(emojis: [String] = ["❤️", "🔥", "👏", "🚀", "⚡", "📡"], onPick: @escaping (String) -> Void) {
        self.emojis = emojis
        self.onPick = onPick
    }

    var body: some View {
        HStack(spacing: SQSpace.sm + 2) {
            ForEach(emojis, id: \.self) { emoji in
                Button {
                    Haptics.light()
                    onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .padding(SQSpace.sm + 2)
                        .background(SQColor.surfaceMuted, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Réagir avec \(emoji)")
            }
        }
        .padding(SQSpace.sm)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }
}
