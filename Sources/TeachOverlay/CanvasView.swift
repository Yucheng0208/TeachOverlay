import AppKit
import Combine

enum DrawTool: String, CaseIterable {
    case pen = "畫筆", highlighter = "螢光筆", line = "直線", arrow = "箭頭", rect = "方框", ellipse = "圓形"
    case compass = "圓規"

    var key: String {
        switch self {
        case .pen: "P"
        case .highlighter: "H"
        case .line: "L"
        case .arrow: "A"
        case .rect: "R"
        case .ellipse: "O"
        case .compass: "G"
        }
    }
}

enum BoardStyle: Int, CaseIterable {
    case white, grid, dark, chalk, lines, dots, chalkGrid

    @MainActor var name: String {
        L(["白色", "方格", "深色", "黑板綠", "橫線", "點格", "黑板方格"][rawValue])
    }
    var isDark: Bool { self == .dark || self == .chalk || self == .chalkGrid }
}

/// 筆畫或圖形
struct Stroke {
    enum Kind { case freehand, line, arrow, rect, ellipse, polygon, arc }
    struct Arc { var center: CGPoint; var radius: CGFloat; var start: CGFloat; var sweep: CGFloat }

    var kind: Kind
    var highlighter = false
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
    var arc: Arc?
}

struct BoardPage {
    var strokes: [Stroke] = []
    /// 截圖頁的背景圖
    var image: NSImage?
}

/// 尺：可移動、旋轉，沿邊緣畫直線
struct RulerState {
    var center: CGPoint
    var angle: CGFloat = 0
    var length: CGFloat = 640
    var height: CGFloat = 68
}

/// 圓規：先設定圓心與半徑，再沿圓周拖曳畫弧
struct CompassState {
    enum Phase { case setting, armed, drawing }
    var center: CGPoint
    var radius: CGFloat = 0
    var pencilAngle: CGFloat = 0
    var phase: Phase = .setting
    var startAngle: CGFloat = 0
    var lastAngle: CGFloat = 0
    var sweep: CGFloat = 0
}

@MainActor
final class DrawSettings: ObservableObject {
    static let shared = DrawSettings()
    static let palette: [(name: String, color: NSColor)] = [
        ("紅", .systemRed), ("藍", .systemBlue), ("綠", .systemGreen),
        ("黃", .systemYellow), ("黑", .black), ("白", .white),
    ]
    private let d = UserDefaults.standard

    @Published var tool: DrawTool { didSet { d.set(tool.rawValue, forKey: "draw.tool") } }
    @Published var colorIndex: Int { didSet { d.set(colorIndex, forKey: "draw.color") } }
    @Published var width: CGFloat { didSet { d.set(Double(width), forKey: "draw.width") } }
    /// 停住不放就自動變成直線、圓、方形或多邊形
    @Published var holdToSnap: Bool { didSet { d.set(holdToSnap, forKey: "draw.holdSnap") } }
    @Published var holdDelay: Double { didSet { d.set(holdDelay, forKey: "draw.holdDelay") } }
    var color: NSColor { Self.palette[colorIndex].color }

    private init() {
        d.register(defaults: ["draw.tool": DrawTool.pen.rawValue, "draw.color": 0, "draw.width": 4.0,
                              "draw.holdSnap": true, "draw.holdDelay": 0.5])
        tool = DrawTool(rawValue: d.string(forKey: "draw.tool") ?? "") ?? .pen
        colorIndex = min(max(d.integer(forKey: "draw.color"), 0), Self.palette.count - 1)
        width = CGFloat(d.double(forKey: "draw.width"))
        holdToSnap = d.bool(forKey: "draw.holdSnap")
        holdDelay = d.double(forKey: "draw.holdDelay")
    }
}

/// 畫布：螢幕標註（透明背景）與白板（不透明背景、多頁）共用
@MainActor
final class CanvasView: NSView {
    private(set) var annotations: [Stroke] = []
    private(set) var pages: [BoardPage] = [BoardPage()]
    private(set) var pageIndex = 0
    private var current: Stroke?

    // 停住變形
    private var holdTimer: Timer?
    private var lastMovePoint = CGPoint.zero
    private var lastMoveTime = Date()
    private var snapped = false

    // 尺與圓規
    private(set) var ruler: RulerState?
    private var rulerDrag: (mode: RulerDragMode, offset: CGPoint, angleOffset: CGFloat)?
    private var rulerEdge: CGFloat?   // 沿尺畫線時：+1 上緣、-1 下緣
    private var compass: CompassState?
    private var hideInstruments = false
    private enum RulerDragMode { case move, rotate }

    /// 內容改變時通知（讓工具列更新頁碼等）
    var onChange: (() -> Void)?

    var whiteboard = false { didSet { needsDisplay = true; onChange?() } }
    var boardStyle: BoardStyle = .white { didSet { needsDisplay = true } }
    var drawingEnabled = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            if !drawingEnabled { compass = nil; needsDisplay = true }
        }
    }

    private var strokes: [Stroke] {
        get { whiteboard ? pages[pageIndex].strokes : annotations }
        set {
            if whiteboard { pages[pageIndex].strokes = newValue } else { annotations = newValue }
            needsDisplay = true
            onChange?()
        }
    }

    var currentPageHasImage: Bool { whiteboard && pages[pageIndex].image != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if drawingEnabled { addCursorRect(bounds, cursor: .crosshair) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        drawingEnabled ? super.hitTest(point) : nil
    }

    // MARK: 滑鼠

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = DrawSettings.shared

        // 尺：拖曳移動、拖曳把手旋轉
        if let r = ruler, let mode = rulerHit(p, r) {
            let angleNow = atan2(p.y - r.center.y, p.x - r.center.x)
            rulerDrag = (mode, CGPoint(x: p.x - r.center.x, y: p.y - r.center.y), angleNow - r.angle)
            return
        }

        if s.tool == .compass {
            compassDown(p)
            return
        }
        compass = nil

        let width = s.tool == .highlighter ? max(s.width * 4, 16) : s.width
        let kind: Stroke.Kind
        switch s.tool {
        case .pen, .highlighter, .compass: kind = .freehand
        case .line: kind = .line
        case .arrow: kind = .arrow
        case .rect: kind = .rect
        case .ellipse: kind = .ellipse
        }

        // 沿尺邊緣畫直線
        rulerEdge = nil
        if let r = ruler, kind == .freehand || kind == .line || kind == .arrow, let edge = nearRulerEdge(p, r) {
            rulerEdge = edge
            let start = projectOnRulerEdge(p, r, edge: edge, strokeWidth: width)
            current = Stroke(kind: kind == .arrow ? .arrow : .line, highlighter: s.tool == .highlighter,
                             color: s.color, width: width, points: [start, start])
            needsDisplay = true
            return
        }

        current = Stroke(kind: kind, highlighter: s.tool == .highlighter, color: s.color, width: width, points: [p])
        snapped = false
        if kind == .freehand && s.holdToSnap {
            lastMovePoint = p
            lastMoveTime = Date()
            holdTimer?.invalidate()
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHold() }
            }
            RunLoop.main.add(t, forMode: .common)
            holdTimer = t
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if let drag = rulerDrag, var r = ruler {
            switch drag.mode {
            case .move:
                r.center = CGPoint(x: p.x - drag.offset.x, y: p.y - drag.offset.y)
            case .rotate:
                var a = atan2(p.y - r.center.y, p.x - r.center.x) - drag.angleOffset
                let deg = a * 180 / .pi
                let snap = (deg / 15).rounded() * 15      // 接近 15° 倍數時吸附
                if abs(deg - snap) < 2 { a = snap * .pi / 180 }
                r.angle = a
            }
            ruler = r
            needsDisplay = true
            return
        }

        if compass != nil, DrawSettings.shared.tool == .compass {
            compassDragged(p)
            return
        }

        guard var c = current else { return }

        if let edge = rulerEdge, let r = ruler {
            c.points[1] = projectOnRulerEdge(p, r, edge: edge, strokeWidth: c.width)
            current = c
            needsDisplay = true
            return
        }

        switch c.kind {
        case .freehand:
            if hypot(p.x - lastMovePoint.x, p.y - lastMovePoint.y) > 3 {
                lastMovePoint = p
                lastMoveTime = Date()
            }
            c.points.append(p)
        case .line where snapped:
            c.points[1] = p      // 已變成直線：終點繼續跟著游標
        case .line, .arrow, .rect, .ellipse:
            if snapped { return }
            // 形狀工具：只保留起點與終點；按住 Shift 畫水平/垂直或正方形/正圓
            var end = p
            if event.modifierFlags.contains(.shift), let start = c.points.first {
                end = constrain(start: start, end: p, kind: c.kind)
            }
            if c.points.count == 1 { c.points.append(end) } else { c.points[1] = end }
        default:
            return
        }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        if rulerDrag != nil { rulerDrag = nil; return }
        if DrawSettings.shared.tool == .compass, compass != nil { compassUp(); return }

        guard var c = current else { return }
        current = nil
        rulerEdge = nil
        if c.points.count == 1 {
            guard c.kind == .freehand else { needsDisplay = true; return }
            c.points.append(c.points[0])  // 點一下畫一個點
        }
        strokes.append(c)
    }

    private func constrain(start: CGPoint, end: CGPoint, kind: Stroke.Kind) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch kind {
        case .rect, .ellipse:
            let d = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -d : d), y: start.y + (dy < 0 ? -d : d))
        default:
            return abs(dx) > abs(dy) ? CGPoint(x: end.x, y: start.y) : CGPoint(x: start.x, y: end.y)
        }
    }

    // MARK: 停住變形（畫完停一下：直線、圓、方形、三角形、多邊形）

    private func checkHold() {
        guard !snapped, var c = current, c.kind == .freehand, c.points.count > 6,
              Date().timeIntervalSince(lastMoveTime) >= DrawSettings.shared.holdDelay else { return }
        guard let shape = ShapeRecognizer.recognize(c.points) else { return }
        c.kind = shape.kind
        c.points = shape.points
        current = c
        snapped = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        needsDisplay = true
    }

    // MARK: 尺

    func toggleRuler() {
        if ruler == nil {
            ruler = RulerState(center: CGPoint(x: bounds.midX, y: bounds.midY),
                               length: min(640, max(300, bounds.width * 0.6)))
        } else {
            ruler = nil
        }
        needsDisplay = true
        onChange?()
    }

    private func rulerLocal(_ p: CGPoint, _ r: RulerState) -> CGPoint {
        let dx = p.x - r.center.x, dy = p.y - r.center.y
        let c = cos(-r.angle), s = sin(-r.angle)
        return CGPoint(x: dx * c - dy * s, y: dx * s + dy * c)
    }

    private func rulerWorld(_ q: CGPoint, _ r: RulerState) -> CGPoint {
        let c = cos(r.angle), s = sin(r.angle)
        return CGPoint(x: r.center.x + q.x * c - q.y * s, y: r.center.y + q.x * s + q.y * c)
    }

    private func rulerHit(_ p: CGPoint, _ r: RulerState) -> RulerDragMode? {
        let q = rulerLocal(p, r)
        let knob = CGPoint(x: r.length / 2 - 26, y: 0)
        if hypot(q.x - knob.x, q.y - knob.y) < 16 { return .rotate }
        // 邊緣 14pt 內留給畫線，中間區域才是拖曳
        if abs(q.x) <= r.length / 2, abs(q.y) <= r.height / 2 - 14 { return .move }
        return nil
    }

    private func nearRulerEdge(_ p: CGPoint, _ r: RulerState) -> CGFloat? {
        let q = rulerLocal(p, r)
        guard abs(q.x) <= r.length / 2 + 30 else { return nil }
        if abs(q.y - r.height / 2) < 22 { return 1 }
        if abs(q.y + r.height / 2) < 22 { return -1 }
        return nil
    }

    private func projectOnRulerEdge(_ p: CGPoint, _ r: RulerState, edge: CGFloat, strokeWidth: CGFloat) -> CGPoint {
        var q = rulerLocal(p, r)
        q.x = min(max(q.x, -r.length / 2), r.length / 2)
        q.y = edge * (r.height / 2 + strokeWidth / 2 + 1)
        return rulerWorld(q, r)
    }

    /// 螢幕每公釐幾點（用於尺的刻度與圓規半徑）
    private var pointsPerMM: CGFloat {
        if let screen = window?.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            let mm = CGDisplayScreenSize(id).width
            if mm > 0 { return screen.frame.width / mm }
        }
        return 96 / 25.4
    }

    // MARK: 圓規

    private func compassDown(_ p: CGPoint) {
        if var c = compass, c.phase == .armed, abs(hypot(p.x - c.center.x, p.y - c.center.y) - c.radius) < 40 {
            let a = atan2(p.y - c.center.y, p.x - c.center.x)
            c.phase = .drawing
            c.startAngle = a
            c.lastAngle = a
            c.pencilAngle = a
            c.sweep = 0
            compass = c
        } else {
            compass = CompassState(center: p)
        }
        needsDisplay = true
    }

    private func compassDragged(_ p: CGPoint) {
        guard var c = compass else { return }
        let a = atan2(p.y - c.center.y, p.x - c.center.x)
        switch c.phase {
        case .setting:
            c.radius = hypot(p.x - c.center.x, p.y - c.center.y)
            c.pencilAngle = a
        case .drawing:
            var delta = a - c.lastAngle
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            c.sweep = min(max(c.sweep + delta, -2 * .pi), 2 * .pi)
            c.lastAngle = a
            c.pencilAngle = a
        case .armed:
            break
        }
        compass = c
        needsDisplay = true
    }

    private func compassUp() {
        guard var c = compass else { return }
        switch c.phase {
        case .setting:
            if c.radius > 6 { c.phase = .armed; compass = c } else { compass = nil }
        case .drawing:
            if abs(c.sweep) > 0.02 {
                let s = DrawSettings.shared
                strokes.append(Stroke(kind: .arc, color: s.color, width: s.width, points: [],
                                      arc: .init(center: c.center, radius: c.radius, start: c.startAngle, sweep: c.sweep)))
            }
            c.phase = .armed
            compass = c
        case .armed:
            break
        }
        needsDisplay = true
    }

    // MARK: 操作

    func undo() { if !strokes.isEmpty { strokes.removeLast() } }
    func clear() { strokes = [] }
    func clearAnnotations() { annotations = []; ruler = nil; compass = nil; needsDisplay = true }

    func newPage() {
        pages.insert(BoardPage(), at: pageIndex + 1)
        pageIndex += 1
        needsDisplay = true
        onChange?()
    }

    /// 截圖後新增一頁，背景就是截圖
    func addImagePage(_ image: NSImage) {
        pages.insert(BoardPage(image: image), at: pageIndex + 1)
        pageIndex += 1
        needsDisplay = true
        onChange?()
    }

    func goToPage(_ delta: Int) {
        pageIndex = min(max(pageIndex + delta, 0), pages.count - 1)
        needsDisplay = true
        onChange?()
    }

    var pageLabel: String { LF("第 %d / %d 頁", pageIndex + 1, pages.count) }

    func snapshotPNG() -> Data? {
        hideInstruments = true
        defer { hideInstruments = false; needsDisplay = true }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    func copyToPasteboard() -> Bool {
        guard let data = snapshotPNG() else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setData(data, forType: .png)
    }

    // MARK: 繪製

    override func draw(_ dirtyRect: NSRect) {
        if whiteboard {
            drawBoard()
            if let img = pages[pageIndex].image { drawPageImage(img) }
        }
        for s in strokes { render(s) }
        if let current { render(current) }
        if !hideInstruments {
            if let ruler { drawRuler(ruler) }
            if let compass, DrawSettings.shared.tool == .compass { drawCompass(compass) }
        }
        if whiteboard && !hideInstruments { drawPageIndicator() }
    }

    private func drawPageImage(_ img: NSImage) {
        var size = img.size
        let area = bounds
        if size.width > area.width || size.height > area.height {
            let k = min((area.width - 48) / size.width, (area.height - 48) / size.height)
            size = NSSize(width: size.width * k, height: size.height * k)
        }
        let rect = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                          width: size.width, height: size.height)
        if rect.size != area.size {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 18
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.set()
            NSColor.white.setFill()
            rect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        img.draw(in: rect)
    }

    private func drawBoard() {
        let white = NSColor.white
        let chalk = NSColor(calibratedRed: 0.13, green: 0.27, blue: 0.21, alpha: 1)
        switch boardStyle {
        case .white: white.setFill(); bounds.fill()
        case .dark: NSColor(calibratedWhite: 0.11, alpha: 1).setFill(); bounds.fill()
        case .chalk: chalk.setFill(); bounds.fill()
        case .grid:
            white.setFill(); bounds.fill()
            drawGrid(color: NSColor(calibratedWhite: 0.86, alpha: 1), step: 32, horizontalOnly: false)
        case .chalkGrid:
            chalk.setFill(); bounds.fill()
            drawGrid(color: NSColor.white.withAlphaComponent(0.14), step: 40, horizontalOnly: false)
        case .lines:
            white.setFill(); bounds.fill()
            drawGrid(color: NSColor(calibratedRed: 0.62, green: 0.75, blue: 0.92, alpha: 1), step: 36, horizontalOnly: true)
            NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.55, alpha: 1).setStroke()
            let margin = NSBezierPath()
            margin.lineWidth = 1.5
            margin.move(to: CGPoint(x: 90, y: 0)); margin.line(to: CGPoint(x: 90, y: bounds.height))
            margin.stroke()
        case .dots:
            white.setFill(); bounds.fill()
            NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
            let step: CGFloat = 28
            var y = step
            while y < bounds.height {
                var x = step
                while x < bounds.width {
                    NSBezierPath(ovalIn: NSRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)).fill()
                    x += step
                }
                y += step
            }
        }
    }

    private func drawGrid(color: NSColor, step: CGFloat, horizontalOnly: Bool) {
        color.setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        if !horizontalOnly {
            var x: CGFloat = 0
            while x < bounds.width { grid.move(to: CGPoint(x: x, y: 0)); grid.line(to: CGPoint(x: x, y: bounds.height)); x += step }
        }
        var y: CGFloat = 0
        while y < bounds.height { grid.move(to: CGPoint(x: 0, y: y)); grid.line(to: CGPoint(x: bounds.width, y: y)); y += step }
        grid.stroke()
    }

    private func drawPageIndicator() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: boardStyle.isDark ? NSColor(calibratedWhite: 0.7, alpha: 1) : NSColor(calibratedWhite: 0.45, alpha: 1),
        ]
        let s = pageLabel as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: bounds.width - size.width - 24, y: 20), withAttributes: attrs)
    }

    private func render(_ s: Stroke) {
        let path = NSBezierPath()
        path.lineWidth = s.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let color = s.highlighter ? s.color.withAlphaComponent(0.35) : s.color

        if s.kind == .arc, let a = s.arc {
            let start = a.start * 180 / .pi
            let end = (a.start + a.sweep) * 180 / .pi
            if abs(a.sweep) >= 2 * .pi - 0.01 {
                path.appendOval(in: NSRect(x: a.center.x - a.radius, y: a.center.y - a.radius,
                                           width: a.radius * 2, height: a.radius * 2))
            } else {
                path.appendArc(withCenter: a.center, radius: a.radius, startAngle: start, endAngle: end,
                               clockwise: a.sweep < 0)
            }
            color.setStroke()
            path.stroke()
            return
        }

        guard let first = s.points.first, let last = s.points.last else { return }
        switch s.kind {
        case .freehand:
            path.move(to: first)
            for p in s.points.dropFirst() { path.line(to: p) }
        case .line:
            path.move(to: first); path.line(to: last)
        case .arrow:
            path.move(to: first); path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let len = max(16, s.width * 4.5)
            let head = NSBezierPath()
            head.move(to: last)
            head.line(to: CGPoint(x: last.x - len * cos(angle - 0.45), y: last.y - len * sin(angle - 0.45)))
            head.line(to: CGPoint(x: last.x - len * cos(angle + 0.45), y: last.y - len * sin(angle + 0.45)))
            head.close()
            color.setFill()
            if hypot(last.x - first.x, last.y - first.y) > 4 { head.fill() }
        case .rect:
            path.appendRect(rectBetween(first, last))
        case .ellipse:
            path.appendOval(in: rectBetween(first, last))
        case .polygon:
            path.move(to: first)
            for p in s.points.dropFirst() { path.line(to: p) }
            path.close()
        case .arc:
            break
        }
        color.setStroke()
        path.stroke()
    }

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: 尺與圓規的外觀

    private func drawRuler(_ r: RulerState) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: r.center.x, y: r.center.y)
        ctx.rotate(by: r.angle)

        let body = NSRect(x: -r.length / 2, y: -r.height / 2, width: r.length, height: r.height)
        let shape = NSBezierPath(roundedRect: body, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        NSColor(calibratedRed: 0.99, green: 0.93, blue: 0.62, alpha: 0.82).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 0.25, alpha: 0.6).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // 刻度：1 mm 短、5 mm 中、10 mm 長並標 cm
        let ppm = pointsPerMM
        let tick = NSBezierPath()
        tick.lineWidth = 1
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1),
        ]
        var mm = 0
        while CGFloat(mm) * ppm <= r.length - 12 {
            let x = -r.length / 2 + 6 + CGFloat(mm) * ppm
            let h: CGFloat = mm % 10 == 0 ? 16 : (mm % 5 == 0 ? 11 : 6)
            tick.move(to: CGPoint(x: x, y: r.height / 2))
            tick.line(to: CGPoint(x: x, y: r.height / 2 - h))
            tick.move(to: CGPoint(x: x, y: -r.height / 2))
            tick.line(to: CGPoint(x: x, y: -r.height / 2 + h))
            if mm % 10 == 0 {
                let label = "\(mm / 10)" as NSString
                let sz = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: x - sz.width / 2, y: r.height / 2 - 30), withAttributes: attrs)
            }
            mm += 1
        }
        NSColor(calibratedWhite: 0.2, alpha: 0.85).setStroke()
        tick.stroke()

        // 角度
        var deg = Int((r.angle * 180 / .pi).rounded()) % 360
        if deg < 0 { deg += 360 }
        let angleText = "\(deg)°" as NSString
        let angleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
        ]
        let asz = angleText.size(withAttributes: angleAttrs)
        angleText.draw(at: CGPoint(x: -asz.width / 2, y: -asz.height / 2 - 6), withAttributes: angleAttrs)

        // 旋轉把手
        let knob = NSRect(x: r.length / 2 - 26 - 11, y: -11, width: 22, height: 22)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor(calibratedWhite: 0.3, alpha: 1).setStroke()
        let kp = NSBezierPath(ovalIn: knob)
        kp.lineWidth = 1.5
        kp.stroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.5
        arrow.appendArc(withCenter: CGPoint(x: knob.midX, y: knob.midY), radius: 6, startAngle: 30, endAngle: 300)
        arrow.stroke()
        ctx.restoreGState()
    }

    private func drawCompass(_ c: CompassState) {
        let accent = DrawSettings.shared.color
        let pencil = CGPoint(x: c.center.x + c.radius * cos(c.pencilAngle), y: c.center.y + c.radius * sin(c.pencilAngle))

        // 輔助虛線圓
        if c.radius > 6 {
            let guide = NSBezierPath(ovalIn: NSRect(x: c.center.x - c.radius, y: c.center.y - c.radius,
                                                    width: c.radius * 2, height: c.radius * 2))
            guide.setLineDash([6, 6], count: 2, phase: 0)
            guide.lineWidth = 1
            NSColor.systemGray.withAlphaComponent(0.6).setStroke()
            guide.stroke()
        }
        // 正在畫的弧
        if c.phase == .drawing, abs(c.sweep) > 0.01 {
            render(Stroke(kind: .arc, color: accent, width: DrawSettings.shared.width, points: [],
                          arc: .init(center: c.center, radius: c.radius, start: c.startAngle, sweep: c.sweep)))
        }
        // 兩支腳與鉸鏈
        let mid = CGPoint(x: (c.center.x + pencil.x) / 2, y: (c.center.y + pencil.y) / 2)
        let dx = pencil.x - c.center.x, dy = pencil.y - c.center.y
        let len = max(hypot(dx, dy), 1)
        var nx = -dy / len, ny = dx / len
        if ny < 0 { nx = -nx; ny = -ny }   // 鉸鏈朝上
        let h = max(50, c.radius * 0.55)
        let hinge = CGPoint(x: mid.x + nx * h, y: mid.y + ny * h)

        let legs = NSBezierPath()
        legs.lineWidth = 5
        legs.lineCapStyle = .round
        legs.move(to: c.center); legs.line(to: hinge); legs.line(to: pencil)
        NSColor(calibratedWhite: 0.35, alpha: 0.9).setStroke()
        legs.stroke()
        NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: hinge.x - 7, y: hinge.y - 7, width: 14, height: 14)).fill()
        NSBezierPath(ovalIn: NSRect(x: c.center.x - 3, y: c.center.y - 3, width: 6, height: 6)).fill()
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: pencil.x - 5, y: pencil.y - 5, width: 10, height: 10)).fill()

        // 半徑
        if c.radius > 6 {
            let cm = c.radius / pointsPerMM / 10
            let text = String(format: "r = %.1f cm", cm) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.6),
            ]
            text.draw(at: CGPoint(x: mid.x + 8, y: mid.y - 18), withAttributes: attrs)
        }
    }
}

/// 手繪辨識：直線、圓／橢圓、長方形、三角形與多邊形
enum ShapeRecognizer {
    static func recognize(_ pts: [CGPoint]) -> (kind: Stroke.Kind, points: [CGPoint])? {
        guard pts.count > 4 else { return nil }
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard length > 30 else { return nil }
        let first = pts.first!, last = pts.last!
        let chord = hypot(last.x - first.x, last.y - first.y)

        // 直線：所有點都離首尾連線很近
        if chord > 0.8 * length * 0.9 || chord > 0.85 * length {
            let maxDev = pts.map { distance($0, toLine: first, last) }.max() ?? 0
            if maxDev < max(10, chord * 0.06) {
                return (.line, [first, snapAngle(from: first, to: last)])
            }
        }

        // 封閉圖形
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let bbox = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let diag = hypot(bbox.width, bbox.height)
        guard chord < max(40, length * 0.18), diag > 24 else { return nil }

        var simplified = rdp(pts, epsilon: diag * 0.07)
        if simplified.count > 2, hypot(simplified.first!.x - simplified.last!.x, simplified.first!.y - simplified.last!.y) < diag * 0.15 {
            simplified.removeLast()
        }
        let n = simplified.count

        // 圓／橢圓：點到中心距離的變異很小
        let cx = xs.reduce(0, +) / CGFloat(xs.count), cy = ys.reduce(0, +) / CGFloat(ys.count)
        let radii = pts.map { hypot($0.x - cx, $0.y - cy) }
        let mean = radii.reduce(0, +) / CGFloat(radii.count)
        let sd = sqrt(radii.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(radii.count))
        let cv = mean > 0 ? sd / mean : 1

        if n >= 3 && n <= 5 && cv > 0.07 {
            return polygonResult(simplified)
        }
        if cv < 0.2 || n > 8 {
            let aspect = bbox.width / max(bbox.height, 1)
            if aspect > 0.85 && aspect < 1.18 {
                let r = mean
                return (.ellipse, [CGPoint(x: cx - r, y: cy - r), CGPoint(x: cx + r, y: cy + r)])
            }
            return (.ellipse, [CGPoint(x: bbox.minX, y: bbox.minY), CGPoint(x: bbox.maxX, y: bbox.maxY)])
        }
        if n >= 3 && n <= 8 { return polygonResult(simplified) }
        return nil
    }

    private static func polygonResult(_ v: [CGPoint]) -> (kind: Stroke.Kind, points: [CGPoint]) {
        if v.count == 4 {
            // 四個角都接近 90° → 長方形
            let angles = (0..<4).map { i -> CGFloat in
                let a = v[(i + 3) % 4], b = v[i], c = v[(i + 1) % 4]
                let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
                let dot = v1.x * v2.x + v1.y * v2.y
                let m = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
                return acos(max(-1, min(1, dot / max(m, 0.001)))) * 180 / .pi
            }
            if angles.allSatisfy({ abs($0 - 90) < 18 }) {
                let edge = CGPoint(x: v[1].x - v[0].x, y: v[1].y - v[0].y)
                var theta = atan2(edge.y, edge.x)
                let deg = theta * 180 / .pi
                let nearest = (deg / 90).rounded() * 90
                if abs(deg - nearest) < 10 {
                    let xs = v.map(\.x), ys = v.map(\.y)
                    return (.rect, [CGPoint(x: xs.min()!, y: ys.min()!), CGPoint(x: xs.max()!, y: ys.max()!)])
                }
                // 傾斜的長方形：沿主軸取外接框
                theta = atan2(edge.y, edge.x)
                let u = CGPoint(x: cos(theta), y: sin(theta)), n = CGPoint(x: -sin(theta), y: cos(theta))
                let pu = v.map { $0.x * u.x + $0.y * u.y }, pn = v.map { $0.x * n.x + $0.y * n.y }
                let (u0, u1, n0, n1) = (pu.min()!, pu.max()!, pn.min()!, pn.max()!)
                func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: a * u.x + b * n.x, y: a * u.y + b * n.y) }
                return (.polygon, [pt(u0, n0), pt(u1, n0), pt(u1, n1), pt(u0, n1)])
            }
        }
        return (.polygon, v)
    }

    private static func snapAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let deg = atan2(dy, dx) * 180 / .pi
        let nearest = (deg / 45).rounded() * 45
        guard abs(deg - nearest) < 6 else { return b }
        let r = nearest * .pi / 180
        return CGPoint(x: a.x + len * cos(r), y: a.y + len * sin(r))
    }

    private static func distance(_ p: CGPoint, toLine a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }

    /// Ramer–Douglas–Peucker 折線簡化
    private static func rdp(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxD: CGFloat = 0, idx = 0
        for i in 1..<(pts.count - 1) {
            let d = distance(pts[i], toLine: pts.first!, pts.last!)
            if d > maxD { maxD = d; idx = i }
        }
        // 封閉路徑首尾重合時，改用離起點最遠的點切開
        if hypot(pts.first!.x - pts.last!.x, pts.first!.y - pts.last!.y) < 1 {
            idx = pts.indices.max { hypot(pts[$0].x - pts[0].x, pts[$0].y - pts[0].y) < hypot(pts[$1].x - pts[0].x, pts[$1].y - pts[0].y) } ?? idx
            maxD = epsilon + 1
        }
        guard maxD > epsilon else { return [pts.first!, pts.last!] }
        let left = rdp(Array(pts[...idx]), epsilon: epsilon)
        let right = rdp(Array(pts[idx...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }
}
