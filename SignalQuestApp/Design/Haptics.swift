import UIKit

enum Haptics {
    @MainActor static func light()    { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func medium()   { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    @MainActor static func heavy()    { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    @MainActor static func rigid()    { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    @MainActor static func soft()     { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    @MainActor static func success()  { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func warning()  { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    @MainActor static func error()    { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    @MainActor static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}
