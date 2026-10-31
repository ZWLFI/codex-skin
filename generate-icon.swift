// Reproducible vector artwork. Run: swift generate-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = root.appendingPathComponent("dist/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    color(0x111D31).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x243B59), ending: color(0x0E1526))!.draw(in: tile, angle: -65)
    tile.lineWidth = 2
    NSColor.white.withAlphaComponent(0.16).setStroke()
    tile.stroke()
    // Offset window silhouettes make the skin/layer metaphor readable at small sizes.
    let back = NSBezierPath(roundedRect: NSRect(x: 210, y: 230, width: 520, height: 470), xRadius: 66, yRadius: 66)
    NSGradient(starting: color(0x38DCC8), ending: color(0x2184AD))!.draw(in: back, angle: -80)
    let front = NSBezierPath(roundedRect: NSRect(x: 300, y: 330, width: 520, height: 470), xRadius: 66, yRadius: 66)
    NSGraphicsContext.saveGraphicsState()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x5B7CF3).setFill()
    front.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x8CA9FF), ending: color(0x4160DB))!.draw(in: front, angle: -70)
    front.lineWidth = 3
    NSColor.white.withAlphaComponent(0.5).setStroke()
    front.stroke()
    let inset = NSBezierPath(roundedRect: NSRect(x: 340, y: 370, width: 440, height: 334), xRadius: 32, yRadius: 32)
    NSColor.white.withAlphaComponent(0.14).setFill()
    inset.fill()
    for x in [353, 391, 429] {
        NSColor.white.withAlphaComponent(0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 742, width: 16, height: 16)).fill()
    }
    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: 580, y: 633))
    spark.curve(to: NSPoint(x: 660, y: 545), controlPoint1: NSPoint(x: 595, y: 568), controlPoint2: NSPoint(x: 608, y: 558))
    spark.curve(to: NSPoint(x: 580, y: 457), controlPoint1: NSPoint(x: 608, y: 532), controlPoint2: NSPoint(x: 595, y: 522))
    spark.curve(to: NSPoint(x: 500, y: 545), controlPoint1: NSPoint(x: 565, y: 522), controlPoint2: NSPoint(x: 552, y: 532))
    spark.curve(to: NSPoint(x: 580, y: 633), controlPoint1: NSPoint(x: 552, y: 558), controlPoint2: NSPoint(x: 565, y: 568))
    spark.close()
    NSColor.white.withAlphaComponent(0.95).setFill()
    spark.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        try render(size * multiplier).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try render(1024).write(to: root.appendingPathComponent("assets/CodexSkin-AppIcon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
precondition(task.terminationStatus == 0, "iconutil failed")
print("App icon generated: 16–1024 px")
