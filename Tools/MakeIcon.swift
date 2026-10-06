import AppKit
import Foundation

let logoURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let logo = NSImage(contentsOf: logoURL) else { fatalError("Logo could not load") }
let dimensions: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, pixels) in dimensions {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
        let graphics = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Bitmap allocation failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSColor(srgbRed: 0.955, green: 0.962, blue: 0.973, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: size * 0.07, y: size * 0.07, width: size * 0.86, height: size * 0.86),
                 xRadius: size * 0.2, yRadius: size * 0.2).fill()
    var proposed = CGRect(x: 0, y: 0, width: size * 0.42, height: size * 0.51)
    if let cg = logo.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
        let cgContext = graphics.cgContext
        let rect = CGRect(x: size * 0.29, y: size * 0.23, width: size * 0.42, height: size * 0.51)
        cgContext.clip(to: rect, mask: cg)
        let colors = [NSColor(white: 0.80, alpha: 1).cgColor,
                      NSColor(white: 0.47, alpha: 1).cgColor,
                      NSColor(white: 0.73, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                  locations: [0, 0.55, 1])!
        cgContext.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
