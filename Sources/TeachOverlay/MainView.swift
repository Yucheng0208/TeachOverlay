import SwiftUI
import AppKit
import ServiceManagement

enum Pane: String, CaseIterable, Identifiable {
    case overview = "總覽"
    case notes = "筆記"
    case keys = "按鍵顯示"
    case shortcuts = "快捷鍵懸停"
    case mouse = "滑鼠效果"
    case spotlight = "聚光燈"
    case draw = "畫圖與白板"
    case hotkeys = "快捷鍵一覽"
    case permissions = "權限"
    case general = "一般"
    case help = "使用說明"
    case about = "關於"

    var id: Self { self }

    var icon: FA {
        switch self {
        case .overview: .gauge
        case .notes: .noteSticky
        case .keys: .keyboard
        case .shortcuts: .thumbtack
        case .mouse: .computerMouse
        case .spotlight: .lightbulb
        case .draw: .chalkboard
        case .hotkeys: .sliders
        case .permissions: .shieldHalved
        case .general: .gear
        case .help: .circleQuestion
        case .about: .circleInfo
        }
    }

    static let groups: [(String, [Pane])] = [
        ("主要", [.overview, .notes]),
        ("效果", [.keys, .shortcuts, .mouse, .spotlight, .draw]),
        ("其他", [.hotkeys, .permissions, .general, .help, .about]),
    ]
}

/// 品牌色（取自 Logo 的藍→紫漸層）
enum Brand {
    static let blue = Color(red: 0.18, green: 0.47, blue: 0.98)
    static let purple = Color(red: 0.49, green: 0.30, blue: 0.94)
    static var gradient: LinearGradient {
        LinearGradient(colors: [blue, purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 側邊欄目前選的頁面（不用 @State，Command Line Tools 沒有 SwiftUI 巨集外掛）
@MainActor
final class NavModel: ObservableObject {
    @Published var pane: Pane? = .overview
}

struct MainView: View {
    @ObservedObject var c: OverlayController
    @ObservedObject var draw: DrawSettings
    @ObservedObject var nav: NavModel
    @ObservedObject var loc: Loc

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.pane) {
                ForEach(Pane.groups, id: \.0) { title, panes in
                    Section(L(title)) {
                        ForEach(panes) { p in
                            Label {
                                Text(L(p.rawValue)).font(.system(size: 14))
                            } icon: {
                                FAIcon(icon: p.icon, size: 14).frame(width: 22)
                            }
                            .padding(.vertical, 3)
                            .tag(p)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
                .navigationTitle(L(nav.pane?.rawValue ?? "總覽"))
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(Brand.blue)
        .accentColor(Brand.blue)
        .id(loc.resolved)   // 換語言時整個重建
    }

    @ViewBuilder private var detail: some View {
        switch nav.pane ?? .overview {
        case .overview: OverviewPane(c: c) { nav.pane = .permissions }
        case .notes: NotesPane(store: .shared)
        case .keys: KeysPane(c: c)
        case .shortcuts: ShortcutsPane(c: c)
        case .mouse: MousePane(c: c)
        case .spotlight: SpotlightPane(c: c)
        case .draw: DrawPane(c: c, draw: draw)
        case .hotkeys: HotkeysPane()
        case .permissions: PermissionsPane(c: c)
        case .general: GeneralPane(loc: loc, prefs: .shared, c: c)
        case .help: HelpPane { nav.pane = $0 }
        case .about: AboutPane { nav.pane = .permissions }
        }
    }
}

// MARK: - 共用元件

struct ShortcutBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor)))
    }
}

struct FeatureCard: View {
    let icon: FA
    let title: String
    let subtitle: String
    let shortcut: String
    @Binding var isOn: Bool

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                FAIcon(icon: icon, size: 22)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ShortcutBadge(text: shortcut)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

struct ActionCard: View {
    let icon: FA
    let title: String
    let subtitle: String
    let shortcut: String
    let buttonTitle: String
    var active = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                FAIcon(icon: icon, size: 22)
                    .foregroundStyle(destructive ? Color.red : (active ? Color.accentColor : Color.secondary))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ShortcutBadge(text: shortcut)
                }
                Spacer(minLength: 8)
                Button(buttonTitle, role: destructive ? .destructive : nil, action: action)
            }
        }
    }
}

struct IconLabel: View {
    let icon: FA
    let text: String
    var style: FAStyle = .solid
    var body: some View {
        Label { Text(text) } icon: { FAIcon(icon: icon, style: style, size: 13) }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }
}

// MARK: - 總覽

struct OverviewPane: View {
    @ObservedObject var c: OverlayController
    let goPermissions: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    if !Permissions.accessibilityGranted || !(Permissions.inputMonitoringGranted || c.keys.isRunning) {
                        Card {
                            HStack(spacing: 12) {
                                FAIcon(icon: .shieldHalved, size: 22).foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L("還需要開啟權限")).font(.headline)
                                    Text(L("按鍵顯示與點擊效果需要「輔助使用」和「輸入監控」權限。"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L("前往設定"), action: goPermissions)
                            }
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    FeatureCard(icon: .keyboard, title: L("放大顯示按鍵"),
                                subtitle: L("打字與組合鍵放大顯示；帳號、密碼等隱私欄位只顯示「已隱藏」。"),
                                shortcut: "⌃⌥K", isOn: $c.keystrokesEnabled)
                    FeatureCard(icon: .handPointer, title: L("雙擊脈衝"),
                                subtitle: L("滑鼠雙擊時出現擴散圓圈，顏色可自訂。"),
                                shortcut: "⌃⌥C", isOn: $c.clickPulseEnabled)
                    FeatureCard(icon: .lightbulb, title: L("聚光燈"),
                                subtitle: L("周圍變暗，只照亮游標附近。按 Esc 也能關閉。"),
                                shortcut: "⌃⌥S",
                                isOn: Binding(get: { c.spotlightOn },
                                              set: { if $0 != c.spotlightOn { c.toggleSpotlight() } }))
                    ActionCard(icon: .penNib, title: L("畫圖標註"),
                               subtitle: L("直接在螢幕上畫線、箭頭、方框。"),
                               shortcut: "⌃⌥D",
                               buttonTitle: c.drawMode && !c.whiteboardOn ? L("結束") : L("開始畫圖"),
                               active: c.drawMode && !c.whiteboardOn) { c.toggleDraw() }
                    ActionCard(icon: .chalkboard, title: L("白板"),
                               subtitle: L("全螢幕白板，多頁、可存成 PNG。"),
                               shortcut: "⌃⌥W",
                               buttonTitle: c.whiteboardOn ? L("關閉白板") : L("開啟白板"),
                               active: c.whiteboardOn) { c.toggleWhiteboard() }
                    ActionCard(icon: .powerOff, title: L("關閉全部效果"),
                               subtitle: L("一次關掉聚光燈、畫圖、白板並清除快捷鍵紀錄。"),
                               shortcut: "⌃⌥X", buttonTitle: L("全部關閉"), destructive: true) { c.turnOffAll() }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - 筆記

struct NotesPane: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    FAIcon(icon: .magnifyingGlass, size: 12).foregroundStyle(.secondary)
                    TextField(L("搜尋筆記"), text: $store.search).textFieldStyle(.plain)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
                .padding(10)

                List(selection: $store.selectedID) {
                    ForEach(store.filtered) { n in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.title.isEmpty ? L("未命名筆記") : n.title).font(.headline).lineLimit(1)
                            Text(n.body.isEmpty ? L("（空白）") : n.body.replacingOccurrences(of: "\n", with: " "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(n.updated.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                        .tag(n.id)
                        .contextMenu {
                            Button(L("刪除"), role: .destructive) { store.delete(n.id) }
                        }
                    }
                }
                .listStyle(.inset)

                HStack {
                    Button { store.add() } label: { IconLabel(icon: .plus, text: L("新增筆記")) }
                    Spacer()
                    if let id = store.selectedID {
                        Button { store.delete(id) } label: { FAIcon(icon: .trashCan, size: 13) }
                            .help(L("刪除"))
                    }
                }
                .padding(10)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            Group {
                if let id = store.selectedID, let note = store.note(id) {
                    NoteEditor(store: store, note: note)
                        .id(id)
                } else {
                    VStack(spacing: 12) {
                        FAIcon(icon: .noteSticky, style: .regular, size: 40).foregroundStyle(.tertiary)
                        Text(L("還沒有筆記")).font(.title3)
                        Text(L("記下上課重點、操作步驟或講稿，可以浮動顯示在螢幕上。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button { store.add() } label: { IconLabel(icon: .plus, text: L("新增筆記")) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct NoteEditor: View {
    @ObservedObject var store: NotesStore
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L("標題"), text: Binding(
                    get: { store.note(note.id)?.title ?? "" },
                    set: { store.update(note.id, title: $0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Button { NotePanel.shared.show(note.id) } label: {
                    IconLabel(icon: .windowRestore, text: L("浮動顯示"))
                }
                .help(L("在所有畫面最上層顯示這則筆記，錄影或分享畫面時盡量不被錄進去"))
            }
            Text(LF("最後修改：%@", (store.note(note.id)?.updated ?? note.updated).formatted(date: .abbreviated, time: .shortened)))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { store.note(note.id)?.body ?? "" },
                set: { store.update(note.id, body: $0) }))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
        .padding(20)
    }
}

// MARK: - 按鍵顯示

struct KeysPane: View {
    @ObservedObject var c: OverlayController

    var body: some View {
        Form {
            Section {
                Toggle(L("顯示按鍵"), isOn: $c.keystrokesEnabled)
                Picker(L("顯示在"), selection: $c.displayTarget) {
                    ForEach(DisplayTarget.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(L("按鍵與快捷鍵會同步顯示在選擇的螢幕；全螢幕 App 與所有桌面空間也會顯示。"))
                    .font(.caption).foregroundStyle(.secondary)
                SliderRow(title: L("字體大小"), value: $c.hudFontSize, range: 24...120, step: 4) { "\(Int($0)) pt" }
                Picker(L("位置"), selection: $c.hudPosition) {
                    ForEach(HUDPosition.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                SliderRow(title: L("停留時間"), value: $c.hudDuration, range: 0.8...5, step: 0.2) { LF("%.1f 秒", $0) }
                HStack {
                    Spacer()
                    Button { c.previewKeys() } label: { IconLabel(icon: .eye, text: L("預覽")) }
                }
            }

            Section {
                Picker(L("組合鍵顯示方式"), selection: $c.comboStyle) {
                    ForEach(ComboStyle.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("顯示功能說明（例如 Command + C 複製）"), isOn: $c.showComboMeaning)
            } header: {
                Text(L("組合鍵"))
            } footer: {
                Text(L("常見快捷鍵會附上功能說明；實際功能仍依各 App 而定。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("中文輸入")) {
                Toggle(L("注音：先顯示注音，選字後顯示中文"), isOn: $c.zhuyinEnabled)
                Text(L("支援 macOS 內建注音（標準鍵盤）與小麥注音。中文字是從目前的輸入框讀出來的；終端機或部分網頁編輯器讀不到時，只會顯示注音。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("隱私保護")) {
                LabeledContent {
                    Text(L("密碼欄位一律只顯示「已隱藏」"))
                } label: {
                    IconLabel(icon: .lock, text: L("密碼"))
                }
                Toggle(L("帳號、學號等隱私欄位也只顯示「已隱藏」"), isOn: $c.hidePrivateFields)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("欄位名稱、提示文字或標籤含有以下字詞就隱藏（以逗號分隔）"))
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $c.privateKeywords)
                        .font(.system(size: 12))
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .disabled(!c.hidePrivateFields)
                    Button(L("還原預設字詞")) {
                        c.privateKeywords = KeystrokeMonitor.defaultPrivateKeywords.joined(separator: ", ")
                    }
                    .controlSize(.small)
                }
                Toggle(L("在終端機中隱藏按鍵（防止 sudo 密碼外洩）"), isOn: $c.hideInTerminals)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 快捷鍵懸停

struct ShortcutsPane: View {
    @ObservedObject var c: OverlayController

    var body: some View {
        Form {
            Section {
                Picker(L("顯示在"), selection: $c.displayTarget) {
                    ForEach(DisplayTarget.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(L("按鍵與快捷鍵會同步顯示在選擇的螢幕；全螢幕 App 與所有桌面空間也會顯示。"))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("顯示位置"), selection: $c.shortcutCorner) {
                    ForEach(ShortcutCorner.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                SliderRow(title: L("字體大小"), value: $c.shortcutFontSize, range: 14...48, step: 2) { "\(Int($0)) pt" }
                Toggle(L("一直保留（直到按 ⌃⌥X 或清除）"), isOn: $c.shortcutPinned)
                SliderRow(title: L("保留時間"), value: $c.shortcutHold, range: 2...60, step: 1) { LF("%d 秒", Int($0)) }
                    .disabled(c.shortcutPinned)
            } footer: {
                Text(L("按下組合鍵（例如 ⌘C、⌘⇧4）時，會在角落堆疊保留最近 6 個，重複按同一個會顯示 ×次數。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("目前紀錄")) {
                if c.shortcutHistory.isEmpty {
                    Text(L("尚無紀錄")).foregroundStyle(.secondary)
                } else {
                    ForEach(c.shortcutHistory) { Text($0.label).font(.system(.body, design: .rounded).weight(.semibold)) }
                }
                HStack {
                    Button { c.previewKeys() } label: { IconLabel(icon: .eye, text: L("測試")) }
                    Spacer()
                    Button { c.clearShortcuts() } label: { IconLabel(icon: .trashCan, text: L("清除紀錄")) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 滑鼠效果

struct ColorSwatchRow: View {
    let title: String
    @Binding var color: NSColor

    static let presets: [NSColor] = [
        .systemYellow, .systemOrange, .systemRed, .systemPink, .systemPurple,
        .systemBlue, .systemTeal, .systemGreen, .white, .black,
    ]

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                ForEach(Self.presets.indices, id: \.self) { i in
                    let p = Self.presets[i]
                    Circle()
                        .fill(Color(nsColor: p))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: isSelected(p) ? 3 : 0).padding(-3))
                        .onTapGesture { color = p }
                }
                Divider().frame(height: 20)
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: color) },
                    set: { color = NSColor($0) }), supportsOpacity: false)
                    .labelsHidden()
                    .help(L("自訂顏色"))
            }
        }
    }

    private func isSelected(_ p: NSColor) -> Bool {
        guard let a = p.usingColorSpace(.sRGB), let b = color.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}

struct MousePane: View {
    @ObservedObject var c: OverlayController

    var body: some View {
        Form {
            Section {
                Toggle(L("雙擊時顯示脈衝圓圈"), isOn: $c.clickPulseEnabled)
                Toggle(L("單擊也顯示（較小的圓圈）"), isOn: $c.showAllClicks)
            }
            Section(L("按鍵與長按")) {
                Toggle(L("游標旁顯示按下的是左鍵、右鍵或中鍵"), isOn: $c.showMouseButtons)
                Toggle(L("長按時顯示「長按」與持續的圓圈"), isOn: $c.showLongPress)
                SliderRow(title: L("長按判定時間"), value: $c.longPressDelay, range: 0.2...1.5, step: 0.05) { LF("%.2f 秒", $0) }
                    .disabled(!c.showLongPress)
            }
            Section(L("顏色")) {
                ColorSwatchRow(title: L("左鍵顏色"), color: $c.leftClickColor)
                ColorSwatchRow(title: L("右鍵顏色"), color: $c.rightClickColor)
                SliderRow(title: L("填色透明度"), value: $c.pulseFillOpacity, range: 0...0.8, step: 0.05) { "\(Int($0 * 100))%" }
            }
            Section(L("樣式")) {
                SliderRow(title: L("大小"), value: $c.pulseScale, range: 0.5...3, step: 0.1) { String(format: "×%.1f", $0) }
                SliderRow(title: L("速度"), value: $c.pulseDuration, range: 0.3...1.5, step: 0.05) { LF("%.2f 秒", $0) }
                Stepper(value: $c.pulseRings, in: 1...4) {
                    LabeledContent(L("圈數"), value: "\(c.pulseRings)")
                }
                SliderRow(title: L("線條粗細"), value: $c.pulseLineWidth, range: 1...10, step: 0.5) { String(format: "%.1f", $0) }
            }
            Section {
                HStack {
                    Spacer()
                    Button { c.testPulse() } label: { IconLabel(icon: .bullseye, text: L("在游標位置測試")) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 聚光燈

struct SpotlightPane: View {
    @ObservedObject var c: OverlayController

    var body: some View {
        Form {
            Section {
                Toggle(L("聚光燈"), isOn: Binding(get: { c.spotlightOn },
                                                set: { if $0 != c.spotlightOn { c.toggleSpotlight() } }))
                SliderRow(title: L("光圈大小"), value: $c.spotlightRadius, range: 50...600, step: 10) { "\(Int($0))" }
                SliderRow(title: L("周圍暗度"), value: $c.spotlightDim, range: 0.2...0.9, step: 0.02) { "\(Int($0 * 100))%" }
            } footer: {
                Text(L("關閉方式：再按一次 ⌃⌥S、按 Esc，或按 ⌃⌥X 關閉全部效果。開啟時可用 ⌃⌥↑ / ⌃⌥↓ 調整大小。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 畫圖與白板

struct DrawPane: View {
    @ObservedObject var c: OverlayController
    @ObservedObject var draw: DrawSettings

    var body: some View {
        Form {
            Section(L("工具")) {
                HStack(spacing: 8) {
                    ForEach(DrawTool.allCases, id: \.self) { t in
                        Button { draw.tool = t } label: {
                            VStack(spacing: 4) {
                                FAIcon(icon: t.fa, style: t.faStyle, size: 18)
                                Text(L(t.rawValue)).font(.caption).lineLimit(1)
                            }
                            .frame(width: 72, height: 52)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(draw.tool == t ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                LabeledContent(L("顏色")) {
                    HStack(spacing: 10) {
                        ForEach(DrawSettings.palette.indices, id: \.self) { i in
                            Circle()
                                .fill(Color(nsColor: DrawSettings.palette[i].color))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.accentColor, lineWidth: draw.colorIndex == i ? 3 : 0))
                                .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                                .onTapGesture { draw.colorIndex = i }
                        }
                    }
                }
                LabeledContent(L("粗細")) {
                    HStack {
                        Slider(value: $draw.width, in: 2...40, step: 2)
                        Text("\(Int(draw.width))").monospacedDigit().frame(width: 32, alignment: .trailing)
                    }
                }
            }

            Section(L("白板")) {
                Picker(L("背景"), selection: $c.boardStyle) {
                    ForEach(BoardStyle.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack {
                    Button { c.toggleDraw() } label: { IconLabel(icon: .penNib, text: L("開始畫圖（⌃⌥D）")) }
                    Button { c.toggleWhiteboard() } label: { IconLabel(icon: .chalkboard, text: L("開啟白板（⌃⌥W）")) }
                }
            } footer: {
                Text(L("畫圖時螢幕上方會出現工具列，可以直接點選；Esc 離開。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 快捷鍵一覽

struct HotkeysPane: View {
    private let global: [(String, String)] = [
        ("⌃⌥K", "顯示按鍵 開／關"), ("⌃⌥C", "雙擊脈衝 開／關"), ("⌃⌥S", "聚光燈 開／關"),
        ("Esc", "關閉聚光燈（聚光燈開啟時）"), ("⌃⌥↑ / ⌃⌥↓", "聚光燈大小"),
        ("⌃⌥D", "畫圖標註"), ("⌃⌥W", "白板"), ("⌃⌥X", "關閉全部效果"), ("⌘,", "開啟主控台"),
    ]
    private let drawing: [(String, String)] = [
        ("P H L A R O", "畫筆、螢光筆、直線、箭頭、方框、圓形"), ("Shift + Drag", "水平／垂直、正方形、正圓"),
        ("1 – 6", "紅、藍、綠、黃、黑、白"), ("- / =", "變細／變粗"), ("⌘Z", "復原"), ("C", "清除"),
        ("W", "切換螢幕標註／白板"), ("B", "白板換背景"), ("N", "白板新增一頁"), ("← / →", "白板換頁"),
        ("⌘S", "白板存成 PNG"), ("Esc", "離開"),
    ]

    var body: some View {
        Form {
            Section(L("全域")) { rows(global) }
            Section(L("畫圖／白板模式")) { rows(drawing) }
        }
        .formStyle(.grouped)
    }

    private func rows(_ items: [(String, String)]) -> some View {
        ForEach(items, id: \.1) { k, v in
            LabeledContent { Text(L(v)).foregroundStyle(.secondary) } label: { ShortcutBadge(text: k) }
        }
    }
}

// MARK: - 權限

struct PermissionsPane: View {
    @ObservedObject var c: OverlayController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                Section {
                    row(L("輔助使用"), detail: L("偵測點擊、密碼與隱私欄位、讀取注音轉換結果"),
                        ok: Permissions.accessibilityGranted, open: Permissions.openAccessibilitySettings)
                    row(L("輸入監控"), detail: L("讀取鍵盤按鍵"),
                        ok: Permissions.inputMonitoringGranted || c.keys.isRunning, open: Permissions.openInputMonitoringSettings)
                } footer: {
                    Text(L("開啟後不需要重新啟動，約 2 秒內生效。若重新編譯過 App，可能需要在設定中先移除再重新加入。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row(_ title: String, detail: String, ok: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            FAIcon(icon: ok ? .circleCheck : .circleXmark, size: 18)
                .foregroundStyle(ok ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(ok ? L("已開啟") : L("開啟設定…"), action: open).disabled(ok)
        }
    }
}

// MARK: - 一般

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "跟隨系統", light = "淺色", dark = "深色"
    var id: String { rawValue }
    var icon: FA {
        switch self {
        case .system: .circleHalfStroke
        case .light: .sun
        case .dark: .moon
        }
    }
}

@MainActor
final class AppPrefs: ObservableObject {
    static let shared = AppPrefs()

    @Published var appearance: AppAppearance =
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "app.appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "app.appearance")
            applyAppearance()
            onAppearanceChange?()
        }
    }
    var onAppearanceChange: (() -> Void)?

    /// 明亮／暗黑模式：nil = 跟隨系統
    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @Published var showWindowAtLaunch: Bool = UserDefaults.standard.object(forKey: "app.showAtLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showWindowAtLaunch, forKey: "app.showAtLaunch") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct GeneralPane: View {
    @ObservedObject var loc: Loc
    @ObservedObject var prefs: AppPrefs
    @ObservedObject var c: OverlayController

    var body: some View {
        Form {
            Section(L("外觀")) {
                LabeledContent(L("App 外觀")) {
                    HStack(spacing: 8) {
                        ForEach(AppAppearance.allCases) { a in
                            Button { prefs.appearance = a } label: {
                                VStack(spacing: 5) {
                                    FAIcon(icon: a.icon, size: 18)
                                    Text(L(a.rawValue)).font(.caption)
                                }
                                .frame(width: 84, height: 54)
                                .background(RoundedRectangle(cornerRadius: 9)
                                    .fill(prefs.appearance == a ? Brand.blue.opacity(0.22) : Color.secondary.opacity(0.08)))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .stroke(prefs.appearance == a ? Brand.blue : Color.clear, lineWidth: 2))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Picker(L("螢幕提示配色"), selection: $c.overlayStyle) {
                    ForEach(OverlayStyle.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(L("螢幕上的按鍵泡泡、快捷鍵、滑鼠圖示與畫圖工具列的配色。"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $loc.choice) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                } label: {
                    IconLabel(icon: .globe, text: L("語言"))
                }
            } footer: {
                Text(L("切換後立即生效，不需要重新啟動。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("啟動")) {
                Toggle(L("啟動時開啟主控台"), isOn: $prefs.showWindowAtLaunch)
                Toggle(L("登入時自動啟動"), isOn: Binding(get: { prefs.launchAtLogin },
                                                      set: { prefs.setLaunchAtLogin($0) }))
                if let err = prefs.loginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 關於

struct AboutPane: View {
    let goPermissions: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }
    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private let features: [(FA, String)] = [
        (.keyboard, "放大顯示按鍵"), (.thumbtack, "快捷鍵懸停"), (.lock, "隱私欄位自動隱藏"),
        (.handPointer, "雙擊脈衝"), (.lightbulb, "聚光燈"), (.penNib, "畫圖標註"),
        (.chalkboard, "白板"), (.noteSticky, "筆記"), (.globe, "五種語言"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    if let icon = FontAwesome.appIcon() {
                        Image(nsImage: icon).resizable().frame(width: 110, height: 110)
                    }
                    Text("TeachOverlay").font(.largeTitle.bold())
                    Text(L("教學螢幕助手")).font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, 10)

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        info(L("版本"), "\(version) (\(build))")
                        info(L("架構"), "Apple Silicon (arm64)")
                        info(L("系統"), osVersion)
                        info(L("筆記位置"), NotesStore.shared.fileURL.path)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("功能")).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(features, id: \.1) { icon, name in
                                IconLabel(icon: icon, text: L(name))
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("專案")).font(.headline)
                        Text(L("TeachOverlay 是開源專案，原始碼、更新與問題回報都在 GitHub。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(AppLinks.repo.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button { NSWorkspace.shared.open(AppLinks.repo) } label: {
                                IconLabel(icon: .github, text: L("GitHub 專案頁面"), style: .brands)
                            }
                            Button { NSWorkspace.shared.open(AppLinks.releases) } label: {
                                IconLabel(icon: .download, text: L("下載最新版本"))
                            }
                            Button { NSWorkspace.shared.open(AppLinks.issues) } label: {
                                IconLabel(icon: .bug, text: L("回報問題"))
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("致謝與授權")).font(.headline)
                        Text(L("圖示：Font Awesome Free 6.7.2（CC BY 4.0，字型 SIL OFL 1.1）· fontawesome.com"))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { openLicense() } label: { IconLabel(icon: .fileLines, text: L("檢視授權")) }
                            Button(action: goPermissions) { IconLabel(icon: .shieldHalved, text: L("權限設定")) }
                        }
                    }
                }

            }
            .padding(24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func openLicense() {
        if let url = Bundle.main.url(forResource: "FontAwesome-LICENSE", withExtension: "txt") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 使用說明

struct HelpPane: View {
    let go: (Pane) -> Void

    private let steps: [(FA, String, String)] = [
        (.shieldHalved, "開啟權限", "到「權限」頁開啟「輔助使用」與「輸入監控」，按鍵與滑鼠效果才會運作。"),
        (.keyboard, "開始上課", "打字、按快捷鍵時，螢幕會自動放大顯示；快捷鍵會顯示成「Command + C 複製」並保留在角落。"),
        (.penNib, "標註與白板", "按 ⌃⌥D 在螢幕上畫圖、⌃⌥W 開白板，上方工具列可直接點選，Esc 離開。"),
        (.powerOff, "一鍵關閉", "任何效果都可以按 ⌃⌥X 一次關閉；聚光燈也能按 Esc 關閉。"),
    ]

    private let features: [(FA, String, String, Pane)] = [
        (.keyboard, "按鍵顯示", "放大顯示打字內容與組合鍵，可調大小、位置、停留時間；支援注音（先注音再中文）。", .keys),
        (.thumbtack, "快捷鍵懸停", "組合鍵堆疊在左上或右上角，可設定保留秒數或一直保留。", .shortcuts),
        (.lock, "隱私保護", "密碼、帳號、學號等欄位只顯示「已隱藏」，關鍵字可自訂。", .keys),
        (.handPointer, "滑鼠效果", "雙擊脈衝、左右鍵提示、長按圓圈，顏色與樣式都能調。", .mouse),
        (.lightbulb, "聚光燈", "周圍變暗、只照亮游標附近，可調大小與暗度。", .spotlight),
        (.chalkboard, "畫圖與白板", "畫筆、螢光筆、箭頭、方框；白板多頁並可存成 PNG。", .draw),
        (.noteSticky, "筆記", "寫講稿或重點，可浮動顯示在畫面最上層。", .notes),
        (.gear, "一般", "語言、明亮／暗黑模式、登入時自動啟動。", .general),
    ]

    private let faq: [(String, String)] = [
        ("按鍵沒有顯示？", "確認「權限」頁兩個權限都已開啟；重新編譯或更新 App 後，可能要在系統設定中先移除再重新加入。"),
        ("輸入密碼會被看到嗎？", "不會。密碼欄位、密碼管理器與（預設）終端機中的按鍵都只會顯示「已隱藏」。"),
        ("注音只顯示注音、沒有中文？", "中文字是從輸入框讀取的，終端機與部分網頁編輯器讀不到，這時只會顯示注音。"),
        ("快捷鍵和其他 App 衝突？", "全域快捷鍵都是 ⌃⌥ 開頭；若無法註冊，代表已被其他 App 佔用。"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    if let icon = FontAwesome.appIcon() {
                        Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("TeachOverlay 使用說明")).font(.title2.bold())
                        Text(L("上課、錄影、直播時，讓觀眾看清楚你在按什麼、點哪裡。"))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L("快速開始")).font(.headline)
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        Card {
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(i + 1)")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(Brand.gradient))
                                VStack(alignment: .leading, spacing: 4) {
                                    IconLabel(icon: step.0, text: L(step.1)).font(.headline)
                                    Text(L(step.2)).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L("功能介紹")).font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(features, id: \.1) { f in
                            Button { go(f.3) } label: {
                                Card {
                                    HStack(alignment: .top, spacing: 12) {
                                        FAIcon(icon: f.0, size: 18).foregroundStyle(Brand.blue).frame(width: 26)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(L(f.1)).font(.headline)
                                            Text(L(f.2)).font(.caption).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 0)
                                        FAIcon(icon: .chevronRight, size: 11).foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L("常見問題")).font(.headline)
                    ForEach(faq, id: \.0) { q, a in
                        Card {
                            VStack(alignment: .leading, spacing: 5) {
                                IconLabel(icon: .circleQuestion, text: L(q)).font(.headline)
                                Text(L(a)).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Card {
                    HStack(spacing: 12) {
                        FAIcon(icon: .github, style: .brands, size: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("更多說明與更新")).font(.headline)
                            Text(AppLinks.repo.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("GitHub 專案頁面")) { NSWorkspace.shared.open(AppLinks.repo) }
                        Button(L("回報問題")) { NSWorkspace.shared.open(AppLinks.issues) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
