import AppKit
import Combine
import SwiftUI

enum TimerMode: String, CaseIterable, Identifiable {
    case countdown = "倒數計時", pomodoro = "番茄鐘", bell = "距離鐘響"
    var id: String { rawValue }
}

enum PomodoroPhase {
    case work, shortBreak, longBreak
    var name: String {
        switch self {
        case .work: "專注"
        case .shortBreak: "短休息"
        case .longBreak: "長休息"
        }
    }
}

/// 倒數計時與番茄鐘
@MainActor
final class TimerController: ObservableObject {
    static let shared = TimerController()
    private let d = UserDefaults.standard

    @Published var mode: TimerMode { didSet { d.set(mode.rawValue, forKey: "timer.mode"); reset() } }
    @Published var countdownSeconds: Int { didSet { d.set(countdownSeconds, forKey: "timer.countdown"); if mode == .countdown && !running { reset() } } }
    @Published var workMinutes: Int { didSet { d.set(workMinutes, forKey: "timer.work"); if !running { reset() } } }
    @Published var shortBreakMinutes: Int { didSet { d.set(shortBreakMinutes, forKey: "timer.short") } }
    @Published var longBreakMinutes: Int { didSet { d.set(longBreakMinutes, forKey: "timer.long") } }
    @Published var cyclesBeforeLong: Int { didSet { d.set(cyclesBeforeLong, forKey: "timer.cycles") } }
    @Published var autoStartNext: Bool { didSet { d.set(autoStartNext, forKey: "timer.autoNext") } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "timer.sound") } }
    @Published var panelScale: Double { didSet { d.set(panelScale, forKey: "timer.scale"); TimerPanel.shared.resize() } }

    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var total: TimeInterval = 1
    @Published private(set) var running = false
    @Published private(set) var phase: PomodoroPhase = .work
    @Published private(set) var completedPomodoros = 0
    @Published private(set) var flashing = false

    private var endDate: Date?
    private var ticker: Timer?

    static let presets = [60, 180, 300, 600, 900, 1500, 1800, 3600]

    private init() {
        d.register(defaults: ["timer.mode": TimerMode.countdown.rawValue, "timer.countdown": 300,
                              "timer.work": 25, "timer.short": 5, "timer.long": 15, "timer.cycles": 4,
                              "timer.autoNext": true, "timer.sound": true, "timer.scale": 1.0])
        mode = TimerMode(rawValue: d.string(forKey: "timer.mode") ?? "") ?? .countdown
        countdownSeconds = d.integer(forKey: "timer.countdown")
        workMinutes = d.integer(forKey: "timer.work")
        shortBreakMinutes = d.integer(forKey: "timer.short")
        longBreakMinutes = d.integer(forKey: "timer.long")
        cyclesBeforeLong = d.integer(forKey: "timer.cycles")
        autoStartNext = d.bool(forKey: "timer.autoNext")
        playSound = d.bool(forKey: "timer.sound")
        panelScale = d.double(forKey: "timer.scale")
        reset()
    }

    private func duration(for phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .work: TimeInterval(workMinutes * 60)
        case .shortBreak: TimeInterval(shortBreakMinutes * 60)
        case .longBreak: TimeInterval(longBreakMinutes * 60)
        }
    }

    var display: String {
        let s = mode == .bell ? BellScheduler.shared.secondsToNext : Int(remaining.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    var progress: Double {
        if mode == .bell { return 0 }
        return total > 0 ? 1 - remaining / total : 0
    }

    @MainActor var title: String {
        switch mode {
        case .countdown: return L("倒數計時")
        case .pomodoro: return LF("%@ · 第 %d 輪", L(phase.name), completedPomodoros + 1)
        case .bell:
            guard let e = BellScheduler.shared.nextEntry else { return L("今天沒有鐘響了") }
            return "\(e.label) · \(e.timeText)"
        }
    }

    // MARK: 控制

    func start() {
        guard !running, mode != .bell else { return }
        if remaining <= 0 { reset() }
        flashing = false
        running = true
        endDate = Date().addingTimeInterval(remaining)
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func pause() {
        guard running else { return }
        tick()
        running = false
        ticker?.invalidate()
        ticker = nil
    }

    func toggle() { running ? pause() : start() }

    func reset() {
        pause()
        flashing = false
        total = mode == .countdown ? TimeInterval(max(countdownSeconds, 1)) : duration(for: phase)
        remaining = total
    }

    /// 番茄鐘：跳到下一階段；倒數：直接結束
    func skip() {
        if mode == .pomodoro { advancePhase(); if autoStartNext { start() } } else { remaining = 0; finish() }
    }

    func setCountdown(_ seconds: Int) {
        mode = .countdown
        countdownSeconds = seconds
        reset()
    }

    func resetPomodoroCycle() {
        completedPomodoros = 0
        phase = .work
        reset()
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 && running { finish() }
    }

    private func finish() {
        running = false
        ticker?.invalidate()
        ticker = nil
        if playSound { NSSound(named: "Glass")?.play() }
        flashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { if self?.running == false { self?.flashing = false } }
        }
        if mode == .pomodoro {
            advancePhase()
            if autoStartNext { start() }
        }
    }

    private func advancePhase() {
        if phase == .work {
            completedPomodoros += 1
            phase = completedPomodoros % max(cyclesBeforeLong, 1) == 0 ? .longBreak : .shortBreak
        } else {
            phase = .work
        }
        total = duration(for: phase)
        remaining = total
    }
}

// MARK: - 浮動計時器視窗

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
final class TimerPanel {
    static let shared = TimerPanel()
    private var panel: NSPanel?
    var isVisible: Bool { panel?.isVisible == true }
    weak var controller: OverlayController?

    private var size: NSSize {
        let k = TimerController.shared.panelScale
        return NSSize(width: 300 * k, height: 172 * k)
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.setFrameAutosaveName("TeachOverlayTimer")
            if p.frame.origin == .zero, let s = NSScreen.main {
                p.setFrameOrigin(NSPoint(x: s.visibleFrame.maxX - size.width - 24, y: s.visibleFrame.minY + 24))
            }
            panel = p
        }
        guard let controller else { return }
        panel?.contentView = DraggableHostingView(rootView: TimerWidget(timer: .shared, controller: controller, loc: .shared))
        resize()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func resize() {
        guard let panel else { return }
        var f = panel.frame
        let s = size
        f.origin.y += f.height - s.height
        f.size = s
        panel.setFrame(f, display: true)
    }
}

struct TimerWidget: View {
    @ObservedObject var timer: TimerController
    @ObservedObject var controller: OverlayController
    @ObservedObject var loc: Loc
    @ObservedObject var bell: BellScheduler = .shared

    var body: some View {
        let k = timer.panelScale
        let theme = controller.overlayTheme
        VStack(spacing: 8 * k) {
            HStack(spacing: 6 * k) {
                FAIcon(icon: timer.mode == .countdown ? .hourglassHalf : (timer.mode == .bell ? .bell : .stopwatch), size: 13 * k)
                Text(timer.title).font(.system(size: 13 * k, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { TimerPanel.shared.hide() } label: { FAIcon(icon: .xmark, size: 12 * k) }
                    .buttonStyle(.plain)
                    .help(L("關閉"))
            }
            Text(timer.display)
                .font(.system(size: 54 * k, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(timer.flashing ? Color.red : Color(nsColor: theme.text))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if timer.mode != .bell {
            ProgressView(value: timer.progress)
                .progressViewStyle(.linear)
                .tint(timer.mode == .pomodoro && timer.phase != .work ? Color.green : Brand.blue)
            }
            if timer.mode == .bell {
                Text(L("距離下一次鐘響")).font(.system(size: 12 * k)).foregroundStyle(.secondary)
            } else {
            HStack(spacing: 14 * k) {
                widgetButton(timer.running ? .pause : .play, L(timer.running ? "暫停" : "開始")) { timer.toggle() }
                widgetButton(.rotateLeft, L("重設")) { timer.reset() }
                if timer.mode == .pomodoro {
                    widgetButton(.forwardStep, L("下一階段")) { timer.skip() }
                }
            }
            }
        }
        .padding(14 * k)
        .frame(width: 300 * k, height: 172 * k)
        .foregroundStyle(Color(nsColor: theme.text))
        .background(
            RoundedRectangle(cornerRadius: 18 * k, style: .continuous)
                .fill(Color(nsColor: theme.background))
                .overlay(RoundedRectangle(cornerRadius: 18 * k, style: .continuous)
                    .stroke(timer.flashing ? Color.red : Color(nsColor: theme.border), lineWidth: timer.flashing ? 3 : 1))
        )
        .environment(\.colorScheme, theme.dark ? .dark : .light)
    }

    private func widgetButton(_ icon: FA, _ help: String, action: @escaping () -> Void) -> some View {
        let k = timer.panelScale
        return Button(action: action) {
            FAIcon(icon: icon, size: 15 * k)
                .frame(width: 38 * k, height: 30 * k)
                .background(RoundedRectangle(cornerRadius: 8 * k).fill(Color.secondary.opacity(0.18)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
