import AppKit
import Combine
import Foundation

@main
struct LiveStatusValidation {
    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            _ = RunLoop.main.run(mode: .default, before: end)
        }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacPulse-live-validation-\(UUID())")
        let previousInterval = UserDefaults.standard.object(forKey: "samplingInterval")
        defer {
            if let previousInterval { UserDefaults.standard.set(previousInterval, forKey: "samplingInterval") }
            else { UserDefaults.standard.removeObject(forKey: "samplingInterval") }
            try? FileManager.default.removeItem(at: directory)
        }
        var model: MonitorModel? = MonitorModel(historyDirectory: directory)
        let modelWasReleased = { [weak model] in model == nil }
        var temperatureUpdates = 0
        var networkUpdates = 0
        var historyViewUpdates = 0
        let temperatureSubscription = model!.liveStatus.$cpuTemperatureCelsius.sink { _ in temperatureUpdates += 1 }
        let networkSubscription = model!.liveStatus.$receivedBytesPerSecond.sink { _ in networkUpdates += 1 }
        let historySubscription = model!.objectWillChange.sink { historyViewUpdates += 1 }
        model!.interval = 10
        pump(2.4)
        precondition(model!.recordCount >= 1, "Initial history sample must be saved")
        precondition(temperatureUpdates >= 3 && networkUpdates >= 3, "Live status must refresh each second at a 10s history interval")
        model!.toggleRecording()
        pump(0.4)
        let pausedCount = model!.recordCount
        let pausedUpdates = temperatureUpdates
        let pausedHistoryViewUpdates = historyViewUpdates
        pump(2.3)
        precondition(model!.recordCount == pausedCount, "Paused history must not grow")
        precondition(temperatureUpdates >= pausedUpdates + 2, "Pausing history must not pause live status")
        precondition(historyViewUpdates == pausedHistoryViewUpdates, "Live status must not redraw paused history charts")

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        precondition(model!.cpuTemperatureCelsius == nil && model!.liveNetworkReceivedBytesPerSecond == nil,
                     "Sleep must clear stale readings")
        let sleepingUpdates = temperatureUpdates
        pump(1.3)
        precondition(temperatureUpdates == sleepingUpdates, "Sleeping status must not publish samples")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        pump(2.3)
        precondition(temperatureUpdates >= sleepingUpdates + 2, "Wake must restart live status")
        precondition(model!.recordCount == pausedCount && !model!.isRecording, "Wake must preserve paused recording")

        // Exercise generation invalidation when sleep and wake arrive while an
        // earlier asynchronous read can still be returning to the main queue.
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        pump(1.3)
        model!.toggleRecording()
        pump(0.8)
        precondition(model!.recordCount > pausedCount, "Resuming must append history again")
        precondition(model!.errorMessage == nil, "Isolated history must remain writable")
        model = nil
        pump(0.4)
        precondition(modelWasReleased(), "Timers and callbacks must not retain a discarded monitor")
        withExtendedLifetime([temperatureSubscription, networkSubscription, historySubscription]) {}
        print("Live status checks passed: 1s refresh, independent pause/interval, sleep/wake, resume, resource lifecycle")
    }
}
