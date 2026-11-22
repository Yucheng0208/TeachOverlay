import Foundation

/// 一個組合鍵，例如 ⌘C、⌃⌘F、⇧⌘4
struct KeyCombo: Equatable {
    var control = false
    var option = false
    var shift = false
    var command = false
    /// 主鍵：大寫字母、數字、符號，或特殊鍵符號（↩ ⇥ ␣ ⌫ ⎋ ← F5…）
    var key: String

    /// macOS 標準順序 ⌃⌥⇧⌘
    var symbols: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }

    var words: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        parts.append(Self.keyWords[key] ?? key)
        return parts.joined(separator: " + ")
    }

    static let keyWords: [String: String] = [
        "↩": "Return", "⌤": "Enter", "⇥": "Tab", "␣": "Space", "⌫": "Delete", "⌦": "Forward Delete",
        "⎋": "Esc", "↖": "Home", "↘": "End", "⇞": "Page Up", "⇟": "Page Down",
        "←": "←", "→": "→", "↑": "↑", "↓": "↓",
    ]
}

enum ComboStyle: String, CaseIterable, Identifiable {
    case words = "文字（Command + C）"
    case symbols = "符號（⌘C）"
    var id: String { rawValue }
}

/// 常見快捷鍵的功能說明（鍵 = 符號寫法；值 = 繁中說明，翻譯在 Strings.swift）
enum ShortcutMeanings {
    static let table: [String: String] = [
        "⌘C": "複製", "⌘V": "貼上", "⌘X": "剪下", "⌘Z": "復原", "⇧⌘Z": "重做",
        "⌘A": "全選", "⌘S": "儲存", "⇧⌘S": "另存新檔", "⌘N": "新增", "⌘O": "打開",
        "⌘W": "關閉視窗", "⌘Q": "結束 App", "⌘T": "新分頁", "⇧⌘T": "重新打開分頁", "⌘F": "尋找",
        "⌘G": "找下一個", "⌘P": "列印", "⌘R": "重新整理", "⌘H": "隱藏 App", "⌘M": "縮到最小",
        "⌘,": "設定", "⌘B": "粗體", "⌘I": "斜體", "⌘U": "底線", "⌘K": "插入連結",
        "⌘L": "選取網址列", "⌘=": "放大", "⌘+": "放大", "⌘-": "縮小", "⌘0": "實際大小",
        "⌘⇥": "切換 App", "⌘`": "切換視窗", "⌘␣": "Spotlight 搜尋", "⌃␣": "切換輸入法",
        "⇧⌘3": "截取全螢幕", "⇧⌘4": "截取選取範圍", "⇧⌘5": "截圖與錄影工具",
        "⌃⌘F": "全螢幕", "⌃⌘Q": "鎖定螢幕", "⌥⌘⎋": "強制結束", "⌘⌫": "刪除",
        "⌘[": "上一頁", "⌘]": "下一頁", "⌃⇥": "下一個分頁", "⌃⇧⇥": "上一個分頁",
        "⇧⌘N": "新增資料夾", "⌘E": "使用所選範圍尋找", "⌘↑": "到最上方", "⌘↓": "到最下方",
        "⌘←": "到行首", "⌘→": "到行尾", "⌥⌘I": "開發者工具", "⌘/": "註解",
    ]

    static func meaning(of combo: KeyCombo) -> String? { table[combo.symbols] }
}
