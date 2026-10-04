import Darwin
import Foundation
import SQLite3

/// Stores the original measurements. Only chart queries are downsampled.
final class HistoryStore {
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    let databaseURL: URL

    private var database: OpaquePointer?
    private let lock = NSLock()
    private var lastPurge = Date.distantPast
    private let purgeInterval: TimeInterval = 60 * 60
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = """
        timestamp, cpu_usage_percent, memory_used_bytes, memory_total_bytes,
        swap_used_bytes, efficiency_mhz, performance_mhz, frequency_source,
        gpu_usage_percent, network_received_bytes_per_second,
        network_sent_bytes_per_second, gpu_source, network_source, recording_segment
        """

    init(directory: URL? = nil) throws {
        let storageDirectory: URL
        if let directory {
            storageDirectory = directory
        } else if let isolatedDirectory = ProcessInfo.processInfo.environment["MACPULSE_DATA_DIR"],
                  !isolatedDirectory.isEmpty {
            storageDirectory = URL(fileURLWithPath: isolatedDirectory, isDirectory: true)
        } else {
            storageDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("MacPulse", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        databaseURL = storageDirectory.appendingPathComponent("history.sqlite")

        let result = sqlite3_open_v2(
            databaseURL.path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK else {
            let error = sqliteError("打开历史数据库")
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
            try migrateSchema()
            try purgeIfNeeded(now: Date(), force: true)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func append(_ sample: MetricSample) throws {
        try synchronized {
            let now = Date()
            try purgeIfNeeded(now: now)
            let values = [sample.timestamp.timeIntervalSince1970, sample.cpuUsagePercent,
                          sample.memoryUsedBytes, sample.memoryTotalBytes, sample.swapUsedBytes]
                + [sample.efficiencyMHz, sample.performanceMHz, sample.gpuUsagePercent,
                   sample.networkReceivedBytesPerSecond, sample.networkSentBytesPerSecond].compactMap { $0 }
            guard values.allSatisfy(\.isFinite) else { throw HistoryError.invalidMeasurement }
            guard sample.gpuUsagePercent.map({ (0...100).contains($0) }) ?? true,
                  sample.networkReceivedBytesPerSecond.map({ $0 >= 0 }) ?? true,
                  sample.networkSentBytesPerSecond.map({ $0 >= 0 }) ?? true else {
                throw HistoryError.invalidMeasurement
            }
            // Delayed or imported measurements cannot reintroduce expired history.
            guard sample.timestamp >= now.addingTimeInterval(-Self.retentionInterval) else { return }
            let statement = try prepare("""
                INSERT OR REPLACE INTO samples (\(Self.columns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, sample.timestamp.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, sample.cpuUsagePercent)
            sqlite3_bind_double(statement, 3, sample.memoryUsedBytes)
            sqlite3_bind_double(statement, 4, sample.memoryTotalBytes)
            sqlite3_bind_double(statement, 5, sample.swapUsedBytes)
            bind(sample.efficiencyMHz, at: 6, to: statement)
            bind(sample.performanceMHz, at: 7, to: statement)
            bindText(sample.frequencySource, at: 8, to: statement)
            bind(sample.gpuUsagePercent, at: 9, to: statement)
            bind(sample.networkReceivedBytesPerSecond, at: 10, to: statement)
            bind(sample.networkSentBytesPerSecond, at: 11, to: statement)
            bindText(sample.gpuSource, at: 12, to: statement)
            bindText(sample.networkSource, at: 13, to: statement)
            if let segment = sample.chartSegment {
                sqlite3_bind_int64(statement, 14, sqlite3_int64(segment))
            } else { sqlite3_bind_null(statement, 14) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError("保存采样") }
        }
    }

    func samples(since: Date, until: Date = Date(), limit: Int = 1_400) throws -> [MetricSample] {
        try synchronized {
            guard limit > 0, since <= until else { return [] }
            try purgeIfNeeded(now: Date())
            let bounds = try prepare("""
                SELECT COUNT(*), MIN(timestamp), MAX(timestamp)
                FROM samples WHERE timestamp >= ? AND timestamp <= ?;
                """)
            defer { sqlite3_finalize(bounds) }
            bindRange(since: since, until: until, to: bounds)
            guard sqlite3_step(bounds) == SQLITE_ROW else { throw sqliteError("读取历史范围") }
            let total = Int(sqlite3_column_int64(bounds, 0))
            guard total > 0 else { return [] }

            if total <= limit {
                var run = 0
                var previous: MetricSample?
                return try readSamples(since: since, until: until).map { original in
                    var sample = original
                    if let previous,
                       original.chartSegment != previous.chartSegment || original.timestamp.timeIntervalSince(previous.timestamp) > 30 {
                        run += 1
                    }
                    sample.chartSegment = run
                    previous = original
                    return sample
                }
            }

            let segments = try recordingSegments(since: since, until: until)
            // Allocate at least one point to each continuous recording run. If there
            // are more runs than display points, sample runs evenly across the range.
            // Never average across a >30-second pause, even inside a large time bucket.
            let selected: [RecordingSegment]
            if segments.count > limit {
                if limit == 1 { selected = [segments[segments.count - 1]] }
                else {
                    selected = (0..<limit).map { index in
                        segments[Int(Double(index) * Double(segments.count - 1) / Double(limit - 1))]
                    }
                }
            } else { selected = segments }
            var budgets = Array(repeating: 1, count: selected.count)
            let remainder = limit - selected.count
            let capacity = selected.reduce(0) { $0 + $1.count - 1 }
            if remainder > 0 && capacity > 0 {
                var fractions: [(index: Int, fraction: Double)] = []
                for (index, segment) in selected.enumerated() {
                    let share = Double(remainder) * Double(segment.count - 1) / Double(capacity)
                    let amount = min(segment.count - 1, Int(share))
                    budgets[index] += amount
                    fractions.append((index, share - Double(amount)))
                }
                var unallocated = limit - budgets.reduce(0, +)
                for entry in fractions.sorted(by: { $0.fraction > $1.fraction }) where unallocated > 0 {
                    if budgets[entry.index] < selected[entry.index].count {
                        budgets[entry.index] += 1
                        unallocated -= 1
                    }
                }
            }
            var result: [MetricSample] = []
            for (index, segment) in selected.enumerated() {
                let points: [MetricSample]
                if segment.count <= budgets[index] {
                    points = try readSamples(since: segment.first, until: segment.last)
                } else {
                    points = try downsample(segment, limit: budgets[index])
                }
                result += points.map { original in
                    var sample = original
                    sample.chartSegment = index
                    return sample
                }
            }
            return result
        }
    }

    func latest() throws -> MetricSample? {
        try synchronized {
            try purgeIfNeeded(now: Date())
            let statement = try prepare("SELECT \(Self.columns) FROM samples ORDER BY timestamp DESC LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteError("读取最新采样") }
            return readSample(statement)
        }
    }

    func count() throws -> Int {
        try synchronized {
            try purgeIfNeeded(now: Date())
            let statement = try prepare("SELECT COUNT(*) FROM samples;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError("读取采样数量") }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Exports original rows, regardless of the chart's display point limit.
    func exportCSV(to url: URL, since: Date, until: Date = Date()) throws {
        try synchronized {
            try purgeIfNeeded(now: Date())
            let statement = try prepare("SELECT \(Self.columns) FROM samples WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp ASC;")
            defer { sqlite3_finalize(statement) }
            bindRange(since: since, until: until, to: statement)

            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let temporaryURL = parent.appendingPathComponent(".macpulse-export-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw HistoryError.exportFailed("无法创建导出文件")
            }
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data((
                "timestamp_iso8601,cpu_usage_percent,memory_used_bytes,memory_total_bytes,"
                + "swap_used_bytes,efficiency_mhz,performance_mhz,frequency_source,"
                + "gpu_usage_percent,network_received_bytes_per_second,network_sent_bytes_per_second,"
                + "gpu_source,network_source\r\n"
            ).utf8))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let sample = readSample(statement)
                let fields = [
                    formatter.string(from: sample.timestamp),
                    String(sample.cpuUsagePercent), String(sample.memoryUsedBytes),
                    String(sample.memoryTotalBytes), String(sample.swapUsedBytes),
                    sample.efficiencyMHz.map { String($0) } ?? "",
                    sample.performanceMHz.map { String($0) } ?? "", sample.frequencySource,
                    sample.gpuUsagePercent.map { String($0) } ?? "",
                    sample.networkReceivedBytesPerSecond.map { String($0) } ?? "",
                    sample.networkSentBytesPerSecond.map { String($0) } ?? "",
                    sample.gpuSource ?? "", sample.networkSource ?? ""
                ]
                let line = fields.map(Self.csvField).joined(separator: ",") + "\r\n"
                try handle.write(contentsOf: Data(line.utf8))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw sqliteError("导出历史采样") }
            try handle.synchronize()
            try handle.close()
            // POSIX rename replaces the destination atomically after the complete export.
            let renameResult = temporaryURL.path.withCString { source in
                url.path.withCString { destination in Darwin.rename(source, destination) }
            }
            guard renameResult == 0 else {
                throw HistoryError.exportFailed(String(cString: strerror(errno)))
            }
        }
    }

    func clear() throws {
        try synchronized { try execute("DELETE FROM samples;") }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Add nullable measurements in one transaction. Reading the actual columns
    /// also makes reopening, and recovery from a partial legacy upgrade, idempotent.
    /// Original rows keep NULL for unavailable GPU/network history.
    private func migrateSchema() throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            let version = try prepare("PRAGMA user_version;")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW else { throw sqliteError("读取历史数据库版本") }
            guard sqlite3_column_int(version, 0) <= 3 else {
                throw HistoryError.database("历史数据库来自更新版本，请使用相应版本的 MacPulse。")
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS samples (
                    timestamp REAL PRIMARY KEY NOT NULL,
                    cpu_usage_percent REAL NOT NULL,
                    memory_used_bytes REAL NOT NULL,
                    memory_total_bytes REAL NOT NULL,
                    swap_used_bytes REAL NOT NULL,
                    efficiency_mhz REAL,
                    performance_mhz REAL,
                    frequency_source TEXT NOT NULL
                );
                """)
            let schema = try prepare("PRAGMA table_info(samples);")
            defer { sqlite3_finalize(schema) }
            var existing = Set<String>()
            var result = sqlite3_step(schema)
            while result == SQLITE_ROW {
                if let name = sqlite3_column_text(schema, 1) { existing.insert(String(cString: name)) }
                result = sqlite3_step(schema)
            }
            guard result == SQLITE_DONE else { throw sqliteError("读取历史数据库字段") }
            let originals = ["timestamp", "cpu_usage_percent", "memory_used_bytes", "memory_total_bytes",
                             "swap_used_bytes", "efficiency_mhz", "performance_mhz", "frequency_source"]
            guard originals.allSatisfy(existing.contains) else {
                throw HistoryError.database("历史数据库缺少必要字段，无法安全升级。")
            }
            let additions = [("gpu_usage_percent", "REAL"), ("network_received_bytes_per_second", "REAL"),
                             ("network_sent_bytes_per_second", "REAL"), ("gpu_source", "TEXT"), ("network_source", "TEXT"),
                             ("recording_segment", "INTEGER")]
            for (name, type) in additions where !existing.contains(name) {
                try execute("ALTER TABLE samples ADD COLUMN \(name) \(type);")
            }
            // The timestamp primary key remains the range-query and retention index.
            try execute("PRAGMA user_version = 3;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func purgeIfNeeded(now: Date, force: Bool = false) throws {
        guard force || now.timeIntervalSince(lastPurge) >= purgeInterval else { return }
        let statement = try prepare("DELETE FROM samples WHERE timestamp < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-Self.retentionInterval).timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError("清理过期历史") }
        lastPurge = now
    }

    private func readSamples(since: Date, until: Date) throws -> [MetricSample] {
        let statement = try prepare("""
            SELECT \(Self.columns) FROM samples WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp ASC;
            """)
        defer { sqlite3_finalize(statement) }
        bindRange(since: since, until: until, to: statement)
        return try collect(statement)
    }

    private struct RecordingSegment {
        let first: Date
        let last: Date
        let count: Int
    }

    private func recordingSegments(since: Date, until: Date) throws -> [RecordingSegment] {
        // Walk the timestamp index once. Window-function sorting of a full
        // week of one-second samples is substantially more expensive.
        let statement = try prepare("""
            SELECT timestamp, recording_segment FROM samples
            WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp ASC;
            """)
        defer { sqlite3_finalize(statement) }
        bindRange(since: since, until: until, to: statement)
        var segments: [RecordingSegment] = []
        var first = 0.0, previous = 0.0, count = 0
        var previousSession: Int64?
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let timestamp = sqlite3_column_double(statement, 0)
            let session = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1)
            if count > 0 && (timestamp - previous > 30 || session != previousSession) {
                segments.append(RecordingSegment(first: Date(timeIntervalSince1970: first),
                                                 last: Date(timeIntervalSince1970: previous), count: count))
                count = 0
            }
            if count == 0 { first = timestamp }
            count += 1
            previous = timestamp
            previousSession = session
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqliteError("读取采样间隔") }
        if count > 0 {
            segments.append(RecordingSegment(first: Date(timeIntervalSince1970: first),
                                             last: Date(timeIntervalSince1970: previous), count: count))
        }
        return segments
    }

    private func downsample(_ segment: RecordingSegment, limit: Int) throws -> [MetricSample] {
        let first = segment.first.timeIntervalSince1970
        let last = segment.last.timeIntervalSince1970
        let width = max((last - first) / Double(limit), 0.000_001)
        // Frequency keeps its original NULL-ignoring average. New GPU/network
        // curves are conservative: any absent value leaves that metric's bucket
        // absent, preserving gaps through downsampling without exceeding the limit.
        let statement = try prepare("""
            SELECT AVG(timestamp), AVG(cpu_usage_percent), AVG(memory_used_bytes),
                   AVG(memory_total_bytes), AVG(swap_used_bytes),
                   AVG(efficiency_mhz), AVG(performance_mhz),
                   CASE WHEN MIN(frequency_source) = MAX(frequency_source)
                        THEN MIN(frequency_source) ELSE '聚合采样' END,
                   CASE WHEN COUNT(gpu_usage_percent) = COUNT(*) THEN AVG(gpu_usage_percent) ELSE NULL END,
                   CASE WHEN COUNT(network_received_bytes_per_second) = COUNT(*) THEN AVG(network_received_bytes_per_second) ELSE NULL END,
                   CASE WHEN COUNT(network_sent_bytes_per_second) = COUNT(*) THEN AVG(network_sent_bytes_per_second) ELSE NULL END,
                   CASE WHEN COUNT(gpu_source) = 0 THEN NULL
                        WHEN MIN(gpu_source) = MAX(gpu_source) THEN MIN(gpu_source) ELSE '聚合采样' END,
                   CASE WHEN COUNT(network_source) = 0 THEN NULL
                        WHEN MIN(network_source) = MAX(network_source) THEN MIN(network_source) ELSE '聚合采样' END,
                   MIN(recording_segment)
            FROM samples WHERE timestamp >= ? AND timestamp <= ?
            GROUP BY MIN(CAST((timestamp - ?) / ? AS INTEGER), ?)
            ORDER BY AVG(timestamp) ASC;
            """)
        defer { sqlite3_finalize(statement) }
        bindRange(since: segment.first, until: segment.last, to: statement)
        sqlite3_bind_double(statement, 3, first)
        sqlite3_bind_double(statement, 4, width)
        sqlite3_bind_int64(statement, 5, sqlite3_int64(limit - 1))
        return try collect(statement)
    }

    private func collect(_ statement: OpaquePointer) throws -> [MetricSample] {
        var samples: [MetricSample] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            samples.append(readSample(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqliteError("读取历史采样") }
        return samples
    }

    private func readSample(_ statement: OpaquePointer) -> MetricSample {
        MetricSample(
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
            cpuUsagePercent: sqlite3_column_double(statement, 1),
            memoryUsedBytes: sqlite3_column_double(statement, 2),
            memoryTotalBytes: sqlite3_column_double(statement, 3),
            swapUsedBytes: sqlite3_column_double(statement, 4),
            efficiencyMHz: optionalDouble(statement, at: 5),
            performanceMHz: optionalDouble(statement, at: 6),
            frequencySource: optionalText(statement, at: 7) ?? "",
            chartSegment: sqlite3_column_type(statement, 13) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 13)),
            gpuUsagePercent: optionalDouble(statement, at: 8),
            networkReceivedBytesPerSecond: optionalDouble(statement, at: 9),
            networkSentBytesPerSecond: optionalDouble(statement, at: 10),
            gpuSource: optionalText(statement, at: 11),
            networkSource: optionalText(statement, at: 12)
        )
    }

    private func optionalDouble(_ statement: OpaquePointer, at column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }

    private func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func optionalText(_ statement: OpaquePointer, at column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func bindText(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        if let value {
            _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        } else { sqlite3_bind_null(statement, index) }
    }

    private func bindRange(since: Date, until: Date, to statement: OpaquePointer) {
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError("准备历史查询") }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError("初始化历史存储")
        }
    }

    private func sqliteError(_ operation: String) -> HistoryError {
        .database("\(operation)：\(String(cString: sqlite3_errmsg(database)))")
    }

    private static func csvField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\r") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private enum HistoryError: LocalizedError {
        case database(String)
        case exportFailed(String)
        case invalidMeasurement

        var errorDescription: String? {
            switch self {
            case .database(let message): return message
            case .exportFailed(let message): return "导出失败：\(message)"
            case .invalidMeasurement: return "采样包含无效数值，未保存该记录。"
            }
        }
    }
}
