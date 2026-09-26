import Foundation
import TermoCore

struct ResourceAlert: Equatable {
    enum Metric: CaseIterable {
        case cpu, memory, disk

        var label: String {
            switch self {
            case .cpu: String(localized: "CPU 使用率", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            case .memory: String(localized: "内存占用", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            case .disk: String(localized: "磁盘占用", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            }
        }
    }

    let metric: Metric
    let percent: Double
    var approximateDuration: Int { ResourceAlertEvaluator.sustainedFrames * 2 }
}

/// Pure sampling policy: no notifications, settings, host lookup or wall-clock reads.
struct ResourceAlertEvaluator {
    static let sustainedFrames = 15
    private static let threshold = 90.0
    private static let cooldown: TimeInterval = 300
    private static let maximumSampleGap: TimeInterval = 6

    private struct Key: Hashable {
        let hostID: String
        let metric: ResourceAlert.Metric
    }

    private struct State {
        var streak = 0
        var lastSample: Date?
        var lastAlert: Date?
    }

    private var states: [Key: State] = [:]

    mutating func evaluate(hostID: String, metrics: HostMetrics, at now: Date) -> [ResourceAlert] {
        let values: [(ResourceAlert.Metric, Double?)] = [
            (.cpu, metrics.cpuPercent),
            (.memory, metrics.memTotalKB > 0 ? metrics.memPercent : nil),
            (.disk, metrics.disks.map(\.percent).filter { $0.isFinite && (0...100).contains($0) }.max())
        ]
        return values.compactMap { metric, value in
            let key = Key(hostID: hostID, metric: metric)
            var state = states[key] ?? State()
            defer { states[key] = state }
            if let last = state.lastSample,
               now.timeIntervalSince(last) > Self.maximumSampleGap || now < last {
                state.streak = 0
            }
            state.lastSample = now
            guard let value, value.isFinite, (Self.threshold...100).contains(value) else {
                state.streak = 0
                return nil
            }
            state.streak += 1
            guard state.streak >= Self.sustainedFrames else { return nil }
            state.streak = 0
            guard state.lastAlert.map({ now.timeIntervalSince($0) >= Self.cooldown }) ?? true else { return nil }
            state.lastAlert = now
            return ResourceAlert(metric: metric, percent: value)
        }
    }

    /// A stopped/reconnected sampler must accumulate fresh samples, preserving notification cooldowns.
    mutating func resetSampling(hostID: String? = nil) {
        for key in Array(states.keys) where hostID == nil || key.hostID == hostID {
            states[key]?.streak = 0
            states[key]?.lastSample = nil
        }
    }

    mutating func remove(hostID: String) {
        states = states.filter { $0.key.hostID != hostID }
    }
}
