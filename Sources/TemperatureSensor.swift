import Foundation
import Darwin
import IOKit

// Sensor-key attribution: the generation-specific CPU key facts below were
// checked against Stats' own sensor catalogue and independently read on M4.
// https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
// Stats explicitly describes these as CPU thermal zones, not individual cores:
// https://github.com/exelban/stats#sensors-show-incorrect-cpugpu-core-count
// The IOKit transport and decoder here are an independent, read-only implementation.
//
// MIT License (Stats sensor catalogue)
// Copyright (c) 2019 Serhiy Mytrovtsiy
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

struct CPUTemperatureReading: Sendable {
    /// Arithmetic mean of successfully read, identified CPU thermal-zone
    /// sensors. It is neither a per-core average nor a CPU-package junction.
    let temperatureCelsius: Double?
    let maximumCelsius: Double?
    let sensorValues: [String: Double]
    let source: String
    let status: String
    var sensorCount: Int { sensorValues.count }
    var sensorKeys: [String] { sensorValues.keys.sorted() }
}

/// A persistent, unprivileged AppleSMC connection. Only key metadata (command
/// 9) and sensor bytes (command 5) are read; no SMC write command is implemented.
final class CPUTemperatureSensor: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AppleSMCReadOnly?
    private var sensors = [String: SMCReadMetadata]()
    private var initializationStatus = "AppleSMC · 等待 CPU 传感器探测"
    private var nextDiscoveryUptime: TimeInterval?
    private var consecutiveReadFailures = 0
    private let cpuKeys: [String]
    let chipName: String

    init() {
        chipName = Self.readChipName()
        cpuKeys = TemperatureMath.cpuSensorKeys(chipName: chipName)
        discover(now: ProcessInfo.processInfo.systemUptime)
    }

    private func discover(now: TimeInterval) {
        consecutiveReadFailures = 0
        guard !cpuKeys.isEmpty else {
            reader = nil
            sensors = [:]
            nextDiscoveryUptime = nil
            initializationStatus = "CPU 温度不可用：当前芯片没有已确认的 CPU 传感器映射"
            return
        }
        do {
            let reader = try AppleSMCReadOnly()
            var sensors = [String: SMCReadMetadata]()
            for key in cpuKeys {
                if let metadata = try? reader.metadata(key: key),
                   TemperatureMath.supportsTemperature(type: metadata.type, byteCount: metadata.size) {
                    sensors[key] = metadata
                }
            }
            self.reader = sensors.isEmpty ? nil : reader
            self.sensors = sensors
            nextDiscoveryUptime = sensors.isEmpty ? now + 10 : nil
            initializationStatus = sensors.isEmpty
                ? "CPU 温度不可用：已确认的 CPU 传感器均不存在或无法读取；10 秒后重试"
                : "AppleSMC · CPU 热区传感器平均"
        } catch {
            reader = nil
            sensors = [:]
            nextDiscoveryUptime = now + 10
            initializationStatus = "CPU 温度不可用：\(error.localizedDescription)；10 秒后重试"
        }
    }

    func sample() -> CPUTemperatureReading {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let nextDiscoveryUptime, now >= nextDiscoveryUptime { discover(now: now) }
        guard let reader, !sensors.isEmpty else {
            return CPUTemperatureReading(temperatureCelsius: nil, maximumCelsius: nil,
                                         sensorValues: [:], source: "AppleSMC", status: initializationStatus)
        }
        var values = [String: Double]()
        for key in sensors.keys.sorted() {
            guard let metadata = sensors[key], let data = try? reader.read(key: key, metadata: metadata),
                  let temperature = TemperatureMath.decodeCelsius(bytes: data, type: metadata.type) else { continue }
            values[key] = temperature
        }
        let aggregate = TemperatureMath.aggregate(values)
        let status: String
        if values.isEmpty {
            consecutiveReadFailures += 1
            if consecutiveReadFailures >= 3 {
                self.reader = nil
                sensors.removeAll()
                nextDiscoveryUptime = ProcessInfo.processInfo.systemUptime + 10
                initializationStatus = "CPU 温度不可用：连续读取失败；10 秒后重新探测"
                status = initializationStatus
            } else {
                status = "CPU 温度不可用：传感器读取失败或返回无效值"
            }
        } else if values.count < sensors.count {
            consecutiveReadFailures = 0
            status = "AppleSMC · \(values.count)/\(sensors.count) 个可读 CPU 热区传感器平均（部分读取失败）"
        } else {
            consecutiveReadFailures = 0
            status = "AppleSMC · \(values.count) 个 CPU 热区传感器平均；最热 \(String(format: "%.1f", aggregate.maximum!)) °C"
        }
        return CPUTemperatureReading(temperatureCelsius: aggregate.mean, maximumCelsius: aggregate.maximum,
                                     sensorValues: values, source: "AppleSMC · CPU thermal-zone sensor mean", status: status)
    }

    func read() -> CPUTemperatureReading { sample() }

    /// Release the user-client and all metadata after sleep. The next sample
    /// opens a new connection and rediscovers readable CPU sensors.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        reader = nil
        sensors.removeAll()
        consecutiveReadFailures = 0
        nextDiscoveryUptime = cpuKeys.isEmpty ? nil : 0
        initializationStatus = cpuKeys.isEmpty
            ? "CPU 温度不可用：当前芯片没有已确认的 CPU 传感器映射"
            : "AppleSMC · 等待 CPU 传感器重新探测"
    }

    private static func readChipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 0, size < 1024 else { return "Unknown Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "Unknown Mac" }
        return String(cString: bytes)
    }
}

enum TemperatureMath {
    /// An explicit per-generation allowlist avoids guessing from a T-prefix.
    /// In particular, M3 uses both CPU Tf0*/Tf4* and GPU Tf2* keys.
    static func cpuSensorKeys(chipName: String) -> [String] {
        let words = chipName.split(separator: " ")
        guard words.count >= 2, words[0] == "Apple" else { return [] }
        switch words[1] {
        case "M1": return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case "M2": return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case "M3": return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case "M4": return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        case "M5": return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        default: return []
        }
    }

    static func supportsTemperature(type: String, byteCount: Int) -> Bool {
        (type == "flt " && byteCount == 4) || (type == "sp78" && byteCount == 2)
    }

    static func decodeCelsius(bytes: [UInt8], type: String) -> Double? {
        guard supportsTemperature(type: type, byteCount: bytes.count) else { return nil }
        let value: Double
        if type == "flt " {
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            value = Double(Float(bitPattern: bits))
        } else {
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            value = Double(Int16(bitPattern: raw)) / 256
        }
        return isValidCelsius(value) ? value : nil
    }

    static func isValidCelsius(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value < 150
    }

    static func aggregate(_ values: [String: Double]) -> (mean: Double?, maximum: Double?) {
        let valid = values.values.filter(isValidCelsius)
        guard !valid.isEmpty else { return (nil, nil) }
        return (valid.reduce(0, +) / Double(valid.count), valid.max())
    }
}

private struct SMCReadMetadata {
    let size: Int
    let type: String
}

private enum SMCReadError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let text): return text }
    }
}

private final class AppleSMCReadOnly {
    private let connection: io_connect_t

    init() throws {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else {
            throw SMCReadError.unavailable("系统没有提供 AppleSMC 服务")
        }
        defer { IOObjectRelease(iterator) }
        var opened: io_connect_t = 0
        var lastResult: kern_return_t = kIOReturnNotFound
        while opened == 0 {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS,
                  String(cString: name) == "AppleSMCKeysEndpoint" else { continue }
            var candidate: io_connect_t = 0
            lastResult = IOServiceOpen(service, mach_task_self_, 0, &candidate)
            if lastResult == KERN_SUCCESS, candidate != 0 { opened = candidate }
        }
        guard opened != 0 else {
            throw SMCReadError.unavailable("AppleSMC CPU 传感器不可访问（\(lastResult)）")
        }
        connection = opened
    }

    deinit { IOServiceClose(connection) }

    func metadata(key: String) throws -> SMCReadMetadata {
        let response = try request(key: key, command: 9)
        let size = Int(Self.readUInt32(response, offset: 28))
        let typeCode = Self.readUInt32(response, offset: 32)
        let typeBytes = (0..<4).map { UInt8(truncatingIfNeeded: typeCode >> (24 - $0 * 8)) }
        guard size > 0, size <= 32, let type = String(bytes: typeBytes, encoding: .ascii) else {
            throw SMCReadError.unavailable("CPU 传感器元数据无效")
        }
        return SMCReadMetadata(size: size, type: type)
    }

    func read(key: String, metadata: SMCReadMetadata) throws -> [UInt8] {
        let response = try request(key: key, command: 5, size: UInt32(metadata.size))
        return Array(response[48..<(48 + metadata.size)])
    }

    /// AppleSMC's established 80-byte user-client ABI. Integers in the packet
    /// have host little-endian layout; the FourCC number is encoded separately.
    /// Offsets: key 0, keyInfo.size 28, result 40, command 42, value bytes 48.
    private func request(key: String, command: UInt8, size: UInt32 = 0) throws -> [UInt8] {
        guard let input = SMCReadProtocol.request(key: key, command: command, size: size) else {
            throw SMCReadError.unavailable("拒绝非读取 SMC 请求")
        }
        var output = [UInt8](repeating: 0, count: SMCReadProtocol.packetSize)
        var outputSize = SMCReadProtocol.packetSize
        let result = input.withUnsafeBytes { request in
            output.withUnsafeMutableBytes { response in
                IOConnectCallStructMethod(connection, 2, request.baseAddress, SMCReadProtocol.packetSize,
                                          response.baseAddress, &outputSize)
            }
        }
        guard SMCReadProtocol.acceptsReply(bytes: output, size: outputSize, result: result) else {
            throw SMCReadError.unavailable("SMC 读取失败（系统 \(result)，传感器 \(output[40])）")
        }
        return output
    }

    private static func readUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

}

enum SMCReadProtocol {
    static let packetSize = 80

    static func request(key: String, command: UInt8, size: UInt32 = 0) -> [UInt8]? {
        guard key.utf8.count == 4, key.utf8.allSatisfy({ $0 > 0 && $0 < 128 }),
              command == 5 || command == 9, size <= 32 else { return nil }
        var packet = [UInt8](repeating: 0, count: packetSize)
        let keyCode = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        writeUInt32(keyCode, to: &packet, offset: 0)
        writeUInt32(size, to: &packet, offset: 28)
        packet[42] = command
        return packet
    }

    static func acceptsReply(bytes: [UInt8], size: Int, result: kern_return_t) -> Bool {
        result == KERN_SUCCESS && size == packetSize && bytes.count == packetSize && bytes[40] == 0
    }

    private static func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
}
