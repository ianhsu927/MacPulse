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
                Button(model.isRecording ? model.text("暂停采集", "Pause Recording") : model.text("继续采集", "Resume Recording")) { model.toggleRecording() }.keyboardShortcut("p")
                Button(model.text("导出当前范围 CSV…", "Export Current Range as CSV…")) { model.exportCSV() }.keyboardShortcut("e").disabled(model.samples.isEmpty)
                Divider()
                Button(model.text("显示历史数据库", "Show History Database")) { model.revealHistory() }
            }
        }
        MenuBarExtra("MacPulse", systemImage: "waveform.path.ecg") {
            Text("\(model.chipName) · \(model.isRecording ? model.text("正在记录", "Recording") : model.text("已暂停", "Paused"))")
            Text(model.text("性能核 \(MetricFormat.frequency(model.latest?.performanceMHz)) GHz", "P-cores \(MetricFormat.frequency(model.latest?.performanceMHz)) GHz"))
            Text(model.text("内存 \(MetricFormat.gibibytes(model.latest?.memoryUsedBytes)) GiB", "Memory \(MetricFormat.gibibytes(model.latest?.memoryUsedBytes)) GiB"))
            Text("GPU \(MetricFormat.percent(model.latest?.gpuUsagePercent))%")
            Text(model.text("网络 ↓ \(MetricFormat.rateLabel(model.latest?.networkReceivedBytesPerSecond)) · ↑ \(MetricFormat.rateLabel(model.latest?.networkSentBytesPerSecond))", "Network ↓ \(MetricFormat.rateLabel(model.latest?.networkReceivedBytesPerSecond)) · ↑ \(MetricFormat.rateLabel(model.latest?.networkSentBytesPerSecond))"))
            Divider()
            ShowDashboardCommand(model: model)
            Button(model.isRecording ? model.text("暂停采集", "Pause Recording") : model.text("继续采集", "Resume Recording")) { model.toggleRecording() }
            Divider()
            Button(model.text("退出 MacPulse", "Quit MacPulse")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
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
