import AppKit

private func curve(_ points: [CGPoint], width: CGFloat, color: NSColor, glow: Bool = false) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for index in 1..<points.count {
        let a = points[index - 1]
        let b = points[index]
        let mid = (a.x + b.x) / 2
        path.curve(to: b, controlPoint1: CGPoint(x: mid, y: a.y), controlPoint2: CGPoint(x: mid, y: b.y))
    }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    if glow {
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = .zero
        shadow.set()
    }
    color.setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

private func renderIcon(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
    let background = NSBezierPath(roundedRect: rect, xRadius: 192, yRadius: 192)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 35
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.04, green: 0.09, blue: 0.17, alpha: 1).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.34, alpha: 1),
                        NSColor(calibratedRed: 0.025, green: 0.065, blue: 0.13, alpha: 1)])?.draw(in: background, angle: -70)

    NSGraphicsContext.saveGraphicsState()
    background.addClip()
    let halo = NSBezierPath(ovalIn: NSRect(x: 100, y: 605, width: 880, height: 620))
    NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.52, blue: 0.60, alpha: 0.13),
               ending: .clear)?.draw(in: halo, relativeCenterPosition: NSPoint(x: -0.2, y: -0.5))
    NSGraphicsContext.restoreGraphicsState()

    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 190, yRadius: 190)
    outline.lineWidth = 3
    NSColor.white.withAlphaComponent(0.12).setStroke()
    outline.stroke()

    // Subtle plot grid and a small pair of legend dots.
    for y in stride(from: 300, through: 700, by: 100) {
        let grid = NSBezierPath()
        grid.move(to: NSPoint(x: 180, y: y))
        grid.line(to: NSPoint(x: 850, y: y))
        grid.lineWidth = 2
        NSColor.white.withAlphaComponent(0.055).setStroke()
        grid.stroke()
    }
    for x in stride(from: 230, through: 830, by: 100) {
        let grid = NSBezierPath()
        grid.move(to: NSPoint(x: x, y: 240))
        grid.line(to: NSPoint(x: x, y: 745))
        grid.lineWidth = 2
        NSColor.white.withAlphaComponent(0.035).setStroke()
        grid.stroke()
    }

    let cyan = NSColor(calibratedRed: 0.25, green: 0.91, blue: 0.86, alpha: 1)
    let blue = NSColor(calibratedRed: 0.29, green: 0.58, blue: 1, alpha: 1)
    let memory: [CGPoint] = [CGPoint(x: 180, y: 328), CGPoint(x: 284, y: 348), CGPoint(x: 372, y: 320),
                             CGPoint(x: 485, y: 385), CGPoint(x: 602, y: 382), CGPoint(x: 719, y: 460),
                             CGPoint(x: 842, y: 433)]
    let frequency: [CGPoint] = [CGPoint(x: 180, y: 479), CGPoint(x: 265, y: 472), CGPoint(x: 334, y: 710),
                                CGPoint(x: 428, y: 402), CGPoint(x: 520, y: 618), CGPoint(x: 619, y: 541),
                                CGPoint(x: 717, y: 679), CGPoint(x: 842, y: 577)]
    curve(memory, width: 22, color: blue, glow: true)
    curve(frequency, width: 25, color: cyan, glow: true)

    for (x, color) in [(CGFloat(196), cyan), (CGFloat(288), blue)] {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 791, width: 24, height: 24)).fill()
    }

    // Highlight each current sample at the right-hand edge.
    for (point, color) in [(memory.last!, blue), (frequency.last!, cyan)] {
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56)).fill()
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon <iconset-directory>\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let filenames: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (name, size) in filenames {
        guard let data = renderIcon(size: size) else { throw NSError(domain: "Icon", code: 1) }
        try data.write(to: output.appendingPathComponent(name))
    }
} catch {
    fputs("Icon generation failed: \(error)\n", stderr)
    exit(1)
}
