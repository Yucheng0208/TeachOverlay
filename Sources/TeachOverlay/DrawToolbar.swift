import SwiftUI

extension DrawTool {
    var fa: FA {
        switch self {
        case .pen: .pen
        case .highlighter: .highlighter
        case .line: .slash
        case .arrow: .arrowRight
        case .rect: .square
        case .ellipse: .circle
        case .compass: .compassDrafting
        }
    }
    var faStyle: FAStyle { self == .rect || self == .ellipse ? .regular : .solid }
}

/// 工具列排成幾排（依螢幕寬度由 OverlayController 決定）
@MainActor
final class ToolbarLayout: ObservableObject {
    @Published var rows = 1
}

/// 畫圖／白板模式時浮在螢幕上方的工具列
struct DrawToolbar: View {
    @ObservedObject var controller: OverlayController
    @ObservedObject var draw: DrawSettings
    @ObservedObject var loc: Loc = .shared
    @ObservedObject var bell: BellScheduler = .shared
    @ObservedObject var layout: ToolbarLayout
    let canvas: () -> CanvasView?

    var body: some View {
        let _ = controller.revision
        Group {
            switch layout.rows {
            case 1:
                HStack(spacing: 6) { header; tools; colors; widths; actions }
            case 2:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { header; tools; colors; widths }
                    HStack(spacing: 6) { actions }
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { header; tools }
                    HStack(spacing: 6) { colors; widths }
                    HStack(spacing: 6) { actions }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(Color(nsColor: theme.text))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: theme.background))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(nsColor: theme.border)))
                .shadow(color: .black.opacity(theme.dark ? 0 : 0.15), radius: 8, y: 2)
        )
        .environment(\.colorScheme, theme.dark ? .dark : .light)
        .fixedSize()
    }

    @ViewBuilder private var header: some View {
        MacCloseButton(size: 14) { controller.exitDraw() }
            .help(L("離開") + "（Esc）")
            .padding(.trailing, 6)
        HStack(spacing: 6) {
            FAIcon(icon: controller.whiteboardOn ? .chalkboard : .penNib, size: 14)
            Text(controller.whiteboardOn ? L("白板") : L("標註")).font(.system(size: 13, weight: .bold))
        }
        .padding(.trailing, 4)
    }

    @ViewBuilder private var tools: some View {
        sep
        ForEach(DrawTool.allCases, id: \.self) { t in
            ToolButton(icon: t.fa, style: t.faStyle, help: "\(L(t.rawValue))（\(t.key)）", selected: draw.tool == t) {
                draw.tool = t
            }
        }
        ToolButton(icon: .ruler, help: L("尺") + "（U）", selected: canvas()?.ruler != nil) {
            canvas()?.toggleRuler()
        }
    }

    @ViewBuilder private var colors: some View {
        if layout.rows < 3 { sep }
        ForEach(DrawSettings.palette.indices, id: \.self) { i in
            Button { draw.colorIndex = i } label: {
                Circle()
                    .fill(Color(nsColor: DrawSettings.palette[i].color))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(draw.colorIndex == i ? Color.accentColor : Color(nsColor: theme.border),
                                             lineWidth: draw.colorIndex == i ? 3 : 1))
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(L(DrawSettings.palette[i].name))（\(i + 1)）")
        }
    }

    @ViewBuilder private var widths: some View {
        sep
        ToolButton(icon: .minus, help: L("變細") + "（-）") { draw.width = max(draw.width - 2, 2) }
        Text("\(Int(draw.width))").font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 22)
        ToolButton(icon: .plus, help: L("變粗") + "（=）") { draw.width = min(draw.width + 2, 40) }
    }

    @ViewBuilder private var actions: some View {
        if layout.rows == 1 { sep }
        ToolButton(icon: .rotateLeft, help: L("復原") + "（⌘Z）") { canvas()?.undo() }
        ToolButton(icon: .trashCan, help: L("清除") + "（C）") { canvas()?.clear() }

        if controller.whiteboardOn {
            sep
            Menu {
                ForEach(BoardStyle.allCases, id: \.self) { style in
                    Button(style.name) { controller.boardStyle = style }
                }
            } label: {
                FAIcon(icon: .palette, size: 15)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .help(L("背景") + "：\(controller.boardStyle.name)（B）")

            ToolButton(icon: .chevronLeft, help: L("上一頁") + "（←）") { canvas()?.goToPage(-1) }
            Text(canvas()?.pageLabel ?? "").font(.system(size: 12, weight: .medium).monospacedDigit())
            ToolButton(icon: .chevronRight, help: L("下一頁") + "（→）") { canvas()?.goToPage(1) }
            ToolButton(icon: .fileCirclePlus, help: L("新增一頁") + "（N）") { canvas()?.newPage() }
            ToolButton(icon: .floppyDisk, help: L("存成 PNG 到桌面") + "（⌘S）") { controller.saveWhiteboard(canvas()) }
            ToolButton(icon: .copy, help: L("拷貝圖片") + "（⌘C）") { controller.copyWhiteboard(canvas()) }
        }

        sep
        ToolButton(icon: .camera, help: L("截圖並標註") + "（⌃⌥P）") { controller.captureScreenshot(.selection) }
        if bell.showCountdownInToolbar, let left = bell.endCountdownText {
            sep
            HStack(spacing: 5) {
                FAIcon(icon: .bell, size: 12)
                Text(L("距離下課")).font(.system(size: 11, weight: .medium)).opacity(0.75)
                Text(left).font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(bell.secondsToNextEnd <= 300 ? Color.red : Color(nsColor: theme.text))
            }
            .help(bell.nextEnd.map { "\($0.label) \($0.timeText)" } ?? "")
            .padding(.horizontal, 2)
        }
        ToolButton(icon: controller.whiteboardOn ? .display : .chalkboard,
                   help: (controller.whiteboardOn ? L("回到螢幕標註") : L("切換到白板")) + "（W）") {
            controller.switchDrawMode()
        }
    }

    private var theme: OverlayTheme { controller.overlayTheme }

    private var sep: some View {
        Rectangle().fill(Color(nsColor: theme.border)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }
}

struct ToolButton: View {
    let icon: FA
    var style: FAStyle = .solid
    var help: String = ""
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FAIcon(icon: icon, style: style, size: 15)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
