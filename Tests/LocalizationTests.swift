import Foundation
import XCTest
@testable import MacPulse

final class LocalizationTests: XCTestCase {
    private func isolatedPreferences(_ values: [String: Any] = [:]) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "MacPulse.LocalizationTests.\(UUID().uuidString)")!
        // An in-memory domain avoids changing the user's interface preference.
        defaults.setVolatileDomain(values, forName: UserDefaults.registrationDomain)
        return defaults
    }

    func testSavedLanguageOverridesSystemLanguage() {
        let english = isolatedPreferences([AppLanguage.preferenceKey: "en"])
        XCTAssertEqual(AppLanguage.preferred(in: english, preferredLanguages: ["zh-Hans-CN"]), .english)
        let chinese = isolatedPreferences([AppLanguage.preferenceKey: "zh-Hans"])
        XCTAssertEqual(AppLanguage.preferred(in: chinese, preferredLanguages: ["en-US"]), .simplifiedChinese)
    }

    func testMissingOrInvalidPreferenceUsesFirstSystemLanguage() {
        let invalid = isolatedPreferences([AppLanguage.preferenceKey: "unsupported"])
        XCTAssertEqual(AppLanguage.preferred(in: invalid, preferredLanguages: ["zh-Hant-TW", "en"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.preferred(in: invalid, preferredLanguages: ["en-US", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.preferred(in: isolatedPreferences(), preferredLanguages: []), .english)
    }

    func testDisplayNamesAndLocalesAreExplicit() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.displayName, "中文")
        XCTAssertEqual(AppLanguage.english.displayName, "English")
        XCTAssertTrue(AppLanguage.simplifiedChinese.locale.identifier.hasPrefix("zh"))
        XCTAssertTrue(AppLanguage.english.locale.identifier.hasPrefix("en"))
        XCTAssertEqual(HistoryRange.week.title(in: .english), "7 days")
        XCTAssertEqual(HistoryRange.fiveMinutes.title(in: .simplifiedChinese), HistoryRange.fiveMinutes.title)
    }

    func testChineseSourcesRemainUnchanged() {
        for (chinese, _) in Localization.diagnosticTranslations {
            XCTAssertEqual(Localization.source(chinese, language: .simplifiedChinese), chinese)
        }
    }

    func testEnglishDiagnosticsContainNoChineseCharacters() {
        for (chinese, _) in Localization.diagnosticTranslations {
            let translated = Localization.source(chinese, language: .english)
            XCTAssertNil(translated.range(of: "[\\u3400-\\u9FFF\\uF900-\\uFAFF]", options: .regularExpression), chinese)
        }
    }

    func testDynamicInterfaceNamesAndSymbolsArePreserved() {
        let network = "系统接口计数 · en0, en7 物理接口合计 · 接收/发送速率"
        XCTAssertEqual(Localization.source(network, language: .english),
                       "System interface counters · en0, en7 physical interfaces combined · receive/send rates")
        XCTAssertEqual(Localization.source("系统接口已变化（IOReportCreateSamples）", language: .english),
                       "System interface changed(IOReportCreateSamples)")
        XCTAssertEqual(Localization.source("导出失败：无法创建导出文件", language: .english),
                       "Export failed: The export file could not be created")
        XCTAssertEqual(Localization.source("读取最新采样：database is locked", language: .english),
                       "Reading the latest sample: database is locked")
    }
}
