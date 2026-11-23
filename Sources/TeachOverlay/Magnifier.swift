import AppKit
import CoreImage
import ScreenCaptureKit

/// 放大鏡用的即時畫面（ScreenCaptureKit，排除 TeachOverlay 自己的視窗避免重複放大）
final class MagnifierCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "teachoverlay.magnifier")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private(set) var displayID: CGDirectDisplayID = 0

    func start(displayID: CGDirectDisplayID, pixelSize: CGSize, completion: @escaping (Bool) -> Void) {
        stop()
        self.displayID = displayID
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let self, let content,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let me = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = Int(pixelSize.width)
            cfg.height = Int(pixelSize.height)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.showsCursor = false
            cfg.queueDepth = 5
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.stream = s
            s.startCapture { err in DispatchQueue.main.async { completion(err == nil) } }
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        lock.lock(); latest = nil; lock.unlock()
    }

    func latestBuffer() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pb = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        lock.lock(); latest = pb; lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); latest = nil; lock.unlock()
    }
}

/// 放大鏡的鏡片（在疊加層上，跟著游標）
@MainActor
final class LensLayer {
    let container = CALayer()
    private let lens = CALayer()
    private let crosshair = CAShapeLayer()

    init() {
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.35
        container.shadowRadius = 12
        container.shadowOffset = CGSize(width: 0, height: -3)
        container.isHidden = true
        lens.masksToBounds = true
        lens.borderWidth = 4
        lens.borderColor = NSColor.white.cgColor
        lens.backgroundColor = NSColor.black.cgColor
        lens.contentsGravity = .resize
        crosshair.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        crosshair.lineWidth = 1
        container.addSublayer(lens)
        lens.addSublayer(crosshair)
    }

    func setVisible(_ v: Bool) { container.isHidden = !v }

    func update(center: CGPoint, image: CGImage?, size: CGFloat, circle: Bool, accent: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        lens.frame = container.bounds
        lens.cornerRadius = circle ? size / 2 : 20
        lens.borderColor = accent.cgColor
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: lens.cornerRadius,
                                      cornerHeight: lens.cornerRadius, transform: nil)
        if let image { lens.contents = image }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: size / 2 - 8, y: size / 2)); p.addLine(to: CGPoint(x: size / 2 + 8, y: size / 2))
        p.move(to: CGPoint(x: size / 2, y: size / 2 - 8)); p.addLine(to: CGPoint(x: size / 2, y: size / 2 + 8))
        crosshair.frame = lens.bounds
        crosshair.path = p
        CATransaction.commit()
    }
}
