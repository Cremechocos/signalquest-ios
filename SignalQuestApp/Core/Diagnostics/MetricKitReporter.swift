import Foundation
import MetricKit
import os

/// Rapports MetricKit relayés à Crashlytics comme non-fatals (OBS-01). Ils
/// couvrent ce que Crashlytics ne voit pas : sorties par le chien de garde ou
/// par manque de mémoire, blocages, et le coût énergétique réel chez les
/// testeurs (localisation en arrière-plan, CPU, données cellulaires).
///
/// MetricKit appelle l'abonné sur une file d'arrière-plan : la classe n'est
/// isolée à aucun acteur, sinon la vérification d'isolation de Swift 6
/// arrêterait l'app à la livraison du rapport.
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitReporter()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let info = Self.summary(of: payload)
            // Un bilan sans aucune mesure (seulement le build et sa durée) n'apprend rien.
            guard Self.hasMeasurements(info) else { continue }
            SQDiagnostics.recordReport("daily", area: .metricKit, info: info)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let info = Self.summary(of: payload)
            guard !info.isEmpty else { continue }
            SQDiagnostics.recordReport("diagnostic", area: .metricKit, info: info)
        }
    }

    static func hasMeasurements(_ info: [String: String]) -> Bool {
        info.keys.contains { $0 != "build" && $0 != "hours" }
    }

    static func summary(of payload: MXMetricPayload) -> [String: String] {
        var info: [String: String] = [
            "build": payload.metaData?.applicationBuildVersion ?? "?",
            "hours": format(payload.timeStampEnd.timeIntervalSince(payload.timeStampBegin) / 3600),
        ]
        if let time = payload.applicationTimeMetrics {
            info["fg_s"] = seconds(time.cumulativeForegroundTime)
            info["bg_s"] = seconds(time.cumulativeBackgroundTime)
            info["bg_location_s"] = seconds(time.cumulativeBackgroundLocationTime)
        }
        if let cpu = payload.cpuMetrics {
            info["cpu_s"] = seconds(cpu.cumulativeCPUTime)
        }
        if let network = payload.networkTransferMetrics {
            info["cell_down_mb"] = megabytes(network.cumulativeCellularDownload)
            info["cell_up_mb"] = megabytes(network.cumulativeCellularUpload)
        }
        if let memory = payload.memoryMetrics {
            info["peak_memory_mb"] = megabytes(memory.peakMemoryUsage)
        }
        if let hangs = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
            var count = 0
            let buckets = hangs.bucketEnumerator
            while let bucket = buckets.nextObject() as? MXHistogramBucket<UnitDuration> {
                count += bucket.bucketCount
            }
            info["hangs"] = String(count)
        }
        if let exits = payload.applicationExitMetrics {
            let fg = exits.foregroundExitData
            let bg = exits.backgroundExitData
            info["exit_fg_watchdog"] = String(fg.cumulativeAppWatchdogExitCount)
            info["exit_fg_memory"] = String(fg.cumulativeMemoryResourceLimitExitCount)
            info["exit_fg_abnormal"] = String(fg.cumulativeAbnormalExitCount)
            info["exit_bg_watchdog"] = String(bg.cumulativeAppWatchdogExitCount)
            info["exit_bg_memory"] = String(bg.cumulativeMemoryResourceLimitExitCount)
            info["exit_bg_cpu"] = String(bg.cumulativeCPUResourceLimitExitCount)
            info["exit_bg_task_timeout"] = String(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount)
            info["exit_bg_abnormal"] = String(bg.cumulativeAbnormalExitCount)
        }
        return info
    }

    static func summary(of payload: MXDiagnosticPayload) -> [String: String] {
        var info: [String: String] = [:]
        if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
            info["crashes"] = String(crashes.count)
            if let first = crashes.first {
                info["crash_build"] = first.metaData.applicationBuildVersion
                if let signal = first.signal { info["crash_signal"] = signal.stringValue }
                if let type = first.exceptionType { info["crash_exception"] = type.stringValue }
                if let reason = first.terminationReason { info["crash_reason"] = String(reason.prefix(120)) }
            }
        }
        if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
            info["hangs"] = String(hangs.count)
            info["hang_max_s"] = format(hangs.map { $0.hangDuration.converted(to: .seconds).value }.max() ?? 0)
        }
        if let cpu = payload.cpuExceptionDiagnostics, !cpu.isEmpty {
            info["cpu_exceptions"] = String(cpu.count)
        }
        if let writes = payload.diskWriteExceptionDiagnostics, !writes.isEmpty {
            info["disk_write_exceptions"] = String(writes.count)
        }
        return info
    }

    private static func seconds(_ value: Measurement<UnitDuration>) -> String {
        format(value.converted(to: .seconds).value)
    }

    private static func megabytes(_ value: Measurement<UnitInformationStorage>) -> String {
        format(value.converted(to: .megabytes).value)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Sonde de gel du fil principal, sous iOS 16 seulement. MetricKit y compte
/// les blocages sans jamais livrer leur pile : un testeur sous iOS 16.7 voyait
/// l'app se figer sur le Profil, sans rien dans Crashlytics. Si le fil
/// principal ne répond plus pendant 5 s, un non-fatal part avec la dernière
/// étape notée (`mark`), envoyé par le SDK au lancement suivant.
final class MainThreadHangProbe: @unchecked Sendable {
    static let shared = MainThreadHangProbe()

    /// Horloge de la sonde, sans minuterie ni fil : testable telle quelle.
    struct Clock {
        static let threshold: UInt64 = 5_000_000_000
        /// Au-delà entre deux tops, l'app était suspendue, pas figée.
        static let suspensionGap: UInt64 = 3_000_000_000
        private var lastTick: UInt64
        private var lastPong: UInt64
        private var reported = false

        init(now: UInt64) {
            lastTick = now
            lastPong = now
        }

        /// Durée du gel, en secondes, la seule fois où il franchit le seuil.
        mutating func tick(now: UInt64) -> Double? {
            if now &- lastTick > Self.suspensionGap {
                lastPong = now
                reported = false
            }
            lastTick = now
            let stalled = now &- lastPong
            guard stalled >= Self.threshold, !reported else { return nil }
            reported = true
            return Double(stalled) / 1_000_000_000
        }

        /// Le fil principal a répondu : le gel suivant sera signalé à nouveau.
        mutating func pong(now: UInt64) {
            lastPong = now
            reported = false
        }
    }

    private static let step = OSAllocatedUnfairLock(initialState: "launch")
    private let queue = DispatchQueue(label: "fr.signalquest.hang-probe", qos: .utility)
    /// Lu et écrit sur `queue` seulement.
    private var clock = Clock(now: DispatchTime.now().uptimeNanoseconds)
    private var timer: DispatchSourceTimer?

    /// Dernière étape de navigation, un nom d'écran (jamais de contenu).
    static func mark(_ value: String) {
        step.withLock { $0 = value }
    }

    func start() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 17 else { return }
        queue.async { [self] in
            guard timer == nil else { return }
            clock = Clock(now: DispatchTime.now().uptimeNanoseconds)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [self] in tick() }
            timer.resume()
            self.timer = timer
        }
    }

    private func tick() {
        if let stalled = clock.tick(now: DispatchTime.now().uptimeNanoseconds) {
            SQDiagnostics.recordReport("main_hang", area: .mainHang, info: [
                "step": Self.step.withLock { $0 },
                "stalled_s": String(format: "%.0f", stalled),
            ])
        }
        DispatchQueue.main.async { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            queue.async { [self] in clock.pong(now: now) }
        }
    }
}
