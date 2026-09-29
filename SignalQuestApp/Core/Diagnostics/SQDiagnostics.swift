import Foundation
import os
import FirebaseCore
import FirebaseCrashlytics

/// Échecs non fatals remontés à Crashlytics (OBS-01). Sans eux, le tableau de
/// bord restait vide : impossible de distinguer « aucun problème » d'une chaîne
/// de remontée cassée.
///
/// Rien de ce qui part d'ici ne porte de contenu : ni texte de message, ni
/// donnée chiffrée, ni message du serveur. Seulement le domaine, le type
/// d'erreur, le statut HTTP, le code d'erreur de l'API et l'identifiant de
/// requête, qui suffisent à retrouver l'incident côté serveur.
enum SQDiagnostics {
    enum Area: String, Sendable {
        case messageSync = "message_sync"
        case messageOutbox = "message_outbox"
        case postOutbox = "post_outbox"
        case speedtestQueue = "speedtest_queue"
        case decoding
        case metricKit = "metrickit"
        case qa
    }

    /// Plafond par domaine et par lancement : un échec répété en boucle (réseau
    /// instable, écran rouvert) ne doit ni noyer le tableau de bord ni coûter
    /// de la bande passante.
    static let perAreaLimit = 5
    private static let counts = OSAllocatedUnfairLock(initialState: [Area: Int]())
    private static let logger = Logger(subsystem: "fr.signalquest.ios", category: "diagnostics")

    static func record(_ error: Error, area: Area, context: [String: String] = [:]) {
        guard shouldReport(error), reserve(area) else { return }
        send(sanitized(error, area: area, context: context))
    }

    /// Rapport fait de compteurs (MetricKit, preuve de la chaîne) : un non-fatal
    /// dont seules les clés comptent.
    static func recordReport(_ name: String, area: Area, info: [String: String]) {
        guard reserve(area) else { return }
        var userInfo: [String: Any] = ["area": area.rawValue]
        for (key, value) in info { userInfo[key] = value }
        send(NSError(domain: "SQ.\(area.rawValue).\(name)", code: 0, userInfo: userInfo))
    }

    /// Chemin des champs en cause (noms de clés et index, jamais de valeur).
    static func decodingContext(_ error: Error, type: Any.Type) -> [String: String] {
        var context = ["type": String(describing: type)]
        guard let decoding = error as? DecodingError else { return context }
        let path: [CodingKey]
        switch decoding {
        case .keyNotFound(let key, let ctx): path = ctx.codingPath + [key]
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx): path = ctx.codingPath
        @unknown default: path = []
        }
        context["codingPath"] = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return context
    }

    private static func reserve(_ area: Area) -> Bool {
        counts.withLock { counts -> Bool in
            let sent = counts[area, default: 0]
            guard sent < perAreaLimit else { return false }
            counts[area] = sent + 1
            return true
        }
    }

    private static func send(_ report: NSError) {
        logger.error("non-fatal \(report.domain, privacy: .public) \(report.code, privacy: .public)")
        guard FirebaseApp.app() != nil else { return }
        #if DEBUG
        // En Debug (poste de développement, tests automatiques qui provoquent des
        // échecs exprès), rien ne part vers le tableau de bord de production, sauf
        // la preuve de chaîne demandée explicitement.
        guard ProcessInfo.processInfo.arguments.contains("--qa-crashlytics-proof") else { return }
        #endif
        Crashlytics.crashlytics().record(error: report)
    }

    /// Annulations et coupures réseau sont l'ordinaire d'une app de terrain :
    /// en zone blanche, elles ne disent rien d'un défaut de l'app.
    static func shouldReport(_ error: Error) -> Bool {
        if error.isCancellation { return false }
        if let api = error as? APIError, case .transport = api { return false }
        if error is URLError { return false }
        return true
    }

    static func sanitized(_ error: Error, area: Area, context: [String: String] = [:]) -> NSError {
        var info: [String: Any] = ["area": area.rawValue]
        for (key, value) in context { info[key] = value }
        let kind: String
        var code = (error as NSError).code
        switch error {
        case let api as APIError:
            switch api {
            case .http(let status, let apiCode, _, let requestId, _):
                kind = "http"
                code = status
                if let apiCode { info["apiCode"] = apiCode }
                if let requestId { info["requestId"] = requestId }
            case .decoding: kind = "decoding"
            case .invalidURL: kind = "invalid_url"
            case .transport: kind = "transport"
            case .missingAuthToken: kind = "missing_auth"
            case .cancelled: kind = "cancelled"
            }
        case is DecodingError:
            kind = "decoding"
        default:
            kind = String(describing: type(of: error))
        }
        return NSError(domain: "SQ.\(area.rawValue).\(kind)", code: code, userInfo: info)
    }
}
