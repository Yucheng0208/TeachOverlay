import AppKit
import Combine
import SwiftUI

enum ClockStyle: String, CaseIterable, Identifiable {
    case digital = "數字", analog = "指針"
    var id: String { rawValue }
}

/// 全螢幕時鐘：可顯示在全部、外接或自選螢幕
@MainActor
final class ClockController: ObservableObject {
    static let shared = ClockController()
    private let d = UserDefaults.standard

    @Published private(set) var active = false
    @Published var target: BlackoutTarget { didSet { d.set(target.rawValue, forKey: "clock.target"); if active { apply() } } }
    @Published var customScreens: Set<String> { didSet { d.set(Array(customScreens), forKey: "clock.custom"); if active { apply() } } }
    @Published var style: ClockStyle { didSet { d.set(style.rawValue, forKey: "clock.style") } }
    @Published var showSeconds: Bool { didSet { d.set(showSeconds, forKey: "clock.seconds") } }
    @Published var use24Hour: Bool { didSet { d.set(use24Hour, forKey: "clock.24h") } }
    @Published var showDate: Bool { didSet { d.set(showDate, forKey: "clock.date") } }
    @Published var showNextBell: Bool { didSet { d.set(showNextBell, forKey: "clock.bell") } }
    @Published var darkBackground: Bool { didSet { d.set(darkBackground, forKey: "clock.dark") } }

    private var windows: [NSWindow] = []

    private init() {
        d.register(defaults: ["clock.target": BlackoutTarget.all.rawValue, "clock.style": ClockStyle.digital.rawValue,
                              "clock.seconds": true, "clock.24h": true, "clock.date": true, "clock.bell": true,
                              "clock.dark": true])
        target = BlackoutTarget(rawValue: d.string(forKey: "clock.target") ?? "") ?? .all
        customScreens = Set(d.stringArray(forKey: "clock.custom") ?? [])
        style = ClockStyle(rawValue: d.string(forKey: "clock.style") ?? "") ?? .digital
        showSeconds = d.bool(forKey: "clock.seconds")
        use24Hour = d.bool(forKey: "clock.24h")
        showDate = d.bool(forKey: "clock.date")
        showNextBell = d.bool(forKey: "clock.bell")
        darkBackground = d.bool(forKey: "clock.dark")
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.active == true { self?.apply() } }
        }
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        switch target {
        case .all: return screens
        case .external:
            let ext = screens.filter { !BlackoutController.isBuiltIn($0) }
            return ext.isEmpty ? screens : ext
        case .custom: return screens.filter { customScreens.contains($0.localizedName) }
        }
    }

    func toggle() { active ? hide() : show() }

    func show() {
        active = true
        apply()
    }

    func hide() {
        active = false
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func apply() {
        windows.forEach { $0.orderOut(nil) }
        windows = targetScreens().map { screen in
            let w = ClockWindow(screen: screen)
            w.onDismiss = { [weak self] in self?.hide() }
            w.closeButton = CornerCloseButton.install(
                in: w, content: NSHostingView(rootView: FullScreenClockView(clock: self, bell: .shared, loc: .shared))) { [weak self] in self?.hide() }
            w.orderFrontRegardless()
            return w
        }
        if windows.isEmpty { active = false }
    }
}

private final class ClockWindow: NSWindow {
    var onDismiss: (() -> Void)?
    var closeButton: CornerCloseButton?

    override func mouseMoved(with event: NSEvent) { closeButton?.reveal() }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onDismiss?() } }
}

struct FullScreenClockView: View {
    @ObservedObject var clock: ClockController
    @ObservedObject var bell: BellScheduler
    @ObservedObject var loc: Loc

    var body: some View {
        GeometryReader { geo in
            let fg: Color = clock.darkBackground ? .white : .black
            let short = min(geo.size.width, geo.size.height)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: short * 0.04) {
                    Spacer(minLength: 0)
                    if clock.style == .digital {
                        Text(timeText(context.date))
                            .font(.system(size: min(geo.size.width / (clock.showSeconds ? 5.2 : 3.6), short * 0.42),
                                          weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.3)
                    } else {
                        AnalogClockFace(date: context.date, showSeconds: clock.showSeconds, color: fg)
                            .frame(width: short * 0.62, height: short * 0.62)
                    }
                    if clock.showDate {
                        Text(dateText(context.date))
                            .font(.system(size: short * 0.06, weight: .medium))
                            .opacity(0.75)
                    }
                    if clock.showNextBell, bell.nextEntry != nil {
                        Text(bell.nextText)
                            .font(.system(size: short * 0.045, weight: .medium).monospacedDigit())
                            .opacity(0.6)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(fg)
            }
        }
        .background(clock.darkBackground ? Color.black : Color.white)
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = (clock.use24Hour ? "HH:mm" : "h:mm") + (clock.showSeconds ? ":ss" : "") + (clock.use24Hour ? "" : " a")
        return f.string(from: d)
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        let id: String
        switch loc.resolved {
        case .zhHans: id = "zh_CN"
        case .en: id = "en_US"
        case .ja: id = "ja_JP"
        case .ko: id = "ko_KR"
        default: id = "zh_TW"
        }
        f.locale = Locale(identifier: id)
        f.setLocalizedDateFormatFromTemplate("yMMMMdEEEE")
        return f.string(from: d)
    }
}

struct AnalogClockFace: View {
    let date: Date
    let showSeconds: Bool
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r + 4, y: c.y - r + 4, width: 2 * r - 8, height: 2 * r - 8)),
                       with: .color(color.opacity(0.85)), lineWidth: r * 0.025)
            for i in 0..<60 {
                let a = Double(i) / 60 * 2 * .pi
                let long = i % 5 == 0
                let r1 = r * (long ? 0.82 : 0.88), r2 = r * 0.93
                var p = Path()
                p.move(to: CGPoint(x: c.x + r1 * sin(a), y: c.y - r1 * cos(a)))
                p.addLine(to: CGPoint(x: c.x + r2 * sin(a), y: c.y - r2 * cos(a)))
                ctx.stroke(p, with: .color(color.opacity(long ? 0.9 : 0.4)), lineWidth: long ? r * 0.02 : r * 0.008)
            }
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let s = Double(comps.second ?? 0), m = Double(comps.minute ?? 0) + s / 60
            let h = Double((comps.hour ?? 0) % 12) + m / 60
            func hand(_ fraction: Double, _ length: Double, _ width: Double, _ col: Color) {
                let a = fraction * 2 * .pi
                var p = Path()
                p.move(to: CGPoint(x: c.x - r * 0.08 * sin(a), y: c.y + r * 0.08 * cos(a)))
                p.addLine(to: CGPoint(x: c.x + r * length * sin(a), y: c.y - r * length * cos(a)))
                ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand(h / 12, 0.5, r * 0.055, color)
            hand(m / 60, 0.75, r * 0.035, color)
            if showSeconds { hand(s / 60, 0.85, r * 0.012, .red) }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.04, y: c.y - r * 0.04, width: r * 0.08, height: r * 0.08)),
                     with: .color(showSeconds ? .red : color))
        }
    }
}
