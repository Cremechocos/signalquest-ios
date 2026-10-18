import SwiftUI
import UIKit

/// Point d'entrée de l'extension « Partager vers SignalQuest » : héberge la
/// feuille SwiftUI. L'extension ne fait que déposer le contenu dans l'App Group ;
/// elle n'ouvre pas l'app (l'utilisateur l'ouvre lui-même) et n'envoie rien.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model?.tearDown()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let model = ShareModel(
            items: items,
            onCancel: { [weak self] in
                let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                self?.extensionContext?.cancelRequest(withError: error)
            },
            onFinish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [])
            }
        )
        self.model = model
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}
