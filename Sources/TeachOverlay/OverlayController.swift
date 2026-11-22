import AppKit
import Carbon
import Combine
import SwiftUI

enum OverlayStyle: String, CaseIterable, Identifiable {
    case follow = "跟隨外觀", dark = "深色", light = "淺色"
    var id: String { rawValue }
}

/// 按鍵泡泡與快捷鍵紀錄要顯示在哪些螢幕
enum DisplayTarget: String, CaseIterable, Identifiable {
    case all = "所有螢幕", mouse = "滑鼠所在螢幕", main = "主螢幕"
    var id: String { rawValue }
}

enum HUDPosition: String, CaseIterable, Identifiable {
    case bottom = "下方", top = "上方"
    var id: String { rawValue }
}

typealias ShortcutCorner = ShortcutStackView.Corner

struct ShortcutEntry: Identifiable {
    let id = UUID()
    var text: String
    var count: Int
    var expires: Date
    var label: String { count > 1 ? "\(text)  ×\(count)" : text }
}

/// 所有功能的狀態（UI 綁定、自動儲存到 UserDefaults）與邏輯
@MainActor
final class OverlayController: ObservableObject {
    private(set) var overlays: [OverlayWindow] = []
    let keys = KeystrokeMonitor()
    private let d = UserDefaults.standard

    // MARK: 設定（自動儲存）

    @Published var keystrokesEnabled: Bool {
        didSet {
            d.set(keystrokesEnabled, forKey: "keys.enabled")
            if !keystrokesEnabled { overlays.forEach { $0.overlayView.hud.hideNow() } }
        }
    }
    @Published var hudFontSize: Double { didSet { d.set(hudFontSize, forKey: "keys.font"); applyHUDStyle() } }
    @Published var hudPosition: HUDPosition { didSet { d.set(hudPosition.rawValue, forKey: "keys.pos"); applyHUDStyle() } }
    @Published var hudDuration: Double { didSet { d.set(hudDuration, forKey: "keys.duration") } }
    @Published var hideInTerminals: Bool { didSet { d.set(hideInTerminals, forKey: "keys.hideTerm"); keys.hideInTerminals = hideInTerminals } }
    @Published var hidePrivateFields: Bool { didSet { d.set(hidePrivateFields, forKey: "keys.hidePrivate"); keys.hidePrivateFields = hidePrivateFields } }
    @Published var privateKeywords: String {
        didSet { d.set(privateKeywords, forKey: "keys.privateWords"); keys.privateKeywords = Self.splitKeywords(privateKeywords) }
    }
    @Published var displayTarget: DisplayTarget {
        didSet { d.set(displayTarget.rawValue, forKey: "keys.display"); renderShortcuts() }
    }
    @Published var comboStyle: ComboStyle { didSet { d.set(comboStyle.rawValue, forKey: "keys.comboStyle") } }
    @Published var showComboMeaning: Bool { didSet { d.set(showComboMeaning, forKey: "keys.comboMeaning") } }
    @Published var zhuyinEnabled: Bool { didSet { d.set(zhuyinEnabled, forKey: "keys.zhuyin"); keys.zhuyinEnabled = zhuyinEnabled } }

    @Published var shortcutCorner: ShortcutCorner {
        didSet {
            d.set(shortcutCorner.rawValue, forKey: "sc.corner")
            overlays.forEach { $0.overlayView.shortcuts.corner = shortcutCorner }
            renderShortcuts()
        }
    }
    @Published var shortcutHold: Double { didSet { d.set(shortcutHold, forKey: "sc.hold") } }
    @Published var shortcutPinned: Bool { didSet { d.set(shortcutPinned, forKey: "sc.pinned") } }
    @Published var shortcutFontSize: Double {
        didSet { d.set(shortcutFontSize, forKey: "sc.font"); overlays.forEach { $0.overlayView.shortcuts.fontSize = shortcutFontSize } }
    }
    @Published private(set) var shortcutHistory: [ShortcutEntry] = []

    @Published var clickPulseEnabled: Bool { didSet { d.set(clickPulseEnabled, forKey: "click.enabled") } }
    @Published var showAllClicks: Bool { didSet { d.set(showAllClicks, forKey: "click.all") } }
    @Published var leftClickColor: NSColor { didSet { saveColor(leftClickColor, "click.left") } }
    @Published var rightClickColor: NSColor { didSet { saveColor(rightClickColor, "click.right") } }
    @Published var pulseScale: Double { didSet { d.set(pulseScale, forKey: "click.scale") } }
    @Published var pulseDuration: Double { didSet { d.set(pulseDuration, forKey: "click.duration") } }
    @Published var pulseRings: Int { didSet { d.set(pulseRings, forKey: "click.rings") } }
    @Published var pulseLineWidth: Double { didSet { d.set(pulseLineWidth, forKey: "click.line") } }
    @Published var pulseFillOpacity: Double { didSet { d.set(pulseFillOpacity, forKey: "click.fill") } }
    @Published var showMouseButtons: Bool { didSet { d.set(showMouseButtons, forKey: "click.badge") } }
    @Published var showLongPress: Bool { didSet { d.set(showLongPress, forKey: "click.long") } }
    @Published var longPressDelay: Double { didSet { d.set(longPressDelay, forKey: "click.longDelay") } }

    private var pulseStyle: PulseStyle {
        PulseStyle(scale: pulseScale, duration: pulseDuration, rings: pulseRings,
                   lineWidth: pulseLineWidth, fillOpacity: pulseFillOpacity)
    }

    @Published private(set) var spotlightOn = false
    @Published var spotlightRadius: Double { didSet { d.set(spotlightRadius, forKey: "spot.radius"); if spotlightOn { updateSpotlight() } } }
    @Published var spotlightDim: Double {
        didSet { d.set(spotlightDim, forKey: "spot.dim"); overlays.forEach { $0.overlayView.effects.setSpotlightDim(spotlightDim) } }
    }

    @Published private(set) var drawMode = false
    @Published private(set) var whiteboardOn = false
    @Published var boardStyle: BoardStyle {
        didSet { d.set(boardStyle.rawValue, forKey: "board.style"); overlays.forEach { $0.overlayView.canvas.boardStyle = boardStyle } }
    }
    @Published var overlayStyle: OverlayStyle {
        didSet { d.set(overlayStyle.rawValue, forKey: "overlay.style"); refreshTheme() }
    }
    @Published private(set) var overlayTheme = OverlayTheme(dark: true)
    private var appearanceObservation: NSKeyValueObservation?

    /// 畫布內容變了（頁碼等），讓工具列重畫
    @Published private(set) var revision = 0

    // MARK: 內部狀態

    private var spotlightTimer: Timer?
    private var spotlightHotkeys: [UInt32] = []
    private var shortcutTimer: Timer?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pressed: MouseButton?
    private var pressStart = Date()
    private var longPressed = false
    private var pressTimer: Timer?
    private var previousApp: NSRunningApplication?
    private var typed = ""
    private var imeBase = ""
    private var lastKeyTime = Date.distantPast
    private var lastWasCombo = false

    static let hotkeyMods = controlKey | optionKey   // ⌃⌥

    init() {
        d.register(defaults: [
            "keys.enabled": true, "keys.font": 44.0, "keys.pos": HUDPosition.bottom.rawValue,
            "keys.duration": 1.6, "keys.hideTerm": true, "keys.hidePrivate": true,
            "keys.privateWords": KeystrokeMonitor.defaultPrivateKeywords.joined(separator: ", "),
            "keys.zhuyin": true, "keys.display": DisplayTarget.all.rawValue,
            "keys.comboStyle": ComboStyle.words.rawValue, "keys.comboMeaning": true,
            "sc.corner": ShortcutCorner.topRight.rawValue, "sc.hold": 8.0, "sc.pinned": false, "sc.font": 22.0,
            "click.enabled": true, "click.all": false,
            "click.scale": 1.0, "click.duration": 0.6, "click.rings": 2, "click.line": 3.0, "click.fill": 0.25,
            "click.badge": true, "click.long": true, "click.longDelay": 0.5,
            "overlay.style": OverlayStyle.follow.rawValue,
            "spot.radius": 150.0, "spot.dim": 0.62, "board.style": 0,
        ])
        keystrokesEnabled = d.bool(forKey: "keys.enabled")
        hudFontSize = d.double(forKey: "keys.font")
        hudPosition = HUDPosition(rawValue: d.string(forKey: "keys.pos") ?? "") ?? .bottom
        hudDuration = d.double(forKey: "keys.duration")
        hideInTerminals = d.bool(forKey: "keys.hideTerm")
        hidePrivateFields = d.bool(forKey: "keys.hidePrivate")
        privateKeywords = d.string(forKey: "keys.privateWords") ?? ""
        zhuyinEnabled = d.bool(forKey: "keys.zhuyin")
        displayTarget = DisplayTarget(rawValue: d.string(forKey: "keys.display") ?? "") ?? .all
        comboStyle = ComboStyle(rawValue: d.string(forKey: "keys.comboStyle") ?? "") ?? .words
        showComboMeaning = d.bool(forKey: "keys.comboMeaning")
        shortcutCorner = ShortcutCorner(rawValue: d.string(forKey: "sc.corner") ?? "") ?? .topRight
        shortcutHold = d.double(forKey: "sc.hold")
        shortcutPinned = d.bool(forKey: "sc.pinned")
        shortcutFontSize = d.double(forKey: "sc.font")
        clickPulseEnabled = d.bool(forKey: "click.enabled")
        showAllClicks = d.bool(forKey: "click.all")
        leftClickColor = Self.loadColor(d, "click.left", .systemYellow)
        rightClickColor = Self.loadColor(d, "click.right", .systemBlue)
        pulseScale = d.double(forKey: "click.scale")
        pulseDuration = d.double(forKey: "click.duration")
        pulseRings = d.integer(forKey: "click.rings")
        pulseLineWidth = d.double(forKey: "click.line")
        pulseFillOpacity = d.double(forKey: "click.fill")
        showMouseButtons = d.bool(forKey: "click.badge")
        showLongPress = d.bool(forKey: "click.long")
        longPressDelay = d.double(forKey: "click.longDelay")
        spotlightRadius = d.double(forKey: "spot.radius")
        spotlightDim = d.double(forKey: "spot.dim")
        boardStyle = BoardStyle(rawValue: d.integer(forKey: "board.style")) ?? .white
        overlayStyle = OverlayStyle(rawValue: d.string(forKey: "overlay.style") ?? "") ?? .follow
    }

    /// 依外觀設定更新螢幕提示配色
    func refreshTheme() {
        let dark: Bool
        switch overlayStyle {
        case .follow:
            switch AppPrefs.shared.appearance {
            case .dark: dark = true
            case .light: dark = false
            case .system: dark = OverlayTheme.systemIsDark
            }
        case .dark: dark = true
        case .light: dark = false
        }
        overlayTheme = OverlayTheme(dark: dark)
        for w in overlays {
            let v = w.overlayView
            v.hud.theme = overlayTheme
            v.shortcuts.theme = overlayTheme
            v.mouseBadge.theme = overlayTheme
        }
    }

    func start() {
        keys.hideInTerminals = hideInTerminals
        keys.hidePrivateFields = hidePrivateFields
        keys.privateKeywords = Self.splitKeywords(privateKeywords)
        keys.zhuyinEnabled = zhuyinEnabled

        rebuildOverlays()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildOverlays() }
        }

        keys.onKey = { [weak self] token, combo in self?.handleKey(token, combo: combo) }
        keys.onCombo = { [weak self] c in
            guard let self else { return }
            self.handleKey(self.format(c), combo: true)
        }
        keys.onIME = { [weak self] segment, started in self?.handleIME(segment, started: started) }
        keys.onSuppressed = { [weak self] in self?.showHidden() }
        keys.onSecureChange = { [weak self] on in if on { self?.showHidden() } }
        keys.start()

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseUp, .rightMouseUp, .otherMouseUp]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            let type = e.type, count = e.clickCount
            MainActor.assumeIsolated { self?.handleMouse(type: type, clickCount: count) }
        }
        // 自己的主控台視窗內也顯示（方便測試）
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            let type = e.type, count = e.clickCount
            if !(e.window is OverlayWindow) {
                MainActor.assumeIsolated { self?.handleMouse(type: type, clickCount: count) }
            }
            return e
        }

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneShortcuts() }
        }
        RunLoop.main.add(t, forMode: .common)
        shortcutTimer = t

        registerHotkeys()

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshTheme() }
            }
        }
    }

    // MARK: 視窗

    private func rebuildOverlays() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { screen in
            let w = OverlayWindow(screen: screen)
            w.keyHandler = { [weak self, weak w] e in
                guard let self, let w else { return }
                self.handleDrawKey(e, in: w)
            }
            let v = w.overlayView
            v.canvas.boardStyle = boardStyle
            v.canvas.onChange = { [weak self] in self?.revision += 1 }
            v.effects.setSpotlightDim(spotlightDim)
            v.effects.setSpotlightVisible(spotlightOn)
            v.shortcuts.corner = shortcutCorner
            v.shortcuts.fontSize = shortcutFontSize
            let toolbar = DrawToolbar(controller: self, draw: .shared, canvas: { [weak v] in v?.canvas })
            v.installToolbar(NSHostingView(rootView: toolbar))
            w.orderFrontRegardless()
            return w
        }
        applyHUDStyle()
        refreshTheme()
        if drawMode { enterDraw(whiteboard: whiteboardOn) }
    }

    private func applyHUDStyle() {
        for w in overlays {
            w.overlayView.hud.fontSize = hudFontSize
            w.overlayView.hud.anchorTop = hudPosition == .top
        }
    }

    private func overlay(at global: CGPoint) -> OverlayWindow? {
        overlays.first { NSMouseInRect(global, $0.frame, false) }
    }

    private var overlayUnderMouse: OverlayWindow? {
        overlay(at: NSEvent.mouseLocation) ?? overlays.first
    }

    // MARK: 快捷鍵

    private func registerHotkeys() {
        let hk = HotKeyCenter.shared
        let m = Self.hotkeyMods
        hk.register(keyCode: kVK_ANSI_K, modifiers: m) { [weak self] in self?.toggleKeystrokes() }
        hk.register(keyCode: kVK_ANSI_S, modifiers: m) { [weak self] in self?.toggleSpotlight() }
        hk.register(keyCode: kVK_ANSI_D, modifiers: m) { [weak self] in self?.toggleDraw() }
        hk.register(keyCode: kVK_ANSI_W, modifiers: m) { [weak self] in self?.toggleWhiteboard() }
        hk.register(keyCode: kVK_ANSI_C, modifiers: m) { [weak self] in self?.toggleClickPulse() }
        hk.register(keyCode: kVK_ANSI_X, modifiers: m) { [weak self] in self?.turnOffAll() }
    }

    /// ⌃⌥X：關閉聚光燈、畫圖、白板、清除快捷鍵紀錄
    func turnOffAll() {
        if spotlightOn { toggleSpotlight() }
        exitDraw()
        shortcutHistory.removeAll()
        renderShortcuts()
        flash(L("全部效果已關閉"))
    }

    // MARK: 按鍵顯示

    func toggleKeystrokes() {
        keystrokesEnabled.toggle()
        flash(keystrokesEnabled ? L("顯示按鍵：開") : L("顯示按鍵：關"))
    }

    private func handleKey(_ token: String, combo: Bool) {
        guard keystrokesEnabled, !drawMode else { return }
        if combo { pushShortcut(token) }
        let now = Date()
        let gap = now.timeIntervalSince(lastKeyTime)
        lastKeyTime = now
        if combo {
            typed = (lastWasCombo && gap < 1.2) ? typed + "  " + token : token
        } else {
            typed = (lastWasCombo || gap > 1.2) ? token : typed + token
        }
        lastWasCombo = combo
        trimTyped()
        showHUD(typed)
    }

    /// 注音：同一段輸入會持續更新（注音 → 中文）
    private func handleIME(_ segment: String, started: Bool) {
        guard keystrokesEnabled, !drawMode else { return }
        let now = Date()
        if started {
            imeBase = (lastWasCombo || now.timeIntervalSince(lastKeyTime) > 1.2) ? "" : typed
        }
        lastKeyTime = now
        lastWasCombo = false
        typed = imeBase + segment
        trimTyped()
        showHUD(typed)
    }

    private func trimTyped() {
        if typed.count > 32 { typed = String(typed.suffix(32)) }
    }

    private func showHidden() {
        guard keystrokesEnabled, !drawMode else { return }
        typed = ""
        lastWasCombo = true
        showHUD("🔒 " + L("已隱藏"))
    }

    /// 依設定決定要同步顯示的螢幕
    private var displayOverlays: [OverlayWindow] {
        switch displayTarget {
        case .all: return overlays
        case .mouse: return overlayUnderMouse.map { [$0] } ?? []
        case .main:
            let main = NSScreen.screens.first?.frame   // 有選單列的主螢幕
            return overlays.filter { $0.frame == main }.isEmpty ? Array(overlays.prefix(1))
                : overlays.filter { $0.frame == main }
        }
    }

    private func showHUD(_ text: String, duration: TimeInterval? = nil) {
        let targets = displayOverlays
        for w in overlays {
            if targets.contains(where: { $0 === w }) {
                w.overlayView.hud.show(text, duration: duration ?? hudDuration)
            } else {
                w.overlayView.hud.hideNow()
            }
        }
    }

    /// 短暫提示（不受「顯示按鍵」開關影響）
    func flash(_ text: String) {
        lastWasCombo = true
        showHUD(text, duration: 1.2)
    }

    /// Command + C  複製  ／  ⌘C  複製
    func format(_ c: KeyCombo) -> String {
        var text = comboStyle == .words ? c.words : c.symbols
        if showComboMeaning, let m = ShortcutMeanings.meaning(of: c) { text += "  " + L(m) }
        return text
    }

    func previewKeys() {
        lastWasCombo = true
        let sample = format(KeyCombo(command: true, key: "C"))
        pushShortcut(sample)
        showHUD(sample, duration: max(hudDuration, 2))
    }

    // MARK: 快捷鍵懸停保留

    private func pushShortcut(_ text: String) {
        guard shortcutCorner != .off else { return }
        let expires = Date().addingTimeInterval(shortcutHold)
        if var first = shortcutHistory.first, first.text == text {
            first.count += 1
            first.expires = expires
            shortcutHistory[0] = first
        } else {
            shortcutHistory.insert(ShortcutEntry(text: text, count: 1, expires: expires), at: 0)
            if shortcutHistory.count > 6 { shortcutHistory.removeLast(shortcutHistory.count - 6) }
        }
        renderShortcuts()
    }

    func clearShortcuts() {
        shortcutHistory.removeAll()
        renderShortcuts()
    }

    private func pruneShortcuts() {
        guard !shortcutPinned, !shortcutHistory.isEmpty else { return }
        let now = Date()
        let before = shortcutHistory.count
        shortcutHistory.removeAll { $0.expires < now }
        if shortcutHistory.count != before { renderShortcuts() }
    }

    private func renderShortcuts() {
        let labels = shortcutHistory.map(\.label)
        let targets = displayOverlays
        for w in overlays {
            w.overlayView.shortcuts.setItems(targets.contains(where: { $0 === w }) ? labels : [])
        }
    }

    // MARK: 點擊脈衝

    func toggleClickPulse() {
        clickPulseEnabled.toggle()
        flash(clickPulseEnabled ? L("雙擊脈衝：開") : L("雙擊脈衝：關"))
    }

    private func handleMouse(type: NSEvent.EventType, clickCount: Int) {
        guard !drawMode else { return }
        switch type {
        case .leftMouseDown: mouseDown(.left, count: clickCount)
        case .rightMouseDown: mouseDown(.right, count: clickCount)
        case .otherMouseDown: mouseDown(.middle, count: clickCount)
        case .leftMouseUp: mouseUp(.left)
        case .rightMouseUp: mouseUp(.right)
        case .otherMouseUp: mouseUp(.middle)
        default: break
        }
    }

    private func color(for b: MouseButton) -> NSColor {
        b == .right ? rightClickColor : leftClickColor
    }

    private func mouseDown(_ b: MouseButton, count: Int) {
        if clickPulseEnabled, count >= 2 || showAllClicks {
            pulse(at: NSEvent.mouseLocation, right: b == .right, strong: count >= 2)
        }
        guard showMouseButtons || showLongPress else { return }
        endPress()
        pressed = b
        pressStart = Date()
        longPressed = false
        if showMouseButtons { updateBadge(long: false) }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPress() }
        }
        RunLoop.main.add(t, forMode: .common)
        pressTimer = t
    }

    private func mouseUp(_ b: MouseButton) {
        guard pressed == b else { return }
        endPress()
    }

    private func endPress() {
        pressTimer?.invalidate()
        pressTimer = nil
        if pressed != nil {
            for w in overlays {
                w.overlayView.mouseBadge.hide()
                w.overlayView.effects.endHold()
            }
        }
        pressed = nil
        longPressed = false
    }

    private func tickPress() {
        guard let b = pressed else { return }
        // 保險：放開事件漏掉時自動結束
        if NSEvent.pressedMouseButtons == 0 { endPress(); return }
        let g = NSEvent.mouseLocation
        if !longPressed, showLongPress, Date().timeIntervalSince(pressStart) >= longPressDelay {
            longPressed = true
            updateBadge(long: true)
            if let w = overlay(at: g) {
                w.overlayView.effects.startHold(at: w.toLocal(g), color: color(for: b), scale: pulseScale)
            }
        }
        for w in overlays {
            let inside = NSMouseInRect(g, w.frame, false)
            let v = w.overlayView
            if inside {
                if v.mouseBadge.alphaValue > 0 { v.mouseBadge.move(cursor: w.toLocal(g)) }
                v.effects.moveHold(to: w.toLocal(g))
            }
        }
    }

    private func updateBadge(long: Bool) {
        guard let b = pressed else { return }
        let g = NSEvent.mouseLocation
        for w in overlays {
            let v = w.overlayView
            if NSMouseInRect(g, w.frame, false) {
                v.mouseBadge.show(b, long: long, color: color(for: b))
                v.mouseBadge.move(cursor: w.toLocal(g))
            } else {
                v.mouseBadge.hideNowIfNeeded()
            }
        }
    }

    private func pulse(at g: CGPoint, right: Bool, strong: Bool) {
        guard let w = overlay(at: g) else { return }
        w.overlayView.effects.pulse(at: w.toLocal(g), color: right ? rightClickColor : leftClickColor,
                                    strong: strong, style: pulseStyle)
    }

    func testPulse() {
        let g = NSEvent.mouseLocation
        pulse(at: g, right: false, strong: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated { self?.pulse(at: g, right: true, strong: true) }
        }
    }

    // MARK: 聚光燈

    func toggleSpotlight() {
        spotlightOn.toggle()
        overlays.forEach { $0.overlayView.effects.setSpotlightVisible(spotlightOn) }
        if spotlightOn {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSpotlight() }
            }
            RunLoop.main.add(t, forMode: .common)
            spotlightTimer = t
            // 聚光燈開啟期間：Esc 關閉、⌃⌥↑/↓ 調整大小
            let hk = HotKeyCenter.shared
            spotlightHotkeys = [
                hk.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
                    if self?.spotlightOn == true { self?.toggleSpotlight() }
                },
                hk.register(keyCode: kVK_UpArrow, modifiers: Self.hotkeyMods) { [weak self] in self?.adjustSpotlight(25) },
                hk.register(keyCode: kVK_DownArrow, modifiers: Self.hotkeyMods) { [weak self] in self?.adjustSpotlight(-25) },
            ]
            updateSpotlight()
        } else {
            spotlightTimer?.invalidate()
            spotlightTimer = nil
            spotlightHotkeys.forEach { HotKeyCenter.shared.unregister($0) }
            spotlightHotkeys = []
        }
    }

    private func adjustSpotlight(_ delta: Double) {
        spotlightRadius = min(max(spotlightRadius + delta, 50), 600)
    }

    private func updateSpotlight() {
        let m = NSEvent.mouseLocation
        for w in overlays {
            let inside = NSMouseInRect(m, w.frame, false)
            w.overlayView.effects.updateSpotlight(center: inside ? w.toLocal(m) : nil, radius: spotlightRadius)
        }
    }

    // MARK: 畫圖 / 白板

    func toggleDraw() {
        if drawMode && !whiteboardOn { exitDraw() } else { enterDraw(whiteboard: false) }
    }

    func toggleWhiteboard() {
        if whiteboardOn { exitDraw() } else { enterDraw(whiteboard: true) }
    }

    func switchDrawMode() {
        enterDraw(whiteboard: !whiteboardOn)
    }

    private func enterDraw(whiteboard: Bool) {
        if !drawMode {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == getpid() ? nil : front
        }
        drawMode = true
        whiteboardOn = whiteboard
        for w in overlays {
            w.ignoresMouseEvents = false
            let v = w.overlayView
            v.canvas.whiteboard = whiteboard
            v.canvas.drawingEnabled = true
            v.hud.hideNow()
            v.toolbarView?.isHidden = false
        }
        revision += 1
        NSApp.activate(ignoringOtherApps: true)
        overlayUnderMouse?.makeKeyAndOrderFront(nil)
    }

    func exitDraw() {
        guard drawMode else { return }
        drawMode = false
        whiteboardOn = false
        for w in overlays {
            w.ignoresMouseEvents = true
            let v = w.overlayView
            v.canvas.drawingEnabled = false
            v.canvas.whiteboard = false     // 白板頁面保留，下次打開還在
            v.canvas.clearAnnotations()     // 螢幕標註離開即清除
            v.toolbarView?.isHidden = true
            w.orderFrontRegardless()
        }
        previousApp?.activate()
        previousApp = nil
    }

    func cycleBoardStyle() {
        boardStyle = BoardStyle(rawValue: (boardStyle.rawValue + 1) % BoardStyle.allCases.count) ?? .white
    }

    private func handleDrawKey(_ e: NSEvent, in w: OverlayWindow) {
        guard drawMode else { return }
        let canvas = w.overlayView.canvas
        let s = DrawSettings.shared
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""

        if e.modifierFlags.contains(.command) {
            if chars == "z" { canvas.undo() }
            if chars == "s" && whiteboardOn { saveWhiteboard(canvas) }
            return
        }

        switch Int(e.keyCode) {
        case kVK_Escape: exitDraw()
        case kVK_LeftArrow where whiteboardOn: canvas.goToPage(-1)
        case kVK_RightArrow where whiteboardOn: canvas.goToPage(1)
        default:
            switch chars {
            case "p": s.tool = .pen
            case "h": s.tool = .highlighter
            case "l": s.tool = .line
            case "a": s.tool = .arrow
            case "r": s.tool = .rect
            case "o": s.tool = .ellipse
            case "1", "2", "3", "4", "5", "6": s.colorIndex = Int(chars)! - 1
            case "=", "+": s.width = min(s.width + 2, 40)
            case "-": s.width = max(s.width - 2, 2)
            case "c": canvas.clear()
            case "w": switchDrawMode()
            case "b" where whiteboardOn: cycleBoardStyle()
            case "n" where whiteboardOn: canvas.newPage()
            default: break
            }
        }
    }

    func saveWhiteboard(_ canvas: CanvasView? = nil) {
        guard let canvas = canvas ?? overlayUnderMouse?.overlayView.canvas,
              let data = canvas.snapshotPNG() else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent("\(L("白板"))-\(fmt.string(from: Date())).png")
        do {
            try data.write(to: url)
            overlayUnderMouse?.overlayView.hud.show(LF("已存到桌面：%@", url.lastPathComponent), duration: 2)
        } catch {
            overlayUnderMouse?.overlayView.hud.show(LF("儲存失敗：%@", error.localizedDescription), duration: 3)
        }
    }

    // MARK: 工具

    private static func splitKeywords(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func saveColor(_ c: NSColor, _ key: String) {
        guard let s = c.usingColorSpace(.sRGB) else { return }
        d.set([s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map(Double.init), forKey: key)
    }

    private static func loadColor(_ d: UserDefaults, _ key: String, _ fallback: NSColor) -> NSColor {
        guard let a = d.array(forKey: key) as? [Double], a.count == 4 else { return fallback }
        return NSColor(srgbRed: a[0], green: a[1], blue: a[2], alpha: a[3])
    }
}
