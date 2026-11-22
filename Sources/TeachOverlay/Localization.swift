import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHant = "zh-Hant", zhHans = "zh-Hans", en, ja, ko
    var id: String { rawValue }

    /// 用該語言本身的名稱顯示（跟隨系統除外）
    @MainActor var displayName: String {
        switch self {
        case .system: L("跟隨系統")
        case .zhHant: "繁體中文"
        case .zhHans: "简体中文"
        case .en: "English"
        case .ja: "日本語"
        case .ko: "한국어"
        }
    }
}

/// App 內切換語言（不需重開）。字串以繁體中文為鍵，翻譯表在 Strings.swift。
@MainActor
final class Loc: ObservableObject {
    static let shared = Loc()

    @Published var choice: AppLanguage {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "app.lang") }
    }

    var resolved: AppLanguage { choice == .system ? Self.systemLanguage() : choice }

    private init() {
        choice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.lang") ?? "") ?? .system
    }

    static func systemLanguage() -> AppLanguage {
        for id in Locale.preferredLanguages {
            let l = id.lowercased()
            if l.hasPrefix("zh") {
                return (l.contains("hans") || l.contains("-cn") || l.contains("-sg")) ? .zhHans : .zhHant
            }
            if l.hasPrefix("ja") { return .ja }
            if l.hasPrefix("ko") { return .ko }
            if l.hasPrefix("en") { return .en }
        }
        return .en
    }

    func t(_ key: String) -> String {
        let index: Int
        switch resolved {
        case .zhHant, .system: return key
        case .zhHans: index = 0
        case .en: index = 1
        case .ja: index = 2
        case .ko: index = 3
        }
        return Strings.table[key]?[index] ?? key
    }
}

@MainActor func L(_ key: String) -> String { Loc.shared.t(key) }
@MainActor func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: Loc.shared.t(key), arguments: args)
}
