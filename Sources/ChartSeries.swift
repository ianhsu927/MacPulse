import Foundation

struct PlotPoint: Identifiable {
    let sample: MetricSample
    let memorySegment: Int
    let performanceSegment: Int
    let efficiencySegment: Int
    let gpuSegment: Int
    let receivedSegment: Int
    let sentSegment: Int
    var id: Date { sample.timestamp }
}

enum ChartSeries {
    static func points(_ samples: [MetricSample]) -> [PlotPoint] {
        var memory = 0, performance = 0, efficiency = 0
        var gpu = 0, received = 0, sent = 0
        var previous: MetricSample?
        return samples.map { sample in
            if let old = previous {
                // A normalized recording run survives chart downsampling, whose
                // adjacent averaged points may legitimately be minutes apart.
                let recordingGap = old.chartSegment != sample.chartSegment
                    || (old.chartSegment == nil && sample.chartSegment == nil
                        && sample.timestamp.timeIntervalSince(old.timestamp) > 30)
                if recordingGap { memory += 1 }
                if recordingGap || old.performanceMHz == nil || sample.performanceMHz == nil { performance += 1 }
                if recordingGap || old.efficiencyMHz == nil || sample.efficiencyMHz == nil { efficiency += 1 }
                if recordingGap || old.gpuUsagePercent == nil || sample.gpuUsagePercent == nil { gpu += 1 }
                if recordingGap || old.networkReceivedBytesPerSecond == nil || sample.networkReceivedBytesPerSecond == nil { received += 1 }
                if recordingGap || old.networkSentBytesPerSecond == nil || sample.networkSentBytesPerSecond == nil { sent += 1 }
            }
            previous = sample
            return PlotPoint(sample: sample, memorySegment: memory,
                             performanceSegment: performance, efficiencySegment: efficiency,
                             gpuSegment: gpu, receivedSegment: received, sentSegment: sent)
        }
    }

    static func nearestRecordedSample(to date: Date, in samples: [MetricSample]) -> MetricSample? {
        guard let first = samples.first, let last = samples.last,
              date >= first.timestamp, date <= last.timestamp else { return nil }
        if let upper = samples.firstIndex(where: { $0.timestamp >= date }) {
            if upper == 0 { return samples[0] }
            let before = samples[upper - 1], after = samples[upper]
            if date > before.timestamp && date < after.timestamp {
                if before.chartSegment != after.chartSegment
                    || (before.chartSegment == nil && after.chartSegment == nil
                        && after.timestamp.timeIntervalSince(before.timestamp) > 30) { return nil }
            }
            return date.timeIntervalSince(before.timestamp) < after.timestamp.timeIntervalSince(date) ? before : after
        }
        return last
    }
}
