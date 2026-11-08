import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Assets/StartupManagerLogo.svg")
let resourceDir = root.appendingPathComponent("Assets")
let iconset = root.appendingPathComponent("Assets/StartupManager.iconset")
try FileManager.default.createDirectory(at: resourceDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
guard let image = NSImage(contentsOf: source) else { fatalError("Cannot load logo SVG at \(source.path)") }

func writePNG(size: Int, path: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Cannot allocate bitmap") }
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current = context
    context?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
    try png.write(to: path)
}

try writePNG(size: 512, path: resourceDir.appendingPathComponent("StartupManagerLogo.png"))
for (base, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try writePNG(size: base, path: iconset.appendingPathComponent("icon_\(suffix).png"))
}
