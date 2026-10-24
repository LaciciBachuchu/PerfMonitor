// Renders the app icon into an .iconset directory: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Squircle body (macOS grid: 824pt body inside 1024 canvas).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.06, green: 0.09, blue: 0.20, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.22, blue: 0.38, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Gauge arc: green → yellow → red.
    let center = CGPoint(x: 512, y: 430)
    let radius: CGFloat = 270
    let start = CGFloat.pi * 1.15, end = -CGFloat.pi * 0.15
    let steps = 60
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let a0 = start + (end - start) * t, a1 = start + (end - start) * (t + 1.0 / CGFloat(steps)) + 0.01
        let color = t < 0.5
            ? NSColor(red: 0.20 + 1.4 * t, green: 0.85, blue: 0.45 - 0.6 * t, alpha: 1)
            : NSColor(red: 0.95, green: 0.85 - 1.3 * (t - 0.5), blue: 0.15, alpha: 1)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(64)
        ctx.setLineCap(i == 0 || i == steps - 1 ? .round : .butt)
        ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
        ctx.strokePath()
    }

    // Needle.
    let angle = start + (end - start) * 0.68
    let tip = CGPoint(x: center.x + cos(angle) * 230, y: center.y + sin(angle) * 230)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.move(to: center); ctx.addLine(to: tip); ctx.strokePath()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88))

    // Bolt.
    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: 540, y: 330))
    bolt.addLine(to: CGPoint(x: 450, y: 200))
    bolt.addLine(to: CGPoint(x: 515, y: 200))
    bolt.addLine(to: CGPoint(x: 480, y: 110 + 30))
    bolt.addLine(to: CGPoint(x: 590, y: 255))
    bolt.addLine(to: CGPoint(x: 525, y: 255))
    bolt.closeSubpath()
    ctx.addPath(bolt)
    ctx.setFillColor(NSColor(red: 1.0, green: 0.82, blue: 0.2, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
