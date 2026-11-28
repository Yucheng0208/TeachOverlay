import AppKit
import QuartzCore

/// 螢幕上提示（按鍵泡泡、快捷鍵、滑鼠圖示、工具列）的配色
struct OverlayTheme: Equatable {
    var dark: Bool
    var background: NSColor { dark ? NSColor.black.withAlphaComponent(0.8) : NSColor(white: 1, alpha: 0.94) }
    var text: NSColor { dark ? .white : NSColor(white: 0.12, alpha: 1) }
    var border: NSColor { dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.14) }

    @MainActor static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// 每個螢幕一個：透明、無邊框、置頂、滑鼠穿透的疊加層視窗
@MainActor
final class OverlayWindow: NSWindow {
    let overlayView: OverlayView
    var keyHandler: ((NSEvent) -> Void)?

    init(screen: NSScreen) {
        overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = overlayView
        overlayView.topInset = screen.frame.maxY - screen.visibleFrame.maxY
        overlayView.bottomInset = screen.visibleFrame.minY - screen.frame.minY
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) { keyHandler?(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let keyHandler else { return false }
        keyHandler(event)
        return true
    }

    func toLocal(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - frame.minX, y: global.y - frame.minY)
    }
}

@MainActor
final class OverlayView: NSView {
    let canvas = CanvasView(frame: .zero)
    let effects = EffectsView(frame: .zero)
    let hud = BubbleView(fontSize: 44)
    let shortcuts = ShortcutStackView(frame: .zero)
    let mouseBadge = MouseBadgeView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
    private(set) var toolbarView: NSView?
    var toolbarLayout: ToolbarLayout?

    /// 選單列高度與 Dock 高度（避免蓋住）
    var topInset: CGFloat = 30 { didSet { needsLayout = true } }
    var bottomInset: CGFloat = 0 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for v in [canvas, effects, shortcuts] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        addSubview(hud)
        addSubview(mouseBadge)
    }

    required init?(coder: NSCoder) { fatalError() }

    func installToolbar(_ v: NSView) {
        toolbarView?.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: centerXAnchor),
            v.topAnchor.constraint(equalTo: topAnchor, constant: topInset + 10),
        ])
        v.isHidden = true
        toolbarView = v
    }

    override func layout() {
        super.layout()
        hud.topInset = topInset + 70
        hud.bottomInset = bottomInset + 90
        hud.reposition()
        shortcuts.topInset = topInset + 12
        shortcuts.relayout()
    }
}

/// 右上／左上角：快捷鍵懸停保留
@MainActor
final class ShortcutStackView: NSView {
    enum Corner: String, CaseIterable, Identifiable {
        case off = "關閉", topLeft = "左上", topRight = "右上"
        var id: String { rawValue }
    }

    var corner: Corner = .topRight { didSet { relayout() } }
    var topInset: CGFloat = 40
    var fontSize: CGFloat = 22 { didSet { rebuild() } }
    var theme = OverlayTheme(dark: true) { didSet { if theme != oldValue { rebuild() } } }
    private var texts: [String] = []
    private var pills: [NSView] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func rebuild() {
        let t = texts
        texts = []
        setItems(t)
    }

    func setItems(_ items: [String]) {
        guard items != texts || pills.count != items.count else { return }
        texts = items
        pills.forEach { $0.removeFromSuperview() }
        pills = items.enumerated().map { i, text in
            let pill = makePill(text)
            pill.alphaValue = max(1 - CGFloat(i) * 0.14, 0.35)   // 越舊越淡
            addSubview(pill)
            return pill
        }
        relayout()
    }

    private func makePill(_ text: String) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = theme.background.cgColor
        v.layer?.cornerRadius = fontSize * 0.45
        v.layer?.borderColor = theme.border.cgColor
        v.layer?.borderWidth = 1
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: fontSize, weight: .semibold)
        l.textColor = theme.text
        let size = l.fittingSize
        let padX = fontSize * 0.6, padY = fontSize * 0.3
        v.frame.size = NSSize(width: size.width + padX * 2, height: size.height + padY * 2)
        l.frame = NSRect(x: padX, y: padY, width: size.width, height: size.height)
        v.addSubview(l)
        return v
    }

    func relayout() {
        isHidden = corner == .off
        var y = bounds.height - topInset
        let floor = bounds.height * 0.35          // 最多用到畫面上方約 65% 高度
        let maxWidth = bounds.width * 0.45
        for p in pills {
            y -= p.frame.height
            p.isHidden = y < floor                // 放不下的舊紀錄先不顯示
            if p.frame.width > maxWidth {
                p.frame.size.width = maxWidth
                if let label = p.subviews.first as? NSTextField {
                    label.lineBreakMode = .byTruncatingTail
                    label.frame.size.width = maxWidth - fontSize * 1.2
                }
            }
            let x = corner == .topLeft ? 20 : bounds.width - p.frame.width - 20
            p.frame.origin = CGPoint(x: x, y: y)
            y -= 8
        }
    }
}

/// 聚光燈與點擊脈衝（Core Animation）
@MainActor
final class EffectsView: NSView {
    private let spotlight = CAShapeLayer()
    private let spotlightRing = CAShapeLayer()
    let lens = LensLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spotlight.fillRule = .evenOdd
        spotlight.fillColor = NSColor.black.withAlphaComponent(0.62).cgColor
        spotlight.isHidden = true
        spotlightRing.fillColor = nil
        spotlightRing.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        spotlightRing.lineWidth = 2
        spotlightRing.isHidden = true
        layer?.addSublayer(spotlight)
        layer?.addSublayer(spotlightRing)
        layer?.addSublayer(lens.container)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        spotlight.frame = bounds
        spotlightRing.frame = bounds
    }

    func setSpotlightDim(_ alpha: CGFloat) {
        spotlight.fillColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    func setSpotlightVisible(_ visible: Bool) {
        spotlight.isHidden = !visible
        spotlightRing.isHidden = !visible
    }

    func updateSpotlight(center: CGPoint?, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = CGMutablePath()
        p.addRect(bounds)
        if let c = center {
            let r = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            p.addEllipse(in: r)
            spotlightRing.path = CGPath(ellipseIn: r, transform: nil)
        } else {
            spotlightRing.path = nil
        }
        spotlight.path = p
        CATransaction.commit()
    }

    /// 擴散圓圈（大小、速度、圈數、粗細、填色透明度皆可調）
    func pulse(at p: CGPoint, color: NSColor, strong: Bool, style: PulseStyle) {
        guard let root = layer else { return }
        let rings = strong ? style.rings : 1
        let r: CGFloat = (strong ? 24 : 16) * style.scale
        for i in 0..<rings {
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
            ring.position = p
            ring.fillColor = color.withAlphaComponent(style.fillOpacity).cgColor
            ring.strokeColor = color.cgColor
            ring.lineWidth = style.lineWidth
            ring.opacity = 0
            root.addSublayer(ring)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.3
            scale.toValue = strong ? 2.4 : 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = style.duration
            let delay = Double(i) * style.duration * 0.23
            group.beginTime = CACurrentMediaTime() + delay
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "pulse")

            DispatchQueue.main.asyncAfter(deadline: .now() + style.duration + delay + 0.05) {
                ring.removeFromSuperlayer()
            }
        }
    }

    // MARK: 長按圓圈

    private var holdRing: CAShapeLayer?

    func startHold(at p: CGPoint, color: NSColor, scale: CGFloat) {
        endHold()
        guard let root = layer else { return }
        let r = 30 * scale
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ring.position = p
        ring.fillColor = color.withAlphaComponent(0.18).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 4
        root.addSublayer(ring)
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.85
        breathe.toValue = 1.1
        breathe.duration = 0.5
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(breathe, forKey: "breathe")
        holdRing = ring
    }

    func moveHold(to p: CGPoint) {
        guard let holdRing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holdRing.position = p
        CATransaction.commit()
    }

    func endHold() {
        holdRing?.removeFromSuperlayer()
        holdRing = nil
    }
}

enum MouseButton {
    case left, right, middle

    @MainActor var label: String {
        switch self {
        case .left: L("左鍵")
        case .right: L("右鍵")
        case .middle: L("中鍵")
        }
    }
}

struct PulseStyle {
    var scale: CGFloat = 1
    var duration: Double = 0.6
    var rings: Int = 2
    var lineWidth: CGFloat = 3
    var fillOpacity: CGFloat = 0.25
}

/// 游標旁的滑鼠小圖：顯示按下左鍵／右鍵／中鍵、長按
@MainActor
final class MouseBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private(set) var button: MouseButton = .left
    private var color: NSColor = .systemYellow
    private var long = false
    var theme = OverlayTheme(dark: true) {
        didSet {
            layer?.backgroundColor = theme.background.cgColor
            label.textColor = theme.text
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor
        layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = theme.text
        addSubview(label)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ button: MouseButton, long: Bool, color: NSColor) {
        self.button = button
        self.long = long
        self.color = color
        label.stringValue = long ? LF("長按%@", button.label) : button.label
        let size = label.fittingSize
        frame.size = NSSize(width: 44 + size.width + 12, height: 50)
        label.frame = NSRect(x: 44, y: (50 - size.height) / 2, width: size.width, height: size.height)
        layer?.borderColor = long ? color.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = long ? 2 : 0
        needsDisplay = true
        alphaValue = 1
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }
    }

    func hideNowIfNeeded() { alphaValue = 0 }

    func move(cursor p: CGPoint) {
        setFrameOrigin(CGPoint(x: p.x + 22, y: p.y - 22 - frame.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 12, y: 7, width: 22, height: 36)
        let shape = NSBezierPath(roundedRect: body, xRadius: 11, yRadius: 11)
        let splitY = body.minY + body.height * 0.55

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        color.setFill()
        switch button {
        case .left: NSRect(x: body.minX, y: splitY, width: body.width / 2, height: body.maxY - splitY).fill()
        case .right: NSRect(x: body.midX, y: splitY, width: body.width / 2, height: body.maxY - splitY).fill()
        case .middle: NSRect(x: body.midX - 3, y: splitY + 3, width: 6, height: 10).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        theme.text.setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1.5
        lines.move(to: CGPoint(x: body.minX, y: splitY))
        lines.line(to: CGPoint(x: body.maxX, y: splitY))
        lines.move(to: CGPoint(x: body.midX, y: splitY))
        lines.line(to: CGPoint(x: body.midX, y: body.maxY))
        lines.stroke()
    }
}

/// 圓角深色泡泡：按鍵 HUD
@MainActor
final class BubbleView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    var anchorTop = false { didSet { reposition() } }
    var theme = OverlayTheme(dark: true) {
        didSet {
            layer?.backgroundColor = theme.background.cgColor
            layer?.borderColor = theme.border.cgColor
            label.textColor = theme.text
        }
    }
    var topInset: CGFloat = 100
    var bottomInset: CGFloat = 110

    var fontSize: CGFloat {
        didSet { label.font = .systemFont(ofSize: fontSize, weight: .semibold); reposition() }
    }

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor
        layer?.borderColor = theme.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = max(10, fontSize * 0.4)
        label.font = .systemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = theme.text
        label.alignment = .center
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 3
        addSubview(label)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// duration = nil 表示一直顯示
    func show(_ text: String, duration: TimeInterval? = 1.6) {
        label.stringValue = text
        reposition()
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            animator().alphaValue = 1
        }
        if let duration {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.fadeOut() }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            animator().alphaValue = 0
        }
    }

    func hideNow() {
        hideWork?.cancel()
        alphaValue = 0
    }

    func reposition() {
        guard let sv = superview else { return }
        let maxW = sv.bounds.width * 0.85
        let padX = fontSize * 0.6 + 8, padY = fontSize * 0.3 + 6
        let fit = label.sizeThatFits(NSSize(width: maxW - padX * 2, height: .greatestFiniteMagnitude))
        let w = min(max(fit.width + padX * 2, fontSize * 2.5), maxW)
        let h = fit.height + padY * 2
        let y = anchorTop ? sv.bounds.height - topInset - h : bottomInset
        frame = NSRect(x: (sv.bounds.width - w) / 2, y: y, width: w, height: h)
        label.frame = NSRect(x: padX, y: padY, width: w - padX * 2, height: fit.height)
    }
}
