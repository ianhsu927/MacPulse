import Foundation
import Combine

/// Only status-item views observe these frequent updates. History charts keep
/// their own recording cadence and do not rebuild on a live-status tick.
final class LiveStatusModel: ObservableObject {
    @Published var cpuTemperatureCelsius: Double?
    @Published var cpuTemperatureSource: String?
    @Published var receivedBytesPerSecond: Double?
    @Published var sentBytesPerSecond: Double?
}

struct LiveMetrics {
    let temperature: CPUTemperatureReading
    let receivedBytesPerSecond: Double?
    let sentBytesPerSecond: Double?
}

/// Owned by the menu-bar sampling queue. Its network baseline is independent of
/// the history sampler, so changing or pausing recording cannot alter live rates.
final class LiveMetricsSampler {
    private lazy var temperature = CPUTemperatureSensor()
    private let network = NetworkRateSensor()

    func reset() {
        temperature.reset()
        network.resetBaseline()
    }

    func sample() -> LiveMetrics {
        let reading = temperature.sample()
        let rates = network.sample()
        return LiveMetrics(temperature: reading,
                           receivedBytesPerSecond: rates.received,
                           sentBytesPerSecond: rates.sent)
    }
}
