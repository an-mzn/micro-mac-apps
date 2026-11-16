import AppKit
import ImageIO
import UniformTypeIdentifiers

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in sizes {
    let pixels = points * scale
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Could not create icon") }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880), cornerWidth: 200, cornerHeight: 200, transform: nil))
    context.fillPath()
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(56)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 300, y: 708))
    context.addLine(to: CGPoint(x: 300, y: 420))
    context.addCurve(to: CGPoint(x: 420, y: 300), control1: CGPoint(x: 300, y: 354), control2: CGPoint(x: 354, y: 300))
    context.addLine(to: CGPoint(x: 708, y: 300))
    context.strokePath()
    guard let image = context.makeImage() else { fatalError("Could not render icon") }
    let suffix = scale == 2 ? "@2x" : ""
    let file = destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    guard let writer = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Could not write icon") }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { fatalError("Could not save icon") }
}
