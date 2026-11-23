import AppKit
import Combine
import UserNotifications

struct BellEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case start, end }
    var id = UUID()
    /// 從 00:00 起算的分鐘
    var minutes: Int
    var kind: Kind
    var label: String

    var timeText: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// 上下課鐘聲：時間到自動打鐘、發通知，並提供距離下一次鐘響的倒數
@MainActor
final class BellScheduler: ObservableObject {
    static let shared = BellScheduler()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "bell.enabled"); if enabled { requestNotificationPermission() } } }
    @Published var entries: [BellEntry] = [] { didSet { save() } }
    /// 1 = 週日 … 7 = 週六
    @Published var weekdays: Set<Int> = [2, 3, 4, 5, 6] { didSet { save() } }
    @Published var ringOnStart: Bool { didSet { d.set(ringOnStart, forKey: "bell.ringStart") } }
    @Published var notify: Bool { didSet { d.set(notify, forKey: "bell.notify"); if notify { requestNotificationPermission() } } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "bell.volume") } }
    @Published var customSoundPath: String? { didSet { d.set(customSoundPath, forKey: "bell.sound") } }
    @Published var showBanner: Bool { didSet { d.set(showBanner, forKey: "bell.banner") } }
    /// 選單列與畫圖工具列顯示「距離下課」
    @Published var showCountdownInMenuBar: Bool { didSet { d.set(showCountdownInMenuBar, forKey: "bell.menubar") } }
    @Published var showCountdownInToolbar: Bool { didSet { d.set(showCountdownInToolbar, forKey: "bell.toolbar") } }

    // 產生課表用
    @Published var genFirstStart: Int { didSet { d.set(genFirstStart, forKey: "bell.gen.first") } }
    @Published var genClassLength: Int { didSet { d.set(genClassLength, forKey: "bell.gen.class") } }
    @Published var genBreakLength: Int { didSet { d.set(genBreakLength, forKey: "bell.gen.break") } }
    @Published var genPeriods: Int { didSet { d.set(genPeriods, forKey: "bell.gen.periods") } }
    @Published var genLunchAfter: Int { didSet { d.set(genLunchAfter, forKey: "bell.gen.lunchAfter") } }
    @Published var genLunchLength: Int { didSet { d.set(genLunchLength, forKey: "bell.gen.lunch") } }

    @Published private(set) var nextEntry: BellEntry?
    @Published private(set) var secondsToNext: Int = 0
    @Published private(set) var nextEnd: BellEntry?
    @Published private(set) var secondsToNextEnd: Int = 0

    /// 打鐘時呼叫（顯示螢幕橫幅）
    var onRing: ((BellEntry) -> Void)?

    private var timer: Timer?
    private var firedKeys: Set<String> = []
    private var sound: NSSound?
    private var loading = true
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeachOverlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bells.json")
    }()

    private struct Saved: Codable { var entries: [BellEntry]; var weekdays: [Int] }

    private init() {
        d.register(defaults: ["bell.enabled": false, "bell.ringStart": true, "bell.notify": true, "bell.volume": 0.8,
                              "bell.banner": true, "bell.menubar": true, "bell.toolbar": true, "bell.gen.first": 8 * 60 + 10, "bell.gen.class": 50,
                              "bell.gen.break": 10, "bell.gen.periods": 7, "bell.gen.lunchAfter": 4, "bell.gen.lunch": 70])
        enabled = d.bool(forKey: "bell.enabled")
        ringOnStart = d.bool(forKey: "bell.ringStart")
        notify = d.bool(forKey: "bell.notify")
        volume = d.double(forKey: "bell.volume")
        customSoundPath = d.string(forKey: "bell.sound")
        showBanner = d.bool(forKey: "bell.banner")
        showCountdownInMenuBar = d.bool(forKey: "bell.menubar")
        showCountdownInToolbar = d.bool(forKey: "bell.toolbar")
        genFirstStart = d.integer(forKey: "bell.gen.first")
        genClassLength = d.integer(forKey: "bell.gen.class")
        genBreakLength = d.integer(forKey: "bell.gen.break")
        genPeriods = d.integer(forKey: "bell.gen.periods")
        genLunchAfter = d.integer(forKey: "bell.gen.lunchAfter")
        genLunchLength = d.integer(forKey: "bell.gen.lunch")
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            entries = s.entries.sorted { $0.minutes < $1.minutes }
            weekdays = Set(s.weekdays)
        }
        loading = false
        if entries.isEmpty { generate() }
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func save() {
        guard !loading else { return }
        let sorted = entries.sorted { $0.minutes < $1.minutes }
        if let data = try? JSONEncoder().encode(Saved(entries: sorted, weekdays: Array(weekdays))) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 課表

    /// 依第一節時間、上課／下課長度、午休產生課表
    func generate() {
        var list: [BellEntry] = []
        var t = genFirstStart
        for p in 1...max(genPeriods, 1) {
            list.append(BellEntry(minutes: t, kind: .start, label: LF("第 %d 節上課", p)))
            t += genClassLength
            list.append(BellEntry(minutes: t, kind: .end, label: LF("第 %d 節下課", p)))
            t += (p == genLunchAfter) ? genLunchLength : genBreakLength
        }
        entries = list.filter { $0.minutes < 24 * 60 }
    }

    func add(minutes: Int, kind: BellEntry.Kind) {
        entries = (entries + [BellEntry(minutes: minutes, kind: kind, label: kind == .start ? L("上課") : L("下課"))])
            .sorted { $0.minutes < $1.minutes }
    }

    func remove(_ id: UUID) { entries.removeAll { $0.id == id } }

    func update(_ entry: BellEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var list = entries
        list[i] = entry
        if list[i].minutes != entries[i].minutes { list.sort { $0.minutes < $1.minutes } }
        entries = list
    }

    // MARK: 時間檢查

    private func tick() {
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let secondOfDay = minuteOfDay * 60 + (comps.second ?? 0)
        let today = weekdays.contains(comps.weekday ?? 0)

        // 下一次鐘響
        let upcoming = today ? entries.first { $0.minutes * 60 > secondOfDay && ($0.kind == .end || ringOnStart) } : nil
        nextEntry = upcoming
        let end = today ? entries.first { $0.kind == .end && $0.minutes * 60 > secondOfDay } : nil
        nextEnd = end
        secondsToNextEnd = end.map { $0.minutes * 60 - secondOfDay } ?? 0
        secondsToNext = upcoming.map { $0.minutes * 60 - secondOfDay } ?? 0

        guard enabled, today else { return }
        let dayKey = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
        for e in entries where e.minutes == minuteOfDay {
            if e.kind == .start && !ringOnStart { continue }
            let key = "\(dayKey)-\(e.id)"
            if firedKeys.contains(key) { continue }
            firedKeys.insert(key)
            ring(e)
        }
    }

    func ring(_ entry: BellEntry? = nil) {
        playBell()
        let e = entry ?? BellEntry(minutes: 0, kind: .end, label: L("下課"))
        if notify { sendNotification(e) }
        if showBanner { onRing?(e) }
    }

    /// 「距離下課」短字串，例如 12:34；今天沒有下課鐘時為 nil
    var endCountdownText: String? {
        guard enabled, nextEnd != nil else { return nil }
        let s = secondsToNextEnd
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    var nextText: String {
        guard let e = nextEntry else { return L("今天沒有鐘響了") }
        let s = secondsToNext
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        let left = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
        return LF("%@（%@）還有 %@", e.label, e.timeText, left)
    }

    // MARK: 聲音

    func playBell() {
        sound?.stop()
        var s: NSSound?
        if let path = customSoundPath, FileManager.default.fileExists(atPath: path) {
            s = NSSound(contentsOfFile: path, byReference: true)
        }
        if s == nil, let url = WestminsterChime.fileURL() {
            s = NSSound(contentsOf: url, byReference: true)
        }
        s?.volume = Float(volume)
        s?.play()
        sound = s
    }

    func stopBell() { sound?.stop() }

    func chooseCustomSound() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { customSoundPath = url.path }
    }

    // MARK: 通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(_ e: BellEntry) {
        let content = UNMutableNotificationContent()
        content.title = e.kind == .end ? L("下課時間到") : L("上課時間到")
        content.body = "\(e.timeText)  \(e.label)"
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// 西敏寺鐘聲（學校常見的「噹噹噹噹」），由程式合成成 WAV
enum WestminsterChime {
    static func fileURL() -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeachOverlay", isDirectory: true)
        let url = dir.appendingPathComponent("westminster-v1.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? render().write(to: url)) != nil else { return nil }
        return url
    }

    private static func render() -> Data {
        let rate = 44100.0
        // E5 C5 D5 G4 ｜ G4 D5 E5 C5
        let notes: [Double] = [659.25, 523.25, 587.33, 392.00, 392.00, 587.33, 659.25, 523.25]
        let step = 0.85
        let total = Double(notes.count) * step + 3.0
        var samples = [Double](repeating: 0, count: Int(total * rate))
        for (i, f) in notes.enumerated() {
            let startIdx = Int(Double(i) * step * rate + (i >= 4 ? 0.5 * rate : 0))
            let dur = 3.2
            // 鐘的泛音：基音、八度、小三度（hum）、五度
            let partials: [(ratio: Double, amp: Double, decay: Double)] = [
                (1.0, 1.0, 1.6), (2.0, 0.5, 2.4), (2.4, 0.28, 2.8), (3.0, 0.22, 3.5), (0.5, 0.25, 1.1),
            ]
            for n in 0..<Int(dur * rate) {
                let idx = startIdx + n
                guard idx < samples.count else { break }
                let t = Double(n) / rate
                let attack = min(1, t / 0.004)
                var v = 0.0
                for p in partials { v += p.amp * exp(-t * p.decay) * sin(2 * .pi * f * p.ratio * t) }
                samples[idx] += v * attack * 0.22
            }
        }
        let peak = samples.map(abs).max() ?? 1
        let k = peak > 0.95 ? 0.95 / peak : 1
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s * k)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
