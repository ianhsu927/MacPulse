import Foundation
import XCTest
@testable import MacPulse

final class PresentationTests: XCTestCase {
    func testMissingFrequenciesAreNotRenderedAsZero() {
        XCTAssertEqual(MetricFormat.frequency(nil), "—")
        XCTAssertEqual(MetricFormat.frequency(2400), "2.40")
        XCTAssertEqual(MetricFormat.frequency(0), "0.00")
    }
    func testMemoryUsesBinaryUnits() {
        XCTAssertEqual(MetricFormat.gibibytes(34_359_738_368), "32.0")
    }
    func testRatesUseBytesPerSecondAndPreserveMissingValues() {
        XCTAssertEqual(MetricFormat.rate(nil).value, "—")
        XCTAssertEqual(MetricFormat.rate(0).unit, "B/s")
        XCTAssertEqual(MetricFormat.rate(1024).unit, "KiB/s")
        XCTAssertEqual(MetricFormat.rate(1_048_576).value, "1.0")
        XCTAssertEqual(MetricFormat.rate(1_048_576).unit, "MiB/s")
    }
    func testRangesRemainWithinRetention() {
        XCTAssertEqual(HistoryRange.week.seconds, 7 * 86400)
        XCTAssertTrue(HistoryRange.allCases.allSatisfy { $0.seconds > 0 && $0.seconds <= 7 * 86400 })
    }
}
