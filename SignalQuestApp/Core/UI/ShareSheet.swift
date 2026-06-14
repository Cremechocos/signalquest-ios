import SwiftUI
import UIKit
import LinkPresentation
import UniformTypeIdentifiers

/// Présente un `UIActivityViewController` avec des éléments arbitraires
/// (image + texte). Permet de partager une image ET son texte d'accompagnement
/// — la plupart des réseaux attachent les deux.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Source d'élément de partage portant une image ET un texte, avec un aperçu
/// riche (vignette + titre) pour la feuille de partage iOS. Fournir ce type
/// comme item unique attache l'image et propose le texte en légende/sujet.
final class ImageAndTextShareItem: NSObject, UIActivityItemSource {
    private let fileURL: URL
    private let text: String
    private let title: String

    init(fileURL: URL, text: String, title: String) {
        self.fileURL = fileURL
        self.text = text
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        fileURL
    }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // Messages/Mail : on veut le fichier de l'image (le texte est fourni séparément
        // en second item). Pour le presse-papier/AirDrop, le fichier suffit.
        fileURL
    }

    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }

    func activityViewController(_ controller: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.png.identifier
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(contentsOf: fileURL)
        return metadata
    }
}
