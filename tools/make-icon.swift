// 把 Logo（白底）做成 macOS App 圖示：去白邊 → 圓角遮罩 → 1024 畫布（824 內容 + 陰影）→ .icns
// 用法：swift tools/make-icon.swift Resources/Logo/logo-source.webp Resources
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("用法：make-icon <logo> <輸出資料夾>"); exit(1)
}
let outDir = URL(fileURLWithPath: args[2])

// 1. 找出非白色區域（logo 本體）
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
        if r < 225 || g < 225 || b < 240 {   // 藍紫色本體
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
// 稍微內縮避免殘留白邊抗鋸齒
let inset = 4
let box = CGRect(x: minX + inset, y: minY + inset, width: maxX - minX - inset * 2, height: maxY - minY - inset * 2)
print("logo 範圍：\(box)")
let flippedBox = CGRect(x: box.minX, y: CGFloat(h) - box.maxY, width: box.width, height: box.height)
let cropped = cg.cropping(to: flippedBox.integral) ?? cg

// 2. 依 macOS 圖示格線繪製（1024 畫布、824 圓角方塊、陰影）
func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.interpolationQuality = .high
    let content = s * 824 / 1024
    let origin = (s - content) / 2
    let rect = CGRect(x: origin, y: origin - s * 0.008, width: content, height: content)
    let path = CGPath(roundedRect: rect, cornerWidth: content * 0.225, cornerHeight: content * 0.225, transform: nil)
    // 陰影
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025,
                color: NSColor.black.withAlphaComponent(0.3).cgColor)
    c.addPath(path); c.setFillColor(NSColor.black.cgColor); c.fillPath()
    c.restoreGState()
    // 內容（放大一點點讓原圖圓角被遮罩切掉）
    c.saveGState()
    c.addPath(path); c.clip()
    let bleed = content * 0.02
    c.draw(cropped, in: rect.insetBy(dx: -bleed, dy: -bleed))
    c.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: outDir.appendingPathComponent("AppIcon.png"))
print("完成：\(iconset.path)")
