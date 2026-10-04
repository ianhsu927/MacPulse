import Foundation
#if TELEMETRY_PROBE || TELEMETRY_SELFTEST
@main
struct TelemetryProbe {
    static func main() throws {
        try checkMath()
        #if TELEMETRY_PROBE
        let sampler = TelemetrySampler()
        print("chip=\(sampler.chipName), sensor=\(sampler.hasFrequencySensor), status=\(sampler.frequencyStatus)")
        sampler.resetBaseline()
        let baseline = sampler.sample()
        precondition(baseline.efficiencyMHz == nil && baseline.performanceMHz == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 1)
            let sample = sampler.sample()
            print(String(data: try encoder.encode(sample), encoding: .utf8)!)
        }
        #endif
    }

    static func checkMath() throws {
        precondition(TelemetryMath.cpuUsage(previous: [0, 0, 0, 0], current: [20, 10, 60, 10]) == 40)
        precondition(TelemetryMath.cpuUsage(previous: [.max - 4, 0, 0, 0], current: [5, 0, 10, 0]) == 50)
        precondition(TelemetryMath.cpuUsage(previous: [1, 1, 1, 1], current: [1, 1, 1, 1]) == 0)
        precondition(TelemetryMath.memoryUsed(internalPages: 100, purgeablePages: 20, wiredPages: 10,
                                             compressedPages: 5, pageSize: 16384, totalBytes: 1e9) == 95 * 16384)
        precondition(TelemetryMath.memoryUsed(internalPages: 10, purgeablePages: 20, wiredPages: 5,
                                             compressedPages: 5, pageSize: 4096, totalBytes: 20000) == 20000)
        func records(_ values: [UInt32]) -> Data {
            var data = Data()
            for value in values {
                let pair = [value.littleEndian, UInt32(700).littleEndian]
                pair.withUnsafeBytes { data.append(contentsOf: $0) }
            }
            return data
        }
        precondition(TelemetryMath.voltageFrequencies(records([0, 600_000_000, 2_064_000_000])) == [600, 2064])
        precondition(TelemetryMath.voltageFrequencies(records([1_312_000, 1_242_000, 1_380_000])) == [1312, 1242, 1380])
        precondition(TelemetryMath.voltageFrequencies(Data([0, 1, 2])) == nil)
        precondition(TelemetryMath.voltageFrequencies(records([1])) == nil)
        let weighted = TelemetryMath.weightedFrequency(names: ["IDLE", "P1", "P2"], residencies: [900, 75, 25], frequencies: [600, 2400])!
        precondition(weighted.weighted / weighted.active == 1050)
        precondition(TelemetryMath.weightedFrequency(names: ["IDLE", "P1", "P2"], residencies: [10, 1, 1], frequencies: [600]) == nil)
        precondition(TelemetryMath.weightedFrequency(names: ["IDLE", "P1"], residencies: [100, 0], frequencies: [600])?.active == 0)
        precondition(TelemetryMath.isClusterName("PCPU1", prefix: "PCPU"))
        precondition(!TelemetryMath.isClusterName("MCPM0", prefix: "MCPU"))
        precondition(!TelemetryMath.isClusterName("PCPU_IDLE", prefix: "PCPU"))
        let oldSample = "{\"timestamp\":0,\"cpuUsagePercent\":10,\"memoryUsedBytes\":100,\"memoryTotalBytes\":200,\"swapUsedBytes\":0,\"frequencySource\":\"unavailable\"}"
        let decoded = try JSONDecoder().decode(MetricSample.self, from: Data(oldSample.utf8))
        precondition(decoded.chartSegment == nil && decoded.efficiencyMHz == nil && decoded.performanceMHz == nil)
        print("Telemetry math checks passed (16 assertions)")
    }
}
#else
import XCTest
@testable import MacPulse

final class TelemetryTests: XCTestCase {
    func testCPUUsageIncludesNiceButExcludesIdleAndHandlesCounterWrap() {
        XCTAssertEqual(TelemetryMath.cpuUsage(previous: [0, 0, 0, 0], current: [20, 10, 60, 10]), 40, accuracy: 0.00001)
        XCTAssertEqual(TelemetryMath.cpuUsage(previous: [.max - 4, 0, 0, 0], current: [5, 0, 10, 0]), 50, accuracy: 0.00001)
        XCTAssertEqual(TelemetryMath.cpuUsage(previous: [1, 1, 1, 1], current: [1, 1, 1, 1]), 0)
    }

    func testMemoryUsedExcludesPurgeableAndCountsPhysicalCompressedStorage() {
        XCTAssertEqual(TelemetryMath.memoryUsed(internalPages: 100, purgeablePages: 20, wiredPages: 10,
                                               compressedPages: 5, pageSize: 16384, totalBytes: 1e9), 95 * 16384)
        XCTAssertEqual(TelemetryMath.memoryUsed(internalPages: 10, purgeablePages: 20, wiredPages: 5,
                                               compressedPages: 5, pageSize: 4096, totalBytes: 20000), 20000)
    }

    func testVoltageTablesDecodeHzAndKHzWithoutReorderingStates() {
        func data(_ values: [UInt32]) -> Data {
            var bytes = Data()
            for value in values {
                var frequency = value.littleEndian
                var voltage: UInt32 = 700
                withUnsafeBytes(of: &frequency) { bytes.append(contentsOf: $0) }
                withUnsafeBytes(of: &voltage) { bytes.append(contentsOf: $0) }
            }
            return bytes
        }
        XCTAssertEqual(TelemetryMath.voltageFrequencies(data([0, 600_000_000, 2_064_000_000])), [600, 2064])
        XCTAssertEqual(TelemetryMath.voltageFrequencies(data([1_312_000, 1_242_000, 1_380_000])), [1312, 1242, 1380])
        XCTAssertNil(TelemetryMath.voltageFrequencies(Data([0, 1, 2])))
        XCTAssertNil(TelemetryMath.voltageFrequencies(data([1])))
    }

    func testActiveFrequencyExcludesIdleAndRejectsMismatchedTables() {
        let value = TelemetryMath.weightedFrequency(names: ["IDLE", "P1", "P2"], residencies: [900, 75, 25], frequencies: [600, 2400])
        XCTAssertEqual(value!.weighted / value!.active, 1050, accuracy: 0.00001)
        XCTAssertNil(TelemetryMath.weightedFrequency(names: ["IDLE", "P1", "P2"], residencies: [10, 1, 1], frequencies: [600]))
        let idle = TelemetryMath.weightedFrequency(names: ["IDLE", "P1"], residencies: [100, 0], frequencies: [600])
        XCTAssertEqual(idle?.active, 0)
    }

    func testFabricAndCompanionChannelsCannotBeMistakenForCPUClusters() {
        XCTAssertTrue(TelemetryMath.isClusterName("PCPU1", prefix: "PCPU"))
        XCTAssertTrue(TelemetryMath.isClusterName("MCPU0", prefix: "MCPU"))
        XCTAssertFalse(TelemetryMath.isClusterName("PCPU_IDLE", prefix: "PCPU"))
        XCTAssertFalse(TelemetryMath.isClusterName("MCPM0", prefix: "MCPU"))
    }
}
#endif
