import AppKit

// Reproducible vector artwork: three windows separated diagonally.
let destination = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(calibratedRed: 0.11, green: 0.32, blue: 0.88, alpha: 1),
           ending: NSColor(calibratedRed: 0.15, green: 0.67, blue: 0.92, alpha: 1))!
    .draw(in: background, angle: 65)
for (index, rect) in [NSRect(x: 188, y: 400, width: 510, height: 360),
                      NSRect(x: 258, y: 322, width: 510, height: 360),
                      NSRect(x: 328, y: 244, width: 510, height: 360)].enumerated() {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.05, alpha: 0.25)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(calibratedWhite: 1, alpha: index == 2 ? 1 : 0.8).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(calibratedRed: 0.13, green: 0.39, blue: 0.74, alpha: 0.22).setFill()
    NSBezierPath(rect: NSRect(x: rect.minX + 22, y: rect.maxY - 75, width: rect.width - 44, height: 3)).fill()
    for dot in 0..<3 {
        NSColor(calibratedRed: 0.16, green: 0.46, blue: 0.8, alpha: 0.65).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 30 + CGFloat(dot * 28), y: rect.maxY - 48, width: 14, height: 14)).fill()
    }
    if index == 2 {
        NSColor(calibratedRed: 0.2, green: 0.55, blue: 0.88, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 30, y: rect.minY + 30, width: 110, height: 218), xRadius: 12, yRadius: 12).fill()
        for line in 0..<3 {
            NSColor(calibratedRed: 0.2, green: 0.55, blue: 0.88, alpha: line == 0 ? 0.45 : 0.18).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 166, y: rect.maxY - 135 - CGFloat(line * 48), width: line == 0 ? 230 : 280, height: 18), xRadius: 9, yRadius: 9).fill()
        }
    }
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
