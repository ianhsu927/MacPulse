import AppKit
import SwiftUI

/// The status item keeps a constant size as readings and their units change.
/// A template image lets AppKit choose the native menu-bar foreground color.
struct MenuBarLabel: View {
    let cpuTemperatureCelsius: Double?
    let receivedBytesPerSecond: Double?
    let sentBytesPerSecond: Double?
    let accessibilityDescription: String

    var body: some View {
        Image(nsImage: MenuBarImage.make(
            temperature: cpuTemperatureCelsius,
            received: receivedBytesPerSecond,
            sent: sentBytesPerSecond
        ))
        .renderingMode(.template)
        .accessibilityLabel(Text(accessibilityDescription))
        .help(accessibilityDescription)
    }
}

enum MenuBarFormat {
    static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite, (0...150).contains(celsius) else { return "—°C" }
        return "\(Int(celsius.rounded()))°C"
    }

    /// K/M/G abbreviate binary byte units here; the open menu uses KiB/s etc.
    static func compactRate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        // Rounded text must not show "1024B/s" at a unit boundary.
        if value.rounded() >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == units.count - 1, value > 999 { return ">999\(units[index])/s" }
        let number = String(format: value >= 10 ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        let compact = number.hasSuffix(".0") ? String(number.dropLast(2)) : number
        return "\(compact)\(units[index])/s"
    }

    static func fullRate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "— B/s" }
        let number = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), bytesPerSecond)
        return "\(number.hasSuffix(".0") ? String(number.dropLast(2)) : number) B/s"
    }
}

enum MenuBarImage {
    static let size = NSSize(width: 148, height: 22)

    static func make(temperature: Double?, received: Double?, sent: Double?) -> NSImage {
        let temperatureText = "CPU \(MenuBarFormat.temperature(temperature))" as NSString
        let receiveText = "↓ \(MenuBarFormat.compactRate(received))" as NSString
        let sendText = "↑ \(MenuBarFormat.compactRate(sent))" as NSString
        let temperatureFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let image = NSImage(size: size, flipped: false) { _ in
            let temperatureStyle = NSMutableParagraphStyle()
            temperatureStyle.alignment = .left
            temperatureStyle.lineBreakMode = .byClipping
            temperatureText.draw(in: NSRect(x: 0, y: 3.5, width: 76, height: 15), withAttributes: [
                .font: temperatureFont, .foregroundColor: NSColor.black, .paragraphStyle: temperatureStyle
            ])

            NSColor.black.withAlphaComponent(0.22).setFill()
            NSRect(x: 77, y: 3, width: 0.5, height: 16).fill()
            let rateStyle = NSMutableParagraphStyle()
            rateStyle.alignment = .left
            rateStyle.lineBreakMode = .byClipping
            let rateAttributes: [NSAttributedString.Key: Any] = [
                .font: rateFont, .foregroundColor: NSColor.black, .paragraphStyle: rateStyle
            ]
            receiveText.draw(in: NSRect(x: 83, y: 11, width: 65, height: 11), withAttributes: rateAttributes)
            sendText.draw(in: NSRect(x: 83, y: 0, width: 65, height: 11), withAttributes: rateAttributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}
