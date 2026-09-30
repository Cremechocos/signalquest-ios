import AVFoundation
import CoreLocation

/// Décide QUAND annoncer une manœuvre. Pure et sans état externe : c'est la
/// règle la plus facile à rendre insupportable (une annonce toutes les deux
/// secondes) et la plus facile à vérifier hors voiture.
enum VoiceAnnouncementPolicy {
    /// Paliers d'annonce, du plus lointain au plus proche. Trois suffisent :
    /// préparer, confirmer, exécuter. Un quatrième palier ne renseigne pas
    /// davantage et transforme le guidage en bavardage.
    static let thresholds: [CLLocationDistance] = [800, 300, 50]

    /// Renvoie le palier à annoncer, ou `nil` s'il n'y a rien à dire.
    ///
    /// - Parameter lastAnnounced: dernier palier déjà annoncé POUR CETTE ÉTAPE.
    ///   Remis à nil au changement d'étape par l'appelant.
    static func announcement(distanceToManeuver: CLLocationDistance,
                             lastAnnounced: CLLocationDistance?) -> CLLocationDistance? {
        // `last` et non `first` : les paliers sont rangés du plus lointain au
        // plus proche, et `first` renverrait le PLUS GRAND palier satisfait —
        // à 200 m de la manœuvre, le guidage annoncerait « dans 800 mètres ».
        // On veut le plus petit palier déjà franchi.
        guard let crossed = thresholds.last(where: { distanceToManeuver <= $0 }) else { return nil }
        // Les paliers se franchissent dans l'ordre décroissant : ne jamais
        // revenir en arrière, sinon un recul GPS relancerait une annonce.
        if let lastAnnounced, crossed >= lastAnnounced { return nil }
        return crossed
    }

    /// Texte prononcé. La distance précède l'instruction : « Dans 300 mètres,
    /// tournez à droite » — l'ordre inverse ferait agir trop tôt.
    static func spokenText(instruction: String, threshold: CLLocationDistance) -> String {
        guard threshold > 50 else { return instruction }
        let distance = SQUnits.distance(meters: threshold)
        return String(localized: "Dans \(distance), \(instruction)")
    }
}

/// Prononce les annonces de guidage.
///
/// ⚠️ Point d'intégration réel, pas un détail : l'app déclare déjà les modes de
/// fond `audio` et `voip`, et `CallManager` (LiveKit + CallKit) tient sa propre
/// session audio. Le guidage doit s'intercaler dans la musique — d'où
/// `.duckOthers` — mais se TAIRE pendant un appel, sinon il parle par-dessus
/// l'interlocuteur.
@MainActor
final class CarPlayVoiceGuide: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    /// Injecté par le coordinateur : le guide n'a pas à connaître `CallManager`.
    private let isCallActive: () -> Bool
    private var lastAnnouncedThreshold: CLLocationDistance?
    private var lastStepIndex: Int?
    /// Annonces encore en file, par identité : la session audio n'est rendue
    /// qu'après la dernière, et une annonce coupée qui se signale en retard ne
    /// la rend pas au milieu de la suivante.
    private var pendingUtterances: Set<ObjectIdentifier> = []

    var isEnabled = true

    init(isCallActive: @escaping () -> Bool) {
        self.isCallActive = isCallActive
        super.init()
        synthesizer.delegate = self
    }

    /// À appeler à chaque mise à jour de progression.
    func handle(progress: RouteProgress, plan: RoutePlan) {
        guard isEnabled, !isCallActive() else { return }
        guard progress.stepIndex < plan.steps.count else { return }

        // Changement d'étape : les paliers repartent de zéro.
        if lastStepIndex != progress.stepIndex {
            lastStepIndex = progress.stepIndex
            lastAnnouncedThreshold = nil
        }

        guard let threshold = VoiceAnnouncementPolicy.announcement(
            distanceToManeuver: progress.distanceToManeuver,
            lastAnnounced: lastAnnouncedThreshold
        ) else { return }

        lastAnnouncedThreshold = threshold
        speak(VoiceAnnouncementPolicy.spokenText(
            instruction: plan.steps[progress.stepIndex].instruction,
            threshold: threshold
        ))
    }

    func announceArrival() {
        guard isEnabled, !isCallActive() else { return }
        speak(String(localized: "Tu es à destination."))
    }

    /// Fin de trajet. Arrivé, l'annonce en cours va jusqu'au bout — elle était
    /// coupée net au moment même où elle commençait. Arrêté par le conducteur,
    /// la voix se tait tout de suite.
    func endTrip(interrupting: Bool) {
        lastAnnouncedThreshold = nil
        lastStepIndex = nil
        guard interrupting else { return }
        synthesizer.stopSpeaking(at: .immediate)
        // Les annonces en file ne rappellent pas toutes le délégué une fois
        // coupées : on rend la session sans les attendre.
        pendingUtterances.removeAll()
        releaseSession()
    }

    private func speak(_ text: String) {
        activateDuckedSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage(
            appLanguage: Bundle.main.preferredLocalizations.first ?? "fr",
            deviceLanguage: AVSpeechSynthesisVoice.currentLanguageCode()
        ))
        pendingUtterances.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    /// Langue de la voix : celle de l'app, puisque les annonces sont traduites
    /// dans cette langue, avec l'accent de l'appareil quand il parle la même
    /// (fr-CA reste fr-CA). Une voix française figée lisait « In 300 meters »
    /// avec l'accent français.
    nonisolated static func voiceLanguage(appLanguage: String, deviceLanguage: String) -> String {
        let app = appLanguage.lowercased().prefix { $0.isLetter }
        let device = deviceLanguage.lowercased().prefix { $0.isLetter }
        if !app.isEmpty, app == device { return deviceLanguage }
        return app == "en" ? "en-US" : "fr-FR"
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceDidEnd(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceDidEnd(id) }
    }

    private func utteranceDidEnd(_ id: ObjectIdentifier) {
        guard pendingUtterances.remove(id) != nil, pendingUtterances.isEmpty else { return }
        releaseSession()
    }

    /// Rend le son aux autres apps une fois l'annonce dite : la session restait
    /// active, et la musique baissée pendant tout le trajet (CAR-04). Jamais
    /// pendant un appel, dont la session audio est la même.
    private func releaseSession() {
        guard !isCallActive() else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Session audio ouverte au moment de parler, et pas à la construction :
    /// l'activer en permanence entrerait en concurrence avec la session VoIP de
    /// `CallManager` même quand aucune annonce n'est en cours.
    private func activateDuckedSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true, options: [])
    }
}
