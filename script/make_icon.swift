import AppKit
import Foundation

let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let c = NSGraphicsContext.current!.cgContext
        c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let bounds = NSRect(x: 54, y: 54, width: 916, height: 916)
        let base = NSBezierPath(roundedRect: bounds, xRadius: 207, yRadius: 207)
        NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.28, blue: 0.68, alpha: 1), ending: NSColor(srgbRed: 0.28, green: 0.53, blue: 0.91, alpha: 1))!.draw(in: base, angle: 65)
        // An original continuous route bends toward a rising destination.
        let route = NSBezierPath(); route.move(to: NSPoint(x: 280, y: 294))
        route.line(to: NSPoint(x: 543, y: 294))
        route.curve(to: NSPoint(x: 710, y: 461), controlPoint1: NSPoint(x: 648, y: 294), controlPoint2: NSPoint(x: 710, y: 356))
        route.line(to: NSPoint(x: 710, y: 710))
        route.lineWidth = 112; route.lineCapStyle = .round; route.lineJoinStyle = .round
        NSColor.white.setStroke(); route.stroke()
        let upper = NSBezierPath(); upper.move(to: NSPoint(x: 300, y: 506)); upper.line(to: NSPoint(x: 300, y: 710))
        upper.lineWidth = 112; upper.lineCapStyle = .round
        NSColor(srgbRed: 0.62, green: 0.84, blue: 1, alpha: 1).setStroke(); upper.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
