import SwiftUI
import AppKit

// MARK: - 計時器

struct TimerPane: View {
    @ObservedObject var timer: TimerController
    @ObservedObject var bell: BellScheduler

    private func presetLabel(_ s: Int) -> String {
        s >= 3600 ? LF("%d 小時", s / 3600) : LF("%d 分鐘", s / 60)
    }

    var body: some View {
        Form {
            Section {
                Text(timer.display)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                FlowLayout {
                    Button { timer.toggle() } label: {
                        IconLabel(icon: timer.running ? .pause : .play, text: L(timer.running ? "暫停" : "開始"))
                    }
                    .disabled(timer.mode == .bell)
                    Button { timer.reset() } label: { IconLabel(icon: .rotateLeft, text: L("重設")) }
                        .disabled(timer.mode == .bell)
                    Button { TimerPanel.shared.toggle() } label: { IconLabel(icon: .windowRestore, text: L("浮動顯示")) }
                }
                Picker(L("模式"), selection: $timer.mode) {
                    ForEach(TimerMode.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(L("浮動計時器會顯示在所有畫面最上層，觀眾也看得到，可以拖曳移動。快捷鍵 ⌃⌥T。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            switch timer.mode {
            case .countdown:
                Section(L("倒數計時")) {
                    FlowLayout {
                        ForEach(TimerController.presets, id: \.self) { s in
                            Button(presetLabel(s)) { timer.setCountdown(s) }
                        }
                    }
                    Stepper(value: Binding(get: { timer.countdownSeconds / 60 },
                                           set: { timer.countdownSeconds = max(1, $0) * 60 }), in: 1...600) {
                        LabeledContent(L("自訂分鐘"), value: "\(timer.countdownSeconds / 60)")
                    }
                }
            case .pomodoro:
                Section(L("番茄鐘")) {
                    Stepper(value: $timer.workMinutes, in: 1...120) { LabeledContent(L("專注（分鐘）"), value: "\(timer.workMinutes)") }
                    Stepper(value: $timer.shortBreakMinutes, in: 1...60) { LabeledContent(L("短休息（分鐘）"), value: "\(timer.shortBreakMinutes)") }
                    Stepper(value: $timer.longBreakMinutes, in: 1...90) { LabeledContent(L("長休息（分鐘）"), value: "\(timer.longBreakMinutes)") }
                    Stepper(value: $timer.cyclesBeforeLong, in: 2...10) { LabeledContent(L("幾輪後長休息"), value: "\(timer.cyclesBeforeLong)") }
                    Toggle(L("自動開始下一階段"), isOn: $timer.autoStartNext)
                    LabeledContent(L("已完成"), value: LF("%d 輪", timer.completedPomodoros))
                    Button(L("重新開始一組")) { timer.resetPomodoroCycle() }
                }
            case .bell:
                Section(L("距離鐘響")) {
                    Text(bell.nextText).font(.title3.monospacedDigit())
                    Text(L("依「鐘聲」頁的課表倒數到下一次鐘響。")).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L("外觀與提醒")) {
                Toggle(L("時間到播放提示音"), isOn: $timer.playSound)
                SliderRow(title: L("浮動視窗大小"), value: $timer.panelScale, range: 0.7...2.2, step: 0.1) { String(format: "×%.1f", $0) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 鐘聲

struct BellPane: View {
    @ObservedObject var bell: BellScheduler

    private static let dayNames = ["日", "一", "二", "三", "四", "五", "六"]

    private func timeBinding(_ entry: BellEntry) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: entry.minutes / 60, minute: entry.minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                var e = entry
                e.minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                bell.update(e)
            })
    }

    private func minuteBinding(_ kp: ReferenceWritableKeyPath<BellScheduler, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: bell[keyPath: kp] / 60, minute: bell[keyPath: kp] % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                bell[keyPath: kp] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("依課表自動打鐘"), isOn: $bell.enabled)
                Text(bell.nextText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                LabeledContent(L("上課日")) {
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { day in
                            let on = bell.weekdays.contains(day)
                            Button(L(Self.dayNames[day - 1])) {
                                if on { bell.weekdays.remove(day) } else { bell.weekdays.insert(day) }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Brand.blue : Color.secondary.opacity(0.15)))
                            .foregroundStyle(on ? .white : .primary)
                        }
                    }
                }
                Toggle(L("上課也打鐘"), isOn: $bell.ringOnStart)
                Toggle(L("發送系統通知"), isOn: $bell.notify)
                Toggle(L("在螢幕上顯示提示"), isOn: $bell.showBanner)
                Toggle(L("選單列顯示距離下課"), isOn: $bell.showCountdownInMenuBar)
                Toggle(L("畫圖工具列顯示距離下課"), isOn: $bell.showCountdownInToolbar)
            }

            Section(L("鐘聲")) {
                LabeledContent(L("聲音")) {
                    HStack {
                        Text(bell.customSoundPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("西敏寺鐘聲（學校鐘聲）"))
                            .lineLimit(1).truncationMode(.middle)
                        Button(L("選擇音檔…")) { bell.chooseCustomSound() }
                        if bell.customSoundPath != nil {
                            Button(L("改回預設")) { bell.customSoundPath = nil }
                        }
                    }
                }
                SliderRow(title: L("音量"), value: $bell.volume, range: 0...1, step: 0.05) { "\(Int($0 * 100))%" }
                HStack {
                    Button { bell.ring() } label: { IconLabel(icon: .bell, text: L("試聽並測試通知")) }
                    Button(L("停止")) { bell.stopBell() }
                }
            }

            Section {
                ForEach(bell.entries) { e in
                    HStack {
                        DatePicker("", selection: timeBinding(e), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .frame(width: 90)
                        Picker("", selection: Binding(get: { e.kind }, set: { var x = e; x.kind = $0; bell.update(x) })) {
                            Text(L("上課")).tag(BellEntry.Kind.start)
                            Text(L("下課")).tag(BellEntry.Kind.end)
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        TextField("", text: Binding(get: { e.label }, set: { var x = e; x.label = $0; bell.update(x) }))
                        Button { bell.remove(e.id) } label: { FAIcon(icon: .trashCan, size: 12) }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button { bell.add(minutes: (bell.entries.last?.minutes ?? 480) + 10, kind: .end) } label: {
                        IconLabel(icon: .plus, text: L("新增時間"))
                    }
                }
            } header: {
                Text(L("課表"))
            }

            Section {
                LabeledContent(L("第一節上課")) {
                    DatePicker("", selection: minuteBinding(\.genFirstStart), displayedComponents: .hourAndMinute).labelsHidden()
                }
                Stepper(value: $bell.genClassLength, in: 10...180, step: 5) { LabeledContent(L("每節（分鐘）"), value: "\(bell.genClassLength)") }
                Stepper(value: $bell.genBreakLength, in: 0...60, step: 5) { LabeledContent(L("下課（分鐘）"), value: "\(bell.genBreakLength)") }
                Stepper(value: $bell.genPeriods, in: 1...14) { LabeledContent(L("節數"), value: "\(bell.genPeriods)") }
                Stepper(value: $bell.genLunchAfter, in: 0...14) { LabeledContent(L("第幾節後午休（0 = 無）"), value: "\(bell.genLunchAfter)") }
                Stepper(value: $bell.genLunchLength, in: 10...180, step: 5) { LabeledContent(L("午休（分鐘）"), value: "\(bell.genLunchLength)") }
                Button { bell.generate() } label: { IconLabel(icon: .rotateRight, text: L("產生課表（會取代上方課表）")) }
            } header: {
                Text(L("快速產生課表"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 抽籤

struct PickerPane: View {
    @ObservedObject var store: PickerStore
    @ObservedObject var nav: PickerPaneState = .shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Button { store.draw() } label: {
                        IconLabel(icon: store.rolling ? .pause : .dice, text: store.rolling ? L("停！") : L("抽籤"))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(Brand.gradient))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Stepper(value: $store.drawCount, in: 1...20) { Text(LF("一次 %d 人", store.drawCount)) }
                        .fixedSize()
                    Spacer()
                    Text(LF("剩餘 %d", store.remainingCount)).foregroundStyle(.secondary)
                    Button { PickerPanel.shared.toggle() } label: { IconLabel(icon: .windowRestore, text: L("浮動顯示")) }
                }
                if !store.lastResults.isEmpty {
                    Text(store.lastResults.joined(separator: "、")).font(.title3.bold())
                }
                Picker(L("抽籤來源"), selection: $store.source) {
                    ForEach(PickSource.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("自動停止"), isOn: $store.autoStop)
                SliderRow(title: L("滾動時間"), value: $store.rollDuration, range: 0.5...10, step: 0.5) { LF("%.1f 秒", $0) }
                    .disabled(!store.autoStop)
                if !store.autoStop {
                    Text(L("手動停止：抽籤後畫面會一直滾動，按「停！」或再按一次 ⌃⌥R 才揭曉。")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L("不重複抽（排除已抽過）"), isOn: $store.excludePicked)
                Toggle(L("排除請假"), isOn: $store.excludeAbsent)
                Button(L("重設已抽過")) { store.resetPicked() }
            } footer: {
                Text(L("快捷鍵 ⌃⌥R 直接抽籤，結果會以大字顯示在畫面上。")).font(.caption).foregroundStyle(.secondary)
            }

            if store.source == .seats {
                Section(L("座號範圍")) {
                    Stepper(value: $store.seatFrom, in: 1...999) { LabeledContent(L("從"), value: "\(store.seatFrom)") }
                    Stepper(value: $store.seatTo, in: 1...999) { LabeledContent(L("到"), value: "\(store.seatTo)") }
                    Text(L("點座號可切換：藍色＝已抽過、灰色斜線＝請假（右鍵）")).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                        ForEach(min(store.seatFrom, store.seatTo)...max(store.seatFrom, store.seatTo), id: \.self) { n in
                            let picked = store.seatPicked.contains(n), absent = store.seatAbsent.contains(n)
                            Text("\(n)")
                                .font(.callout.monospacedDigit())
                                .strikethrough(absent)
                                .frame(width: 40, height: 30)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(absent ? Color.secondary.opacity(0.25) : (picked ? Brand.blue.opacity(0.8) : Color.secondary.opacity(0.1))))
                                .foregroundStyle(picked && !absent ? .white : .primary)
                                .onTapGesture {
                                    if picked { store.seatPicked.remove(n) } else { store.seatPicked.insert(n) }
                                }
                                .contextMenu {
                                    Button(absent ? L("取消請假") : L("請假")) { store.toggleSeatAbsent(n) }
                                }
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        Button {
                            if let n = store.importWithPanel() { nav.message = LF("已匯入 %d 人", n) }
                        } label: { IconLabel(icon: .fileImport, text: L("匯入 txt…")) }
                        Button { store.exportWithPanel() } label: { IconLabel(icon: .floppyDisk, text: L("匯出")) }
                        Spacer()
                        Text(nav.message).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L("txt 每行一人，可寫「座號 學號 姓名」、「學號,姓名」或只寫姓名；以空白、Tab 或逗號分隔。"))
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text(L("名冊"))
                }

                Section {
                    TextField(L("學號樣式"), text: $store.idPattern)
                    Stepper(value: $store.patternFrom, in: 0...9999) { LabeledContent(L("從"), value: "\(store.patternFrom)") }
                    Stepper(value: $store.patternTo, in: 0...9999) { LabeledContent(L("到"), value: "\(store.patternTo)") }
                    LabeledContent(L("預覽"), value: "\(PickerStore.format(store.idPattern, store.patternFrom)) … \(PickerStore.format(store.idPattern, store.patternTo))")
                    Button(L("依樣式產生名冊（會取代目前名冊）")) { store.generateFromPattern() }
                } header: {
                    Text(L("自訂學號樣式"))
                } footer: {
                    Text(L("{###} 會換成補零的號碼（位數＝#的數量），{n} 換成不補零的號碼。例：B111{###} → B111001。"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section(LF("學生（%d 人）", store.students.count)) {
                    ForEach(store.students) { st in
                        HStack {
                            Text(st.display).strikethrough(st.absent)
                            Spacer()
                            if st.picked { Text(L("已抽")).font(.caption).foregroundStyle(Brand.blue) }
                            Toggle(L("請假"), isOn: Binding(get: { st.absent }, set: { _ in store.toggleAbsent(st.id) }))
                                .toggleStyle(.checkbox)
                            Button { store.togglePicked(st.id) } label: {
                                FAIcon(icon: st.picked ? .checkDouble : .circle, style: st.picked ? .solid : .regular, size: 12)
                            }
                            .buttonStyle(.borderless)
                            .help(L("標記已抽過"))
                        }
                    }
                }
            }

            if !store.history.isEmpty {
                Section(L("抽籤紀錄")) {
                    ForEach(store.history.prefix(30)) { r in
                        LabeledContent(r.text, value: r.date.formatted(date: .omitted, time: .shortened))
                    }
                    Button(L("清除紀錄")) { store.history.removeAll() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class PickerPaneState: ObservableObject {
    static let shared = PickerPaneState()
    @Published var message = ""
}

// MARK: - 放大鏡

struct MagnifierPane: View {
    @ObservedObject var c: OverlayController

    var body: some View {
        Form {
            Section {
                Toggle(L("放大鏡"), isOn: Binding(get: { c.magnifierOn }, set: { if $0 != c.magnifierOn { c.toggleMagnifier() } }))
                SliderRow(title: L("放大倍率"), value: $c.magnifierZoom, range: 1.5...8, step: 0.5) { String(format: "×%.1f", $0) }
                SliderRow(title: L("鏡片大小"), value: $c.magnifierSize, range: 140...600, step: 10) { "\(Int($0))" }
                Picker(L("形狀"), selection: $c.magnifierCircle) {
                    Text(L("圓形")).tag(true)
                    Text(L("圓角方形")).tag(false)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(L("快捷鍵 ⌃⌥Z 開關，開啟時 ⌃⌥= / ⌃⌥- 調整倍率。需要「螢幕錄製」權限。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("截圖並標註")) {
                HStack {
                    Button { c.captureScreenshot(.selection) } label: { IconLabel(icon: .cropSimple, text: L("選取範圍")) }
                    Button { c.captureScreenshot(.window) } label: { IconLabel(icon: .windowRestore, text: L("視窗")) }
                    Button { c.captureScreenshot(.screen) } label: { IconLabel(icon: .display, text: L("整個螢幕")) }
                }
                Text(L("截圖會放進白板的新頁面，可以直接在上面畫圖，⌘S 存檔、⌘C 拷貝。快捷鍵 ⌃⌥P。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 黑屏

struct BlackoutCard: View {
    @ObservedObject var black: BlackoutController
    var body: some View {
        ActionCard(icon: .eyeSlash, title: L("黑屏"),
                   subtitle: L("讓投影畫面變黑，筆電畫面保留。"),
                   shortcut: "⌃⌥B", buttonTitle: black.active ? L("恢復畫面") : L("黑屏"),
                   active: black.active) { black.toggle() }
    }
}

struct BlackoutPane: View {
    @ObservedObject var black: BlackoutController

    var body: some View {
        Form {
            Section {
                Toggle(L("黑屏"), isOn: Binding(get: { black.active }, set: { $0 ? black.activate() : black.deactivate() }))
                Picker(L("要黑掉的螢幕"), selection: $black.target) {
                    ForEach(BlackoutTarget.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if black.target == .custom {
                    ForEach(black.screens, id: \.localizedName) { s in
                        Toggle(isOn: Binding(
                            get: { black.customScreens.contains(s.localizedName) },
                            set: { on in
                                if on { black.customScreens.insert(s.localizedName) } else { black.customScreens.remove(s.localizedName) }
                            })) {
                            Text(s.localizedName + (BlackoutController.isBuiltIn(s) ? "（" + L("筆電") + "）" : ""))
                        }
                    }
                }
                Toggle(L("黑屏時顯示「請看老師」"), isOn: $black.showMessage)
            } footer: {
                Text(L("快捷鍵 ⌃⌥B。螢幕若是「鏡像輸出」，筆電和投影是同一個畫面，無法只黑掉投影；請在系統設定改成「延伸顯示」。全部黑掉時，在畫面上點一下或按 Esc 就會恢復。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 自訂不顯示按鍵的 App

struct ExcludedAppsEditor: View {
    @ObservedObject var c: OverlayController

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func name(_ bid: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("其他不顯示按鍵的 App")).font(.callout)
                Spacer()
                Menu(L("加入 App…")) {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            if let bid = app.bundleIdentifier, !c.extraExcludedApps.contains(bid) {
                                c.extraExcludedApps.append(bid)
                            }
                        }
                    }
                }
                .fixedSize()
            }
            ForEach(c.extraExcludedApps, id: \.self) { bid in
                HStack {
                    Text(name(bid))
                    Spacer()
                    Button { c.extraExcludedApps.removeAll { $0 == bid } } label: { FAIcon(icon: .xmark, size: 11) }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
            }
        }
        .disabled(!c.hideInChatApps)
    }
}


// MARK: - 全螢幕時鐘

struct ClockCard: View {
    @ObservedObject var clock: ClockController
    var body: some View {
        ActionCard(icon: .clock, title: L("全螢幕時鐘"),
                   subtitle: L("全螢幕大時鐘，可顯示在全部或特定螢幕。"),
                   shortcut: "⌃⌥L", buttonTitle: clock.active ? L("關閉") : L("顯示"),
                   active: clock.active) { clock.toggle() }
    }
}

struct ClockPane: View {
    @ObservedObject var clock: ClockController

    var body: some View {
        Form {
            Section {
                Toggle(L("全螢幕時鐘"), isOn: Binding(get: { clock.active }, set: { $0 ? clock.show() : clock.hide() }))
                Picker(L("顯示在"), selection: $clock.target) {
                    ForEach(BlackoutTarget.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if clock.target == .custom {
                    ForEach(NSScreen.screens, id: \.localizedName) { s in
                        Toggle(isOn: Binding(
                            get: { clock.customScreens.contains(s.localizedName) },
                            set: { on in
                                if on { clock.customScreens.insert(s.localizedName) } else { clock.customScreens.remove(s.localizedName) }
                            })) {
                            Text(s.localizedName + (BlackoutController.isBuiltIn(s) ? "（" + L("筆電") + "）" : ""))
                        }
                    }
                }
            } footer: {
                Text(L("快捷鍵 ⌃⌥L。在時鐘畫面上點一下或按 Esc 關閉。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("樣式")) {
                Picker(L("樣式"), selection: $clock.style) {
                    ForEach(ClockStyle.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("24 小時制"), isOn: $clock.use24Hour)
                Toggle(L("顯示秒數"), isOn: $clock.showSeconds)
                Toggle(L("顯示日期"), isOn: $clock.showDate)
                Toggle(L("顯示距離下一次鐘響"), isOn: $clock.showNextBell)
                Toggle(L("深色背景"), isOn: $clock.darkBackground)
            }
        }
        .formStyle(.grouped)
    }
}
