import SwiftUI

/// « À qui est cette box » — une rangée, pas un mur.
///
/// Même parti que sur le web et Android : le sélecteur d'emoji est à GAUCHE du
/// champ, parce qu'il se lit avec le libellé et non après — c'est lui qui
/// distingue une box d'une autre dans la liste. Les suggestions ne s'étalent
/// pas sur quatre lignes : elles défilent horizontalement sur une seule, ce qui
/// garde la feuille courte pour un réglage facultatif.
struct SentinelleOwnerField: View {
    @Binding var label: String
    @Binding var emoji: String

    @State private var showPalette = false

    /// Filtrées à la frappe : proposer huit étiquettes dont aucune ne
    /// correspond n'aide plus, ça encombre. Propriété calculée et non `let`
    /// dans le `body` : à l'intérieur d'un ViewBuilder, la résolution de
    /// `ForEach` retombait sur la surcharge `Range<Int>`.
    private var suggestions: [SentinelleOwnerLabel.Suggestion] {
        SentinelleOwnerLabel.filter(label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Button {
                    showPalette.toggle()
                } label: {
                    // Sans emoji choisi, un contour discret plutôt qu'un
                    // symbole insistant : le champ est facultatif.
                    Text(emoji.isEmpty ? "☺" : emoji)
                        .font(.system(size: emoji.isEmpty ? 15 : 21))
                        .foregroundStyle(emoji.isEmpty ? SQColor.labelSecondary : SQColor.label)
                        .frame(width: 52, height: 44)
                        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: SQRadius.sm)
                                .stroke(SQColor.separator, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji.isEmpty ? "Choisir un emoji" : "Emoji : \(emoji). Changer")

                TextField("À qui est cette box ? (facultatif)", text: $label)
                    .textFieldStyle(.plain)
                    .font(SQFont.body(15))
                    .padding(.horizontal, SQSpace.sm)
                    .frame(height: 44)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: SQRadius.sm)
                            .stroke(SQColor.separator, lineWidth: 1)
                    )
                    .onChange(of: label) { newValue in
                        if newValue.count > SentinelleOwnerLabel.labelMax {
                            label = String(newValue.prefix(SentinelleOwnerLabel.labelMax))
                        }
                    }
            }

            if showPalette {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SQSpace.xxs) {
                        if !emoji.isEmpty {
                            emojiCell("✕") { emoji = ""; showPalette = false }
                        }
                        ForEach(SentinelleOwnerLabel.emojiPalette, id: \.self) { value in
                            emojiCell(value) { emoji = value; showPalette = false }
                        }
                    }
                }
            }

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SQSpace.xs) {
                        // `id:` explicite : sans lui le compilateur retombait sur la
                        // surcharge `Range<Int>` de ForEach et refusait le tableau.
                        ForEach(suggestions, id: \.value) { suggestion in
                            Button {
                                if suggestion.value == label {
                                    label = ""
                                } else {
                                    label = suggestion.value
                                    // L'emoji choisi à la main n'est pas
                                    // écrasé : on ne défait pas un geste
                                    // explicite.
                                    if emoji.isEmpty { emoji = suggestion.emoji }
                                }
                            } label: {
                                Text("\(suggestion.emoji)  \(suggestion.value)")
                                    .font(SQFont.body(13))
                                    .foregroundStyle(
                                        suggestion.value == label ? SQColor.accentInk : SQColor.label
                                    )
                                    .padding(.horizontal, SQSpace.sm)
                                    .padding(.vertical, SQSpace.xs)
                                    .background(
                                        suggestion.value == label
                                            ? SQColor.accentSoft
                                            : SQColor.surface,
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().stroke(SQColor.separator, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func emojiCell(_ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(value)
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: SQRadius.sm)
                        .stroke(SQColor.separator, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
