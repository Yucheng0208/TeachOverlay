import AppKit
import Carbon
import Combine
import SwiftUI

struct Speaker: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var minutes: Double
}

/// 多段提醒：剩幾分鐘時提醒一次（0 = 時間到）
struct SpeakerAlert: Identifiable, Codable, Equatable {
    var id = UUID()
    var minutesLeft: Double
    var message: String
}

enum SpeakerDisplay: String, CaseIterable, Identifiable {
    case floating = "浮動視窗", fullScreen = "全螢幕"
    var id: String { rawValue }
}

enum SpeakerPhase {
    case green, yellow, red, over

    var color: Color {
        switch self {
        case .green: Color(red: 0.13, green: 0.62, blue: 0.35)
        case .yellow: Color(red: 0.95, green: 0.72, blue: 0.05)
        case .red: Color(red: 0.84, green: 0.22, blue: 0.22)
        case .over: Color(red: 0.70, green: 0.08, blue: 0.10)
        }
    }

    var label: String {
        switch self {
        case .green: "剩餘時間"
        case .yellow: "請準備結束"
        case .red: "時間快到了"
        case .over: "已超時"
        }
    }
}

/// 演講計時：綠、黃、紅燈號提醒講者，超時後顯示超出多久
@MainActor
final class SpeakerTimer: ObservableObject {
    static let shared = SpeakerTimer()
    private let d = UserDefaults.standard

    @Published var totalMinutes: Double { didSet { d.set(totalMinutes, forKey: "spk.total"); if !running { objectWillChange.send() } } }
    @Published var yellowMinutes: Double { didSet { d.set(yellowMinutes, forKey: "spk.yellow") } }
    @Published var redMinutes: Double { didSet { d.set(redMinutes, forKey: "spk.red") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "spk.sound") } }
    @Published var flashOvertime: Bool { didSet { d.set(flashOvertime, forKey: "spk.flash") } }
    @Published var display: SpeakerDisplay { didSet { d.set(display.rawValue, forKey: "spk.display"); if active { show() } } }
    @Published var target: BlackoutTarget { didSet { d.set(target.rawValue, forKey: "spk.target"); if active { show() } } }
    @Published var customScreens: Set<String> { didSet { d.set(Array(customScreens), forKey: "spk.custom"); if active { show() } } }
    @Published var speakers: [Speaker] = [] { didSet { saveSpeakers() } }
    @Published var useAgenda: Bool { didSet { d.set(useAgenda, forKey: "spk.agenda"); applyCurrentSpeaker() } }
    @Published var alerts: [SpeakerAlert] = [] { didSet { saveAlerts() } }
    @Published var overtimeRepeat: Bool { didSet { d.set(overtimeRepeat, forKey: "spk.overRepeat") } }
    /// 正在顯示的提醒大字
    @Published private(set) var banner: String?
    private var firedAlerts: Set<UUID> = []
    private var overtimeMinutesAlerted = 0
    private var bannerWork: DispatchWorkItem?

    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var running = false
    @Published private(set) var active = false
    @Published private(set) var currentIndex = 0
    @Published private(set) var flashOn = false

    private var startDate: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?
    private var lastPhase: SpeakerPhase = .green
    private var windows: [NSWindow] = []
    private var panel: NSPanel?
    private var startHotkey: UInt32?

    static let presets: [Double] = [3, 5, 7, 10, 15, 20, 30, 45]

    private init() {
        d.register(defaults: ["spk.total": 10.0, "spk.yellow": 2.0, "spk.red": 1.0, "spk.sound": true,
                              "spk.flash": true, "spk.display": SpeakerDisplay.floating.rawValue,
                              "spk.target": BlackoutTarget.all.rawValue, "spk.agenda": false, "spk.overRepeat": true])
        overtimeRepeat = d.bool(forKey: "spk.overRepeat")
        totalMinutes = d.double(forKey: "spk.total")
        yellowMinutes = d.double(forKey: "spk.yellow")
        redMinutes = d.double(forKey: "spk.red")
        playSounds = d.bool(forKey: "spk.sound")
        flashOvertime = d.bool(forKey: "spk.flash")
        display = SpeakerDisplay(rawValue: d.string(forKey: "spk.display") ?? "") ?? .floating
        target = BlackoutTarget(rawValue: d.string(forKey: "spk.target") ?? "") ?? .all
        customScreens = Set(d.stringArray(forKey: "spk.custom") ?? [])
        useAgenda = d.bool(forKey: "spk.agenda")
        if let data = d.data(forKey: "spk.speakers"), let list = try? JSONDecoder().decode([Speaker].self, from: data) {
            speakers = list
        }
        if let data = d.data(forKey: "spk.alerts"), let list = try? JSONDecoder().decode([SpeakerAlert].self, from: data) {
            alerts = list
        } else {
            alerts = Self.defaultAlerts()
        }
    }

    static func defaultAlerts() -> [SpeakerAlert] {
        [SpeakerAlert(minutesLeft: 2, message: L("剩 2 分鐘")),
         SpeakerAlert(minutesLeft: 1, message: L("最後 1 分鐘")),
         SpeakerAlert(minutesLeft: 0, message: L("時間到"))]
    }

    private func saveAlerts() {
        if let data = try? JSONEncoder().encode(alerts) { d.set(data, forKey: "spk.alerts") }
    }

    func addAlert() {
        alerts.append(SpeakerAlert(minutesLeft: 3, message: L("剩 3 分鐘")))
        alerts.sort { $0.minutesLeft > $1.minutesLeft }
    }

    func removeAlert(_ id: UUID) { alerts.removeAll { $0.id == id } }

    func updateAlert(_ a: SpeakerAlert) {
        if let i = alerts.firstIndex(where: { $0.id == a.id }) { alerts[i] = a }
    }

    /// 依剩餘時間重新判斷哪些提醒已經過了（加時後會重新啟用）
    private func rearmAlerts() {
        let r = remaining
        firedAlerts = Set(alerts.filter { r <= $0.minutesLeft * 60 }.map(\.id))
        overtimeMinutesAlerted = r < 0 ? Int(-r / 60) : 0
    }

    private func showBanner(_ text: String) {
        banner = text
        bannerWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.banner = nil } }
        bannerWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    private func saveSpeakers() {
        if let data = try? JSONEncoder().encode(speakers) { d.set(data, forKey: "spk.speakers") }
    }

    // MARK: 狀態

    var total: TimeInterval { totalMinutes * 60 }
    var remaining: TimeInterval { total - elapsed }

    var phase: SpeakerPhase {
        let r = remaining
        if r <= 0 { return .over }
        if r <= redMinutes * 60 { return .red }
        if r <= yellowMinutes * 60 { return .yellow }
        return .green
    }

    var displayText: String {
        let r = remaining
        let s = Int(abs(r).rounded(r >= 0 ? .up : .down))
        let text = String(format: "%d:%02d", s / 60, s % 60)
        return r < 0 ? "+" + text : text
    }

    var progress: Double { total > 0 ? min(1, elapsed / total) : 0 }

    var currentSpeakerName: String? {
        guard useAgenda, speakers.indices.contains(currentIndex) else { return nil }
        let n = speakers[currentIndex].name
        return n.isEmpty ? LF("第 %d 位", currentIndex + 1) : n
    }

    var nextSpeakerName: String? {
        guard useAgenda, speakers.indices.contains(currentIndex + 1) else { return nil }
        let n = speakers[currentIndex + 1].name
        return n.isEmpty ? LF("第 %d 位", currentIndex + 2) : n
    }

    // MARK: 控制

    func start() {
        guard !running else { return }
        running = true
        startDate = Date()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func pause() {
        guard running else { return }
        tick()
        accumulated = elapsed
        startDate = nil
        running = false
        ticker?.invalidate()
        ticker = nil
    }

    func toggle() { running ? pause() : start() }

    func reset() {
        pause()
        accumulated = 0
        elapsed = 0
        lastPhase = .green
        flashOn = false
        banner = nil
        firedAlerts = []
        overtimeMinutesAlerted = 0
    }

    func adjust(minutes: Double) {
        totalMinutes = max(0.5, totalMinutes + minutes)
        lastPhase = phase
        rearmAlerts()
    }

    func setPreset(_ m: Double) {
        useAgenda = false
        totalMinutes = m
        reset()
    }

    func next() {
        guard useAgenda, !speakers.isEmpty else { reset(); return }
        currentIndex = min(currentIndex + 1, speakers.count - 1)
        applyCurrentSpeaker()
    }

    func previous() {
        guard useAgenda, !speakers.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
        applyCurrentSpeaker()
    }

    func restartAgenda() {
        currentIndex = 0
        applyCurrentSpeaker()
    }

    private func applyCurrentSpeaker() {
        if useAgenda, speakers.indices.contains(currentIndex) {
            totalMinutes = speakers[currentIndex].minutes
        }
        reset()
    }

    func addSpeaker() {
        speakers.append(Speaker(name: "", minutes: totalMinutes))
    }

    func removeSpeaker(_ id: UUID) {
        speakers.removeAll { $0.id == id }
        currentIndex = min(currentIndex, max(speakers.count - 1, 0))
    }

    func updateSpeaker(_ s: Speaker) {
        if let i = speakers.firstIndex(where: { $0.id == s.id }) { speakers[i] = s }
    }

    private func tick() {
        if let startDate { elapsed = accumulated + Date().timeIntervalSince(startDate) }
        let p = phase
        lastPhase = p
        // 多段提醒：越過門檻時提醒一次（同時越過多個只提醒最後一個）
        let r = remaining
        let due = alerts.filter { !firedAlerts.contains($0.id) && r <= $0.minutesLeft * 60 }
        if let last = due.min(by: { $0.minutesLeft < $1.minutesLeft }) {
            due.forEach { firedAlerts.insert($0.id) }
            if playSounds { NSSound(named: last.minutesLeft <= 0 ? "Glass" : "Ping")?.play() }
            showBanner(last.message)
        }
        if overtimeRepeat, r < 0 {
            let over = Int(-r / 60)
            if over > overtimeMinutesAlerted {
                overtimeMinutesAlerted = over
                if playSounds { NSSound(named: "Sosumi")?.play() }
                showBanner(LF("已超時 %d 分鐘", over))
            }
        }
        flashOn = p == .over && flashOvertime ? (Int(Date().timeIntervalSince1970 * 2) % 2 == 0) : false
    }

    // MARK: 顯示

    func toggleDisplay() { active ? hide() : show() }

    func show() {
        closeWindows()
        active = true
        switch display {
        case .floating: showPanel()
        case .fullScreen:
            windows = targetScreens().map { screen in
                let w = SpeakerWindow(screen: screen)
                w.timer = self
                w.closeButton = CornerCloseButton.install(
                    in: w, content: NSHostingView(rootView: SpeakerFullView(timer: self, loc: .shared))) { [weak self] in self?.hide() }
                w.orderFrontRegardless()
                return w
            }
            windows.first?.makeKey()
        }
        // 顯示期間 ⌃⌥Space 在任何地方都能開始／暫停
        if startHotkey == nil {
            startHotkey = HotKeyCenter.shared.register(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
                self?.toggle()
            }
        }
    }

    func hide() {
        active = false
        closeWindows()
        if let id = startHotkey { HotKeyCenter.shared.unregister(id); startHotkey = nil }
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        panel?.orderOut(nil)
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

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 230),
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
            p.setFrameAutosaveName("TeachOverlaySpeaker")
            if p.frame.origin == .zero, let s = NSScreen.main {
                p.setFrameOrigin(NSPoint(x: s.visibleFrame.maxX - 364, y: s.visibleFrame.maxY - 254))
            }
            p.contentView = SpeakerHost(rootView: SpeakerFloatingView(timer: self, loc: .shared))
            panel = p
        }
        panel?.keepOnScreen()
        panel?.orderFrontRegardless()
    }
}

private final class SpeakerHost<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// 全螢幕：空白鍵開始／暫停、←/→ 增減 1 分鐘、N 下一位、R 重設、Esc 關閉
private final class SpeakerWindow: NSWindow {
    weak var timer: SpeakerTimer?
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

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let timer else { return }
            switch Int(event.keyCode) {
            case kVK_Escape: timer.hide()
            case kVK_Space, kVK_Return: timer.toggle()
            case kVK_RightArrow, kVK_UpArrow: timer.adjust(minutes: 1)
            case kVK_LeftArrow, kVK_DownArrow: timer.adjust(minutes: -1)
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "n": timer.next()
                case "p": timer.previous()
                case "r": timer.reset()
                default: break
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { timer?.toggle() }
    }
}

struct SpeakerFullView: View {
    @ObservedObject var timer: SpeakerTimer
    @ObservedObject var loc: Loc

    var body: some View {
        GeometryReader { geo in
            let short = min(geo.size.width, geo.size.height)
            let phase = timer.phase
            ZStack {
                (timer.flashOn ? Color.white : phase.color).ignoresSafeArea()
                VStack(spacing: short * 0.03) {
                    if let name = timer.currentSpeakerName {
                        Text(name).font(.system(size: short * 0.07, weight: .semibold)).lineLimit(1)
                    }
                    Text(L(phase.label)).font(.system(size: short * 0.06, weight: .bold)).opacity(0.85)
                    Text(timer.displayText)
                        .font(.system(size: min(geo.size.width / 3.4, short * 0.45), weight: .bold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                    ProgressView(value: timer.progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: geo.size.width * 0.6)
                    HStack(spacing: short * 0.04) {
                        if !timer.running { Text(L("已暫停")).bold() }
                        if let next = timer.nextSpeakerName { Text(LF("下一位：%@", next)) }
                    }
                    .font(.system(size: short * 0.035))
                    .opacity(0.8)
                }
                .foregroundStyle(timer.flashOn ? phase.color : (phase == .yellow ? Color.black : Color.white))

                if let banner = timer.banner {
                    VStack {
                        Text(banner)
                            .font(.system(size: short * 0.08, weight: .heavy))
                            .padding(.horizontal, short * 0.05).padding(.vertical, short * 0.02)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .foregroundStyle(.white)
                            .padding(.top, short * 0.06)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: timer.banner)
        }
    }
}

struct SpeakerFloatingView: View {
    @ObservedObject var timer: SpeakerTimer
    @ObservedObject var loc: Loc

    var body: some View {
        let phase = timer.phase
        let fg: Color = timer.flashOn ? phase.color : (phase == .yellow ? .black : .white)
        VStack(spacing: 8) {
            HStack {
                Color.clear.frame(width: 14, height: 1)   // 留給左上角關閉鈕
                FAIcon(icon: .microphone, size: 13)
                Text(timer.currentSpeakerName ?? L("演講計時")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(L(phase.label)).font(.system(size: 12, weight: .bold))
            }
            Text(timer.displayText)
                .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            ProgressView(value: timer.progress).progressViewStyle(.linear).tint(fg)
            HStack(spacing: 10) {
                speakerButton(timer.running ? .pause : .play) { timer.toggle() }
                speakerButton(.rotateLeft) { timer.reset() }
                speakerButton(.minus) { timer.adjust(minutes: -1) }
                speakerButton(.plus) { timer.adjust(minutes: 1) }
                if timer.useAgenda { speakerButton(.forwardStep) { timer.next() } }
            }
        }
        .padding(14)
        .frame(width: 340, height: 230)
        .macCloseButton { timer.hide() }
        .overlay(alignment: .top) {
            if let banner = timer.banner {
                Text(banner)
                    .font(.system(size: 22, weight: .heavy))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .foregroundStyle(.white)
                    .padding(.top, 34)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: timer.banner)
        .foregroundStyle(fg)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(timer.flashOn ? Color.white : phase.color))
        .environment(\.colorScheme, phase == .yellow ? .light : .dark)
    }

    private func speakerButton(_ icon: FA, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FAIcon(icon: icon, size: 14)
                .frame(width: 40, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 設定頁

struct SpeakerPane: View {
    @ObservedObject var timer: SpeakerTimer

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 10).fill(timer.phase.color).frame(width: 18, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timer.currentSpeakerName ?? L(timer.phase.label)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(timer.displayText).font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 0)
                }
                FlowLayout {
                    Button { timer.toggle() } label: { IconLabel(icon: timer.running ? .pause : .play, text: L(timer.running ? "暫停" : "開始")) }
                    Button { timer.reset() } label: { IconLabel(icon: .rotateLeft, text: L("重設")) }
                    Button("-1 " + L("分鐘")) { timer.adjust(minutes: -1) }
                    Button("+1 " + L("分鐘")) { timer.adjust(minutes: 1) }
                    if timer.useAgenda {
                        Button { timer.previous() } label: { IconLabel(icon: .chevronLeft, text: L("上一位")) }
                        Button { timer.next() } label: { IconLabel(icon: .forwardStep, text: L("下一位")) }
                    }
                    Button { timer.toggleDisplay() } label: {
                        IconLabel(icon: .windowRestore, text: timer.active ? L("隱藏計時畫面") : L("顯示計時畫面"))
                    }
                }
            } footer: {
                Text(L("快捷鍵 ⌃⌥V 顯示／隱藏；顯示時 ⌃⌥Space 開始／暫停。全螢幕時：空白鍵開始／暫停、←/→ 增減 1 分鐘、N 下一位、R 重設、Esc 關閉。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("演講時間")) {
                FlowLayout {
                    ForEach(SpeakerTimer.presets, id: \.self) { m in
                        Button(LF("%d 分鐘", Int(m))) { timer.setPreset(m) }
                    }
                }
                .disabled(timer.useAgenda)
                Stepper(value: $timer.totalMinutes, in: 0.5...240, step: 0.5) {
                    LabeledContent(L("總時間（分鐘）"), value: String(format: "%g", timer.totalMinutes))
                }
                .disabled(timer.useAgenda)
                Stepper(value: $timer.yellowMinutes, in: 0...60, step: 0.5) {
                    LabeledContent(L("剩幾分鐘變黃燈"), value: String(format: "%g", timer.yellowMinutes))
                }
                Stepper(value: $timer.redMinutes, in: 0...60, step: 0.5) {
                    LabeledContent(L("剩幾分鐘變紅燈"), value: String(format: "%g", timer.redMinutes))
                }
                Toggle(L("超時後閃爍"), isOn: $timer.flashOvertime)
            }

            Section {
                ForEach(timer.alerts) { a in
                    HStack {
                        Stepper(value: Binding(get: { a.minutesLeft }, set: { var x = a; x.minutesLeft = $0; timer.updateAlert(x) }),
                                in: 0...120, step: 0.5) {
                            Text(a.minutesLeft <= 0 ? L("時間到時") : LF("剩 %@ 分鐘時", String(format: "%g", a.minutesLeft)))
                                .monospacedDigit()
                        }
                        .fixedSize()
                        TextField(L("提醒文字"), text: Binding(get: { a.message }, set: { var x = a; x.message = $0; timer.updateAlert(x) }))
                        Button { timer.removeAlert(a.id) } label: { FAIcon(icon: .trashCan, size: 12) }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button { timer.addAlert() } label: { IconLabel(icon: .plus, text: L("新增提醒")) }
                    Spacer()
                    Button(L("還原預設提醒")) { timer.alerts = SpeakerTimer.defaultAlerts() }
                }
                Toggle(L("超時後每分鐘再提醒一次"), isOn: $timer.overtimeRepeat)
                Toggle(L("提醒時播放提示音"), isOn: $timer.playSounds)
            } header: {
                Text(L("多段提醒"))
            } footer: {
                Text(L("每個提醒在剩下指定時間時響一聲，並在計時畫面上大字顯示；時間到與超時會用不同的提示音。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("使用講者名單"), isOn: $timer.useAgenda)
                if timer.useAgenda {
                    ForEach(Array(timer.speakers.enumerated()), id: \.element.id) { i, s in
                        HStack {
                            Text("\(i + 1)").monospacedDigit().foregroundStyle(i == timer.currentIndex ? Brand.blue : .secondary)
                                .frame(width: 22)
                            TextField(L("講者名稱"), text: Binding(get: { s.name }, set: { var x = s; x.name = $0; timer.updateSpeaker(x) }))
                            Stepper(value: Binding(get: { s.minutes }, set: { var x = s; x.minutes = $0; timer.updateSpeaker(x) }),
                                    in: 0.5...240, step: 0.5) {
                                Text(LF("%@ 分鐘", String(format: "%g", s.minutes))).monospacedDigit()
                            }
                            .fixedSize()
                            Button { timer.removeSpeaker(s.id) } label: { FAIcon(icon: .trashCan, size: 12) }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button { timer.addSpeaker() } label: { IconLabel(icon: .plus, text: L("新增講者")) }
                        Spacer()
                        Button(L("從第一位開始")) { timer.restartAgenda() }
                    }
                }
            } header: {
                Text(L("講者名單"))
            }

            Section(L("顯示方式")) {
                Picker(L("顯示方式"), selection: $timer.display) {
                    ForEach(SpeakerDisplay.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                if timer.display == .fullScreen {
                    Picker(L("顯示在"), selection: $timer.target) {
                        ForEach(BlackoutTarget.allCases) { Text(L($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    if timer.target == .custom {
                        ForEach(NSScreen.screens, id: \.localizedName) { s in
                            Toggle(isOn: Binding(
                                get: { timer.customScreens.contains(s.localizedName) },
                                set: { on in
                                    if on { timer.customScreens.insert(s.localizedName) } else { timer.customScreens.remove(s.localizedName) }
                                })) {
                                Text(s.localizedName + (BlackoutController.isBuiltIn(s) ? "（" + L("筆電") + "）" : ""))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SpeakerCard: View {
    @ObservedObject var timer: SpeakerTimer
    var body: some View {
        ActionCard(icon: .microphone, title: L("演講計時"),
                   subtitle: L("綠黃紅燈號與多段提醒，避免講者超時。"),
                   shortcut: "⌃⌥V", buttonTitle: timer.active ? L("隱藏") : L("顯示"),
                   active: timer.active) { timer.toggleDisplay() }
    }
}
