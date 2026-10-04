import Foundation
#if TEMPERATURE_SELFTEST || TEMPERATURE_PROBE
@main
struct TemperatureProbe {
    static func main() {
        func floatBytes(_ value: Float) -> [UInt8] {
            let bits = value.bitPattern
            return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        }
        precondition(TemperatureMath.decodeCelsius(bytes: floatBytes(72.5), type: "flt ") == 72.5)
        precondition(TemperatureMath.decodeCelsius(bytes: [0x32, 0x80], type: "sp78") == 50.5)
        precondition(TemperatureMath.decodeCelsius(bytes: [0xff, 0x80], type: "sp78") == nil)
        precondition(TemperatureMath.decodeCelsius(bytes: floatBytes(.nan), type: "flt ") == nil)
        precondition(TemperatureMath.decodeCelsius(bytes: floatBytes(.infinity), type: "flt ") == nil)
        precondition(TemperatureMath.decodeCelsius(bytes: [0, 0, 0, 0], type: "flt ") == nil)
        precondition(TemperatureMath.decodeCelsius(bytes: floatBytes(150), type: "flt ") == nil)
        precondition(TemperatureMath.decodeCelsius(bytes: [0, 0, 0], type: "flt ") == nil)
        precondition(TemperatureMath.decodeCelsius(bytes: [0, 0, 0, 0], type: "ui32") == nil)
        let average = TemperatureMath.aggregate(["Te05": 40, "Tp01": 60, "bad": .nan])
        precondition(average.mean == 50 && average.maximum == 60)
        precondition(TemperatureMath.aggregate([:]).mean == nil)
        precondition(TemperatureMath.aggregate(["bad": 0]).maximum == nil)
        precondition(!TemperatureMath.cpuSensorKeys(chipName: "Apple M3 Max").contains("Tf24"))
        precondition(!TemperatureMath.cpuSensorKeys(chipName: "Apple M4").contains("Tg0G"))
        precondition(TemperatureMath.cpuSensorKeys(chipName: "Apple M40").isEmpty)
        precondition(TemperatureMath.cpuSensorKeys(chipName: "Intel Core i7").isEmpty)
        let request = SMCReadProtocol.request(key: "Te05", command: 5, size: 4)!
        precondition(request.count == 80 && Array(request.prefix(4)) == [0x35, 0x30, 0x65, 0x54])
        precondition(request[28] == 4 && request[42] == 5 && request[48...].allSatisfy { $0 == 0 })
        precondition(SMCReadProtocol.request(key: "Te05", command: 6) == nil)
        precondition(SMCReadProtocol.request(key: "Te0", command: 5) == nil)
        precondition(SMCReadProtocol.request(key: "Te05", command: 5, size: 33) == nil)
        var reply = [UInt8](repeating: 0, count: 80)
        precondition(SMCReadProtocol.acceptsReply(bytes: reply, size: 80, result: 0))
        precondition(!SMCReadProtocol.acceptsReply(bytes: reply, size: 79, result: 0))
        precondition(!SMCReadProtocol.acceptsReply(bytes: reply, size: 80, result: 1))
        reply[40] = 132
        precondition(!SMCReadProtocol.acceptsReply(bytes: reply, size: 80, result: 0))
        precondition(!SMCReadProtocol.acceptsReply(bytes: Array(reply.prefix(79)), size: 80, result: 0))
        print("Temperature checks passed (26 assertions)")
        #if TEMPERATURE_PROBE
        let sensor = CPUTemperatureSensor()
        print("chip=\(sensor.chipName)")
        for index in 0..<4 {
            if index == 2 { sensor.reset(); print("reset connection and sensor metadata") }
            let start = ProcessInfo.processInfo.systemUptime
            let reading = sensor.sample()
            let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
            print("mean=\(reading.temperatureCelsius as Any), max=\(reading.maximumCelsius as Any), count=\(reading.sensorCount), status=\(reading.status), values=\(reading.sensorValues), read_ms=\(duration)")
            Thread.sleep(forTimeInterval: 1)
        }
        #endif
    }
}
#else
import XCTest
@testable import MacPulse

final class TemperatureTests: XCTestCase {
    func testFloatAndSignedFixedPointDecodersRequireCorrectUnitsAndSize() {
        let bits = Float(72.5).bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        XCTAssertEqual(TemperatureMath.decodeCelsius(bytes: bytes, type: "flt "), 72.5)
        XCTAssertEqual(TemperatureMath.decodeCelsius(bytes: [0x32, 0x80], type: "sp78"), 50.5)
        XCTAssertNil(TemperatureMath.decodeCelsius(bytes: [0xff, 0x80], type: "sp78"))
        XCTAssertNil(TemperatureMath.decodeCelsius(bytes: [0, 0, 0], type: "flt "))
        XCTAssertNil(TemperatureMath.decodeCelsius(bytes: [0, 0, 0, 0], type: "ui32"))
    }

    func testInvalidValuesAndEmptyAggregationRemainUnavailable() {
        XCTAssertFalse(TemperatureMath.isValidCelsius(.nan))
        XCTAssertFalse(TemperatureMath.isValidCelsius(.infinity))
        XCTAssertFalse(TemperatureMath.isValidCelsius(0))
        XCTAssertFalse(TemperatureMath.isValidCelsius(150))
        XCTAssertNil(TemperatureMath.aggregate([:]).mean)
        let value = TemperatureMath.aggregate(["Te05": 40, "Tp01": 60, "invalid": .nan])
        XCTAssertEqual(value.mean, 50)
        XCTAssertEqual(value.maximum, 60)
    }

    func testCPUKeyMapsCannotIncludeGPUOrUnknownGenerationSensors() {
        XCTAssertFalse(TemperatureMath.cpuSensorKeys(chipName: "Apple M3 Max").contains("Tf24"))
        XCTAssertFalse(TemperatureMath.cpuSensorKeys(chipName: "Apple M4").contains("Tg0G"))
        XCTAssertEqual(TemperatureMath.cpuSensorKeys(chipName: "Apple M4").count, 12)
        XCTAssertTrue(TemperatureMath.cpuSensorKeys(chipName: "Apple M40").isEmpty)
        XCTAssertTrue(TemperatureMath.cpuSensorKeys(chipName: "Intel Core i7").isEmpty)
    }

    func testReadProtocolRejectsWritesAndFailedOrMalformedReplies() {
        let request = SMCReadProtocol.request(key: "Te05", command: 5, size: 4)!
        XCTAssertEqual(Array(request.prefix(4)), [0x35, 0x30, 0x65, 0x54])
        XCTAssertEqual(request[28], 4)
        XCTAssertEqual(request[42], 5)
        XCTAssertNil(SMCReadProtocol.request(key: "Te05", command: 6))
        XCTAssertNil(SMCReadProtocol.request(key: "Te05", command: 5, size: 33))
        XCTAssertNil(SMCReadProtocol.request(key: "Te0", command: 5))
        var reply = [UInt8](repeating: 0, count: 80)
        XCTAssertTrue(SMCReadProtocol.acceptsReply(bytes: reply, size: 80, result: 0))
        XCTAssertFalse(SMCReadProtocol.acceptsReply(bytes: reply, size: 79, result: 0))
        XCTAssertFalse(SMCReadProtocol.acceptsReply(bytes: reply, size: 80, result: 1))
        reply[40] = 132
        XCTAssertFalse(SMCReadProtocol.acceptsReply(bytes: reply, size: 80, result: 0))
    }
}
#endif
