import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MacPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        Window(model.text("MacPulse · 性能记录", "MacPulse · Performance History"), id: "dashboard") {
            DashboardView(model: model)
        }
        .defaultSize(width: 1160, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { ShowDashboardCommand(model: model) }
            CommandMenu(model.text("记录", "Recording")) {
                Button(model.isRecording ? model.text("暂停记录", "Pause Recording") : model.text("继续记录", "Resume Recording")) { model.toggleRecording() }.keyboardShortcut("p")
                Button(model.text("导出当前范围 CSV…", "Export Current Range as CSV…")) { model.exportCSV() }.keyboardShortcut("e").disabled(model.samples.isEmpty)
                Divider()
                Button(model.text("显示历史数据库", "Show History Database")) { model.revealHistory() }
            }
        }
        MenuBarExtra {
            Text("\(model.chipName) · \(model.isRecording ? model.text("正在记录", "Recording") : model.text("记录已暂停", "Recording Paused"))")
            LiveMenuBarReading(status: model.liveStatus, language: model.language, kind: .temperature)
            Text(model.text("性能核 \(MetricFormat.frequency(model.latest?.performanceMHz)) GHz", "P-cores \(MetricFormat.frequency(model.latest?.performanceMHz)) GHz"))
            Text(model.text("内存 \(MetricFormat.gibibytes(model.latest?.memoryUsedBytes)) GiB", "Memory \(MetricFormat.gibibytes(model.latest?.memoryUsedBytes)) GiB"))
            Text("GPU \(MetricFormat.percent(model.latest?.gpuUsagePercent))%")
            LiveMenuBarReading(status: model.liveStatus, language: model.language, kind: .network)
            Divider()
            ShowDashboardCommand(model: model)
            Button(model.isRecording ? model.text("暂停记录", "Pause Recording") : model.text("继续记录", "Resume Recording")) { model.toggleRecording() }
            Divider()
            Button(model.text("退出 MacPulse", "Quit MacPulse")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            LiveMenuBarLabel(status: model.liveStatus, language: model.language, isRecording: model.isRecording)
        }
    }
}

// The one-second live feed is observed only by these menu-bar views. The
// history model and DashboardView do not subscribe to its frequent changes.
private struct LiveMenuBarReading: View {
    enum Kind { case temperature, network }
    @ObservedObject var status: LiveStatusModel
    let language: AppLanguage
    let kind: Kind

    @ViewBuilder var body: some View {
        switch kind {
        case .temperature:
            Text(Localization.text(
                "CPU 温度 \(MenuBarFormat.temperature(status.cpuTemperatureCelsius))",
                "CPU Temperature \(MenuBarFormat.temperature(status.cpuTemperatureCelsius))",
                language: language
            ))
        case .network:
            Text(Localization.text(
                "网络 ↓ \(MetricFormat.rateLabel(status.receivedBytesPerSecond)) · ↑ \(MetricFormat.rateLabel(status.sentBytesPerSecond))",
                "Network ↓ \(MetricFormat.rateLabel(status.receivedBytesPerSecond)) · ↑ \(MetricFormat.rateLabel(status.sentBytesPerSecond))",
                language: language
            ))
        }
    }
}

private struct LiveMenuBarLabel: View {
    @ObservedObject var status: LiveStatusModel
    let language: AppLanguage
    let isRecording: Bool

    var body: some View {
        MenuBarLabel(
            cpuTemperatureCelsius: status.cpuTemperatureCelsius,
            receivedBytesPerSecond: status.receivedBytesPerSecond,
            sentBytesPerSecond: status.sentBytesPerSecond,
            accessibilityDescription: Localization.text(
                "MacPulse，CPU 温度 \(MenuBarFormat.temperature(status.cpuTemperatureCelsius))，接收 \(MenuBarFormat.fullRate(status.receivedBytesPerSecond))，发送 \(MenuBarFormat.fullRate(status.sentBytesPerSecond))，\(isRecording ? "正在记录" : "记录已暂停")",
                "MacPulse, CPU temperature \(MenuBarFormat.temperature(status.cpuTemperatureCelsius)), receive \(MenuBarFormat.fullRate(status.receivedBytesPerSecond)), send \(MenuBarFormat.fullRate(status.sentBytesPerSecond)), \(isRecording ? "recording" : "recording paused")",
                language: language
            )
        )
    }
}

private struct ShowDashboardCommand: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.text("打开性能记录", "Open Performance History")) {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("1")
    }
}
