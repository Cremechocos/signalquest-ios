import AppIntents
import Foundation

// Raccourcis qui répondent à voix haute sans ouvrir l'app (lot 5 CarPlay,
// choix d'Alexandre du 13/11). Ils servent en voiture, où l'on ne doit jamais
// renvoyer quelqu'un vers son iPhone : chaque réponse tient en une ou deux
// phrases, refus compris, et ne contient aucune consigne à l'écran.

/// « Arrête le drive test » : arrête le trajet en cours, lancé de la voiture
/// ou de l'iPhone, et en lit le bilan.
struct StopDriveTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Arrêter le drive test"
    static let description = IntentDescription("Arrête le drive test en cours et en donne le bilan.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let drive = AppServicesHolder.services.driveTest
        guard drive.isRunning else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Aucun drive test en cours.")))
        }
        drive.stop()
        let answer = DriveTestVoice.stoppedAnswer(recap: drive.lastSessionRecap, now: Date())
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

/// « Comment est le réseau ici ? » : le verdict communautaire de l'onglet Ici,
/// en une phrase (verdict, opérateur, base de mesures).
struct NetworkHereIntent: AppIntent {
    static let title: LocalizedStringResource = "Réseau ici"
    static let description = IntentDescription("Dit ce que vaut le réseau à la position actuelle, d'après les mesures de la communauté.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServicesHolder.services
        // Délai court : Siri attend la réponse, et une position qui ne vient
        // pas en 5 s ne viendra pas mieux en 8.
        guard let location = await services.location.currentLocation(timeoutSeconds: 5) else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Position indisponible pour l'instant.")))
        }
        let path = services.networkPath.status
        let quality = await services.nearbyQuality.verdict(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            isCellular: path.connection == .cellular,
            simPlmn: services.networkPath.simPLMN().plmn,
            maxAge: nil
        )
        return .result(dialog: IntentDialog(stringLiteral: NetworkHereVoice.answer(quality)))
    }
}

/// Réponses parlées du drive test, séparées des intents pour être testées.
@MainActor
enum DriveTestVoice {
    static var isSignedIn: Bool {
        if case .authenticated = AppServicesHolder.session.state { return true }
        return false
    }

    /// Démarre un trajet depuis la voiture et dit ce qui s'est passé. Mêmes
    /// règles que l'onglet Trajet (`DriveTestHandsFreeStart`) ; le trajet
    /// s'arrêtera donc aussi au débranchement de CarPlay.
    static func start(services: AppServices, isSignedIn: Bool) -> String {
        guard isSignedIn else { return String(localized: "Aucun compte connecté sur SignalQuest.") }
        let drive = services.driveTest
        guard !drive.isRunning else { return String(localized: "Un drive test est déjà en cours.") }
        let report = DriveTestPreflightPolicy.evaluate(.current(services: services))
        if let refusal = DriveTestHandsFreeStart.refusal(disclosureSeen: DriveTestHandsFreeStart.disclosureSeen,
                                                         report: report) {
            return spoken(DriveTestHandsFreeStart.reason(refusal))
        }
        drive.startFromCarPlay()
        guard drive.isRunning else {
            return drive.errorMessage ?? String(localized: "Impossible de démarrer")
        }
        return startedAnswer(warnings: report.issues)
    }

    /// « Drive test lancé. », suivi des avertissements du départ s'il y en a :
    /// ils ne bloquent pas, mais le conducteur doit les entendre.
    static func startedAnswer(warnings: [DriveTestPreflightIssue]) -> String {
        let labels = warnings.filter { $0.severity == .warning }
            .compactMap(DriveTripTemplateBuilder.warningLabel)
            .map(lowercasingFirstLetter)
        guard !labels.isEmpty else { return String(localized: "Drive test lancé.") }
        return String(localized: "Drive test lancé. Attention : \(labels.joined(separator: ", ")).")
    }

    /// Le bilan qui vient d'être enregistré. `stop()` remet l'ANCIEN bilan en
    /// place quand le trajet était trop court pour être gardé : seul un bilan
    /// daté de l'instant appartient à ce trajet.
    static func stoppedAnswer(recap: DriveTestViewModel.SessionRecap?, now: Date) -> String {
        guard let recap, abs(now.timeIntervalSince(recap.endedAt)) < 10 else {
            return String(localized: "Drive test arrêté, trop court pour être enregistré.")
        }
        let distance = SQUnits.distance(meters: recap.distanceMeters)
        let tests = String(localized: "\(recap.testCount) test")
        return String(localized: "Drive test arrêté : \(distance), \(tests).")
    }

    /// « Titre. Détail. » : la raison telle que l'écran du véhicule l'affiche.
    static func spoken(_ reason: (title: String, detail: String)) -> String {
        "\(reason.title). \(reason.detail)"
    }

    private static func lowercasingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// Réponse parlée du réseau ici, aux mots de l'onglet Ici.
@MainActor
enum NetworkHereVoice {
    /// « Réseau ici : correct chez Bouygues Telecom, d'après 214 mesures à
    /// moins de 1 km. » L'opérateur et la base de mesures qualifient le
    /// verdict, comme à l'écran.
    static func answer(_ quality: NearbyNetworkQuality?) -> String {
        guard let quality, quality.level != .unknown else {
            return String(localized: "Pas assez de mesures ici pour juger le réseau.")
        }
        let verdict = NearestAntennaTemplateBuilder.verdictTitle(quality.level)
        let carrier = NearestAntennaTemplateBuilder.operatorName(quality)
        let samples = NearestAntennaTemplateBuilder.samplesPhrase(quality)
        return String(localized: "\(verdict) chez \(carrier), d'après \(samples).")
    }
}
