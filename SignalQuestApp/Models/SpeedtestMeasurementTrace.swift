import Foundation

struct SpeedtestMeasurementInterval: Codable, Equatable, Sendable {
    let startMs: Int64
    let endMs: Int64
    let bytes: Int64
}

struct SpeedtestTimedRate: Codable, Equatable, Sendable {
    let elapsedMs: Int64
    let mbps: Double
}

struct SpeedtestPhaseTrace: Codable, Equatable, Sendable {
    let phase: String
    let attemptId: String
    let startOffsetMs: Int64
    let warmupEndOffsetMs: Int64
    let measurementEndOffsetMs: Int64
    let totalEndOffsetMs: Int64
    let measuredBytes: Int64
    let totalTransferredBytes: Int64
    let byteSource: String
    let sampleByteSource: String
    let liveWindowMs: Int64
    let peakWindowMs: Int64
    let samples: [SpeedtestMeasurementInterval]
    var finalMeasurement: SpeedtestFinalMeasurement? = nil

    var usefulDurationMs: Int64 { measurementEndOffsetMs - warmupEndOffsetMs }
    var recentSeries: [SpeedtestTimedRate] { SpeedtestTraceMath.windows(samples, windowMs: liveWindowMs) }
    var averageSeries: [SpeedtestTimedRate] {
        var bytes: Int64 = 0
        return samples.map { sample in
            bytes += sample.bytes
            return SpeedtestTimedRate(elapsedMs: sample.endMs, mbps: SpeedtestTraceMath.mbps(bytes: Double(bytes), durationMs: sample.endMs - warmupEndOffsetMs))
        }
    }
}

struct SpeedtestFinalMeasurement: Codable, Equatable, Sendable {
    let bytes: Int64
    let durationMs: Int64
    let source: String
    let averageMbps: Double
    let maxMbps: Double?
    let peakWindowMs: Int64
    let samples: [SpeedtestMeasurementInterval]
}

struct SpeedtestAbandonedAttempt: Codable, Equatable, Sendable {
    let phase: String
    let attemptId: String
    let startOffsetMs: Int64
    let endOffsetMs: Int64
    let reason: String
}

struct SpeedtestRunTransferredBytes: Codable, Equatable, Sendable {
    var download: Int64 = 0
    var upload: Int64 = 0
}

struct SpeedtestMeasurementTrace: Codable, Equatable, Sendable {
    let runId: String
    let phases: [SpeedtestPhaseTrace]
    let abandonedAttempts: [SpeedtestAbandonedAttempt]
    var schemaVersion: Int = 1
    var methodologyVersion: Int = 6
    var runTransferredBytes: SpeedtestRunTransferredBytes? = nil
}

enum SpeedtestTraceMath {
    static func mbps(bytes: Double, durationMs: Int64) -> Double {
        guard bytes.isFinite, bytes >= 0, durationMs > 0 else { return 0 }
        return bytes * 8 / Double(durationMs) / 1000
    }

    static func windows(_ samples: [SpeedtestMeasurementInterval], windowMs: Int64) -> [SpeedtestTimedRate] {
        let clean = samples.filter { $0.bytes >= 0 && $0.endMs > $0.startMs }
        guard let first = clean.map(\.startMs).min() else { return [] }
        let integral = SpeedtestIntervalIntegral(clean)
        return Set(clean.map(\.endMs)).sorted().compactMap { end in
            let start = end - max(1000, windowMs)
            guard start >= first else { return nil }
            return SpeedtestTimedRate(elapsedMs: end, mbps: mbps(bytes: integral.bytes(start: start, end: end), durationMs: end - start))
        }
    }

    static func percentile(_ values: [Double], _ percentage: Double) -> Double? {
        let values = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !values.isEmpty else { return nil }
        let position = Double(values.count - 1) * min(1, max(0, percentage))
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
    }
}

private struct SpeedtestIntervalIntegral {
    let times: [Int64]
    let areas: [Double]
    let rates: [Double]

    init(_ samples: [SpeedtestMeasurementInterval]) {
        var deltas: [Int64: Double] = [:]
        for sample in samples {
            let rate = Double(sample.bytes) / Double(sample.endMs - sample.startMs)
            deltas[sample.startMs, default: 0] += rate
            deltas[sample.endMs, default: 0] -= rate
        }
        times = deltas.keys.sorted()
        var areas: [Double] = [], rates: [Double] = [], rate = 0.0, area = 0.0
        for (index, time) in times.enumerated() {
            if index > 0 { area += rate * Double(time - times[index - 1]) }
            rate = max(0, rate + (deltas[time] ?? 0))
            areas.append(area); rates.append(rate)
        }
        self.areas = areas; self.rates = rates
    }

    private func area(at time: Int64) -> Double {
        var lower = 0, upper = times.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if times[middle] <= time { lower = middle + 1 } else { upper = middle }
        }
        let index = lower - 1
        guard index >= 0 else { return 0 }
        return areas[index] + rates[index] * Double(time - times[index])
    }
    func bytes(start: Int64, end: Int64) -> Double { max(0, area(at: end) - area(at: start)).rounded() }
}


/// Scoped to one async run, including transport retries; never shared across runs.
enum SpeedtestTraceScope {
    @TaskLocal static var current: SpeedtestTraceRecorder?
}

final class SpeedtestTraceRecorder: @unchecked Sendable {
    let runId = UUID()
    let startedAt = Date()
    let origin = ProcessInfo.processInfo.systemUptime
    let ownerScopeId = LocalAccountScope.currentOwnerScopeId
    private let lock = NSLock()
    private var phases: [SpeedtestPhaseTrace] = []
    private var abandoned: [SpeedtestAbandonedAttempt] = []
    private var traffic = SpeedtestRunTransferredBytes()
    private var trafficObserved = false

    func recordTraffic(phase: String, bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        trafficObserved = true
        if phase == "download" { traffic.download += Int64(bytes) } else { traffic.upload += Int64(bytes) }
    }

    func offset(_ time: Double) -> Int64 { max(0, Int64(((time - origin) * 1000).rounded())) }
    func abandon(phase: String, id: String, start: Double, reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard abandoned.count < 64 else { return }
        abandoned.append(.init(phase: phase, attemptId: id, startOffsetMs: offset(start),
                               endOffsetMs: offset(ProcessInfo.processInfo.systemUptime), reason: reason))
    }
    func retain(phase: String, id: String, start: Double, baseline: Double, end: Double,
                measuredBytes: Int, totalBytes: Int, source: String, samples: [SpeedtestMeasurementInterval],
                finalMeasurement: SpeedtestFinalMeasurement? = nil) {
        let lower = offset(baseline), upper = offset(end)
        guard upper > lower else { return }
        let intervals = samples.map { SpeedtestMeasurementInterval(startMs: lower + $0.startMs, endMs: lower + $0.endMs, bytes: $0.bytes) }
        // Quantization uses one useful duration, so sample endpoints and phase bounds agree.
        let duration = samples.last?.endMs ?? upper - lower
        let value = SpeedtestPhaseTrace(phase: phase, attemptId: id, startOffsetMs: offset(start),
            warmupEndOffsetMs: lower, measurementEndOffsetMs: lower + duration,
            totalEndOffsetMs: max(lower + duration, offset(ProcessInfo.processInfo.systemUptime)),
            measuredBytes: Int64(measuredBytes), totalTransferredBytes: Int64(totalBytes),
            byteSource: source, sampleByteSource: phase == "download" ? "client-received" : "client-written",
            liveWindowMs: 1000, peakWindowMs: max(1000, Int64(Double(duration) * 0.3)), samples: intervals, finalMeasurement: finalMeasurement)
        lock.lock(); defer { lock.unlock() }
        if let old = phases.first(where: { $0.phase == phase }), abandoned.count < 64 {
            abandoned.append(.init(phase: phase, attemptId: old.attemptId, startOffsetMs: old.startOffsetMs,
                                   endOffsetMs: old.totalEndOffsetMs, reason: "REPLACED"))
        }
        phases.removeAll { $0.phase == phase }; phases.append(value)
    }
    func snapshot(retainingUpload: Bool = true) -> SpeedtestMeasurementTrace? {
        lock.lock(); defer { lock.unlock() }
        let retained = phases.filter { retainingUpload || $0.phase != "upload" }
        guard !retained.isEmpty else { return nil }
        var dropped = abandoned
        if !retainingUpload, let upload = phases.first(where: { $0.phase == "upload" }), dropped.count < 64 {
            dropped.append(.init(phase: "upload", attemptId: upload.attemptId, startOffsetMs: upload.startOffsetMs,
                                 endOffsetMs: upload.totalEndOffsetMs, reason: "INSUFFICIENT_DATA"))
        }
        var trace = SpeedtestMeasurementTrace(runId: runId.uuidString, phases: retained, abandonedAttempts: dropped)
        trace.runTransferredBytes = trafficObserved ? traffic : nil
        return trace
    }
}
