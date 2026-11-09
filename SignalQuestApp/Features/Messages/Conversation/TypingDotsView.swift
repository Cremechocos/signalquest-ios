import SwiftUI

/// Trois points qui respirent tour à tour (indicateur « en train d'écrire »).
/// Avec Reduce Motion, les points restent statiques.
struct TypingDotsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(time: nil)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                dots(time: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    func dots(time: TimeInterval?) -> some View {
        HStack(spacing: SQSpace.xs + 1) {
            ForEach(0..<3, id: \.self) { index in
                let phase: Double = time.map { sin(($0 * 2 * .pi / 1.2) - Double(index) * 0.85) } ?? 0
                Circle()
                    .fill(SQColor.labelSecondary)
                    .frame(width: 7, height: 7)
                    // Respiration à la iMessage : chaque point grossit et s'éclaire à son tour.
                    .scaleEffect(0.75 + 0.25 * max(0, phase))
                    .offset(y: CGFloat(max(0, phase)) * -1.5)
                    .opacity(0.35 + 0.65 * max(0, phase))
            }
        }
    }
}
