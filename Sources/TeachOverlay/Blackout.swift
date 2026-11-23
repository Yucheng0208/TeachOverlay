import AppKit
import Combine

enum BlackoutTarget: String, CaseIterable, Identifiable {
    case external = "外接螢幕（保留筆電畫面）", all = "全部螢幕", custom = "自選螢幕"
    var id: String { rawValue }
}

/// 黑屏：讓投影／外接螢幕變黑，老師的筆電照常顯示
@MainActor
final class BlackoutController: ObservableObject {
    static let shared = BlackoutController()
    private let d = UserDefaults.standard

    @Published private(set) var active = false
    @Published var target: BlackoutTarget { didSet { d.set(target.rawValue, forKey: "black.target"); if active { apply() } } }
    /// 自選時要黑掉的螢幕（以螢幕名稱記住）
    @Published var customScreens: Set<String> { didSet { d.set(Array(customScreens), forKey: "black.custom"); if active { apply() } } }
    @Published var showMessage: Bool { didSet { d.set(showMessage, forKey: "black.message"); if active { apply() } } }

    private var windows: [NSWindow] = []

    private init() {
        d.register(defaults: ["black.target": BlackoutTarget.external.rawValue, "black.message": false])
        target = BlackoutTarget(rawValue: d.string(forKey: "black.target") ?? "") ?? .external
        customScreens = Set(d.stringArray(forKey: "black.custom") ?? [])
        showMessage = d.bool(forKey: "black.message")
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.active == true { self?.apply() } }
        }
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    var screens: [NSScreen] { NSScreen.screens }

    private func targetScreens() -> [NSScreen] {
        switch target {
        case .all: return screens
        case .external:
            let ext = screens.filter { !Self.isBuiltIn($0) }
            // 只有一個螢幕（或鏡像輸出）時就黑掉全部
            return ext.isEmpty ? screens : ext
        case .custom: return screens.filter { customScreens.contains($0.localizedName) }
        }
    }

    func toggle() { active ? deactivate() : activate() }

    func activate() {
        active = true
        apply()
    }

    func deactivate() {
        active = false
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func apply() {
        windows.forEach { $0.orderOut(nil) }
        windows = targetScreens().map { screen in
            let w = BlackoutWindow(screen: screen, message: showMessage ? L("請看老師") : nil)
            w.onDismiss = { [weak self] in self?.deactivate() }
            w.orderFrontRegardless()
            return w
        }
        if windows.isEmpty { active = false }
    }
}

private final class BlackoutWindow: NSWindow {
    var onDismiss: (() -> Void)?

    init(screen: NSScreen, message: String?) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .black
        isOpaque = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: true)
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        if let message {
            let l = NSTextField(labelWithString: message)
            l.font = .systemFont(ofSize: 48, weight: .semibold)
            l.textColor = NSColor(white: 0.55, alpha: 1)
            l.sizeToFit()
            l.frame.origin = CGPoint(x: (v.bounds.width - l.frame.width) / 2, y: (v.bounds.height - l.frame.height) / 2)
            l.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            v.addSubview(l)
        }
        contentView = v
    }

    override var canBecomeKey: Bool { true }
    // 在黑掉的畫面上點一下或按 Esc 恢復（避免全黑時找不到開關）
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onDismiss?() } }
}
