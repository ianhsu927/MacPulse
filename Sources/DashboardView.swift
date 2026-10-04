import AppKit
import Charts
import SwiftUI

// The macOS 27 SDK also exports a State macro whose plugin ships with Xcode.
// An explicit wrapper alias keeps this project buildable with Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

private enum Palette {
    static let performance = Color(red: 0.29, green: 0.39, blue: 0.91)
    static let efficiency = Color(red: 0.08, green: 0.65, blue: 0.63)
    static let memory = Color(red: 0.55, green: 0.36, blue: 0.83)
    static let cpu = Color(red: 0.89, green: 0.55, blue: 0.20)
    static let gpu = Color(red: 0.86, green: 0.35, blue: 0.49)
    static let received = Color(red: 0.05, green: 0.59, blue: 0.77)
    static let sent = Color(red: 0.91, green: 0.58, blue: 0.18)
}

enum AppSection: String, CaseIterable {
    case overview, settings
    func title(in model: MonitorModel) -> String {
        self == .overview ? model.text("实时概览", "Overview") : model.text("记录与设置", "Recording & Settings")
    }
    var icon: String { self == .overview ? "waveform.path.ecg" : "slider.horizontal.3" }
}

// A Window scene's initial title may be retained by AppKit after a language
// change. Keep the attached native window in sync without adding any layout.
private struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowTitleView {
        let view = WindowTitleView(frame: .zero)
        view.windowTitle = title
        return view
    }

    func updateNSView(_ nsView: WindowTitleView, context: Context) {
        nsView.windowTitle = title
    }

    final class WindowTitleView: NSView {
        var windowTitle = "" {
            didSet { updateWindowTitle() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateWindowTitle()
        }

        private func updateWindowTitle() {
            guard let window, window.title != windowTitle else { return }
            window.title = windowTitle
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    @ViewState private var section: AppSection = .overview
    @ViewState private var confirmClear = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.45)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if section == .overview { overview } else { settings }
                    }
                    .padding(22)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1030, minHeight: 740)
        .tint(Palette.performance)
        .environment(\.locale, model.language.locale)
        .background {
            WindowTitleUpdater(title: model.text("MacPulse · 性能记录", "MacPulse · Performance History"))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .alert(model.text("清空本机历史记录？", "Clear local history?"), isPresented: $confirmClear) {
            Button(model.text("取消", "Cancel"), role: .cancel) {}
            Button(model.text("清空记录", "Clear Records"), role: .destructive) { model.clearHistory() }
        } message: {
            Text(model.text("将删除已保存的采样记录。正在进行的采集会继续生成新记录。", "This deletes saved samples. Active recording will continue to create new records."))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Palette.performance)
                    .frame(width: 38, height: 38)
                    .background(Palette.performance.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacPulse").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(model.text("每一刻，都有迹可循", "Every moment, recorded")).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(model.text("工作空间", "WORKSPACE")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(AppSection.allCases, id: \.self) { item in
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 18)
                            Text(item == .settings ? model.text("记录与设置", "Settings") : item.title(in: model))
                                .font(.system(size: 13, weight: section == item ? .semibold : .regular))
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer()
                            if section == item { Circle().fill(Palette.performance).frame(width: 5, height: 5) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .foregroundStyle(section == item ? Palette.performance : Color.primary)
                        .background(section == item ? Palette.performance.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title(in: model))
                    .help(item.title(in: model))
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Image(systemName: "desktopcomputer").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.chipName).font(.system(size: 12, weight: .medium))
                        Text(model.text("\(MetricFormat.gibibytes(model.latest?.memoryTotalBytes)) GiB 统一内存", "\(MetricFormat.gibibytes(model.latest?.memoryTotalBytes)) GiB unified memory"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                Divider()
                Label(model.text("仅在本机保存", "Saved on this Mac"), systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(model.text("关闭窗口后继续采集\n退出应用后停止记录", "Recording continues with the window closed.\nQuit the app to stop recording."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(4)
            }
        }
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 24)
        .frame(width: 205)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(section == .overview ? model.text("性能记录", "Performance History") : model.text("记录与设置", "Recording & Settings"))
                    .font(.system(size: 23, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(section == .overview ? model.text("CPU、GPU、内存与网络，记录这台 Mac 的每一刻。", "CPU, GPU, memory and network activity over time.") : model.text("调整采样节奏，管理本机保存的历史记录。", "Adjust sampling and manage your local history."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle().fill(model.errorMessage != nil ? Color.orange : model.isRecording ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(model.errorMessage != nil ? model.text("采集异常", "Recording Error") : model.isRecording ? model.text("正在记录", "Recording") : model.text("已暂停", "Paused"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.primary.opacity(0.04), in: Capsule())
            Button { model.toggleRecording() } label: {
                Image(systemName: model.isRecording ? "pause.fill" : "play.fill").frame(width: 19, height: 19)
            }
            .help(model.isRecording ? model.text("暂停采集（⌘P）", "Pause recording (⌘P)") : model.text("继续采集（⌘P）", "Resume recording (⌘P)"))
            .accessibilityLabel(model.isRecording ? model.text("暂停采集", "Pause Recording") : model.text("继续采集", "Resume Recording"))
            Button { model.exportCSV() } label: { Label(model.text("导出", "Export"), systemImage: "square.and.arrow.up") }
                .disabled(model.samples.isEmpty).help(model.text("导出当前时间范围的全部原始记录", "Export all original samples in the current time range"))
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 22).padding(.vertical, 18)
    }

    @ViewBuilder private var overview: some View {
        if let error = model.errorMessage {
            Label(model.source(error), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.orange).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        HStack(spacing: 12) {
            statCard(model.text("CPU 使用率", "CPU Usage"), icon: "cpu", value: MetricFormat.percent(model.latest?.cpuUsagePercent), unit: "%", color: Palette.cpu,
                     detail: model.text("性能核 \(MetricFormat.frequency(model.latest?.performanceMHz)) · 能效核 \(MetricFormat.frequency(model.latest?.efficiencyMHz)) GHz", "P \(MetricFormat.frequency(model.latest?.performanceMHz)) · E \(MetricFormat.frequency(model.latest?.efficiencyMHz)) GHz"))
            statCard(model.text("GPU 使用率", "GPU Usage"), icon: "square.stack.3d.up.fill", value: MetricFormat.percent(model.latest?.gpuUsagePercent), unit: "%", color: Palette.gpu,
                    detail: model.latest?.gpuUsagePercent == nil ? model.text("等待有效 GPU 样本", "Waiting for a valid GPU sample") : model.text("系统 GPU 忙碌程度", "GPU activity"))
            statCard(model.text("内存占用", "Memory Used"), icon: "memorychip", value: MetricFormat.gibibytes(model.latest?.memoryUsedBytes), unit: "GiB", color: Palette.memory,
                     detail: model.text("占物理内存 \(MetricFormat.percent(model.latest == nil ? nil : model.memoryPercent))%", "\(MetricFormat.percent(model.latest == nil ? nil : model.memoryPercent))% of physical memory"))
            networkStatCard
        }
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text(model.text("最近", "Last")).foregroundStyle(.secondary)
                Text(model.selectedRange.title(in: model.language)).fontWeight(.semibold)
            }.font(.system(size: 12))
            Spacer()
            Picker(model.text("时间范围", "Time Range"), selection: $model.selectedRange) {
                ForEach(HistoryRange.allCases) { range in Text(range.title(in: model.language)).tag(range) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 450)
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            MetricChartCard(model: model, kind: .frequency)
            MetricChartCard(model: model, kind: .gpu)
            MetricChartCard(model: model, kind: .memory)
            MetricChartCard(model: model, kind: .network)
        }
        HStack(spacing: 8) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            Text(model.text("\(Int(model.interval)) 秒采样 · 保留 7 天 · 当前范围覆盖 \(model.dataSpan)", "\(Int(model.interval))s sampling · 7-day history · Coverage \(model.dataSpan)"))
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer()
            if let date = model.latest?.timestamp {
                Text(model.text("最近记录 \(model.formattedDate(date, date: .omitted, time: .standard))", "Latest \(model.formattedDate(date, date: .omitted, time: .standard))")).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        if let message = model.exportMessage { Text(model.source(message)).font(.system(size: 11)).foregroundStyle(.secondary) }
    }

    private func statCard(_ title: String, icon: String, value: String, unit: String, color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.05)))
    }

    private var networkStatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.text("网络收发", "Network Traffic")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Image(systemName: "network").font(.system(size: 12)).foregroundStyle(Palette.received)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "arrow.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.received)
                let download = MetricFormat.rate(model.latest?.networkReceivedBytesPerSecond)
                Text(download.value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(download.unit).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(model.text("↑ \(MetricFormat.rateLabel(model.latest?.networkSentBytesPerSecond)) · 物理网卡合计", "↑ \(MetricFormat.rateLabel(model.latest?.networkSentBytesPerSecond)) · Physical interfaces"))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.05)))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsBlock(model.text("语言", "Language"), icon: "globe") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.text("界面语言", "Interface Language")).font(.system(size: 13, weight: .medium))
                        Text(model.text("切换后即时生效，记录继续进行。", "Applies immediately while recording continues."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(model.text("语言", "Language"), selection: $model.language) {
                        ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }
            settingsBlock(model.text("采样", "Sampling"), icon: "metronome") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.text("采样间隔", "Sampling Interval")).font(.system(size: 13, weight: .medium))
                        Text(model.text("较长的间隔可以降低采集和绘图开销。", "Longer intervals reduce sampling and chart overhead.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(model.text("采样间隔", "Sampling Interval"), selection: $model.interval) {
                        ForEach([1.0, 2, 5, 10], id: \.self) { interval in Text(model.text("\(Int(interval)) 秒", "\(Int(interval)) seconds")).tag(interval) }
                    }.labelsHidden().frame(width: 120)
                }
                Divider()
                Text(model.text("应用运行期间采集；关闭窗口后继续，退出应用后停止。Mac 休眠时不采集，唤醒后继续。曲线中的空白表示没有记录。", "Recording continues while the app is running, including with its window closed. It stops when you quit, pauses during sleep, and resumes on wake. Gaps indicate periods without records.")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            }
            settingsBlock(model.text("历史记录", "History"), icon: "internaldrive") {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.text("\(model.recordCount.formatted(.number.locale(model.language.locale))) 条原始记录", "\(model.recordCount.formatted(.number.locale(model.language.locale))) original samples")).font(.system(size: 19, weight: .semibold, design: .rounded))
                        Text(model.text("自动保留最近 7 天，下次采集时清理过期数据。", "Keeps the last 7 days and periodically removes expired samples."))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.text("在 Finder 中显示", "Show in Finder")) { model.revealHistory() }.disabled(model.databaseURL == nil)
                }
                if let url = model.databaseURL {
                    Text(url.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Divider()
                HStack {
                    Text(model.text("CSV 导出包含所选范围内全部原始样本。长时间曲线按时间桶聚合展示。", "CSV exports include all original samples in the selected range. Longer ranges display time-bucket averages.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.text("清空历史记录", "Clear History"), role: .destructive) { confirmClear = true }
                }
            }
            settingsBlock(model.text("指标说明", "About the Metrics"), icon: "info.circle") {
                definition(model.text("CPU 频率", "CPU Frequency"), model.text("来自 CPU 性能状态驻留计数与芯片频率表，表示采样区间中核心活跃时的加权平均频率。不同于某一瞬间的时钟；核心完全空闲或读数不可用时显示空白。", "Computed from CPU performance-state residency and the chip frequency table. This is a weighted average during active core time, rather than an instantaneous clock reading. Fully idle cores and unavailable readings remain blank."))
                definition(model.text("数据源", "CPU Source"), model.source(model.latest?.frequencySource ?? model.text("正在初始化系统采样器。", "Initializing the system sampler.")))
                definition(model.text("内存占用", "Memory Used"), model.text("统计系统使用的物理内存，包含压缩器占用，不把压缩前的逻辑大小重复计入；GiB = 1,073,741,824 字节。不同于内存压力。", "Physical memory used by the system, including compressed-memory storage without counting its original logical size again. GiB = 1,073,741,824 bytes. This is distinct from memory pressure."))
                definition(model.text("GPU 使用率", "GPU Usage"), model.text("优先使用 GPU 活跃状态占总驻留时间的比例；备用数据为驱动报告的设备使用率，具体来源见下方。读数不可用时保留空白，旧版历史没有 GPU 数据。", "Prefers active GPU-state time as a share of total residency. The fallback is device utilization reported by the driver; its source is listed below. Unavailable readings remain blank. Older history may contain no GPU data."))
                definition(model.text("GPU 数据源", "GPU Source"), model.source(model.latest?.gpuSource ?? model.text("正在初始化 GPU 采样器。", "Initializing the GPU sampler.")))
                definition(model.text("网络收发", "Network Traffic"), model.text("记录物理网卡接收、发送的字节速率，排除回环与 VPN 等虚拟接口，避免重复计算。1 KiB/s = 1,024 字节/秒。首次采样、暂停恢复和网卡切换需要重新建立基线。", "Receive and send rates for physical network interfaces, excluding loopback, VPN and other virtual interfaces to avoid double counting. 1 KiB/s = 1,024 bytes/second. Initial sampling, resuming and interface changes establish a new baseline."))
                definition(model.text("网络数据源", "Network Source"), model.source(model.latest?.networkSource ?? model.text("正在初始化网络采样器。", "Initializing the network sampler.")))
                definition(model.text("兼容性", "Compatibility"), model.text("Apple Silicon 的频率采集使用 macOS IOReport 系统接口。系统升级可能改变该接口；无法读取时保留缺失值，并继续记录内存和 CPU 使用率。", "Apple Silicon frequency sampling uses macOS IOReport. System updates may change this interface. Unavailable readings remain missing, while memory and CPU usage continue to be recorded."))
                definition(model.text("隐私", "Privacy"), model.text("采集和历史记录全部在本机完成，无账号、无联网传输。", "Sampling and history stay on this Mac. No account or network transmission is required."))
            }
        }
        .buttonStyle(.bordered)
    }

    private func settingsBlock<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold))
            content()
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.05)))
    }
    private func definition(_ label: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text(label).font(.system(size: 12, weight: .medium))
                .frame(width: model.language == .english ? 112 : 65, alignment: .leading)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).textSelection(.enabled)
        }
    }
}

private enum ChartKind {
    case frequency, memory, gpu, network
    func title(in model: MonitorModel) -> String {
        switch self {
        case .frequency: return model.text("CPU 频率", "CPU Frequency")
        case .memory: return model.text("内存占用", "Memory Used")
        case .gpu: return model.text("GPU 使用率", "GPU Usage")
        case .network: return model.text("网络收发", "Network Traffic")
        }
    }
    func subtitle(in model: MonitorModel) -> String {
        switch self {
        case .frequency: return model.text("活跃核心的平均工作频率", "Average frequency of active cores")
        case .memory: return model.text("系统已使用的物理内存", "Physical memory in use")
        case .gpu: return model.text("系统 GPU 的忙碌程度", "GPU activity over each sample interval")
        case .network: return model.text("物理网卡每秒接收与发送字节", "Physical-interface receive and send rates")
        }
    }
}
private struct MetricChartCard: View {
    @ObservedObject var model: MonitorModel
    let kind: ChartKind
    @ViewState private var selectedDate: Date?

    private var points: [PlotPoint] {
        ChartSeries.points(model.samples)
    }
    private var selected: MetricSample? {
        guard let selectedDate else { return nil }
        return ChartSeries.nearestRecordedSample(to: selectedDate, in: model.samples)
    }
    private var domain: ClosedRange<Date> {
        let last = model.samples.last?.timestamp ?? Date()
        let end = model.isRecording ? max(last, Date()) : last
        let earliest = model.samples.first?.timestamp ?? end
        let covered = min(model.selectedRange.seconds, max(60, end.timeIntervalSince(earliest) * 1.03))
        return end.addingTimeInterval(-covered)...end
    }
    private var maxFrequency: Double {
        let highest = model.samples.flatMap { [$0.performanceMHz, $0.efficiencyMHz].compactMap { $0 } }.max() ?? 4000
        return max(1, ceil(highest / 500) * 0.5)
    }
    private var unavailable: Bool {
        switch kind {
        case .frequency: return !model.samples.contains { $0.performanceMHz != nil || $0.efficiencyMHz != nil }
        case .memory: return model.samples.isEmpty
        case .gpu: return !model.samples.contains { $0.gpuUsagePercent != nil }
        case .network: return !model.samples.contains { $0.networkReceivedBytesPerSecond != nil || $0.networkSentBytesPerSecond != nil }
        }
    }
    private var focusedSample: MetricSample? { selected ?? model.latest }
    private var maximumRate: Double {
        model.networkPlotMaximum
    }
    private var rateDivisor: Double {
        if maximumRate >= 1_073_741_824 { return 1_073_741_824 }
        if maximumRate >= 1_048_576 { return 1_048_576 }
        if maximumRate >= 1024 { return 1024 }
        return 1
    }
    private var unit: String {
        switch kind {
        case .frequency: return "GHz"
        case .memory: return "GiB"
        case .gpu: return "%"
        case .network: return rateDivisor == 1 ? "B/s" : rateDivisor == 1024 ? "KiB/s" : rateDivisor == 1_048_576 ? "MiB/s" : "GiB/s"
        }
    }
    private var maximumY: Double {
        switch kind {
        case .frequency: return maxFrequency
        case .memory: return max(1, (model.latest?.memoryTotalBytes ?? 1_073_741_824) / 1_073_741_824)
        case .gpu: return 100
        case .network: return max(1, maximumRate / rateDivisor * 1.15)
        }
    }
    private var unavailableReason: String {
        switch kind {
        case .frequency: return model.source(model.latest?.frequencySource ?? model.text("等待下一个样本", "Waiting for the next sample"))
        case .gpu: return model.source(model.latest?.gpuSource ?? model.text("升级后的 GPU 记录正在积累", "GPU history is being collected"))
        case .network: return model.source(model.latest?.networkSource ?? model.text("等待网络计数基线", "Waiting for a network-counter baseline"))
        case .memory: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(kind.title(in: model)).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(kind.subtitle(in: model))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer()
                chartLegend.lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(height: 36, alignment: .top)
            Chart {
                ForEach(points) { point in
                    chartMarks(point)
                }
                if let selected {
                    RuleMark(x: .value(model.text("时间", "Time"), selected.timestamp)).foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    selectedMarks(selected)
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...maximumY)
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisTick().foregroundStyle(Color.primary.opacity(0.10))
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(axisLabel(date))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if let plotFrame = proxy.plotFrame {
                                    let frame = geometry[plotFrame]
                                    if frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX),
                                       let first = model.samples.first, let last = model.samples.last,
                                       date >= first.timestamp, date <= last.timestamp {
                                        selectedDate = date
                                    } else { selectedDate = nil }
                                }
                            case .ended: selectedDate = nil
                            }
                        }
                }
            }
            .frame(height: 125)
            .overlay {
                if unavailable {
                    VStack(spacing: 7) {
                        Image(systemName: kind == .frequency ? "waveform.path" : "chart.xyaxis.line").font(.system(size: 19)).foregroundStyle(.tertiary)
                        Text(model.samples.isEmpty ? model.text("记录正在积累，曲线会随采样出现", "Charts will appear as samples are recorded") : model.text("\(kind.title(in: model))暂不可用", "\(kind.title(in: model)) is unavailable"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        if kind != .memory && !model.samples.isEmpty {
                            Text(unavailableReason).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack {
                Text(unit).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                Spacer()
                Text(selected.map { model.formattedDate($0.timestamp, date: .abbreviated, time: .standard) } ?? model.text("移动指针查看记录", "Hover to inspect a sample"))
                    .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(height: 12)
        }
        .padding(18)
        // Hover details replace the footer text and never change the card's layout.
        .frame(height: 234, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.05)))
    }

    private func legend(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).monospacedDigit()
        }.font(.system(size: 10))
    }

    @ViewBuilder private var chartLegend: some View {
        VStack(alignment: .trailing, spacing: 5) {
            switch kind {
            case .frequency:
                legend(model.text("性能核", "P-cores"), value: "\(MetricFormat.frequency(focusedSample?.performanceMHz)) GHz", color: Palette.performance)
                legend(model.text("能效核", "E-cores"), value: "\(MetricFormat.frequency(focusedSample?.efficiencyMHz)) GHz", color: Palette.efficiency)
            case .memory:
                legend(model.text("已用", "Used"), value: "\(MetricFormat.gibibytes(focusedSample?.memoryUsedBytes)) GiB", color: Palette.memory)
                Text(model.text("总计 \(MetricFormat.gibibytes(model.latest?.memoryTotalBytes)) GiB", "Total \(MetricFormat.gibibytes(model.latest?.memoryTotalBytes)) GiB"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            case .gpu:
                legend(model.text("使用率", "Usage"), value: "\(MetricFormat.percent(focusedSample?.gpuUsagePercent))%", color: Palette.gpu)
            case .network:
                legend(model.text("↓ 接收", "↓ Receive"), value: MetricFormat.rateLabel(focusedSample?.networkReceivedBytesPerSecond), color: Palette.received)
                legend(model.text("↑ 发送", "↑ Send"), value: MetricFormat.rateLabel(focusedSample?.networkSentBytesPerSecond), color: Palette.sent)
            }
        }
    }

    @ChartContentBuilder private func chartMarks(_ point: PlotPoint) -> some ChartContent {
        switch kind {
        case .frequency:
            if let value = point.sample.performanceMHz {
                curve(point.sample.timestamp, value / 1000, series: "P\(point.performanceSegment)", color: Palette.performance)
            }
            if let value = point.sample.efficiencyMHz {
                curve(point.sample.timestamp, value / 1000, series: "E\(point.efficiencySegment)", color: Palette.efficiency)
            }
        case .memory:
            let value = point.sample.memoryUsedBytes / 1_073_741_824
            fill(point.sample.timestamp, value, series: "M\(point.memorySegment)", color: Palette.memory)
            curve(point.sample.timestamp, value, series: "M\(point.memorySegment)", color: Palette.memory)
        case .gpu:
            if let value = point.sample.gpuUsagePercent {
                fill(point.sample.timestamp, value, series: "G\(point.gpuSegment)", color: Palette.gpu)
                curve(point.sample.timestamp, value, series: "G\(point.gpuSegment)", color: Palette.gpu)
            }
        case .network:
            if let value = point.sample.networkReceivedBytesPerSecond {
                curve(point.sample.timestamp, value / rateDivisor, series: "R\(point.receivedSegment)", color: Palette.received)
            }
            if let value = point.sample.networkSentBytesPerSecond {
                curve(point.sample.timestamp, value / rateDivisor, series: "S\(point.sentSegment)", color: Palette.sent)
            }
        }
    }

    private func curve(_ date: Date, _ value: Double, series: String, color: Color) -> some ChartContent {
        LineMark(x: .value(model.text("时间", "Time"), date), y: .value(unit, value), series: .value(model.text("指标", "Metric"), series))
            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.8)).interpolationMethod(.linear)
    }

    private func fill(_ date: Date, _ value: Double, series: String, color: Color) -> some ChartContent {
        AreaMark(x: .value(model.text("时间", "Time"), date), yStart: .value(model.text("零", "Zero"), 0.0), yEnd: .value(unit, value), series: .value(model.text("指标", "Metric"), series))
            .foregroundStyle(LinearGradient(colors: [color.opacity(0.18), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
            .interpolationMethod(.linear)
    }

    @ChartContentBuilder private func selectedMarks(_ sample: MetricSample) -> some ChartContent {
        switch kind {
        case .frequency:
            if let value = sample.performanceMHz { dot(sample.timestamp, value / 1000, color: Palette.performance) }
            if let value = sample.efficiencyMHz { dot(sample.timestamp, value / 1000, color: Palette.efficiency) }
        case .memory: dot(sample.timestamp, sample.memoryUsedBytes / 1_073_741_824, color: Palette.memory)
        case .gpu:
            if let value = sample.gpuUsagePercent { dot(sample.timestamp, value, color: Palette.gpu) }
        case .network:
            if let value = sample.networkReceivedBytesPerSecond { dot(sample.timestamp, value / rateDivisor, color: Palette.received) }
            if let value = sample.networkSentBytesPerSecond { dot(sample.timestamp, value / rateDivisor, color: Palette.sent) }
        }
    }

    private func dot(_ date: Date, _ value: Double, color: Color) -> some ChartContent {
        PointMark(x: .value(model.text("时间", "Time"), date), y: .value(unit, value)).foregroundStyle(color).symbolSize(35)
    }

    private func axisLabel(_ date: Date) -> String {
        if domain.upperBound.timeIntervalSince(domain.lowerBound) <= 120 {
            return date.formatted(.dateTime.hour().minute().second().locale(model.language.locale))
        }
        if model.selectedRange == .week { return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().locale(model.language.locale)) }
        return date.formatted(.dateTime.hour().minute().locale(model.language.locale))
    }
}
