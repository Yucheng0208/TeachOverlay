import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let controller = OverlayController()
    private var mainWindow: NSWindow?
    private let nav = NavModel()
    private var langSub: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontAwesome.register()
        if let icon = FontAwesome.appIcon() { NSApp.applicationIconImage = icon }
        AppPrefs.shared.applyAppearance()
        Permissions.requestIfNeeded()
        setupMainMenu()
        setupStatusItem()
        controller.start()
        AppPrefs.shared.onAppearanceChange = { [weak self] in self?.controller.refreshTheme() }
        if AppPrefs.shared.showWindowAtLaunch { showMainWindow() }

        // 換語言：重建選單與標題
        langSub = Loc.shared.$choice.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.setupMainMenu()
                    self?.setupStatusMenu()
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: 主控台視窗

    func showMainWindow(pane: Pane? = nil) {
        if let pane { nav.pane = pane }
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainView(c: controller, draw: .shared, nav: nav, loc: .shared))
            let w = NSWindow(contentViewController: host)
            w.title = "TeachOverlay"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 980, height: 660))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("TeachOverlayMain")
            mainWindow = w
        }
        // 開著主控台時出現在 Dock 和 ⌘Tab；關掉後回到只在選單列
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NotesStore.shared.saveNow()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotesStore.shared.saveNow()
    }

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(ClosureMenuItem(L("關於 TeachOverlay")) { [weak self] in self?.showMainWindow(pane: .about) })
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(L("主控台…"), key: ",") { [weak self] in self?.showMainWindow() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隱藏 TeachOverlay"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("結束 TeachOverlay"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("編輯"))
        editMenu.addItem(withTitle: L("復原"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪下"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷貝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("貼上"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全選"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: L("說明"))
        helpMenu.addItem(ClosureMenuItem(L("TeachOverlay 使用說明"), key: "?") { [weak self] in self?.showMainWindow(pane: .help) })
        helpMenu.addItem(.separator())
        helpMenu.addItem(ClosureMenuItem(L("GitHub 專案頁面"), icon: .github) { NSWorkspace.shared.open(AppLinks.repo) })
        helpMenu.addItem(ClosureMenuItem(L("回報問題"), icon: .bug) { NSWorkspace.shared.open(AppLinks.issues) })
        helpItem.submenu = helpMenu

        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: L("視窗"))
        winMenu.addItem(withTitle: L("關閉"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: L("縮到最小"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        main.addItem(winItem)
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    // MARK: 選單列

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = FontAwesome.templateImage(.chalkboardUser, size: 15)
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "TeachOverlay")
        setupStatusMenu()
    }

    private func setupStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let c = controller
        let mods: NSEvent.ModifierFlags = [.control, .option]

        menu.addItem(ClosureMenuItem(L("開啟主控台…"), key: ",", icon: .gauge) { [weak self] in self?.showMainWindow() })
        menu.addItem(ClosureMenuItem(L("筆記"), icon: .noteSticky) { [weak self] in self?.showMainWindow(pane: .notes) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("顯示按鍵"), key: "k", mods: mods, icon: .keyboard, state: { c.keystrokesEnabled }) { c.toggleKeystrokes() })
        menu.addItem(ClosureMenuItem(L("雙擊脈衝"), key: "c", mods: mods, icon: .handPointer, state: { c.clickPulseEnabled }) { c.toggleClickPulse() })
        menu.addItem(ClosureMenuItem(L("聚光燈"), key: "s", mods: mods, icon: .lightbulb, state: { c.spotlightOn }) { c.toggleSpotlight() })
        menu.addItem(ClosureMenuItem(L("畫圖標註"), key: "d", mods: mods, icon: .penNib, state: { c.drawMode && !c.whiteboardOn }) { c.toggleDraw() })
        menu.addItem(ClosureMenuItem(L("白板"), key: "w", mods: mods, icon: .chalkboard, state: { c.whiteboardOn }) { c.toggleWhiteboard() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("放大鏡"), key: "z", mods: mods, icon: .magnifyingGlassPlus, state: { c.magnifierOn }) { c.toggleMagnifier() })
        menu.addItem(ClosureMenuItem(L("截圖並標註"), key: "p", mods: mods, icon: .camera) { c.captureScreenshot(.selection) })
        menu.addItem(ClosureMenuItem(L("黑屏"), key: "b", mods: mods, icon: .eyeSlash, state: { BlackoutController.shared.active }) { BlackoutController.shared.toggle() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("計時器"), key: "t", mods: mods, icon: .stopwatch, state: { TimerPanel.shared.isVisible }) { TimerPanel.shared.toggle() })
        menu.addItem(ClosureMenuItem(L("抽籤"), key: "r", mods: mods, icon: .dice) { PickerStore.shared.draw() })
        menu.addItem(ClosureMenuItem(L("全螢幕時鐘"), key: "l", mods: mods, icon: .clock, state: { ClockController.shared.active }) { ClockController.shared.toggle() })
        menu.addItem(ClosureMenuItem(L("鐘聲設定…"), icon: .bell) { [weak self] in self?.showMainWindow(pane: .bell) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("關閉全部效果"), key: "x", mods: mods, icon: .powerOff) { c.turnOffAll() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("使用說明"), icon: .circleQuestion) { [weak self] in self?.showMainWindow(pane: .help) })
        menu.addItem(ClosureMenuItem(L("關於 TeachOverlay"), icon: .circleInfo) { [weak self] in self?.showMainWindow(pane: .about) })
        menu.addItem(ClosureMenuItem(L("結束 TeachOverlay"), key: "q") { NSApp.terminate(nil) })
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if let ci = item as? ClosureMenuItem, let s = ci.stateProvider { ci.state = s() ? .on : .off }
        }
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    let stateProvider: (() -> Bool)?

    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [.command], icon: FA? = nil,
         state: (() -> Bool)? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        self.stateProvider = state
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
        if let icon { image = FontAwesome.templateImage(icon, size: 13, style: icon == .github ? .brands : .solid) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
