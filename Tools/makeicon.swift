// 生成 AppIcon.iconset。用位图上下文绘制，不依赖窗口服务器，命令行下也能跑。
// 用法: swift Tools/makeicon.swift <输出目录>
import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let size = CGFloat(pixels)
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let body = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.29, green: 0.44, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.52, green: 0.29, blue: 0.90, alpha: 1),
    ])
    gradient?.draw(in: body, angle: -60)

    // 四角取景框
    let stroke = NSColor(white: 1, alpha: 0.85)
    stroke.setStroke()
    let lineWidth = max(1, size * 0.035)
    let corner = size * 0.14
    let frameRect = rect.insetBy(dx: size * 0.14, dy: size * 0.14)
    let marks = NSBezierPath()
    marks.lineWidth = lineWidth
    marks.lineCapStyle = .round
    for (cx, cy, dx, dy) in [
        (frameRect.minX, frameRect.maxY, 1.0, -1.0),
        (frameRect.maxX, frameRect.maxY, -1.0, -1.0),
        (frameRect.minX, frameRect.minY, 1.0, 1.0),
        (frameRect.maxX, frameRect.minY, -1.0, 1.0),
    ] {
        marks.move(to: NSPoint(x: cx + corner * dx, y: cy))
        marks.line(to: NSPoint(x: cx, y: cy))
        marks.line(to: NSPoint(x: cx, y: cy + corner * dy))
    }
    marks.stroke()

    // 中央「词」
    let font = NSFont.systemFont(ofSize: size * 0.42, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let glyph = NSAttributedString(string: "词", attributes: attributes)
    let glyphSize = glyph.size()
    glyph.draw(at: NSPoint(x: (size - glyphSize.width) / 2, y: (size - glyphSize.height) / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = render(pixels: variant.pixels) else {
        FileHandle.standardError.write("绘制 \(variant.name) 失败\n".data(using: .utf8)!)
        exit(1)
    }
    let path = (outputDir as NSString).appendingPathComponent("\(variant.name).png")
    try? data.write(to: URL(fileURLWithPath: path))
}
print("已生成 \(outputDir)")
