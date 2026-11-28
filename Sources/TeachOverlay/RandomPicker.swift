import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct Student: Identifiable, Codable, Equatable {
    var id = UUID()
    var seat: Int?
    var studentID: String = ""
    var name: String = ""
    var picked = false
    var absent = false

    var display: String {
        [seat.map { "\($0)" }, studentID.isEmpty ? nil : studentID, name.isEmpty ? nil : name]
            .compactMap { $0 }.joined(separator: "  ")
    }
}

enum PickSource: String, CaseIterable, Identifiable {
    case roster = "名冊", seats = "座號範圍"
    var id: String { rawValue }
}

struct PickRecord: Identifiable, Codable {
    var id = UUID()
    var text: String
    var date: Date
}

/// 抽籤：名冊（txt 匯入／學號樣式產生）或座號範圍，可排除已抽過與請假
@MainActor
final class PickerStore: ObservableObject {
    static let shared = PickerStore()
    private let d = UserDefaults.standard

    @Published var students: [Student] = [] { didSet { save() } }
    @Published var source: PickSource { didSet { d.set(source.rawValue, forKey: "pick.source") } }
    @Published var seatFrom: Int { didSet { d.set(seatFrom, forKey: "pick.from") } }
    @Published var seatTo: Int { didSet { d.set(seatTo, forKey: "pick.to") } }
    @Published var seatPicked: Set<Int> = [] { didSet { save() } }
    @Published var seatAbsent: Set<Int> = [] { didSet { save() } }
    @Published var excludePicked: Bool { didSet { d.set(excludePicked, forKey: "pick.excludePicked") } }
    @Published var excludeAbsent: Bool { didSet { d.set(excludeAbsent, forKey: "pick.excludeAbsent") } }
    @Published var drawCount: Int { didSet { d.set(drawCount, forKey: "pick.count") } }
    @Published var idPattern: String { didSet { d.set(idPattern, forKey: "pick.pattern") } }
    @Published var patternFrom: Int { didSet { d.set(patternFrom, forKey: "pick.pFrom") } }
    @Published var patternTo: Int { didSet { d.set(patternTo, forKey: "pick.pTo") } }
    @Published var history: [PickRecord] = [] { didSet { save() } }
    /// 自動停止：滾動幾秒後自動揭曉；關閉時要按「停！」才停
    @Published var autoStop: Bool { didSet { d.set(autoStop, forKey: "pick.autoStop") } }
    @Published var rollDuration: Double { didSet { d.set(rollDuration, forKey: "pick.rollDuration") } }

    // 浮動視窗顯示
    @Published private(set) var displayText = ""
    @Published private(set) var rolling = false
    @Published private(set) var lastResults: [String] = []

    private var loading = true
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeachOverlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("roster.json")
    }()

    private struct Saved: Codable {
        var students: [Student]
        var seatPicked: [Int]
        var seatAbsent: [Int]
        var history: [PickRecord]
    }

    private init() {
        d.register(defaults: ["pick.source": PickSource.seats.rawValue, "pick.from": 1, "pick.to": 40,
                              "pick.excludePicked": true, "pick.excludeAbsent": true, "pick.count": 1,
                              "pick.pattern": "B111{###}", "pick.pFrom": 1, "pick.pTo": 40,
                              "pick.autoStop": true, "pick.rollDuration": 2.0])
        autoStop = d.bool(forKey: "pick.autoStop")
        rollDuration = d.double(forKey: "pick.rollDuration")
        source = PickSource(rawValue: d.string(forKey: "pick.source") ?? "") ?? .seats
        seatFrom = d.integer(forKey: "pick.from")
        seatTo = d.integer(forKey: "pick.to")
        excludePicked = d.bool(forKey: "pick.excludePicked")
        excludeAbsent = d.bool(forKey: "pick.excludeAbsent")
        drawCount = max(1, d.integer(forKey: "pick.count"))
        idPattern = d.string(forKey: "pick.pattern") ?? "B111{###}"
        patternFrom = d.integer(forKey: "pick.pFrom")
        patternTo = d.integer(forKey: "pick.pTo")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            students = s.students
            seatPicked = Set(s.seatPicked)
            seatAbsent = Set(s.seatAbsent)
            history = s.history
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Saved(students: students, seatPicked: Array(seatPicked), seatAbsent: Array(seatAbsent), history: history)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: 名冊

    /// 學號樣式：{###} 補零到 3 位、{n} 不補零。例：B111{###} → B111001
    static func format(_ pattern: String, _ n: Int) -> String {
        var out = pattern
        if let r = out.range(of: #"\{#+\}"#, options: .regularExpression) {
            let width = out[r].count - 2
            out.replaceSubrange(r, with: String(format: "%0\(width)d", n))
        }
        return out.replacingOccurrences(of: "{n}", with: "\(n)")
    }

    func generateFromPattern() {
        let lo = min(patternFrom, patternTo), hi = max(patternFrom, patternTo)
        students = (lo...hi).map { n in Student(seat: n, studentID: Self.format(idPattern, n)) }
    }

    /// 匯入 txt：每行一人，可為「座號 學號 姓名」「學號,姓名」「姓名」等，以空白、Tab 或逗號分隔
    func importTXT(_ url: URL) -> Int {
        guard let raw = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .utf16)) else { return 0 }
        var result: [Student] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let delimiters: Set<Character> = [",", "\t", "，"]
            let hasDelimiter = trimmed.contains { delimiters.contains($0) }
            let parts: [Substring] = hasDelimiter
                ? trimmed.split(whereSeparator: { delimiters.contains($0) })
                : trimmed.split(separator: " ")
            var tokens: [String] = parts.map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var s = Student()
            if let f = tokens.first, f.count <= 3, let n = Int(f) {
                s.seat = n
                tokens.removeFirst()
            }
            if let f = tokens.first, f.count >= 4, f.rangeOfCharacter(from: .decimalDigits) != nil,
               f.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                s.studentID = f
                tokens.removeFirst()
            }
            s.name = tokens.joined(separator: " ")
            if s.seat == nil && s.studentID.isEmpty && s.name.isEmpty { continue }
            if s.seat == nil { s.seat = result.count + 1 }
            result.append(s)
        }
        if !result.isEmpty { students = result }
        return result.count
    }

    func exportTXT(to url: URL) {
        let text = students.map { [$0.seat.map { "\($0)" } ?? "", $0.studentID, $0.name].joined(separator: "\t") }
            .joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func toggleAbsent(_ id: UUID) {
        if let i = students.firstIndex(where: { $0.id == id }) { students[i].absent.toggle() }
    }

    func togglePicked(_ id: UUID) {
        if let i = students.firstIndex(where: { $0.id == id }) { students[i].picked.toggle() }
    }

    func resetPicked() {
        for i in students.indices { students[i].picked = false }
        seatPicked = []
    }

    func toggleSeatAbsent(_ n: Int) {
        if seatAbsent.contains(n) { seatAbsent.remove(n) } else { seatAbsent.insert(n) }
    }

    // MARK: 抽籤

    private struct Candidate { let text: String; let mark: () -> Void }

    private func pool() -> [Candidate] {
        switch source {
        case .roster:
            return students.filter { (!excludePicked || !$0.picked) && (!excludeAbsent || !$0.absent) }
                .map { st in Candidate(text: st.display) { [weak self] in
                    if let i = self?.students.firstIndex(where: { $0.id == st.id }) { self?.students[i].picked = true }
                } }
        case .seats:
            let lo = min(seatFrom, seatTo), hi = max(seatFrom, seatTo)
            return (lo...hi).filter { (!excludePicked || !seatPicked.contains($0)) && (!excludeAbsent || !seatAbsent.contains($0)) }
                .map { n in Candidate(text: LF("%d 號", n)) { [weak self] in self?.seatPicked.insert(n) } }
        }
    }

    var remainingCount: Int { pool().count }

    private var rollTimer: Timer?
    private var rollStart = Date()
    private var rollPool: [Candidate] = []
    private var stopping = false

    /// 抽籤：開始滾動；滾動中再按一次（或按「停！」）就停下來揭曉
    func draw() {
        if rolling { stop(); return }
        let candidates = pool()
        guard !candidates.isEmpty else {
            displayText = L("沒有可抽的人了")
            lastResults = []
            PickerPanel.shared.show()
            return
        }
        PickerPanel.shared.show()
        rollPool = candidates
        rolling = true
        stopping = false
        rollStart = Date()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rollTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        rollTimer = t
    }

    /// 手動停止
    func stop() {
        guard rolling, !stopping else { return }
        stopping = true
        rollTimer?.invalidate()
        rollTimer = nil
        slowDown(step: 0)
    }

    private func rollTick() {
        displayText = rollPool.randomElement()?.text ?? ""
        if autoStop && Date().timeIntervalSince(rollStart) >= rollDuration { stop() }
    }

    /// 減速幾下再揭曉
    private func slowDown(step: Int) {
        let steps = 7
        if step >= steps {
            let winners = Array(rollPool.shuffled().prefix(max(1, drawCount)))
            winners.forEach { $0.mark() }
            lastResults = winners.map(\.text)
            displayText = lastResults.joined(separator: "\n")
            history.insert(contentsOf: lastResults.map { PickRecord(text: $0, date: Date()) }, at: 0)
            if history.count > 200 { history.removeLast(history.count - 200) }
            rolling = false
            stopping = false
            NSSound(named: "Hero")?.play()
            return
        }
        displayText = rollPool.randomElement()?.text ?? ""
        let delay = 0.08 + Double(step * step) * 0.02
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.slowDown(step: step + 1) }
        }
    }

    func importWithPanel() -> Int? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, UTType(filenameExtension: "csv") ?? .plainText]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return nil }
        return importTXT(url)
    }

    func exportWithPanel() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.plainText]
        p.nameFieldStringValue = "roster.txt"
        guard p.runModal() == .OK, let url = p.url else { return }
        exportTXT(to: url)
    }
}

// MARK: - 抽籤結果浮動視窗

@MainActor
final class PickerPanel {
    static let shared = PickerPanel()
    private var panel: NSPanel?
    weak var controller: OverlayController?

    func toggle() { panel?.isVisible == true ? hide() : show() }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
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
            p.setFrameAutosaveName("TeachOverlayPicker")
            if p.frame.origin == .zero, let s = NSScreen.main {
                p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - 230, y: s.visibleFrame.midY - 150))
            }
            panel = p
        }
        guard let controller else { return }
        if panel?.contentView == nil || !(panel?.isVisible ?? false) {
            panel?.contentView = DraggablePickerHost(rootView: PickerWidget(store: .shared, controller: controller, loc: .shared))
        }
        panel?.keepOnScreen()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private final class DraggablePickerHost<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct PickerWidget: View {
    @ObservedObject var store: PickerStore
    @ObservedObject var controller: OverlayController
    @ObservedObject var loc: Loc

    var body: some View {
        let theme = controller.overlayTheme
        VStack(spacing: 14) {
            HStack {
                Color.clear.frame(width: 10, height: 1)   // 留給左上角關閉鈕
                IconLabel(icon: .shuffle, text: L("抽籤")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(LF("剩餘 %d", store.remainingCount)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(store.displayText.isEmpty ? "?" : store.displayText)
                .font(.system(size: store.lastResults.count > 2 ? 30 : 46, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .minimumScaleFactor(0.4)
                .foregroundStyle(store.rolling ? Color.secondary : Color(nsColor: theme.text))
                .scaleEffect(store.rolling ? 0.94 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: store.rolling)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button { store.draw() } label: {
                    IconLabel(icon: store.rolling ? .pause : .dice, text: store.rolling ? L("停！") : L("抽籤"))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Capsule().fill(store.rolling ? AnyShapeStyle(Color.red) : AnyShapeStyle(Brand.gradient)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                Stepper(value: $store.drawCount, in: 1...20) {
                    Text(LF("一次 %d 人", store.drawCount)).font(.callout)
                }
                .fixedSize()
            }
        }
        .padding(18)
        .frame(width: 460, height: 300)
        .macCloseButton { PickerPanel.shared.hide() }
        .foregroundStyle(Color(nsColor: theme.text))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: theme.background))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(nsColor: theme.border)))
        )
        .environment(\.colorScheme, theme.dark ? .dark : .light)
    }
}
