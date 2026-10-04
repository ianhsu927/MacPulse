import Foundation
import CoreFoundation
import Darwin
import IOKit

struct MetricSample: Codable, Identifiable, Sendable {
    var timestamp: Date
    var cpuUsagePercent: Double
    var memoryUsedBytes: Double
    var memoryTotalBytes: Double
    var swapUsedBytes: Double
    var efficiencyMHz: Double?
    var performanceMHz: Double?
    var frequencySource: String
    var chartSegment: Int? = nil
    var gpuUsagePercent: Double? = nil
    var networkReceivedBytesPerSecond: Double? = nil
    var networkSentBytesPerSecond: Double? = nil
    var gpuSource: String? = nil
    var networkSource: String? = nil
    var id: Date { timestamp }
}

/// Uses system-wide Mach counters. Frequency is the active residency-weighted
/// clock of each CPU cluster, not the nominal clock or a utilization estimate.
/// sample() is serialized internally and never sleeps or starts a subprocess.
final class TelemetrySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let host = mach_host_self()
    private var previousTicks: [UInt32]?
    private let frequencies: CPUFrequencySensor?
    private let gpu = GPUUsageSensor()
    private let network = NetworkRateSensor()
    private let initialFrequencyStatus: String
    private var lastMemoryUsed = 0.0
    private var lastCPUUsage = 0.0
    private var lastSwapUsed = 0.0
    let memoryTotalBytes: Double
    let chipName: String
    let efficiencyLabel: String
    let performanceLabel: String

    init() {
        memoryTotalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        chipName = Self.sysctlString("machdep.cpu.brand_string") ?? "Mac"
        let lowerName = Self.sysctlString("hw.perflevel1.name") ?? "Efficiency"
        let higherName = Self.sysctlString("hw.perflevel0.name") ?? "Performance"
        efficiencyLabel = lowerName == "Efficiency" ? "能效核心" : lowerName
        performanceLabel = higherName == "Performance" ? "性能核心" : higherName
        do {
            frequencies = try CPUFrequencySensor()
            initialFrequencyStatus = "IOReport · 活跃时间加权平均频率"
        } catch {
            frequencies = nil
            initialFrequencyStatus = "频率不可用：\(error.localizedDescription)"
        }
        previousTicks = readTicks()
    }

    deinit { mach_port_deallocate(mach_task_self_, host) }

    var frequencyStatus: String {
        lock.lock(); defer { lock.unlock() }
        return frequencies?.status ?? initialFrequencyStatus
    }

    var hasFrequencySensor: Bool { frequencies != nil }

    var maximumFrequencyMHz: Double { frequencies?.maximumMHz ?? 5000 }

    /// Discard deltas across a recording pause or system sleep. The next
    /// sample establishes a fresh baseline; frequencies are nil for that point.
    func resetBaseline() {
        lock.lock(); defer { lock.unlock() }
        previousTicks = nil
        lastCPUUsage = 0
        frequencies?.resetBaseline()
        gpu.resetBaseline()
        network.resetBaseline()
    }

    func sample() -> MetricSample {
        lock.lock(); defer { lock.unlock() }
        var issues = [String]()
        if let current = readTicks() {
            if let previous = previousTicks {
                lastCPUUsage = TelemetryMath.cpuUsage(previous: previous, current: current)
            }
            previousTicks = current
        } else {
            issues.append("CPU 使用率读取失败，保留上次值")
        }
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        if result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS {
            // Activity Monitor's Memory Used = anonymous app memory (excluding
            // purgeable pages) + wired + physically stored compressed pages.
            // File-backed cache is reclaimable and deliberately excluded.
            lastMemoryUsed = TelemetryMath.memoryUsed(
                internalPages: UInt64(vm.internal_page_count),
                purgeablePages: UInt64(vm.purgeable_count),
                wiredPages: UInt64(vm.wire_count),
                compressedPages: UInt64(vm.compressor_page_count),
                pageSize: UInt64(pageSize), totalBytes: memoryTotalBytes)
        } else {
            issues.append("内存读取失败，保留上次值")
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            lastSwapUsed = Double(swap.xsu_used)
        } else {
            issues.append("交换内存读取失败，保留上次值")
        }
        let frequency = frequencies?.sample()
        let gpuUsage = gpu.sample()
        let networkRate = network.sample()
        let source = (frequencies?.status ?? initialFrequencyStatus)
            + (issues.isEmpty ? "" : " · " + issues.joined(separator: "；"))
        return MetricSample(timestamp: Date(), cpuUsagePercent: lastCPUUsage,
                            memoryUsedBytes: lastMemoryUsed, memoryTotalBytes: memoryTotalBytes,
                            swapUsedBytes: lastSwapUsed, efficiencyMHz: frequency?.efficiency,
                            performanceMHz: frequency?.performance, frequencySource: source,
                            gpuUsagePercent: gpuUsage,
                            networkReceivedBytesPerSecond: networkRate.received,
                            networkSentBytesPerSecond: networkRate.sent,
                            gpuSource: gpu.status, networkSource: network.status)
    }

    private func readTicks() -> [UInt32]? {
        var cpu = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

enum TelemetryMath {
    /// Time in actual GPU hardware P-states divided by all time in that
    /// channel. Require recognizable idle and active state names so a changed
    /// driver cannot silently turn unknown states into a claimed 100% load.
    static func gpuUsage(names: [String], residencies: [UInt64]) -> Double? {
        guard names.count == residencies.count, !names.isEmpty,
              residencies.allSatisfy({ $0 < (UInt64(1) << 63) }) else { return nil }
        let inactive = Set(["OFF", "IDLE", "DOWN", "SLEEP"])
        let upper = names.map { $0.uppercased() }
        guard upper.contains(where: { inactive.contains($0) }),
              upper.contains(where: { !inactive.contains($0) }) else { return nil }
        func isPState(_ name: String) -> Bool {
            if name.hasPrefix("P") {
                let number = name.dropFirst()
                return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
            }
            let parts = name.split(separator: "P", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].hasPrefix("V") else { return false }
            return [parts[0].dropFirst(), parts[1][...]].allSatisfy {
                !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
            }
        }
        guard upper.allSatisfy({ inactive.contains($0) || isPState($0) }) else { return nil }
        let total = residencies.reduce(0.0) { $0 + Double($1) }
        guard total > 0, total.isFinite else { return nil }
        let active = zip(upper, residencies).reduce(0.0) { value, state in
            value + (inactive.contains(state.0) ? 0 : Double(state.1))
        }
        return min(100, max(0, active / total * 100))
    }

    /// Real interfaces use 64-bit byte counters. A decrease normally means a
    /// reset/recreated interface. Only a boundary-adjacent decrease is accepted
    /// as wrapping, avoiding an enormous fabricated throughput after resets.
    static func networkCounterDelta(previous: UInt64, current: UInt64) -> UInt64? {
        if current >= previous { return current - previous }
        let boundary: UInt64 = 1 << 40
        guard previous >= UInt64.max - boundary, current <= boundary else { return nil }
        return current &- previous
    }

    static func isPhysicalNetworkInterface(name: String, flags: Int32, type: UInt8) -> Bool {
        guard name.hasPrefix("en") else { return false }
        let suffix = name.dropFirst(2)
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
              flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
              flags & IFF_LOOPBACK == 0 else { return false }
        // Ethernet and Wi-Fi, including USB Ethernet/tethering adapters.
        return type == 6 || type == 71
    }

    static func isActiveNetworkMedia(status: Int32) -> Bool {
        status & IFM_AVALID != 0 && status & IFM_ACTIVE != 0
    }

    static func cpuUsage(previous: [UInt32], current: [UInt32]) -> Double {
        guard previous.count == 4, current.count == 4 else { return 0 }
        // Mach CPU ticks are UInt32 counters and may wrap after long uptimes.
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return 0 }
        return min(100, max(0, Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) * 100))
    }

    static func memoryUsed(internalPages: UInt64, purgeablePages: UInt64,
                           wiredPages: UInt64, compressedPages: UInt64,
                           pageSize: UInt64, totalBytes: Double) -> Double {
        let anonymous = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let bytes = (Double(anonymous) + Double(wiredPages) + Double(compressedPages)) * Double(pageSize)
        return min(max(0, totalBytes), max(0, bytes))
    }

    /// Decode IORegistry's little-endian (frequency, voltage) UInt32 records.
    /// Preserve state order: sorting would break residency-to-clock matching.
    static func voltageFrequencies(_ data: Data) -> [Double]? {
        guard !data.isEmpty, data.count % 8 == 0 else { return nil }
        let values = stride(from: 0, to: data.count, by: 8).map { offset -> Double in
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            let raw = Double(UInt32(littleEndian: value))
            if raw >= 100_000_000 { return raw / 1_000_000 }
            if raw >= 100_000 { return raw / 1000 }
            return raw
        }.filter { $0 > 0 }
        guard !values.isEmpty, values.allSatisfy({ $0 >= 100 && $0 <= 10_000 }) else { return nil }
        return values
    }

    static func weightedFrequency(names: [String], residencies: [UInt64], frequencies: [Double]) -> (weighted: Double, active: Double)? {
        guard names.count == residencies.count else { return nil }
        let activeStates = names.indices.filter { !["IDLE", "DOWN", "OFF"].contains(names[$0].uppercased()) }
        guard activeStates.count == frequencies.count, !frequencies.isEmpty,
              frequencies.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var weighted = 0.0
        var active = 0.0
        for (frequencyIndex, stateIndex) in activeStates.enumerated() {
            let duration = Double(residencies[stateIndex])
            active += duration
            weighted += duration * frequencies[frequencyIndex]
        }
        return (weighted, active)
    }

    static func isClusterName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.isEmpty || suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

private enum FrequencyError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): return reason }
    }
}

/// Private IOReport entry points are resolved at runtime. Missing symbols fail
/// safely; no private framework linker stubs or third-party dependencies needed.
private final class IOReportAPI {
    typealias CopyGroup = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UInt64, UInt64) -> UnsafeMutableRawPointer?
    typealias Subscribe = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UInt64, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias Samples = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias GetString = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias GetCount = @convention(c) (UnsafeRawPointer?) -> Int32
    typealias GetStateName = @convention(c) (UnsafeRawPointer?, Int32) -> UnsafeRawPointer?
    typealias GetResidency = @convention(c) (UnsafeRawPointer?, Int32) -> UInt64
    let copyGroup: CopyGroup
    let subscribe: Subscribe
    let createSamples: Samples
    let createDelta: Samples
    let channelName: GetString
    let subgroup: GetString
    let stateCount: GetCount
    let stateName: GetStateName
    let residency: GetResidency
    private let library: UnsafeMutableRawPointer

    init() throws {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL) else {
            throw FrequencyError.unavailable("系统未提供 IOReport 接口")
        }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else {
                throw FrequencyError.unavailable("系统接口已变化（\(name)）")
            }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            copyGroup = try symbol("IOReportCopyChannelsInGroup", CopyGroup.self)
            subscribe = try symbol("IOReportCreateSubscription", Subscribe.self)
            createSamples = try symbol("IOReportCreateSamples", Samples.self)
            createDelta = try symbol("IOReportCreateSamplesDelta", Samples.self)
            channelName = try symbol("IOReportChannelGetChannelName", GetString.self)
            subgroup = try symbol("IOReportChannelGetSubGroup", GetString.self)
            stateCount = try symbol("IOReportStateGetCount", GetCount.self)
            stateName = try symbol("IOReportStateGetNameForIndex", GetStateName.self)
            residency = try symbol("IOReportStateGetResidency", GetResidency.self)
        } catch {
            dlclose(library)
            throw error
        }
        self.library = library
    }

    deinit { dlclose(library) }

    func string(_ pointer: UnsafeRawPointer?) -> String? {
        guard let pointer else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

private final class CPUFrequencySensor {
    private let api: IOReportAPI
    private let subscription: AnyObject
    private let channels: CFDictionary
    private let tables: [String: [Double]]
    private var previous: CFDictionary?
    private(set) var status = "IOReport · 等待下一次采样"
    var maximumMHz: Double { tables.values.flatMap { $0 }.max() ?? 5000 }

    init() throws {
        #if !arch(arm64)
        throw FrequencyError.unavailable("目前频率传感器支持 Apple Silicon")
        #else
        let api = try IOReportAPI()
        let group = "CPU Stats" as CFString
        guard let rawChannels = api.copyGroup(Unmanaged.passUnretained(group).toOpaque(), nil, 0, 0, 0) else {
            throw FrequencyError.unavailable("CPU 性能状态通道不存在或读取被系统拒绝")
        }
        let requested = Unmanaged<CFDictionary>.fromOpaque(rawChannels).takeRetainedValue()
        var subscribed: UnsafeMutableRawPointer?
        guard let rawSubscription = api.subscribe(nil, Unmanaged.passUnretained(requested).toOpaque(), &subscribed, 0, nil) else {
            throw FrequencyError.unavailable("CPU 状态订阅被系统拒绝；当前权限无法读取频率")
        }
        // IOReport's opaque subscription is a retained CF object. Owning it
        // through ARC releases it on initialization failure and sampler teardown.
        let subscription = Unmanaged<AnyObject>.fromOpaque(rawSubscription).takeRetainedValue()
        guard let subscribed else { throw FrequencyError.unavailable("系统未返回可用的订阅通道") }
        let channels = Unmanaged<CFDictionary>.fromOpaque(subscribed).takeRetainedValue()
        var keys = [1, 5]
        if let data = Self.registryData("acc-clusters"), data.count % 8 == 0 {
            keys += stride(from: 0, to: data.count, by: 8).map { Int(data[$0]) }
        }
        var tables = [String: [Double]]()
        for key in Set(keys) {
            let property = "voltage-states\(key)-sram"
            if let data = Self.registryData(property), let frequencies = TelemetryMath.voltageFrequencies(data) {
                tables[property] = frequencies
            }
        }
        guard !tables.isEmpty else {
            throw FrequencyError.unavailable("无法读取 CPU DVFS 频率表；未使用标称频率替代")
        }
        self.api = api
        self.subscription = subscription
        self.channels = channels
        self.tables = tables
        previous = snapshot()
        #endif
    }

    func sample() -> (efficiency: Double?, performance: Double?) {
        guard let current = snapshot() else {
            status = "频率不可用：IOReport 采样失败或系统拒绝访问"
            previous = nil
            return (nil, nil)
        }
        defer { previous = current }
        guard let previous else {
            status = "IOReport · 等待下一次采样"
            return (nil, nil)
        }
        guard let rawDelta = api.createDelta(Unmanaged.passUnretained(previous).toOpaque(),
                                              Unmanaged.passUnretained(current).toOpaque(), nil) else {
            status = "频率不可用：无法计算性能状态差值"
            return (nil, nil)
        }
        let delta = Unmanaged<CFDictionary>.fromOpaque(rawDelta).takeRetainedValue()
        let dictionary = unsafeBitCast(delta, to: NSDictionary.self)
        guard let entries = dictionary["IOReportChannels"] as? [NSDictionary] else {
            status = "频率不可用：系统采样结构已变化"
            return (nil, nil)
        }
        var eWeighted = 0.0, eActive = 0.0, pWeighted = 0.0, pActive = 0.0
        var matched = 0
        for entry in entries {
            let pointer = Unmanaged.passUnretained(entry).toOpaque()
            guard api.string(api.subgroup(pointer)) == "CPU Complex Performance States",
                  let name = api.string(api.channelName(pointer)) else { continue }
            let isE = TelemetryMath.isClusterName(name, prefix: "ECPU") || TelemetryMath.isClusterName(name, prefix: "MCPU")
            let isP = TelemetryMath.isClusterName(name, prefix: "PCPU")
            guard isE || isP else { continue }
            let count = Int(api.stateCount(pointer))
            guard count > 0, count < 128 else { continue }
            let names = (0..<count).map { api.string(api.stateName(pointer, Int32($0))) ?? "" }
            guard names.allSatisfy({ !$0.isEmpty }) else { continue }
            let activeCount = names.filter { !["IDLE", "DOWN", "OFF"].contains($0.uppercased()) }.count
            let preferredKey = isP ? "voltage-states5-sram" : "voltage-states1-sram"
            let table: [Double]?
            if let preferred = tables[preferredKey], preferred.count == activeCount {
                table = preferred
            } else {
                // A novel cluster may only be matched by an unambiguous table.
                // If equal-sized tables disagree, reporting nil is safer.
                let candidates = tables.values.filter { $0.count == activeCount }
                table = candidates.first.flatMap { first in candidates.allSatisfy { $0 == first } ? first : nil }
            }
            guard let table else { continue }
            let residencies = (0..<count).map { api.residency(pointer, Int32($0)) }
            guard let value = TelemetryMath.weightedFrequency(names: names, residencies: residencies, frequencies: table) else { continue }
            matched += 1
            if isE { eWeighted += value.weighted; eActive += value.active }
            if isP { pWeighted += value.weighted; pActive += value.active }
        }
        if matched == 0 {
            status = "频率不可用：性能状态与 DVFS 表未能可靠对应"
        } else if eActive == 0 && pActive == 0 {
            status = "IOReport · 本采样区间核心休眠，无活跃频率"
        } else {
            status = "IOReport · 活跃时间加权平均频率（休眠时间不计入）"
        }
        return (eActive > 0 ? eWeighted / eActive : nil, pActive > 0 ? pWeighted / pActive : nil)
    }

    func resetBaseline() {
        previous = nil
        status = "IOReport · 等待下一次采样"
    }

    private func snapshot() -> CFDictionary? {
        guard let raw = api.createSamples(Unmanaged.passUnretained(subscription).toOpaque(), Unmanaged.passUnretained(channels).toOpaque(), nil) else { return nil }
        return Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue()
    }

    private static func registryData(_ key: String) -> Data? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntrySearchCFProperty(root, kIOServicePlane, key as CFString,
                                                            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) else { return nil }
        return property as? Data
    }
}

/// The primary source is the GPU hardware residency channel, not clock speed
/// or allocated memory. IOKit's genuine Device Utilization % is an explicitly
/// labelled fallback if a driver stops exposing its IOReport state channel.
private final class GPUUsageSensor {
    private let residency: IOReportGPUUsageSensor?
    private var needsBaseline = true
    private(set) var status = "GPU · 等待下一次采样"

    init() { residency = try? IOReportGPUUsageSensor() }

    func resetBaseline() {
        residency?.resetBaseline()
        needsBaseline = true
        status = "GPU · 等待下一次采样"
    }

    func sample() -> Double? {
        let value = residency?.sample()
        if needsBaseline {
            needsBaseline = false
            status = residency?.status ?? "IOKit · 等待下一次采样"
            return nil
        }
        if let value {
            status = residency!.status
            return value
        }
        if let residency, !residency.readFailed {
            status = residency.status
            return nil
        }
        if let utilization = Self.registryUtilization() {
            status = "IOKit · GPU 驱动设备利用率（备用来源）"
            return utilization
        }
        status = "GPU 不可用：系统未提供可读的活跃驻留或设备利用率"
        return nil
    }

    private static func registryUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var values = [Double]()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                            kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let statistics = raw as? [String: Any],
                  let number = statistics["Device Utilization %"] as? NSNumber else { continue }
            let value = number.doubleValue
            if value.isFinite, value >= 0, value <= 100 { values.append(value) }
        }
        // No trustworthy whole-system weighting exists for several unrelated
        // drivers; do not label an arbitrary sum/maximum as aggregate GPU load.
        return values.count == 1 ? values[0] : nil
    }
}

private final class IOReportGPUUsageSensor {
    private let api: IOReportAPI
    private let subscription: AnyObject
    private let channels: CFDictionary
    private var previous: CFDictionary?
    private(set) var status = "IOReport · 等待下一次 GPU 采样"
    private(set) var readFailed = false

    init() throws {
        #if !arch(arm64)
        throw FrequencyError.unavailable("GPU 驻留采样支持 Apple Silicon")
        #else
        let api = try IOReportAPI()
        let group = "GPU Stats" as CFString
        let subgroup = "GPU Performance States" as CFString
        guard let raw = api.copyGroup(Unmanaged.passUnretained(group).toOpaque(),
                                       Unmanaged.passUnretained(subgroup).toOpaque(), 0, 0, 0) else {
            throw FrequencyError.unavailable("GPU 硬件性能状态通道不可用")
        }
        let requested = Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue()
        var subscribed: UnsafeMutableRawPointer?
        guard let rawSubscription = api.subscribe(nil, Unmanaged.passUnretained(requested).toOpaque(),
                                                  &subscribed, 0, nil) else {
            throw FrequencyError.unavailable("GPU 状态订阅被系统拒绝")
        }
        let subscription = Unmanaged<AnyObject>.fromOpaque(rawSubscription).takeRetainedValue()
        guard let subscribed else { throw FrequencyError.unavailable("GPU 订阅无可读通道") }
        self.api = api
        self.subscription = subscription
        self.channels = Unmanaged<CFDictionary>.fromOpaque(subscribed).takeRetainedValue()
        #endif
    }

    func resetBaseline() {
        previous = nil
        readFailed = false
        status = "IOReport · 等待下一次 GPU 采样"
    }

    func sample() -> Double? {
        readFailed = false
        guard let raw = api.createSamples(Unmanaged.passUnretained(subscription).toOpaque(),
                                           Unmanaged.passUnretained(channels).toOpaque(), nil) else {
            previous = nil
            readFailed = true
            status = "GPU 不可用：IOReport 采样失败"
            return nil
        }
        let current = Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue()
        defer { previous = current }
        guard let previous else {
            status = "IOReport · 等待下一次 GPU 采样"
            return nil
        }
        guard let rawDelta = api.createDelta(Unmanaged.passUnretained(previous).toOpaque(),
                                             Unmanaged.passUnretained(current).toOpaque(), nil) else {
            readFailed = true
            status = "GPU 不可用：无法计算驻留差值"
            return nil
        }
        let delta = Unmanaged<CFDictionary>.fromOpaque(rawDelta).takeRetainedValue()
        guard let entries = unsafeBitCast(delta, to: NSDictionary.self)["IOReportChannels"] as? [NSDictionary] else {
            readFailed = true
            status = "GPU 不可用：系统驻留采样结构已变化"
            return nil
        }
        var active = 0.0, total = 0.0
        for entry in entries {
            let pointer = Unmanaged.passUnretained(entry).toOpaque()
            guard api.string(api.subgroup(pointer)) == "GPU Performance States",
                  let name = api.string(api.channelName(pointer)),
                  name == "GPUPH" || TelemetryMath.isClusterName(name, prefix: "GPU") else { continue }
            let count = Int(api.stateCount(pointer))
            guard count > 1, count < 128 else { continue }
            let names = (0..<count).map { api.string(api.stateName(pointer, Int32($0))) ?? "" }
            let residencies = (0..<count).map { api.residency(pointer, Int32($0)) }
            guard let percent = TelemetryMath.gpuUsage(names: names, residencies: residencies) else { continue }
            let duration = residencies.reduce(0.0) { $0 + Double($1) }
            total += duration
            active += duration * percent / 100
        }
        guard total > 0 else {
            readFailed = true
            status = "GPU 不可用：硬件活跃与休眠状态无法可靠对应"
            return nil
        }
        status = "IOReport · GPU 活跃时间占比（采样区间平均）"
        return min(100, max(0, active / total * 100))
    }
}

struct NetworkInterfaceCounter: Equatable {
    var name: String
    var index: UInt32
    var received: UInt64
    var sent: UInt64
    var lastChange: Int64 = 0
    var identity: String { "\(name)#\(index)" }
}

/// Keeps each interface's own baseline, including its administrative change
/// timestamp. A changed interface set or reset counter leaves a gap rather
/// than counting all traffic since boot as newly transferred data.
struct NetworkRateTracker {
    private var previous: [String: NetworkInterfaceCounter]?
    private var previousTime: Double?

    mutating func resetBaseline() { previous = nil; previousTime = nil }

    mutating func sample(_ interfaces: [NetworkInterfaceCounter], at time: Double) -> (received: Double?, sent: Double?) {
        let current = Dictionary(interfaces.map { ($0.identity, $0) }, uniquingKeysWith: { _, new in new })
        defer { previous = current; previousTime = time }
        guard !current.isEmpty, time.isFinite,
              let previous, let previousTime,
              previous.keys.count == current.keys.count,
              Set(previous.keys) == Set(current.keys) else { return (nil, nil) }
        let elapsed = time - previousTime
        guard elapsed > 0, elapsed.isFinite else { return (nil, nil) }
        var received = 0.0, sent = 0.0
        for (identity, counter) in current {
            guard let older = previous[identity], older.lastChange == counter.lastChange,
                  let rx = TelemetryMath.networkCounterDelta(previous: older.received, current: counter.received),
                  let tx = TelemetryMath.networkCounterDelta(previous: older.sent, current: counter.sent) else { return (nil, nil) }
            received += Double(rx)
            sent += Double(tx)
        }
        let rx = received / elapsed, tx = sent / elapsed
        guard rx.isFinite, tx.isFinite else { return (nil, nil) }
        return (rx, tx)
    }
}

final class NetworkRateSensor {
    private var tracker = NetworkRateTracker()
    private(set) var status = "网络 · 等待下一次采样"

    func resetBaseline() {
        tracker.resetBaseline()
        status = "网络 · 等待下一次采样"
    }

    func sample() -> (received: Double?, sent: Double?) {
        guard let interfaces = Self.readCounters() else {
            tracker.resetBaseline()
            status = "网络不可用：无法读取系统接口计数器"
            return (nil, nil)
        }
        let rates = tracker.sample(interfaces, at: ProcessInfo.processInfo.systemUptime)
        let names = interfaces.map { $0.name }.sorted().joined(separator: "、")
        if interfaces.isEmpty {
            status = "网络不可用：没有已连接的物理网络接口"
        } else if rates.received == nil {
            status = "系统接口计数 · \(names) · 等待有效采样区间"
        } else {
            status = "系统接口计数 · \(names) 物理接口合计 · 接收/发送速率"
        }
        return rates
    }

    private static func readCounters() -> [NetworkInterfaceCounter]? {
        // NET_RT_IFLIST2 returns if_msghdr2/if_data64; getifaddrs' if_data
        // uses 32-bit byte counters and can overflow during large transfers.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var buffer = Data()
        var succeeded = false
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
                  size > 0, size < 16 * 1024 * 1024 else { return nil }
            buffer = Data(count: size)
            let result = buffer.withUnsafeMutableBytes { bytes in
                sysctl(&mib, u_int(mib.count), bytes.baseAddress, &size, nil, 0)
            }
            if result == 0 {
                buffer.count = size
                succeeded = true
                break
            }
            guard errno == ENOMEM else { return nil }
        }
        guard succeeded else { return nil }
        let mediaSocket = socket(AF_INET, SOCK_DGRAM, 0)
        guard mediaSocket >= 0 else { return nil }
        defer { close(mediaSocket) }
        var counters = [NetworkInterfaceCounter]()
        var offset = 0
        while offset + 4 <= buffer.count {
            let messageLength = buffer.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
            guard messageLength >= 4, offset + messageLength <= buffer.count else { return nil }
            if buffer[offset + 3] == UInt8(RTM_IFINFO2) {
                guard messageLength >= MemoryLayout<if_msghdr2>.size else { return nil }
                let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
                guard header.ifm_version == UInt8(RTM_VERSION) else { return nil }
                var nameBytes = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                if if_indextoname(UInt32(header.ifm_index), &nameBytes) != nil {
                    let name = String(cString: nameBytes)
                    if TelemetryMath.isPhysicalNetworkInterface(name: name, flags: header.ifm_flags, type: header.ifm_data.ifi_type),
                       linkIsActive(name: name, socket: mediaSocket) {
                        let changed = header.ifm_data.ifi_lastchange
                        let lastChange = Int64(changed.tv_sec) * 1_000_000 + Int64(changed.tv_usec)
                        counters.append(NetworkInterfaceCounter(name: name, index: UInt32(header.ifm_index),
                                                                received: header.ifm_data.ifi_ibytes,
                                                                sent: header.ifm_data.ifi_obytes, lastChange: lastChange))
                    }
                }
            }
            offset += messageLength
        }
        guard offset == buffer.count else { return nil }
        return counters
    }

    private static func linkIsActive(name: String, socket: Int32) -> Bool {
        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { bytes in
            for (index, byte) in name.utf8.prefix(bytes.count - 1).enumerated() { bytes[index] = byte }
        }
        // Swift cannot import the structure-valued SIOCGIFMEDIA macro. Encode
        // its public SDK definition: _IOWR('i', 56, struct ifmediareq).
        let operation = UInt(IOC_INOUT)
            | ((UInt(MemoryLayout<ifmediareq>.size) & UInt(IOCPARM_MASK)) << 16)
            | (UInt(105) << 8) | 56
        guard ioctl(socket, operation, &request) == 0 else { return false }
        return TelemetryMath.isActiveNetworkMedia(status: request.ifm_status)
    }
}
