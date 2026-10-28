// Zeichnet das App-Icon und legt ein .iconset an.
// Aufruf: ./build.sh --icon
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Ein Foto-Abzug mit weißem Rand, um seinen Mittelpunkt gedreht.
func drawPhoto(center: NSPoint, size: NSSize, angle: CGFloat, scale s: CGFloat, sky: (UInt32, UInt32), dimmed: Bool) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: angle)
    transform.concat()

    let frame = NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: frame, xRadius: 18 * s, yRadius: 18 * s).fill()
    NSGraphicsContext.restoreGraphicsState()

    let picture = frame.insetBy(dx: 22 * s, dy: 22 * s)
    let clip = NSBezierPath(roundedRect: picture, xRadius: 8 * s, yRadius: 8 * s)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    NSGradient(starting: color(sky.0), ending: color(sky.1))!.draw(in: picture, angle: -90)
    // Sonne
    color(0xFFD45C).setFill()
    NSBezierPath(ovalIn: NSRect(x: picture.maxX - picture.width * 0.32, y: picture.maxY - picture.height * 0.36,
                                width: picture.width * 0.18, height: picture.width * 0.18)).fill()
    // Berge
    let back = NSBezierPath()
    back.move(to: NSPoint(x: picture.minX, y: picture.minY + picture.height * 0.25))
    back.line(to: NSPoint(x: picture.minX + picture.width * 0.35, y: picture.minY + picture.height * 0.68))
    back.line(to: NSPoint(x: picture.minX + picture.width * 0.62, y: picture.minY + picture.height * 0.36))
    back.line(to: NSPoint(x: picture.maxX, y: picture.minY + picture.height * 0.55))
    back.line(to: NSPoint(x: picture.maxX, y: picture.minY))
    back.line(to: NSPoint(x: picture.minX, y: picture.minY))
    back.close()
    color(0x2E8B57).setFill()
    back.fill()
    let front = NSBezierPath()
    front.move(to: NSPoint(x: picture.minX, y: picture.minY + picture.height * 0.12))
    front.line(to: NSPoint(x: picture.minX + picture.width * 0.55, y: picture.minY + picture.height * 0.45))
    front.line(to: NSPoint(x: picture.maxX, y: picture.minY + picture.height * 0.18))
    front.line(to: NSPoint(x: picture.maxX, y: picture.minY))
    front.line(to: NSPoint(x: picture.minX, y: picture.minY))
    front.close()
    color(0x1F6E45).setFill()
    front.fill()
    if dimmed {
        NSColor.white.withAlphaComponent(0.35).setFill()
        picture.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = CGFloat(pixels) / 1024
    // Grundform nach Apples Icon-Raster: 824 × 824 mit 100 px Rand.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSGradient(starting: color(0x4FA3FF), ending: color(0x5B3FD6))!.draw(in: tilePath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let photoSize = NSSize(width: 440 * s, height: 360 * s)
    drawPhoto(center: NSPoint(x: 440 * s, y: 560 * s), size: photoSize, angle: 10, scale: s, sky: (0x9BD4FF, 0xD9F0FF), dimmed: true)
    drawPhoto(center: NSPoint(x: 580 * s, y: 450 * s), size: photoSize, angle: -6, scale: s, sky: (0x7CC4FF, 0xCFEAFF), dimmed: false)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    try render(pixels: entry.pixels).write(to: output.appendingPathComponent("\(entry.name).png"))
}
print("Icon-Set geschrieben: \(output.path)")
