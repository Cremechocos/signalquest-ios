import SwiftUI

/// Propriétaire UNIQUE du graphe de services pour tout le process.
///
/// Jusqu'ici, `SignalQuestApp.init()` était le seul point de construction :
/// l'app démarrait toujours par sa fenêtre. Ce n'est plus vrai avec CarPlay —
/// au branchement du véhicule, iOS lance l'app EN ARRIÈRE-PLAN et connecte la
/// scène CarPlay ; la fenêtre iPhone peut ne jamais apparaître. L'accès
/// paresseux rend l'ordre d'arrivée indifférent.
///
/// Et il garantit qu'un SEUL graphe existe. C'est le point important : deux
/// `AppServices` signifieraient deux `APIClient`, donc deux jeux de cookies et
/// deux refresh concurrents sur 401 — la coalescence des refresh est par
/// instance, le second refresh invaliderait le jeton obtenu par le premier.
///
/// `@MainActor` porte toute la protection : `storedServices` n'a besoin ni de
/// verrou ni de `nonisolated(unsafe)`, et les délégués de scène y accèdent
/// SYNCHRONEMENT puisque `UISceneDelegate` — donc aussi
/// `CPTemplateApplicationSceneDelegate` — est lui-même isolé au main actor.
@MainActor
enum AppServicesHolder {
    private static var storedServices: AppServices?
    private static var storedSession: AuthSessionViewModel?

    static var services: AppServices {
        if let storedServices { return storedServices }
        let created = AppServices()
        storedServices = created
        // Ponts vers le code UIKit posés ICI, et non plus dans le `.task` d'une
        // vue : une scène CarPlay peut se connecter — et une push silencieuse
        // arriver — avant le premier rendu. Les poser à la construction corrige
        // au passage un défaut existant : une push `e2ee_sync` reçue avant que
        // `AppRootView` n'apparaisse trouvait `sharedE2EE` à nil et repartait
        // en `.noData`, sans jamais partager la clé de conversation.
        AppDelegate.sharedPush = created.push
        AppDelegate.sharedCallManager = created.callManager
        AppDelegate.sharedE2EE = created.e2ee
        return created
    }

    static var session: AuthSessionViewModel {
        if let storedSession { return storedSession }
        let created = AuthSessionViewModel(service: services.auth)
        storedSession = created
        return created
    }
}
