import CoreImage; import AppKit; import Foundation
let payload = CommandLine.arguments[2]
let f = CIFilter(name: "CIQRCodeGenerator")!
f.setValue(payload.data(using: .utf8), forKey: "inputMessage")
f.setValue("M", forKey: "inputCorrectionLevel")
let img = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
let cg = CIContext().createCGImage(img, from: img.extent)!
let rep = NSBitmapImageRep(cgImage: cg)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
