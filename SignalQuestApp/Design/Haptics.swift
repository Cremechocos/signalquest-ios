import UIKit

/// Retours haptiques : générateurs **réutilisés et pré-préparés** (recommandation
/// Apple) plutôt que recréés à chaque tap. `prepare()` après usage garde le Taptic
/// Engine chaud → latence haptique plus faible et moins d'allocations (PERF-HAPTIC-01).
@MainActor
enum Haptics {
    private static var impactGenerators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private static let notification = UINotificationFeedbackGenerator()
    private static let selectionGenerator = UISelectionFeedbackGenerator()

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator: UIImpactFeedbackGenerator
        if let existing = impactGenerators[style] {
            generator = existing
        } else {
            generator = UIImpactFeedbackGenerator(style: style)
            impactGenerators[style] = generator
        }
        generator.impactOccurred()
        generator.prepare()
    }

    static func light()  { impact(.light) }
    static func medium() { impact(.medium) }

    static func success()  { notification.notificationOccurred(.success); notification.prepare() }
    static func warning()  { notification.notificationOccurred(.warning); notification.prepare() }
    static func error()    { notification.notificationOccurred(.error); notification.prepare() }
    static func selection() { selectionGenerator.selectionChanged(); selectionGenerator.prepare() }
}
