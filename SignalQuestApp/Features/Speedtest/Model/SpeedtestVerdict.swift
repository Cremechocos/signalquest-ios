import Foundation

/// Ce qu'un résultat permet, en mots (MES-05) : le palier de l'échelle commune
/// et les usages courants. Seuils publics des services concernés (Netflix,
/// YouTube, Zoom), arrondis vers le haut : le verdict promet peu et tient.
/// Pur et testable ; la carte choisit icônes et couleurs.
struct SpeedtestVerdict: Equatable {
    enum Usage: String, CaseIterable, Equatable {
        case web, hdVideo, uhdVideo, videoCall, gaming
    }

    enum Fit: Equatable { case good, limited, poor }

    let tier: SQQualityScale.Throughput
    /// Absent quand la mesure ne permet pas de juger (visio sans envoi mesuré,
    /// jeu sans latence) : on ne promet rien de ce qui n'a pas été mesuré.
    let fits: [Usage: Fit]
    /// Temps de téléchargement d'un fichier de 1 Go, en secondes.
    let oneGigabyteSeconds: Double?

    init(downloadMbps: Double, uploadMbps: Double?, latencyMs: Double?, jitterMs: Double?) {
        let download = downloadMbps.isFinite ? max(downloadMbps, 0) : 0
        let upload = uploadMbps.flatMap { $0.isFinite ? max($0, 0) : nil }
        tier = SQQualityScale.Throughput(mbps: download)
        oneGigabyteSeconds = download > 0 ? 8_000 / download : nil
        var fits: [Usage: Fit] = [:]
        fits[.web] = download >= 1 ? .good : download >= 0.5 ? .limited : .poor
        fits[.hdVideo] = download >= 5 ? .good : download >= 3 ? .limited : .poor
        fits[.uhdVideo] = download >= 25 ? .good : download >= 15 ? .limited : .poor
        // La visio envoie autant qu'elle reçoit.
        if let upload {
            let latency = latencyMs ?? 0
            if download >= 3, upload >= 3, latency <= 150 { fits[.videoCall] = .good }
            else if download >= 1.5, upload >= 1.5, latency <= 300 { fits[.videoCall] = .limited }
            else { fits[.videoCall] = .poor }
        }
        // Le jeu dépend de la réactivité plus que du débit.
        if let latency = latencyMs, latency.isFinite {
            let steady = (jitterMs ?? 0) <= 30
            if latency <= 50, steady, download >= 3 { fits[.gaming] = .good }
            else if latency <= 100, download >= 1.5 { fits[.gaming] = .limited }
            else { fits[.gaming] = .poor }
        }
        self.fits = fits
    }

    init(result: SpeedtestRunResult) {
        self.init(downloadMbps: result.downloadAverageMbps, uploadMbps: result.uploadAverageMbps,
                  latencyMs: result.primaryPingMs, jitterMs: result.jitterMs)
    }
}
