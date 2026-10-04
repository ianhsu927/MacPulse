import AppKit
#if MENUBAR_SELFTEST
@main
struct MenuBarSelfTest {
    static func main() {
        for value in [Double?.none, .some(.nan), .some(.infinity), .some(-1)] {
            precondition(MenuBarFormat.compactRate(value) == "—")
            precondition(MenuBarFormat.fullRate(value) == "— B/s")
        }
        precondition(MenuBarFormat.compactRate(0) == "0B/s")
        precondition(MenuBarFormat.temperature(nil) == "—°C")
        precondition(MenuBarFormat.temperature(.nan) == "—°C")
        precondition(MenuBarFormat.temperature(0) == "0°C")
        precondition(MenuBarFormat.temperature(52.4) == "52°C")
        precondition(MenuBarFormat.compactRate(1023) == "1023B/s")
        precondition(MenuBarFormat.compactRate(1023.5) == "1K/s")
        precondition(MenuBarFormat.compactRate(1024) == "1K/s")
        precondition(MenuBarFormat.compactRate(122_880) == "120K/s")
        precondition(MenuBarFormat.compactRate(1_048_576) == "1M/s")
        precondition(MenuBarFormat.compactRate(9.5 * 1_048_576) == "9.5M/s")
        precondition(MenuBarFormat.fullRate(122_880) == "122880 B/s")
        precondition(MenuBarFormat.compactRate(.greatestFiniteMagnitude) == ">999E/s")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        for rate in [0.0, 1023, 122_880, Double.greatestFiniteMagnitude] {
            let text = "↓ \(MenuBarFormat.compactRate(rate))" as NSString
            precondition(text.size(withAttributes: [.font: font]).width <= 65)
        }
        let temperatureText = "CPU 150°C" as NSString
        precondition(temperatureText.size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ]).width <= 76)
        let unavailable = MenuBarImage.make(temperature: nil, received: nil, sent: nil)
        let busy = MenuBarImage.make(temperature: 150, received: .greatestFiniteMagnitude, sent: 122_880)
        precondition(unavailable.size == NSSize(width: 148, height: 22))
        precondition(busy.size == unavailable.size)
        precondition(unavailable.isTemplate && busy.isTemplate)
        precondition(unavailable.tiffRepresentation != nil && busy.tiffRepresentation != nil)
        print("Menu-bar checks passed (missing values, binary units, accessible B/s, actual text widths, fixed template rendering)")
    }
}
#else
import XCTest
@testable import MacPulse

final class MenuBarFormatTests: XCTestCase {
    func testUnavailableReadingsStayDistinctFromRealZero() {
        for value in [Double?.none, .some(.nan), .some(.infinity), .some(-1)] {
            XCTAssertEqual(MenuBarFormat.compactRate(value), "—")
            XCTAssertEqual(MenuBarFormat.fullRate(value), "— B/s")
        }
        XCTAssertEqual(MenuBarFormat.compactRate(0), "0B/s")
        XCTAssertEqual(MenuBarFormat.temperature(nil), "—°C")
        XCTAssertEqual(MenuBarFormat.temperature(.nan), "—°C")
        XCTAssertEqual(MenuBarFormat.temperature(0), "0°C")
        XCTAssertEqual(MenuBarFormat.temperature(52.4), "52°C")
    }

    func testBinaryUnitsRoundAtTheirBoundary() {
        XCTAssertEqual(MenuBarFormat.compactRate(1023), "1023B/s")
        XCTAssertEqual(MenuBarFormat.compactRate(1023.5), "1K/s")
        XCTAssertEqual(MenuBarFormat.compactRate(1024), "1K/s")
        XCTAssertEqual(MenuBarFormat.compactRate(122_880), "120K/s")
        XCTAssertEqual(MenuBarFormat.compactRate(1_048_576), "1M/s")
        XCTAssertEqual(MenuBarFormat.compactRate(9.5 * 1_048_576), "9.5M/s")
        XCTAssertEqual(MenuBarFormat.fullRate(122_880), "122880 B/s")
    }

    func testExtremeFiniteRatesCannotOverflowTheCompactLabel() {
        let value = MenuBarFormat.compactRate(.greatestFiniteMagnitude)
        XCTAssertEqual(value, ">999E/s")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        for rate in [0.0, 1023, 122_880, Double.greatestFiniteMagnitude] {
            let text = "↓ \(MenuBarFormat.compactRate(rate))" as NSString
            XCTAssertLessThanOrEqual(text.size(withAttributes: [.font: font]).width, 65)
        }
    }

    func testImageSizeAndTemplateColorDoNotChangeWithReadings() {
        let unavailable = MenuBarImage.make(temperature: nil, received: nil, sent: nil)
        let busy = MenuBarImage.make(temperature: 150, received: .greatestFiniteMagnitude, sent: 122_880)
        XCTAssertEqual(unavailable.size, NSSize(width: 148, height: 22))
        XCTAssertEqual(busy.size, unavailable.size)
        XCTAssertTrue(unavailable.isTemplate)
        XCTAssertTrue(busy.isTemplate)
    }
}
#endif
