// 把 Logo（白底）做成 macOS App 圖示：去白邊 → 圓角遮罩 → 1024 畫布（824 內容 + 陰影）→ .icns
// 用法：swift tools/make-icon.swift <logo 圖檔> Resources [背景差異門檻，預設 60]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let src = NSImage(contentsOfFile: args[1]),
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
// 背景色取四個角落的平均（白底或淺色漸層底都適用）
func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * w + x) * 4
    return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
}
let corners = [pixel(4, 4), pixel(w - 5, 4), pixel(4, h - 5), pixel(w - 5, h - 5)]
let bg = (corners.map(\.0).reduce(0, +) / 4, corners.map(\.1).reduce(0, +) / 4, corners.map(\.2).reduce(0, +) / 4)
let threshold = Int(CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 60 : 60)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in stride(from: 0, to: h, by: 1) {
    for x in stride(from: 0, to: w, by: 1) {
        let (r, g, b) = pixel(x, y)
        let diff = abs(r - bg.0) + abs(g - bg.1) + abs(b - bg.2)
        if diff > threshold {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
// 稍微內縮避免殘留白邊抗鋸齒
let inset = 4
var bw = maxX - minX - inset * 2, bh = maxY - minY - inset * 2
// App 圖示是正方形：高度比寬度多出來的通常是底下的陰影，保留上緣、裁成正方形
if bh > bw { bh = bw }
if bw > bh { let extra = bw - bh; minX += extra / 2; bw = bh }
let box = CGRect(x: minX + inset, y: minY + inset, width: bw, height: bh)
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
