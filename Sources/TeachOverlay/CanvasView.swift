import AppKit
import Combine

enum DrawTool: String, CaseIterable {
    case pen = "畫筆", highlighter = "螢光筆", line = "直線", arrow = "箭頭", rect = "方框", ellipse = "圓形"

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .ellipse: "circle"
        }
    }

    var key: String {
        switch self {
        case .pen: "P"
        case .highlighter: "H"
        case .line: "L"
        case .arrow: "A"
        case .rect: "R"
        case .ellipse: "O"
        }
    }
}

enum BoardStyle: Int, CaseIterable {
    case white, grid, dark, chalk
    @MainActor var name: String { L(["白色", "方格", "深色", "黑板綠"][rawValue]) }
}

struct Stroke {
    var tool: DrawTool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
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
    var color: NSColor { Self.palette[colorIndex].color }

    private init() {
        d.register(defaults: ["draw.tool": DrawTool.pen.rawValue, "draw.color": 0, "draw.width": 4.0])
        tool = DrawTool(rawValue: d.string(forKey: "draw.tool") ?? "") ?? .pen
        colorIndex = min(max(d.integer(forKey: "draw.color"), 0), Self.palette.count - 1)
        width = CGFloat(d.double(forKey: "draw.width"))
    }
}

/// 畫布：螢幕標註（透明背景）與白板（不透明背景、多頁）共用
@MainActor
final class CanvasView: NSView {
    private(set) var annotations: [Stroke] = []
    private(set) var pages: [[Stroke]] = [[]]
    private(set) var pageIndex = 0
    private var current: Stroke?

    /// 內容改變時通知（讓工具列更新頁碼等）
    var onChange: (() -> Void)?

    var whiteboard = false { didSet { needsDisplay = true; onChange?() } }
    var boardStyle: BoardStyle = .white { didSet { needsDisplay = true } }
    var drawingEnabled = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private var strokes: [Stroke] {
        get { whiteboard ? pages[pageIndex] : annotations }
        set {
            if whiteboard { pages[pageIndex] = newValue } else { annotations = newValue }
            needsDisplay = true
            onChange?()
        }
    }

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
        let w = s.tool == .highlighter ? max(s.width * 4, 16) : s.width
        current = Stroke(tool: s.tool, color: s.color, width: w, points: [p])
    }

    override func mouseDragged(with event: NSEvent) {
        guard var c = current else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch c.tool {
        case .pen, .highlighter:
            c.points.append(p)
        default:
            // 形狀工具：只保留起點與終點；按住 Shift 畫水平/垂直或正方形/正圓
            var end = p
            if event.modifierFlags.contains(.shift), let start = c.points.first {
                end = constrain(start: start, end: p, tool: c.tool)
            }
            if c.points.count == 1 { c.points.append(end) } else { c.points[1] = end }
        }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var c = current else { return }
        current = nil
        if c.points.count == 1 {
            guard c.tool == .pen || c.tool == .highlighter else { needsDisplay = true; return }
            c.points.append(c.points[0])  // 點一下畫一個點
        }
        strokes.append(c)
    }

    private func constrain(start: CGPoint, end: CGPoint, tool: DrawTool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .rect, .ellipse:
            let d = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -d : d), y: start.y + (dy < 0 ? -d : d))
        default:
            return abs(dx) > abs(dy) ? CGPoint(x: end.x, y: start.y) : CGPoint(x: start.x, y: end.y)
        }
    }

    // MARK: 操作

    func undo() { if !strokes.isEmpty { strokes.removeLast() } }
    func clear() { strokes = [] }
    func clearAnnotations() { annotations = []; needsDisplay = true }

    func newPage() {
        pages.insert([], at: pageIndex + 1)
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
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: 繪製

    override func draw(_ dirtyRect: NSRect) {
        if whiteboard { drawBoard() }
        for s in strokes { render(s) }
        if let current { render(current) }
        if whiteboard { drawPageIndicator() }
    }

    private func drawBoard() {
        switch boardStyle {
        case .white:
            NSColor.white.setFill(); bounds.fill()
        case .grid:
            NSColor.white.setFill(); bounds.fill()
            NSColor(calibratedWhite: 0.86, alpha: 1).setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 1
            let step: CGFloat = 32
            var x: CGFloat = 0
            while x < bounds.width { grid.move(to: CGPoint(x: x, y: 0)); grid.line(to: CGPoint(x: x, y: bounds.height)); x += step }
            var y: CGFloat = 0
            while y < bounds.height { grid.move(to: CGPoint(x: 0, y: y)); grid.line(to: CGPoint(x: bounds.width, y: y)); y += step }
            grid.stroke()
        case .dark:
            NSColor(calibratedWhite: 0.11, alpha: 1).setFill(); bounds.fill()
        case .chalk:
            NSColor(calibratedRed: 0.13, green: 0.27, blue: 0.21, alpha: 1).setFill(); bounds.fill()
        }
    }

    private func drawPageIndicator() {
        let light = boardStyle == .white || boardStyle == .grid
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: light ? NSColor(calibratedWhite: 0.45, alpha: 1) : NSColor(calibratedWhite: 0.7, alpha: 1),
        ]
        let s = pageLabel as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: bounds.width - size.width - 24, y: 20), withAttributes: attrs)
    }

    private func render(_ s: Stroke) {
        guard let first = s.points.first, let last = s.points.last else { return }
        let path = NSBezierPath()
        path.lineWidth = s.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let color = s.tool == .highlighter ? s.color.withAlphaComponent(0.35) : s.color

        switch s.tool {
        case .pen, .highlighter:
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
        }
        color.setStroke()
        path.stroke()
    }

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
