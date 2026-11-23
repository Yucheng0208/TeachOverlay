import AppKit
import Carbon
import CoreImage
import ScreenCaptureKit

enum ScreenshotMode { case selection, window, screen }

/// 截圖標註、放大鏡、鐘聲橫幅
extension OverlayController {

    // MARK: 截圖後標註

    func captureScreenshot(_ mode: ScreenshotMode) {
        guard Permissions.screenRecordingGranted else {
            Permissions.requestScreenRecording()
            flash(L("請先開啟「螢幕錄製」權限"))
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("teachoverlay-\(UUID().uuidString).png")
        var args = ["-x"]
        switch mode {
        case .selection: args += ["-i", "-s"]
        case .window: args += ["-i", "-W"]
        case .screen:
            let screen = overlayUnderMouse?.screen ?? NSScreen.main
            if let f = screen?.frame, let primary = NSScreen.screens.first?.frame {
                args += ["-R", "\(Int(f.minX)),\(Int(primary.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))"]
            }
        }
        args.append(url.path)
        // 先隱藏疊加層，避免截到工具列與標註
        overlays.forEach { $0.orderOut(nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishCapture(url) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            do { try p.run() } catch {
                MainActor.assumeIsolated { self.finishCapture(url) }
            }
        }
    }

    private func finishCapture(_ url: URL) {
        overlays.forEach { $0.orderFrontRegardless() }
        guard let image = NSImage(contentsOf: url) else { return }   // 使用者按 Esc 取消
        try? FileManager.default.removeItem(at: url)
        enterDraw(whiteboard: true)
        overlayUnderMouse?.overlayView.canvas.addImagePage(image)
        flash(L("截圖已放到白板，可以直接標註"))
    }

    // MARK: 放大鏡

    func toggleMagnifier() {
        if magnifierOn {
            magnifierOn = false
            magnifierTimer?.invalidate()
            magnifierTimer = nil
            magnifierCapture.stop()
            magnifierHotkeys.forEach { HotKeyCenter.shared.unregister($0) }
            magnifierHotkeys = []
            overlays.forEach { $0.overlayView.effects.lens.setVisible(false) }
            return
        }
        guard Permissions.screenRecordingGranted else {
            Permissions.requestScreenRecording()
            flash(L("請先開啟「螢幕錄製」權限"))
            return
        }
        magnifierOn = true
        startMagnifierStream()
        let hk = HotKeyCenter.shared
        magnifierHotkeys = [
            hk.register(keyCode: kVK_ANSI_Equal, modifiers: Self.hotkeyMods) { [weak self] in
                guard let self else { return }
                self.magnifierZoom = min(self.magnifierZoom + 0.5, 8)
            },
            hk.register(keyCode: kVK_ANSI_Minus, modifiers: Self.hotkeyMods) { [weak self] in
                guard let self else { return }
                self.magnifierZoom = max(self.magnifierZoom - 0.5, 1.5)
            },
        ]
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMagnifier() }
        }
        RunLoop.main.add(t, forMode: .common)
        magnifierTimer = t
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
    }

    private func startMagnifierStream() {
        guard let screen = overlayUnderMouse?.screen ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let size = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        magnifierCapture.start(displayID: displayID(of: screen), pixelSize: size) { [weak self] ok in
            MainActor.assumeIsolated {
                if !ok, self?.magnifierOn == true {
                    self?.flash(L("放大鏡無法啟動，請確認「螢幕錄製」權限"))
                    self?.toggleMagnifier()
                }
            }
        }
    }

    private func updateMagnifier() {
        guard magnifierOn else { return }
        let g = NSEvent.mouseLocation
        guard let w = overlay(at: g), let screen = w.screen else { return }
        // 換螢幕時改擷取那個螢幕
        if displayID(of: screen) != magnifierCapture.displayID {
            overlays.forEach { $0.overlayView.effects.lens.setVisible(false) }
            startMagnifierStream()
            return
        }
        let size = CGFloat(magnifierSize)
        let local = w.toLocal(g)
        var image: CGImage?
        if let pb = magnifierCapture.latestBuffer() {
            let scale = screen.backingScaleFactor
            let region = size / CGFloat(magnifierZoom)
            let rect = CGRect(x: (local.x - region / 2) * scale, y: (local.y - region / 2) * scale,
                              width: region * scale, height: region * scale)
            let ci = CIImage(cvPixelBuffer: pb).clampedToExtent()
            image = ciContext.createCGImage(ci, from: rect)
        }
        for o in overlays {
            let lens = o.overlayView.effects.lens
            if o === w {
                lens.setVisible(true)
                lens.update(center: local, image: image, size: size, circle: magnifierCircle, accent: .white)
            } else {
                lens.setVisible(false)
            }
        }
    }

    // MARK: 鐘聲橫幅

    func showBellBanner(_ e: BellEntry) {
        let title = e.kind == .end ? L("下課時間到") : L("上課時間到")
        let text = "\(title)  \(e.timeText)  \(e.label)"
        for w in overlays { w.overlayView.hud.show(text, duration: 6) }
    }
}
