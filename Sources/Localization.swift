import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preferenceKey = "interfaceLanguage"
    var id: String { rawValue }
    var displayName: String { self == .simplifiedChinese ? "中文" : "English" }
    var locale: Locale { Locale(identifier: self == .simplifiedChinese ? "zh_Hans_CN" : "en_US") }

    static var preferred: AppLanguage { preferred(in: .standard) }

    static func preferred(in defaults: UserDefaults, preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let saved = defaults.string(forKey: preferenceKey), let language = AppLanguage(rawValue: saved) {
            return language
        }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

/// Stored measurements and CSV keep their original source descriptions. Only
/// presentation translates them, including records collected by earlier versions.
enum Localization {
    static func text(_ chinese: String, _ english: String, language: AppLanguage) -> String {
        language == .simplifiedChinese ? chinese : english
    }

    static func source(_ value: String, language: AppLanguage) -> String {
        guard language == .english else { return value }
        var translated = value
        for (chinese, english) in diagnosticTranslations {
            translated = translated.replacingOccurrences(of: chinese, with: english)
        }
        return translated
    }

    // Long phrases precede their substrings. Dynamic interface names, symbols,
    // filenames, numeric values, and SQLite/system messages remain intact.
    static let diagnosticTranslations: [(String, String)] = [
        ("历史数据库来自更新版本，请使用相应版本的 MacPulse。", "This history database was created by a newer version. Use the corresponding version of MacPulse."),
        ("历史数据库缺少必要字段，无法安全升级。", "The history database is missing required fields and cannot be upgraded safely."),
        ("采样包含无效数值，未保存该记录。", "The sample contains invalid values and was not saved."),
        ("CPU 使用率读取失败，保留上次值", "CPU usage could not be read; keeping the previous value"),
        ("内存读取失败，保留上次值", "Memory could not be read; keeping the previous value"),
        ("交换内存读取失败，保留上次值", "Swap usage could not be read; keeping the previous value"),
        ("CPU 性能状态通道不存在或读取被系统拒绝", "The CPU performance-state channel is missing or access was denied by the system"),
        ("CPU 状态订阅被系统拒绝；当前权限无法读取频率", "CPU state subscription was denied; current permissions cannot read frequency"),
        ("无法读取 CPU DVFS 频率表；未使用标称频率替代", "The CPU DVFS frequency table could not be read; nominal frequency was not substituted"),
        ("目前频率传感器支持 Apple Silicon", "The frequency sensor currently supports Apple Silicon"),
        ("系统未提供 IOReport 接口", "The system does not provide the IOReport interface"),
        ("系统未返回可用的订阅通道", "The system did not return a usable subscription channel"),
        ("IOReport 采样失败或系统拒绝访问", "IOReport sampling failed or access was denied by the system"),
        ("无法计算性能状态差值", "Performance-state deltas could not be calculated"),
        ("系统采样结构已变化", "The system sampling structure has changed"),
        ("性能状态与 DVFS 表未能可靠对应", "Performance states could not be matched reliably to the DVFS table"),
        ("本采样区间核心休眠，无活跃频率", "Cores were asleep in this sampling interval; no active frequency"),
        ("活跃时间加权平均频率（休眠时间不计入）", "Active-time weighted average frequency (sleep time excluded)"),
        ("活跃时间加权平均频率", "Active-time weighted average frequency"),
        ("GPU 驻留采样支持 Apple Silicon", "GPU residency sampling supports Apple Silicon"),
        ("GPU 硬件性能状态通道不可用", "The GPU hardware performance-state channel is unavailable"),
        ("GPU 状态订阅被系统拒绝", "GPU state subscription was denied by the system"),
        ("GPU 订阅无可读通道", "The GPU subscription has no readable channel"),
        ("GPU 驱动设备利用率（备用来源）", "GPU driver device utilization (fallback source)"),
        ("系统未提供可读的活跃驻留或设备利用率", "The system provides neither readable active residency nor device utilization"),
        ("IOReport 采样失败", "IOReport sampling failed"),
        ("无法计算驻留差值", "Residency deltas could not be calculated"),
        ("系统驻留采样结构已变化", "The system residency sampling structure has changed"),
        ("硬件活跃与休眠状态无法可靠对应", "Hardware active and sleep states could not be identified reliably"),
        ("GPU 活跃时间占比（采样区间平均）", "GPU active-time ratio (sampling-interval average)"),
        ("无法读取系统接口计数器", "System interface counters could not be read"),
        ("没有已连接的物理网络接口", "No connected physical network interface"),
        ("等待有效采样区间", "Waiting for a valid sampling interval"),
        ("物理接口合计", "physical interfaces combined"),
        ("接收/发送速率", "receive/send rates"),
        ("系统接口计数", "System interface counters"),
        ("等待下一次 GPU 采样", "Waiting for the next GPU sample"),
        ("等待下一次采样", "Waiting for the next sample"),
        ("频率不可用：", "Frequency unavailable: "),
        ("GPU 不可用：", "GPU unavailable: "),
        ("网络不可用：", "Network unavailable: "),
        ("网络 ·", "Network ·"),
        ("系统接口已变化", "System interface changed"),
        ("聚合采样", "Aggregated samples"),
        ("能效核心", "Efficiency cores"),
        ("性能核心", "Performance cores"),
        ("打开历史数据库", "Opening the history database"),
        ("保存采样", "Saving the sample"),
        ("读取历史范围", "Reading the history range"),
        ("读取最新采样", "Reading the latest sample"),
        ("读取采样数量", "Reading the sample count"),
        ("无法创建导出文件", "The export file could not be created"),
        ("导出历史采样", "Exporting historical samples"),
        ("读取历史数据库版本", "Reading the history database version"),
        ("读取历史数据库字段", "Reading the history database columns"),
        ("清理过期历史", "Removing expired history"),
        ("读取采样间隔", "Reading the sampling interval"),
        ("读取历史采样", "Reading historical samples"),
        ("准备历史查询", "Preparing the history query"),
        ("初始化历史存储", "Initializing history storage"),
        ("采集或保存失败：", "Sampling or saving failed: "),
        ("导出失败：", "Export failed: "),
        ("已导出：", "Exported: "),
        ("（", "("), ("）", ")"), ("：", ": "), ("；", "; ")
    ].sorted { $0.0.count > $1.0.count }
}
