import CarPlay
import os

/// Rappel de fin d'une opération de navigation CarPlay.
///
/// `success` est faux quand le système a refusé la présentation : profondeur de
/// pile dépassée, template non autorisé par la catégorie d'entitlement, scène
/// déjà déconnectée.
typealias CarPlayNavigationCompletion = @MainActor @Sendable (Bool, (any Error)?) -> Void

/// Indirection sur `CPInterfaceController`.
///
/// Elle existe pour deux raisons.
///
/// 1. `CPInterfaceController.init` est `NS_UNAVAILABLE` — seul le système en
///    fabrique un, à la connexion du véhicule. Sans ce protocole, la navigation
///    entre templates ne serait vérifiable qu'avec un simulateur CarPlay ouvert,
///    donc jamais en test automatisé. Les templates, eux, s'instancient
///    librement : c'est la pile qui avait besoin d'être découplée, pas leur
///    contenu.
///
/// 2. ⚠️ CarPlay LÈVE UNE EXCEPTION quand une présentation échoue et qu'aucun
///    bloc de complétion n'est fourni — c'est écrit noir sur blanc dans
///    `CPInterfaceController.h`. Une exception Objective-C n'est pas rattrapable
///    depuis Swift : c'est un crash, au volant. Les implémentations ci-dessous
///    passent donc TOUJOURS un bloc au système, même quand l'appelant se
///    désintéresse du résultat. Un refus devient une ligne de journal au lieu
///    d'une app qui disparaît de l'écran du véhicule.
@MainActor
protocol CarPlayInterfaceControlling: AnyObject {
    func setRoot(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?)
    func push(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?)
    func pop(animated: Bool, completion: CarPlayNavigationCompletion?)
    func present(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?)
    func dismiss(animated: Bool, completion: CarPlayNavigationCompletion?)

    /// Nombre de templates actuellement empilés, racine comprise.
    ///
    /// ⚠️ Lecture coûteuse : elle peut déclencher un appel IPC synchrone vers le
    /// véhicule. À réserver aux décisions de navigation ponctuelles, jamais à un
    /// chemin parcouru en continu.
    var templateCount: Int { get }
}

/// Surcharges de confort : la plupart des appels ne font rien du résultat, et la
/// journalisation interne suffit à ce qu'un refus ne passe plus inaperçu.
extension CarPlayInterfaceControlling {
    func setRoot(_ template: CPTemplate, animated: Bool) {
        setRoot(template, animated: animated, completion: nil)
    }

    func push(_ template: CPTemplate, animated: Bool) {
        push(template, animated: animated, completion: nil)
    }

    func pop(animated: Bool) {
        pop(animated: animated, completion: nil)
    }

    func present(_ template: CPTemplate, animated: Bool) {
        present(template, animated: animated, completion: nil)
    }

    func dismiss(animated: Bool) {
        dismiss(animated: animated, completion: nil)
    }
}

extension CPInterfaceController: CarPlayInterfaceControlling {
    var templateCount: Int { templates.count }

    func setRoot(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?) {
        let label = CarPlayNavigationLog.label(for: template)
        setRootTemplate(template, animated: animated) { success, error in
            CarPlayNavigationLog.record("setRoot", target: label, success: success, error: error)
            completion?(success, error)
        }
    }

    func push(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?) {
        let label = CarPlayNavigationLog.label(for: template)
        pushTemplate(template, animated: animated) { success, error in
            CarPlayNavigationLog.record("push", target: label, success: success, error: error)
            completion?(success, error)
        }
    }

    func pop(animated: Bool, completion: CarPlayNavigationCompletion?) {
        popTemplate(animated: animated) { success, error in
            CarPlayNavigationLog.record("pop", target: "—", success: success, error: error)
            completion?(success, error)
        }
    }

    func present(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?) {
        let label = CarPlayNavigationLog.label(for: template)
        presentTemplate(template, animated: animated) { success, error in
            CarPlayNavigationLog.record("present", target: label, success: success, error: error)
            completion?(success, error)
        }
    }

    func dismiss(animated: Bool, completion: CarPlayNavigationCompletion?) {
        dismissTemplate(animated: animated) { success, error in
            CarPlayNavigationLog.record("dismiss", target: "—", success: success, error: error)
            completion?(success, error)
        }
    }
}

/// Journalise les refus de navigation CarPlay.
///
/// Sans elle, un template refusé par le système ne laisse aucune trace : le
/// conducteur appuie, rien ne s'ouvre, et le développeur n'a rien à lire. C'est
/// exactement ce qui rend le plafond de profondeur des apps « driving task »
/// indétectable en développement.
enum CarPlayNavigationLog {
    private static let logger = Logger(subsystem: "fr.signalquest.ios", category: "CarPlay")

    static func label(for template: CPTemplate) -> String {
        String(describing: type(of: template))
    }

    static func record(_ operation: String, target: String, success: Bool, error: (any Error)?) {
        if let error {
            logger.error("""
                Navigation CarPlay refusée — \(operation, privacy: .public) \
                \(target, privacy: .public) : \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        // Un `pop` sans effet n'est pas une anomalie : la pile était déjà à la
        // racine. On le note sans en faire une erreur.
        if !success {
            logger.debug("Navigation CarPlay sans effet — \(operation, privacy: .public) \(target, privacy: .public)")
        }
    }
}
