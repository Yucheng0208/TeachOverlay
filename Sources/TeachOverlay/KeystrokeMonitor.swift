import AppKit
import Carbon

/// 監聽全域按鍵，並在偵測到密碼輸入時自動隱藏。
///
/// 密碼保護分三層：
/// 1. 系統 Secure Event Input（原生密碼框、Safari/Chrome 密碼欄位）—此時系統根本不會把按鍵送進 event tap
/// 2. 用輔助使用 API 檢查目前焦點元件是否為 AXSecureTextField
/// 3. 黑名單 App（密碼管理器、終端機 —— 終端機的 sudo 密碼無法自動偵測）
@MainActor
final class KeystrokeMonitor {
    /// (顯示文字, 是否為組合鍵)
    var onKey: ((String, Bool) -> Void)?
    /// 組合鍵（⌘C、⌃⌥K…）
    var onCombo: ((KeyCombo) -> Void)?
    /// 按鍵因為在密碼情境中而被隱藏
    var onSuppressed: (() -> Void)?
    /// 系統安全輸入模式開關變化
    var onSecureChange: ((Bool) -> Void)?

    /// 注音輸入中的顯示內容（已轉換的中文 + 尚未完成的注音）；Bool = 是否為新的一段輸入
    var onIME: ((String, Bool) -> Void)?

    var hideInTerminals = true
    /// 聊天／社群 App 中完全不顯示（連「已隱藏」也不顯示）
    var hideInChatApps = true
    var extraExcludedApps: Set<String> = []
    var chatTitleKeywords: [String] = KeystrokeMonitor.defaultChatKeywords

    static let chatApps: Set<String> = [
        "jp.naver.line.mac", "com.apple.MobileSMS", "com.facebook.archon", "com.facebook.archon.developerID",
        "com.hnc.Discord", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tencent.xinWeChat",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.tinyspeck.slackmacgap", "com.microsoft.teams2",
        "com.microsoft.teams", "org.whispersystems.signal-desktop", "com.skype.skype", "com.kakao.KakaoTalkMac",
        "com.burbn.instagram", "com.google.Chat",
    ]
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox",
        "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "com.google.Chrome.canary", "com.apple.SafariTechnologyPreview",
    ]
    static let defaultChatKeywords = [
        "Instagram", "Messenger", "Facebook", "LINE", "WhatsApp", "Discord", "Telegram", "Threads",
        "WeChat", "Slack", "Microsoft Teams", "Google Chat", "Signal", "KakaoTalk", "Dcard", "Plurk",
    ]
    var zhuyinEnabled = true
    /// 帳號、學號等隱私欄位：欄位名稱／提示文字／標籤含這些字就隱藏
    var hidePrivateFields = true
    var privateKeywords: [String] = KeystrokeMonitor.defaultPrivateKeywords

    static let defaultPrivateKeywords = [
        "帳號", "帳戶", "賬號", "使用者", "用戶", "學號", "學生證", "員工編號", "工號",
        "身分證", "身份證", "密碼", "驗證碼", "手機", "電話", "信用卡", "卡號",
        "账号", "用户名", "密码", "学号", "身份证", "验证码", "电话",
        "アカウント", "ユーザー", "パスワード", "学籍番号", "電話番号", "暗証番号",
        "계정", "아이디", "비밀번호", "학번", "전화", "주민등록",
        "account", "username", "user name", "login", "email", "e-mail",
        "student", "password", "passcode", "otp", "phone", "mobile", "ssn", "card", "cvv",
    ]
    private(set) var isRunning = false

    // 注音狀態
    private var imeBaseline: String?      // 開始組字前輸入框的內容
    private var imeConverted = ""         // 從輸入框讀到的新中文
    private var imeZhuyin = ""            // 尚未轉換的注音符號
    private var imeFinalized = 0          // 已打完聲調、等待轉換的注音字數
    private var imeStarted = false
    private var imeLastKey = Date.distantPast

    private var tap: CFMachPort?
    private var retryTimer: Timer?
    private var secureTimer: Timer?
    private var secureActive = false
    private let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.1)
        return el
    }()

    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
    ]
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "io.alacritty",
        "com.github.wez.wezterm",
    ]

    static let specialKeys: [Int: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// 標準注音鍵盤配置（依實體按鍵位置）
    static let zhuyinMap: [Int: String] = [
        kVK_ANSI_1: "ㄅ", kVK_ANSI_Q: "ㄆ", kVK_ANSI_A: "ㄇ", kVK_ANSI_Z: "ㄈ",
        kVK_ANSI_2: "ㄉ", kVK_ANSI_W: "ㄊ", kVK_ANSI_S: "ㄋ", kVK_ANSI_X: "ㄌ",
        kVK_ANSI_E: "ㄍ", kVK_ANSI_D: "ㄎ", kVK_ANSI_C: "ㄏ",
        kVK_ANSI_R: "ㄐ", kVK_ANSI_F: "ㄑ", kVK_ANSI_V: "ㄒ",
        kVK_ANSI_5: "ㄓ", kVK_ANSI_T: "ㄔ", kVK_ANSI_G: "ㄕ", kVK_ANSI_B: "ㄖ",
        kVK_ANSI_Y: "ㄗ", kVK_ANSI_H: "ㄘ", kVK_ANSI_N: "ㄙ",
        kVK_ANSI_U: "ㄧ", kVK_ANSI_J: "ㄨ", kVK_ANSI_M: "ㄩ",
        kVK_ANSI_8: "ㄚ", kVK_ANSI_I: "ㄛ", kVK_ANSI_K: "ㄜ", kVK_ANSI_Comma: "ㄝ",
        kVK_ANSI_9: "ㄞ", kVK_ANSI_O: "ㄟ", kVK_ANSI_L: "ㄠ", kVK_ANSI_Period: "ㄡ",
        kVK_ANSI_0: "ㄢ", kVK_ANSI_P: "ㄣ", kVK_ANSI_Semicolon: "ㄤ", kVK_ANSI_Slash: "ㄥ",
        kVK_ANSI_Minus: "ㄦ",
    ]
    static let toneMap: [Int: String] = [
        kVK_Space: "", kVK_ANSI_6: "ˊ", kVK_ANSI_3: "ˇ", kVK_ANSI_4: "ˋ", kVK_ANSI_7: "˙",
    ]

    func start() {
        if !installTap() {
            // 使用者還沒授權：每 2 秒重試，授權後自動生效
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    if self?.installTap() == true { t.invalidate() }
                }
            }
        }
        secureTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSecureInput() }
        }
    }

    private func installTap() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,           // 只聽不改，不會影響使用者輸入
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let me = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { me.handle(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }

        if hideInChatApps, isChatContext() { return }   // 聊天中：什麼都不顯示
        if isSensitiveContext() {
            onSuppressed?()
            return
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isCombo = flags.contains(.maskControl) || flags.contains(.maskAlternate)
            || flags.contains(.maskCommand)

        // 注音：先顯示注音，轉換後換成中文
        if zhuyinEnabled, !isCombo, !flags.contains(.maskShift), isZhuyinActive(flags) {
            if handleZhuyin(keyCode) { return }
        } else if imeBaseline != nil {
            endIME()
        }

        func combo(_ key: String) -> KeyCombo {
            KeyCombo(control: flags.contains(.maskControl), option: flags.contains(.maskAlternate),
                     shift: flags.contains(.maskShift), command: flags.contains(.maskCommand), key: key)
        }

        if let special = Self.specialKeys[keyCode] {
            let comboish = isCombo || (flags.contains(.maskShift) && keyCode != 49)
            if comboish { onCombo?(combo(special)) } else { onKey?(special, false) }
            return
        }

        let ns = NSEvent(cgEvent: event)
        if isCombo {
            // 用不含 Shift 的原始按鍵（⌘⇧/ 顯示成 Command + Shift + /，而不是 ?）
            let raw = ns?.characters(byApplyingModifiers: []) ?? ns?.charactersIgnoringModifiers ?? ""
            let base = raw.uppercased()
            guard !base.isEmpty, base.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return }
            onCombo?(combo(base))
        } else {
            let chars = ns?.characters ?? ""
            guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return }
            onKey?(chars, false)
        }
    }

    private func isSensitiveContext() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            if Self.passwordManagers.contains(bid) { return true }
            if hideInTerminals && Self.terminals.contains(bid) { return true }
        }
        return focusedElementIsPrivate()
    }

    /// 前景是聊天／社群 App，或瀏覽器正在開聊天／社群網站
    private func isChatContext() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier else { return false }
        if Self.chatApps.contains(bid) || extraExcludedApps.contains(bid) { return true }
        guard Self.browsers.contains(bid), !chatTitleKeywords.isEmpty else { return false }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, "AXFocusedWindow" as CFString, &win) == .success,
              let win, CFGetTypeID(win) == AXUIElementGetTypeID(),
              let title = axString(win as! AXUIElement, "AXTitle") else { return false }
        return chatTitleKeywords.contains { !$0.isEmpty && title.range(of: $0, options: .caseInsensitive) != nil }
    }

    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let arr = v as? [String] { return arr.joined(separator: " ") }
        return nil
    }

    private func focusedElementIsPrivate() -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, "AXFocusedUIElement" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let el = value as! AXUIElement
        if axString(el, "AXSubrole") == "AXSecureTextField" { return true }
        guard hidePrivateFields, !privateKeywords.isEmpty else { return false }

        // 只檢查單行輸入框（避免在文件編輯器裡誤判）
        let role = axString(el, "AXRole") ?? ""
        guard role == "AXTextField" || role == "AXComboBox" else { return false }

        var texts = ["AXTitle", "AXDescription", "AXPlaceholderValue", "AXHelp",
                     "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList"]
            .compactMap { axString(el, $0) }
        // 網頁／表單旁邊的文字標籤
        var labelRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXTitleUIElement" as CFString, &labelRef) == .success,
           let labelRef, CFGetTypeID(labelRef) == AXUIElementGetTypeID() {
            let label = labelRef as! AXUIElement
            texts += ["AXValue", "AXTitle", "AXDescription"].compactMap { axString(label, $0) }
        }
        let haystack = texts.joined(separator: " ").lowercased()
        guard !haystack.isEmpty else { return false }
        return privateKeywords.contains { !$0.isEmpty && haystack.contains($0.lowercased()) }
    }

    // MARK: 注音

    private func isZhuyinActive(_ flags: CGEventFlags) -> Bool {
        if flags.contains(.maskAlphaShift) { return false }   // Caps Lock = 英文
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        func prop(_ key: CFString) -> String? {
            guard let p = TISGetInputSourceProperty(src, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
        let ids = [prop(kTISPropertyInputModeID), prop(kTISPropertyInputSourceID)]
            .compactMap { $0 }.joined(separator: " ")
        if ids.contains("Eten") { return false }   // 倚天鍵盤配置不同，暫不支援
        return ids.contains("Zhuyin") || ids.contains("Bopomofo")
    }

    /// 回傳 true 表示這個按鍵已當作注音處理
    private func handleZhuyin(_ keyCode: Int) -> Bool {
        let now = Date()
        if imeBaseline != nil, now.timeIntervalSince(imeLastKey) > 3 { endIME() }
        imeLastKey = now

        if let sym = Self.zhuyinMap[keyCode] {
            if imeBaseline == nil { startIME() }
            imeZhuyin += sym
            emitIME()
            return true
        }
        if let tone = Self.toneMap[keyCode] {
            if !imeZhuyin.isEmpty {
                imeZhuyin += tone
                imeFinalized = imeZhuyin.count
                emitIME()
                scheduleProbe(end: false)
                return true
            }
            if imeBaseline != nil { scheduleProbe(end: false); return true }  // 空白鍵選字
            return false
        }
        guard imeBaseline != nil else { return false }
        switch keyCode {
        case kVK_Delete:
            if !imeZhuyin.isEmpty {
                imeZhuyin.removeLast()
                imeFinalized = min(imeFinalized, imeZhuyin.count)
                emitIME()
            } else {
                scheduleProbe(end: false)
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            scheduleProbe(end: true)
            return true
        case kVK_Escape:
            imeZhuyin = ""
            scheduleProbe(end: true)
            return true
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Tab:
            scheduleProbe(end: false)
            return true
        default:
            scheduleProbe(end: true)
            return false
        }
    }

    private func startIME() {
        imeBaseline = focusedText() ?? ""
        imeConverted = ""
        imeZhuyin = ""
        imeFinalized = 0
        imeStarted = true
    }

    private func endIME() {
        imeBaseline = nil
        imeConverted = ""
        imeZhuyin = ""
        imeFinalized = 0
    }

    private func emitIME() {
        onIME?(imeConverted + imeZhuyin, imeStarted)
        imeStarted = false
    }

    /// 等輸入法把字放進輸入框後，讀取輸入框內容找出新增的中文
    private func scheduleProbe(end: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.probe()
                if end { self.endIME() }
            }
        }
    }

    private func probe() {
        guard let base = imeBaseline, let now = focusedText() else { return }
        let inserted = Self.insertedText(from: base, to: now)
        guard inserted != imeConverted else { return }
        imeConverted = inserted
        if !inserted.isEmpty {
            imeZhuyin = String(imeZhuyin.dropFirst(min(imeFinalized, imeZhuyin.count)))
            imeFinalized = 0
        }
        emitIME()
    }

    private func focusedText() -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, "AXFocusedUIElement" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyAttributeValue(value as! AXUIElement, "AXValue" as CFString, &text) == .success,
              let s = text as? String, s.utf16.count < 200_000 else { return nil }
        return s
    }

    static func insertedText(from a: String, to b: String) -> String {
        let x = Array(a), y = Array(b)
        var p = 0
        while p < x.count, p < y.count, x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p, s < y.count - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        return String(y[p..<(y.count - s)])
    }

    private func pollSecureInput() {
        let now = IsSecureEventInputEnabled()
        if now != secureActive {
            secureActive = now
            onSecureChange?(now)
        }
    }
}
