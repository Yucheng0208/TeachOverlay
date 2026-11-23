import AppKit
import CoreText
import SwiftUI

/// Font Awesome Free 6.7.2（圖示 CC BY 4.0、字型 SIL OFL 1.1）
enum FA: UInt32 {
    case pen = 0xf304, highlighter = 0xf591, slash = 0xf715, arrowRight = 0xf061
    case square = 0xf0c8, circle = 0xf111
    case rotateLeft = 0xf2ea, trashCan = 0xf2ed, plus = 0x2b, minus = 0xf068
    case chevronLeft = 0xf053, chevronRight = 0xf054, fileCirclePlus = 0xe494, floppyDisk = 0xf0c7
    case xmark = 0xf00d, chalkboard = 0xf51b, chalkboardUser = 0xf51c, display = 0xe163
    case palette = 0xf53f, keyboard = 0xf11c, handPointer = 0xf25a, bullseye = 0xf140
    case penNib = 0xf5ad, shieldHalved = 0xf3ed, gauge = 0xf624, powerOff = 0xf011
    case lock = 0xf023, eye = 0xf06e, eyeSlash = 0xf070, circleCheck = 0xf058
    case circleXmark = 0xf057, computerMouse = 0xf8cc, lightbulb = 0xf0eb, gear = 0xf013
    case sliders = 0xf1de, house = 0xf015, wand = 0xe2ca, thumbtack = 0xf08d
    case layerGroup = 0xf5fd, clock = 0xf017, borderAll = 0xf84c
    case noteSticky = 0xf249, circleInfo = 0xf05a, globe = 0xf0ac, magnifyingGlass = 0xf002
    case windowRestore = 0xf2d2, rocket = 0xf135, code = 0xf121, heart = 0xf004
    case fileLines = 0xf15c, droplet = 0xf043, expand = 0xf065
    case sun = 0xf185, moon = 0xf186, circleHalfStroke = 0xf042
    case circleQuestion = 0xf059, bug = 0xf188, download = 0xf019, book = 0xf02d, circlePlay = 0xf144
    case github = 0xf09b   // brands
    case compassDrafting = 0xf568, ruler = 0xf545, camera = 0xf030, magnifyingGlassPlus = 0xf00e
    case magnifyingGlassMinus = 0xf010, stopwatch = 0xf2f2, hourglassHalf = 0xf252, play = 0xf04b
    case pause = 0xf04c, rotateRight = 0xf2f9, forwardStep = 0xf051, copy = 0xf0c5, cropSimple = 0xf565
    case shapes = 0xf61f, user = 0xf007, bell = 0xf0f3, shuffle = 0xf074, users = 0xf0c0
    case fileImport = 0xf56f, userSlash = 0xf506, checkDouble = 0xf560, hashtag = 0x23, dice = 0xf522

    var glyph: String { String(Character(UnicodeScalar(rawValue)!)) }
}

enum FAStyle {
    case solid, regular, brands
    var postScriptName: String {
        switch self {
        case .solid: "FontAwesome6Free-Solid"
        case .regular: "FontAwesome6Free-Regular"
        case .brands: "FontAwesome6Brands-Regular"
        }
    }
}

/// 專案連結
enum AppLinks {
    static let repo = URL(string: "https://github.com/Yucheng0208/TeachOverlay")!
    static let issues = URL(string: "https://github.com/Yucheng0208/TeachOverlay/issues")!
    static let releases = URL(string: "https://github.com/Yucheng0208/TeachOverlay/releases")!
    static let author = "Yu-Cheng Chang"
    static let authorGitHub = URL(string: "https://github.com/Yucheng0208")!
    static let authorWebsite = URL(string: "https://www.yucheng208.net/")!
    static let firstYear = 2026

    /// 版權年份每年元旦自動更新：© 2026–目前年份
    static var copyright: String {
        let year = Calendar.current.component(.year, from: Date())
        let span = year > firstYear ? "\(firstYear)–\(year)" : "\(firstYear)"
        return "© \(span) \(author)"
    }
}

enum FontAwesome {
    private static let files = ["fa-solid-900", "fa-regular-400", "fa-brands-400"]

    /// 啟動時呼叫一次：把 App 內附的字型註冊給本程式使用
    static func register() {
        for name in files {
            guard let url = locate(name) else {
                NSLog("TeachOverlay: 找不到字型 \(name).ttf")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static var isAvailable: Bool { NSFont(name: FAStyle.solid.postScriptName, size: 12) != nil }

    /// .app 內在 Contents/Resources；`swift run` 時往上找專案的 Resources/Fonts
    private static func locate(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "ttf") { return u }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("Resources/Fonts/\(name).ttf")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    /// 選單列用的單色樣板圖
    static func templateImage(_ icon: FA, size: CGFloat, style: FAStyle = .solid) -> NSImage? {
        guard let font = NSFont(name: style.postScriptName, size: size) else { return nil }
        let s = NSAttributedString(string: icon.glyph, attributes: [.font: font, .foregroundColor: NSColor.black])
        let sz = s.size()
        let img = NSImage(size: NSSize(width: ceil(sz.width), height: ceil(sz.height)), flipped: false) { _ in
            s.draw(at: .zero)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// App 圖示：優先用內附的 Logo（Resources/AppIcon.png），找不到才用 Font Awesome 畫
    static func appIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"), let img = NSImage(contentsOf: url) {
            return img
        }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let d = dir else { break }
            let c = d.appendingPathComponent("Resources/AppIcon.png")
            if let img = NSImage(contentsOf: c) { return img }
            dir = d.deletingLastPathComponent()
        }
        return fallbackIcon()
    }

    private static func fallbackIcon() -> NSImage? {
        guard let font = NSFont(name: FAStyle.solid.postScriptName, size: 250) else { return nil }
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: 92, yRadius: 92)
            NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1),
                       ending: NSColor(calibratedRed: 0.45, green: 0.25, blue: 0.85, alpha: 1))?
                .draw(in: box, angle: -60)
            let s = NSAttributedString(string: FA.chalkboardUser.glyph,
                                       attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            return true
        }
    }
}

struct FAIcon: View {
    let icon: FA
    var style: FAStyle = .solid
    var size: CGFloat = 15

    var body: some View {
        Text(icon.glyph)
            .font(.custom(style.postScriptName, fixedSize: size))
    }
}
