import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum HistoryRange: String, CaseIterable, Identifiable {
    case fiveMinutes, fifteenMinutes, hour, sixHours, day, week
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .hour: return 3600
        case .sixHours: return 21600
        case .day: return 86400
        case .week: return 604800
        }
    }
    var title: String {
        switch self {
        case .fiveMinutes: return "5 分钟"
        case .fifteenMinutes: return "15 分钟"
        case .hour: return "1 小时"
        case .sixHours: return "6 小时"
        case .day: return "24 小时"
        case .week: return "7 天"
        }
    }

    func title(in language: AppLanguage) -> String {
        guard language == .english else { return title }
        switch self {
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .hour: return "1 hour"
        case .sixHours: return "6 hours"
        case .day: return "24 hours"
        case .week: return "7 days"
        }
    }
}

private final class SamplingWorker {
    lazy var sampler = TelemetrySampler()
    private var store: HistoryStore?
    private var recordingSegment = Int.random(in: 1...Int.max)
    private var plotCache: [HistoryRange: (refreshedAt: Date, samples: [MetricSample])] = [:]

    // Cache successful initialization only. A temporary filesystem failure can
    // recover on a later sampling tick without requiring an application restart.
    func database() throws -> HistoryStore {
        if let store { return store }
        let value = try HistoryStore()
        store = value
        return value
    }

    func resetBaseline() {
        sampler.resetBaseline()
        recordingSegment = Int.random(in: 1...Int.max)
        plotCache.removeAll()
    }

    func clearHistory() throws {
        try database().clear()
        plotCache.removeAll()
    }

    func collect(range: HistoryRange, recording: Bool, forceGraphRefresh: Bool) throws -> (MetricSample?, [MetricSample], Int, URL) {
        let database = try database()
        let current: MetricSample?
        if recording {
            var value = sampler.sample()
            value.chartSegment = recordingSegment
            try database.append(value)
            current = value
        } else {
            current = try database.latest()
        }
        let now = Date()
        let longRange = range == .day || range == .week
        let cached = plotCache[range]
        let cacheAge = cached.map { now.timeIntervalSince($0.refreshedAt) }
        let points: [MetricSample]
        if longRange, recording, !forceGraphRefresh, let cached, let cacheAge,
           cacheAge >= 0, cacheAge < 10 {
            points = cached.samples
        } else {
            points = try database.samples(since: now.addingTimeInterval(-range.seconds), until: now)
            plotCache[range] = (now, points)
        }
        return (current, points, try database.count(), database.databaseURL)
    }
}

final class MonitorModel: ObservableObject {
    @Published var language: AppLanguage = .preferred {
        didSet { language.save() }
    }
    @Published var samples: [MetricSample] = []
    @Published var latest: MetricSample?
    @Published var recordCount = 0
    @Published var networkPlotMaximum = 0.0
    @Published var isRecording = true
    @Published var errorMessage: String?
    @Published var exportMessage: String?
    @Published var databaseURL: URL?
    @Published var selectedRange: HistoryRange = .fifteenMinutes {
        didSet { refresh(recording: false) }
    }
    @Published var interval: Double = 2 {
        didSet {
            guard [1.0, 2, 5, 10].contains(interval) else { interval = 2; return }
            UserDefaults.standard.set(interval, forKey: "samplingInterval")
            schedule()
        }
    }
    let chipName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: chars)
    }()
    private let queue = DispatchQueue(label: "local.ian.macpulse.sampling", qos: .utility)
    private let worker = SamplingWorker()
    private var timer: Timer?
    private var pending = false
    private var needsRefresh = false
    private var needsRecording = false
    private var needsGraphRefresh = false
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    init() {
        let saved = UserDefaults.standard.double(forKey: "samplingInterval")
        if [1.0, 2, 5, 10].contains(saved) { interval = saved }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.timer?.invalidate()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetBaseline()
            self?.schedule()
            self?.refresh(recording: self?.isRecording ?? false)
        })
        schedule()
        updateActivity()
        refresh(recording: true)
    }

    deinit {
        timer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var memoryPercent: Double {
        guard let latest, latest.memoryTotalBytes > 0 else { return 0 }
        return latest.memoryUsedBytes / latest.memoryTotalBytes * 100
    }

    func text(_ chinese: String, _ english: String) -> String {
        Localization.text(chinese, english, language: language)
    }

    func source(_ value: String) -> String {
        Localization.source(value, language: language)
    }

    func formattedDate(_ value: Date, date: Date.FormatStyle.DateStyle = .omitted,
                       time: Date.FormatStyle.TimeStyle = .standard) -> String {
        value.formatted(Date.FormatStyle(date: date, time: time, locale: language.locale))
    }

    var dataSpan: String {
        guard let first = samples.first, let last = samples.last else { return text("等待首个样本", "Waiting for the first sample") }
        let seconds = max(0, Int(last.timestamp.timeIntervalSince(first.timestamp)))
        if seconds < 60 { return text("\(seconds) 秒", "\(seconds) sec") }
        if seconds < 3600 { return text("\(seconds / 60) 分钟", "\(seconds / 60) min") }
        if seconds < 86400 { return text("\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟", "\(seconds / 3600) hr \(seconds % 3600 / 60) min") }
        return text("\(seconds / 86400) 天 \(seconds % 86400 / 3600) 小时", "\(seconds / 86400) days \(seconds % 86400 / 3600) hr")
    }

    func toggleRecording() {
        isRecording.toggle()
        updateActivity()
        if isRecording { resetBaseline(); refresh(recording: true) }
    }

    private func updateActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if isRecording {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: text("持续记录 Mac 性能与网络曲线", "Continuously recording Mac performance and network charts"))
        }
    }

    private func resetBaseline() {
        queue.async { [weak self] in self?.worker.resetBaseline() }
    }

    func schedule() {
        timer?.invalidate()
        let value = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.refresh(recording: true)
        }
        value.tolerance = min(0.3, interval * 0.1)
        RunLoop.main.add(value, forMode: .common)
        timer = value
    }

    func refresh(recording: Bool, forceGraphRefresh: Bool = false) {
        let forceGraphRefresh = forceGraphRefresh || !recording
        guard !pending else {
            needsRefresh = true
            needsRecording = needsRecording || recording
            needsGraphRefresh = needsGraphRefresh || forceGraphRefresh
            return
        }
        pending = true
        let range = selectedRange
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.worker.collect(range: range, recording: recording, forceGraphRefresh: forceGraphRefresh) }
            DispatchQueue.main.async {
                self.pending = false
                switch result {
                case .success(let value):
                    if let current = value.0 { self.latest = current }
                    self.samples = value.1
                    self.networkPlotMaximum = value.1.flatMap {
                        [$0.networkReceivedBytesPerSecond, $0.networkSentBytesPerSecond].compactMap { $0 }
                    }.max() ?? 0
                    self.recordCount = value.2
                    self.databaseURL = value.3
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = "采集或保存失败：\(error.localizedDescription)"
                }
                if self.needsRefresh || range != self.selectedRange {
                    let recording = self.needsRecording && self.isRecording
                    let forceGraphRefresh = self.needsGraphRefresh || range != self.selectedRange
                    self.needsRefresh = false
                    self.needsRecording = false
                    self.needsGraphRefresh = false
                    self.refresh(recording: recording, forceGraphRefresh: forceGraphRefresh)
                }
            }
        }
    }

    func exportCSV() {
        let range = selectedRange
        let exportDate = Date()
        let since = exportDate.addingTimeInterval(-range.seconds)
        let panel = NSSavePanel()
        panel.title = text("导出\(range.title)的原始记录", "Export raw records for \(range.title(in: language))")
        panel.prompt = text("保存", "Save")
        panel.nameFieldLabel = text("名称：", "Name:")
        panel.allowedContentTypes = [.commaSeparatedText]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "MacPulse-\(formatter.string(from: exportDate)).csv"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.queue.async {
                let result = Result { try self.worker.database().exportCSV(to: url, since: since, until: exportDate) }
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.exportMessage = "已导出：\(url.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    case .failure(let error): self.errorMessage = "导出失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func revealHistory() {
        if let databaseURL { NSWorkspace.shared.activateFileViewerSelecting([databaseURL]) }
    }

    func clearHistory() {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.worker.clearHistory() }
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    self.errorMessage = error.localizedDescription
                    return
                }
                self.samples = []
                self.latest = nil
                self.recordCount = 0
                self.networkPlotMaximum = 0
                self.refresh(recording: self.isRecording)
            }
        }
    }
}

enum MetricFormat {
    static func frequency(_ mhz: Double?) -> String {
        guard let mhz else { return "—" }
        return String(format: "%.2f", mhz / 1000)
    }
    static func gibibytes(_ bytes: Double?) -> String {
        guard let bytes else { return "—" }
        return String(format: "%.1f", bytes / 1_073_741_824)
    }
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }
    static func rate(_ bytesPerSecond: Double?) -> (value: String, unit: String) {
        guard let bytesPerSecond else { return ("—", "KiB/s") }
        let units = ["B/s", "KiB/s", "MiB/s", "GiB/s"]
        var value = max(0, bytesPerSecond), index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        return (String(format: value >= 100 ? "%.0f" : "%.1f", value), units[index])
    }
    static func rateLabel(_ bytesPerSecond: Double?) -> String {
        let formatted = rate(bytesPerSecond)
        return "\(formatted.value) \(formatted.unit)"
    }
}
