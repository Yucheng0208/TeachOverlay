import AppKit
import SwiftUI

/// macOS 風格的紅色關閉鈕（放在視窗左上角）
struct MacCloseButton: View {
    var size: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.55))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("關閉"))
    }
}

extension View {
    /// 把關閉鈕固定在視窗左上角（與 macOS 紅點位置相同：距上緣 9pt、左緣 10pt）
    func macCloseButton(size: CGFloat = 13, action: @escaping () -> Void) -> some View {
        overlay(alignment: .topLeading) {
            MacCloseButton(size: size, action: action)
                .padding(.top, 9)
                .padding(.leading, 10)
        }
    }
}

/// 全螢幕畫面用：移動滑鼠時才在左上角出現，幾秒後自動隱藏
final class CornerCloseButton: NSView {
    var onClick: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        alphaValue = 0
        toolTip = nil
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        NSColor(calibratedRed: 1.0, green: 0.37, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.black.withAlphaComponent(0.2).setStroke()
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = 0.5
        ring.stroke()
        let x = NSBezierPath()
        let k = r.width * 0.28
        x.move(to: CGPoint(x: r.midX - k, y: r.midY - k)); x.line(to: CGPoint(x: r.midX + k, y: r.midY + k))
        x.move(to: CGPoint(x: r.midX - k, y: r.midY + k)); x.line(to: CGPoint(x: r.midX + k, y: r.midY - k))
        x.lineWidth = 2.2
        x.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.55).setStroke()
        x.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard alphaValue > 0.1 else { return }
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reveal() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self?.animator().alphaValue = 0
            }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    /// 放進全螢幕視窗：內容在下、關閉鈕在左上
    static func install(in window: NSWindow, content: NSView, onClose: @escaping () -> Void) -> CornerCloseButton {
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        let button = CornerCloseButton()
        button.onClick = onClose
        button.frame.origin = CGPoint(x: 14, y: container.bounds.height - 44)
        button.autoresizingMask = [.maxXMargin, .minYMargin]
        container.addSubview(button)
        window.contentView = container
        window.acceptsMouseMovedEvents = true
        return button
    }
}
