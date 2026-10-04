import Foundation
import SQLite3
import XCTest
@testable import MacPulse

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPulse-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testOriginalMeasurementsPersistAfterReopening() throws {
        let timestamp = Date().addingTimeInterval(-30)
        var firstStore: HistoryStore? = try HistoryStore(directory: directory)
        try firstStore?.append(sample(at: timestamp, cpu: 28, efficiency: 1_200, performance: 2_600))
        firstStore = nil
        let reopened = try HistoryStore(directory: directory)
        XCTAssertEqual(try reopened.count(), 1)
        let latest = try XCTUnwrap(reopened.latest())
        XCTAssertEqual(latest.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(latest.cpuUsagePercent, 28)
        XCTAssertEqual(latest.memoryUsedBytes, 4_000_000_000)
        XCTAssertEqual(latest.memoryTotalBytes, 16_000_000_000)
        XCTAssertEqual(latest.swapUsedBytes, 128_000_000)
        XCTAssertEqual(latest.efficiencyMHz, 1_200)
        XCTAssertEqual(latest.performanceMHz, 2_600)
    }

    func testExpiredHistoryIsPurgedOnOpenAndCannotBeReintroduced() throws {
        let now = Date()
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let databaseURL = try XCTUnwrap(store?.databaseURL)
        try store?.append(sample(at: now.addingTimeInterval(-60)))
        store = nil
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let expired = now.addingTimeInterval(-8 * 24 * 60 * 60).timeIntervalSince1970
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO samples (timestamp, cpu_usage_percent, memory_used_bytes, memory_total_bytes, swap_used_bytes, efficiency_mhz, performance_mhz, frequency_source) VALUES (\(expired), 1, 1, 2, 0, NULL, NULL, 'old');", nil, nil, nil), SQLITE_OK)

        let reopened = try HistoryStore(directory: directory)
        XCTAssertEqual(try reopened.count(), 1)
        try reopened.append(sample(at: now.addingTimeInterval(-HistoryStore.retentionInterval - 10)))
        XCTAssertEqual(try reopened.count(), 1)
    }

    func testNilFrequenciesStayNilAndPartialFrequencyRemainsAvailable() throws {
        let store = try HistoryStore(directory: directory)
        let start = Date().addingTimeInterval(-100)
        try store.append(sample(at: start))
        try store.append(sample(at: start.addingTimeInterval(1), performance: 2_500))
        let originals = try store.samples(since: start, limit: 10)
        XCTAssertNil(originals[0].efficiencyMHz)
        XCTAssertNil(originals[0].performanceMHz)
        XCTAssertNil(originals[1].efficiencyMHz)
        XCTAssertEqual(originals[1].performanceMHz, 2_500)
        let averaged = try XCTUnwrap(store.samples(since: start, limit: 1).first)
        XCTAssertNil(averaged.efficiencyMHz)
        XCTAssertEqual(averaged.performanceMHz, 2_500)
    }

    func testRangeQueryAndDownsamplingAreBoundedAndPreserveMean() throws {
        let store = try HistoryStore(directory: directory)
        let start = Date().addingTimeInterval(-2_000)
        for index in 0..<1_000 {
            try store.append(sample(at: start.addingTimeInterval(Double(index)), cpu: Double(index)))
        }
        let originals = try store.samples(since: start.addingTimeInterval(100), until: start.addingTimeInterval(199))
        XCTAssertEqual(originals.count, 100)
        XCTAssertEqual(originals.first?.cpuUsagePercent, 100)
        XCTAssertEqual(originals.last?.cpuUsagePercent, 199)
        let averaged = try store.samples(since: start, until: start.addingTimeInterval(999), limit: 10)
        XCTAssertEqual(averaged.count, 10)
        XCTAssertEqual(averaged.map(\.cpuUsagePercent).reduce(0, +) / 10, 499.5, accuracy: 0.000_001)
        XCTAssertTrue(zip(averaged, averaged.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        XCTAssertTrue(averaged.allSatisfy { $0.timestamp >= start && $0.timestamp <= start.addingTimeInterval(999) })
        XCTAssertEqual(try store.count(), 1_000, "A chart query must not discard original rows")
        XCTAssertTrue(try store.samples(since: start, limit: 0).isEmpty)
        XCTAssertTrue(try store.samples(since: Date(), until: start).isEmpty)
    }

    func testDownsamplingLeavesLargeRecordingGapsEmpty() throws {
        let store = try HistoryStore(directory: directory)
        let start = Date().addingTimeInterval(-2_000)
        for index in 0..<100 {
            try store.append(sample(at: start.addingTimeInterval(Double(index))))
            try store.append(sample(at: start.addingTimeInterval(1_000 + Double(index))))
        }
        let result = try store.samples(since: start, limit: 20)
        XCTAssertLessThanOrEqual(result.count, 20)
        XCTAssertFalse(result.contains { $0.timestamp > start.addingTimeInterval(100) && $0.timestamp < start.addingTimeInterval(1_000) })
        let gaps = zip(result, result.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }
        XCTAssertGreaterThan(try XCTUnwrap(gaps.max()), 800)
    }

    func testDownsamplingDoesNotAverageAcrossGapInsideSingleBucket() throws {
        let store = try HistoryStore(directory: directory)
        let start = Date().addingTimeInterval(-500)
        for index in 0..<10 {
            try store.append(sample(at: start.addingTimeInterval(Double(index)), segment: 91))
            try store.append(sample(at: start.addingTimeInterval(120 + Double(index)), segment: 91))
        }
        let twoPoints = try store.samples(since: start, limit: 2)
        XCTAssertEqual(twoPoints.count, 2)
        XCTAssertEqual(twoPoints[0].chartSegment, 0)
        XCTAssertEqual(twoPoints[1].chartSegment, 1)
        XCTAssertLessThan(twoPoints[0].timestamp, start.addingTimeInterval(10))
        XCTAssertGreaterThan(twoPoints[1].timestamp, start.addingTimeInterval(120))
        let raw = try store.samples(since: start, limit: 100)
        XCTAssertEqual(raw[0].chartSegment, 0)
        XCTAssertEqual(raw[9].chartSegment, 0)
        XCTAssertEqual(raw[10].chartSegment, 1)
        XCTAssertEqual(raw[19].chartSegment, 1)
        let onePoint = try XCTUnwrap(store.samples(since: start, limit: 1).first)
        XCTAssertGreaterThan(onePoint.timestamp, start.addingTimeInterval(120))
    }

    func testCSVExportsEveryOriginalRowAndEscapesSource() throws {
        let store = try HistoryStore(directory: directory)
        let start = Date().addingTimeInterval(-3_000)
        for index in 0..<1_500 {
            let source = index == 0 ? "sensor, \"quoted\"\nnext" : "Unavailable"
            try store.append(sample(at: start.addingTimeInterval(Double(index)), source: source))
        }
        XCTAssertEqual(try store.samples(since: start, limit: 10).count, 10)
        let url = directory.appendingPathComponent("export.csv")
        try Data("previous output".utf8).write(to: url)
        try store.exportCSV(to: url, since: start)
        let text = try String(contentsOf: url, encoding: .utf8)
        let records = parseCSV(text)
        XCTAssertEqual(records.count, 1_501)
        XCTAssertEqual(records[0], csvHeader)
        XCTAssertEqual(records[1][7], "sensor, \"quoted\"\nnext")
        XCTAssertEqual(records[1][5], "")
        XCTAssertEqual(records[1][6], "")
        XCTAssertTrue(records[1][0].hasSuffix("Z"))
        XCTAssertEqual(records.last?[7], "Unavailable")
        XCTAssertTrue(records.allSatisfy { $0.count == 13 })
        XCTAssertEqual(Array(records[1][8...12]), ["", "", "", "", ""])
    }

    func testClearAndDuplicateTimestamp() throws {
        let store = try HistoryStore(directory: directory)
        let now = Date()
        try store.append(sample(at: now, cpu: 10))
        try store.append(sample(at: now, cpu: 20))
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.latest()?.cpuUsagePercent, 20)
        try store.clear()
        XCTAssertEqual(try store.count(), 0)
        XCTAssertNil(try store.latest())
    }

    func testCSVRespectsCapturedInclusiveRangeAndExcludesLaterSamples() throws {
        let store = try HistoryStore(directory: directory)
        let start = Date().addingTimeInterval(-20)
        for index in 0..<10 {
            try store.append(sample(at: start.addingTimeInterval(Double(index)), cpu: Double(index)))
        }
        let url = directory.appendingPathComponent("bounded.csv")
        try store.exportCSV(to: url, since: start.addingTimeInterval(2), until: start.addingTimeInterval(6))
        let exported = parseCSV(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(exported.count, 6)
        XCTAssertEqual(exported[0], csvHeader)
        XCTAssertEqual(exported.dropFirst().map { $0[1] }, ["2.0", "3.0", "4.0", "5.0", "6.0"])
        XCTAssertTrue(exported.allSatisfy { $0.count == 13 })
        XCTAssertEqual(try store.count(), 10)

        // A record whose timestamp is later than the export snapshot is kept
        // in history, but is never silently appended to that snapshot's CSV.
        let future = Date().addingTimeInterval(60)
        try store.append(sample(at: future, cpu: 99))
        try store.exportCSV(to: url, since: start)
        let current = parseCSV(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(current.count, 11)
        XCTAssertFalse(current.dropFirst().contains { $0[1] == "99.0" })
        try store.exportCSV(to: url, since: start, until: future)
        let explicit = parseCSV(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(explicit.count, 12)
        XCTAssertEqual(explicit.last?[1], "99.0")
    }

    func testVersionOneMigrationPreservesOriginalRowsAndIsIdempotent() throws {
        let start = Date().addingTimeInterval(-200)
        try createVersionOneFixture(start: start)
        var store: HistoryStore? = try HistoryStore(directory: directory)
        XCTAssertEqual(try store?.count(), 2)
        let originals = try XCTUnwrap(store?.samples(since: start, limit: 10))
        XCTAssertEqual(originals[0].cpuUsagePercent, 17)
        XCTAssertEqual(originals[0].memoryUsedBytes, 1_024)
        XCTAssertEqual(originals[0].memoryTotalBytes, 4_096)
        XCTAssertEqual(originals[0].swapUsedBytes, 64)
        XCTAssertEqual(originals[0].efficiencyMHz, 1_200)
        XCTAssertEqual(originals[0].performanceMHz, 2_400)
        XCTAssertEqual(originals[0].frequencySource, "legacy source")
        XCTAssertEqual(originals[1].cpuUsagePercent, 33)
        XCTAssertNil(originals[1].efficiencyMHz)
        XCTAssertNil(originals[1].performanceMHz)
        for sample in originals {
            XCTAssertNil(sample.gpuUsagePercent)
            XCTAssertNil(sample.networkReceivedBytesPerSecond)
            XCTAssertNil(sample.networkSentBytesPerSecond)
            XCTAssertNil(sample.gpuSource)
            XCTAssertNil(sample.networkSource)
        }
        let aggregate = try XCTUnwrap(store?.samples(since: start, limit: 1).first)
        XCTAssertNil(aggregate.gpuUsagePercent)
        XCTAssertNil(aggregate.networkReceivedBytesPerSecond)
        XCTAssertNil(aggregate.networkSentBytesPerSecond)
        XCTAssertNil(aggregate.gpuSource)
        XCTAssertNil(aggregate.networkSource)
        store = nil
        for _ in 0..<3 {
            let reopened = try HistoryStore(directory: directory)
            XCTAssertEqual(try reopened.count(), 2)
            XCTAssertEqual(try reopened.latest()?.frequencySource, "legacy missing frequency")
        }
        try inspectSchema { database in
            XCTAssertEqual(try scalar(database, sql: "PRAGMA user_version;"), 3)
            XCTAssertEqual(try scalar(database, sql: "SELECT COUNT(*) FROM pragma_table_info('samples');"), 14)
            XCTAssertEqual(try scalar(database, sql: "SELECT COUNT(*) FROM samples WHERE gpu_usage_percent IS NULL AND network_received_bytes_per_second IS NULL AND network_sent_bytes_per_second IS NULL;"), 2)
        }
    }

    func testPartialMigrationUsesActualColumnsAndPreservesExistingValues() throws {
        let start = Date().addingTimeInterval(-200)
        try createVersionOneFixture(start: start, partiallyMigrated: true)
        let store = try HistoryStore(directory: directory)
        let originals = try store.samples(since: start)
        XCTAssertEqual(originals.count, 2)
        XCTAssertEqual(originals[0].networkSource, "partial source")
        XCTAssertNil(originals[0].networkReceivedBytesPerSecond)
        XCTAssertNil(originals[0].gpuUsagePercent)
        let added = sample(at: start.addingTimeInterval(2), gpu: 42, received: 256, sent: 128,
                           gpuSource: "gpu", networkSource: "interface")
        try store.append(added)
        let latest = try XCTUnwrap(store.latest())
        XCTAssertEqual(latest.gpuUsagePercent, 42)
        XCTAssertEqual(latest.networkReceivedBytesPerSecond, 256)
        XCTAssertEqual(latest.networkSentBytesPerSecond, 128)
        XCTAssertEqual(latest.gpuSource, "gpu")
        XCTAssertEqual(latest.networkSource, "interface")
        try inspectSchema { database in
            XCTAssertEqual(try scalar(database, sql: "PRAGMA user_version;"), 3)
            XCTAssertEqual(try scalar(database, sql: "SELECT COUNT(*) FROM pragma_table_info('samples');"), 14)
        }
    }

    func testGPUAndNetworkPersistAggregateAndExportWithExplicitUnits() throws {
        let start = Date().addingTimeInterval(-200)
        try createVersionOneFixture(start: start)
        let gpuSource = "IOKit, \"busy\"\nnext"
        let networkSource = "en0, \"Wi-Fi\"\r\nphysical"
        var store: HistoryStore? = try HistoryStore(directory: directory)
        try store?.append(sample(at: start.addingTimeInterval(2), gpu: 25, received: 1_024, sent: 512,
                                 gpuSource: gpuSource, networkSource: networkSource))
        try store?.append(sample(at: start.addingTimeInterval(3), gpu: 75, received: 3_072,
                                 gpuSource: "IOReport", networkSource: networkSource))
        store = nil
        let reopened = try HistoryStore(directory: directory)
        let rows = try reopened.samples(since: start)
        XCTAssertEqual(rows.count, 4)
        XCTAssertNil(rows[0].gpuUsagePercent)
        XCTAssertEqual(rows[2].gpuUsagePercent, 25)
        XCTAssertEqual(rows[2].networkReceivedBytesPerSecond, 1_024)
        XCTAssertEqual(rows[2].networkSentBytesPerSecond, 512)
        XCTAssertEqual(rows[2].gpuSource, gpuSource)
        XCTAssertEqual(rows[2].networkSource, networkSource)
        let latest = try XCTUnwrap(reopened.latest())
        XCTAssertEqual(latest.gpuUsagePercent, 75)
        XCTAssertEqual(latest.networkReceivedBytesPerSecond, 3_072)
        XCTAssertNil(latest.networkSentBytesPerSecond)
        let averaged = try XCTUnwrap(reopened.samples(since: start, limit: 1).first)
        XCTAssertNil(averaged.gpuUsagePercent)
        XCTAssertNil(averaged.networkReceivedBytesPerSecond)
        XCTAssertNil(averaged.networkSentBytesPerSecond)
        XCTAssertEqual(averaged.gpuSource, "聚合采样")
        XCTAssertEqual(averaged.networkSource, networkSource)
        let validOnly = try XCTUnwrap(reopened.samples(since: start.addingTimeInterval(2), limit: 1).first)
        XCTAssertEqual(validOnly.gpuUsagePercent, 50)
        XCTAssertEqual(validOnly.networkReceivedBytesPerSecond, 2_048)
        XCTAssertNil(validOnly.networkSentBytesPerSecond)
        let url = directory.appendingPathComponent("gpu-network.csv")
        try reopened.exportCSV(to: url, since: start)
        let csv = parseCSV(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(csv.count, 5)
        XCTAssertEqual(csv[0], csvHeader)
        XCTAssertTrue(csv.allSatisfy { $0.count == 13 })
        XCTAssertEqual(Array(csv[1][8...12]), ["", "", "", "", ""])
        XCTAssertEqual(Array(csv[3][8...12]), ["25.0", "1024.0", "512.0", gpuSource, networkSource])
        XCTAssertEqual(csv[4][10], "")
        XCTAssertEqual(csv[4][11], "IOReport")
    }

    func testDownsamplingPreservesIndependentMissingGPUAndNetworkBuckets() throws {
        let store = try HistoryStore(directory: directory)
        let start = Date().addingTimeInterval(-200)
        for index in 0..<20 {
            try store.append(sample(at: start.addingTimeInterval(Double(index)), cpu: Double(index),
                                    gpu: index == 10 ? nil : Double(index),
                                    received: index == 6 ? nil : Double(index * 100),
                                    sent: Double(index * 10), gpuSource: "gpu", networkSource: "network"))
        }
        let points = try store.samples(since: start, until: start.addingTimeInterval(19), limit: 4)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points[0].gpuUsagePercent, 2)
        XCTAssertEqual(points[1].gpuUsagePercent, 7)
        XCTAssertNil(points[2].gpuUsagePercent)
        XCTAssertEqual(points[3].gpuUsagePercent, 17)
        XCTAssertEqual(points[0].networkReceivedBytesPerSecond, 200)
        XCTAssertNil(points[1].networkReceivedBytesPerSecond)
        XCTAssertEqual(points[2].networkReceivedBytesPerSecond, 1_200)
        XCTAssertEqual(points[3].networkReceivedBytesPerSecond, 1_700)
        XCTAssertEqual(points[0].networkSentBytesPerSecond, 20)
        XCTAssertEqual(points[3].networkSentBytesPerSecond, 170)
        XCTAssertEqual(points.map(\.cpuUsagePercent).reduce(0, +) / 4, 9.5)
        XCTAssertEqual(try store.count(), 20)
        let plotted = ChartSeries.points(points)
        XCTAssertEqual(plotted[0].gpuSegment, plotted[1].gpuSegment)
        XCTAssertFalse(plotted[1].gpuSegment == plotted[3].gpuSegment)
        XCTAssertFalse(plotted[0].receivedSegment == plotted[2].receivedSegment)
        XCTAssertEqual(plotted[0].sentSegment, plotted[3].sentSegment)
        XCTAssertEqual(plotted[0].memorySegment, plotted[3].memorySegment)
    }

    func testInvalidGPUAndNetworkMeasurementsAreRejected() throws {
        let store = try HistoryStore(directory: directory)
        let now = Date()
        let invalid = [
            sample(at: now, gpu: .nan), sample(at: now, gpu: .infinity),
            sample(at: now, gpu: -1), sample(at: now, gpu: 101),
            sample(at: now, received: .nan), sample(at: now, received: .infinity),
            sample(at: now, received: -1), sample(at: now, sent: .nan),
            sample(at: now, sent: -.infinity), sample(at: now, sent: -1),
            sample(at: now, cpu: .nan), sample(at: Date(timeIntervalSince1970: .nan))
        ]
        for measurement in invalid {
            var rejected = false
            do { try store.append(measurement) } catch { rejected = true }
            XCTAssertTrue(rejected)
        }
        XCTAssertEqual(try store.count(), 0)
        try store.append(sample(at: now, gpu: 0, received: 0, sent: 0))
        let zero = try XCTUnwrap(store.latest())
        XCTAssertEqual(zero.gpuUsagePercent, 0)
        XCTAssertEqual(zero.networkReceivedBytesPerSecond, 0)
        XCTAssertEqual(zero.networkSentBytesPerSecond, 0)
    }

    func testVersionTwoMigrationPreservesMetricsAndSeparatesUpgradeBoundary() throws {
        let start = Date().addingTimeInterval(-200)
        try createVersionOneFixture(start: start)
        try inspectSchema { database in
            let sql = """
                ALTER TABLE samples ADD COLUMN gpu_usage_percent REAL;
                ALTER TABLE samples ADD COLUMN network_received_bytes_per_second REAL;
                ALTER TABLE samples ADD COLUMN network_sent_bytes_per_second REAL;
                ALTER TABLE samples ADD COLUMN gpu_source TEXT;
                ALTER TABLE samples ADD COLUMN network_source TEXT;
                UPDATE samples SET gpu_usage_percent=27, network_received_bytes_per_second=1024,
                    network_sent_bytes_per_second=512, gpu_source='legacy GPU', network_source='en0';
                PRAGMA user_version=2;
                """
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        var store: HistoryStore? = try HistoryStore(directory: directory)
        XCTAssertNil(try store?.latest()?.chartSegment)
        try store?.append(sample(at: start.addingTimeInterval(3), segment: 101))
        XCTAssertEqual(try store?.latest()?.chartSegment, 101)
        store = nil
        let reopened = try HistoryStore(directory: directory)
        let rows = try reopened.samples(since: start)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].gpuUsagePercent, 27)
        XCTAssertEqual(rows[0].networkReceivedBytesPerSecond, 1024)
        XCTAssertEqual(rows[0].networkSentBytesPerSecond, 512)
        XCTAssertEqual(rows[0].gpuSource, "legacy GPU")
        XCTAssertEqual(rows[0].networkSource, "en0")
        XCTAssertEqual(rows[0].frequencySource, "legacy source")
        XCTAssertEqual(rows[0].chartSegment, rows[1].chartSegment)
        XCTAssertFalse(rows[1].chartSegment == rows[2].chartSegment)
        XCTAssertNil(ChartSeries.nearestRecordedSample(to: start.addingTimeInterval(2), in: rows))
        try inspectSchema { database in
            XCTAssertEqual(try scalar(database, sql: "PRAGMA user_version;"), 3)
            XCTAssertEqual(try scalar(database, sql: "SELECT COUNT(*) FROM samples WHERE recording_segment IS NULL;"), 2)
        }
        let url = directory.appendingPathComponent("v3.csv")
        try reopened.exportCSV(to: url, since: start)
        let exported = parseCSV(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(exported.count, 4)
        XCTAssertTrue(exported.allSatisfy { $0.count == 13 })
        XCTAssertEqual(exported[0], csvHeader)
    }

    func testShortPauseSessionsStaySeparatedAfterReopeningAndDownsampling() throws {
        let start = Date().addingTimeInterval(-200)
        var store: HistoryStore? = try HistoryStore(directory: directory)
        for (offset, segment) in [(0, 41), (1, 41), (4, 42), (5, 42), (16, 43), (17, 43)] {
            try store?.append(sample(at: start.addingTimeInterval(Double(offset)), performance: 2400,
                                     gpu: 30, received: 100, sent: 50, segment: segment))
        }
        store = nil
        let reopened = try HistoryStore(directory: directory)
        let raw = try reopened.samples(since: start, limit: 100)
        XCTAssertEqual(raw.map(\.chartSegment), [0, 0, 1, 1, 2, 2])
        XCTAssertNil(ChartSeries.nearestRecordedSample(to: start.addingTimeInterval(2), in: raw))
        XCTAssertNil(ChartSeries.nearestRecordedSample(to: start.addingTimeInterval(10), in: raw))
        let averaged = try reopened.samples(since: start, limit: 3)
        XCTAssertEqual(averaged.count, 3)
        XCTAssertEqual(averaged.map(\.chartSegment), [0, 1, 2])
        XCTAssertEqual(averaged[0].timestamp.timeIntervalSince(start), 0.5, accuracy: 0.000001)
        XCTAssertEqual(averaged[1].timestamp.timeIntervalSince(start), 4.5, accuracy: 0.000001)
        XCTAssertEqual(averaged[2].timestamp.timeIntervalSince(start), 16.5, accuracy: 0.000001)
        let plotted = ChartSeries.points(averaged)
        XCTAssertFalse(plotted[0].memorySegment == plotted[1].memorySegment)
        XCTAssertFalse(plotted[1].memorySegment == plotted[2].memorySegment)
        XCTAssertFalse(plotted[0].performanceSegment == plotted[1].performanceSegment)
        XCTAssertFalse(plotted[0].gpuSegment == plotted[1].gpuSegment)
        XCTAssertFalse(plotted[0].receivedSegment == plotted[1].receivedSegment)
        XCTAssertFalse(plotted[0].sentSegment == plotted[1].sentSegment)
        XCTAssertNil(ChartSeries.nearestRecordedSample(to: start.addingTimeInterval(3), in: averaged))
        XCTAssertNil(ChartSeries.nearestRecordedSample(to: start.addingTimeInterval(10), in: averaged))
    }

    private let csvHeader = ["timestamp_iso8601", "cpu_usage_percent", "memory_used_bytes", "memory_total_bytes",
                             "swap_used_bytes", "efficiency_mhz", "performance_mhz", "frequency_source",
                             "gpu_usage_percent", "network_received_bytes_per_second", "network_sent_bytes_per_second",
                             "gpu_source", "network_source"]

    private func createVersionOneFixture(start: Date, partiallyMigrated: Bool = false) throws {
        try inspectSchema { database in
            let sql = """
                CREATE TABLE samples (
                    timestamp REAL PRIMARY KEY NOT NULL, cpu_usage_percent REAL NOT NULL,
                    memory_used_bytes REAL NOT NULL, memory_total_bytes REAL NOT NULL,
                    swap_used_bytes REAL NOT NULL, efficiency_mhz REAL, performance_mhz REAL,
                    frequency_source TEXT NOT NULL
                );
                INSERT INTO samples VALUES (\(start.timeIntervalSince1970), 17, 1024, 4096, 64, 1200, 2400, 'legacy source');
                INSERT INTO samples VALUES (\(start.addingTimeInterval(1).timeIntervalSince1970), 33, 2048, 4096, 128, NULL, NULL, 'legacy missing frequency');
                PRAGMA user_version = 1;
                """
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
            if partiallyMigrated {
                // Add this column first, so physical column order differs from v2.
                XCTAssertEqual(sqlite3_exec(database, "ALTER TABLE samples ADD COLUMN network_source TEXT; UPDATE samples SET network_source = 'partial source';", nil, nil, nil), SQLITE_OK)
            }
        }
    }

    private func inspectSchema(_ body: (OpaquePointer) throws -> Void) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close(opened) }
        try body(opened)
    }

    private func scalar(_ database: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        return Int(sqlite3_column_int64(prepared, 0))
    }

    private func sample(at timestamp: Date, cpu: Double = 20, efficiency: Double? = nil,
                        performance: Double? = nil, source: String = "Unavailable", gpu: Double? = nil,
                        received: Double? = nil, sent: Double? = nil,
                        gpuSource: String? = nil, networkSource: String? = nil,
                        segment: Int? = nil) -> MetricSample {
        MetricSample(timestamp: timestamp, cpuUsagePercent: cpu,
                     memoryUsedBytes: 4_000_000_000, memoryTotalBytes: 16_000_000_000,
                     swapUsedBytes: 128_000_000, efficiencyMHz: efficiency,
                     performanceMHz: performance, frequencySource: source, chartSegment: segment,
                     gpuUsagePercent: gpu, networkReceivedBytesPerSecond: received,
                     networkSentBytesPerSecond: sent, gpuSource: gpuSource, networkSource: networkSource)
    }

    /// A small independent CSV reader checks round-trip escaping and logical row count.
    private func parseCSV(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else { quoted.toggle() }
            } else if character == "," && !quoted {
                fields.append(field)
                field = ""
            } else if (character == "\r" || character == "\n" || character == "\r\n") && !quoted {
                if character == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" { index += 1 }
                fields.append(field)
                records.append(fields)
                fields = []
                field = ""
            } else { field.append(character) }
            index += 1
        }
        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            records.append(fields)
        }
        return records
    }
}
