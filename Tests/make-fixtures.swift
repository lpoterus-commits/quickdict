// 用法: swift render.swift <out.png> <宽度> <charWrap:0|1> <文字>
import AppKit
let out = CommandLine.arguments[1]
let width = Int(CommandLine.arguments[2])!
let charWrap = CommandLine.arguments[3] == "1"
let text = CommandLine.arguments[4]

let font = NSFont.systemFont(ofSize: 28)
let style = NSMutableParagraphStyle()
style.lineBreakMode = charWrap ? .byCharWrapping : .byWordWrapping
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style]
let str = NSAttributedString(string: text, attributes: attrs)
let bounds = str.boundingRect(with: NSSize(width: CGFloat(width) - 40, height: 10000), options: [.usesLineFragmentOrigin])
let h = Int(bounds.height) + 40
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: h, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: h).fill()
str.draw(with: NSRect(x: 20, y: 20, width: CGFloat(width) - 40, height: CGFloat(h) - 40), options: [.usesLineFragmentOrigin])
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
