import CarPlay

/// Indirection sur `CPInterfaceController`.
///
/// Elle existe pour une raison précise : `CPInterfaceController.init` est
/// `NS_UNAVAILABLE` — seul le système en fabrique un, à la connexion du
/// véhicule. Sans ce protocole, la navigation entre templates ne serait
/// vérifiable qu'avec un simulateur CarPlay ouvert, donc jamais en test
/// automatisé. Les templates, eux, s'instancient librement : c'est la pile qui
/// avait besoin d'être découplée, pas leur contenu.
@MainActor
protocol CarPlayInterfaceControlling: AnyObject {
    func setRoot(_ template: CPTemplate, animated: Bool)
    func push(_ template: CPTemplate, animated: Bool)
    func pop(animated: Bool)
    func present(_ template: CPTemplate, animated: Bool)
    func dismiss(animated: Bool)
}

extension CPInterfaceController: CarPlayInterfaceControlling {
    func setRoot(_ template: CPTemplate, animated: Bool) {
        setRootTemplate(template, animated: animated, completion: nil)
    }

    func push(_ template: CPTemplate, animated: Bool) {
        pushTemplate(template, animated: animated, completion: nil)
    }

    func pop(animated: Bool) {
        popTemplate(animated: animated, completion: nil)
    }

    func present(_ template: CPTemplate, animated: Bool) {
        presentTemplate(template, animated: animated, completion: nil)
    }

    func dismiss(animated: Bool) {
        dismissTemplate(animated: animated, completion: nil)
    }
}
