// Renders the 1024px app icon PNG.
// Usage: swift make-icon.swift out.png            → built-in icon
//        swift make-icon.swift out.png custom.png → your image, shaped like a macOS icon
import AppKit

if CommandLine.arguments.count > 2 {
    let src = NSImage(contentsOfFile: CommandLine.arguments[2])!
    let srcRep = NSBitmapImageRep(data: src.tiffRepresentation!)!
    // Transparent corner = the image is already icon-shaped; use it as is.
    let alreadyShaped = (srcRep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.1
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current?.imageInterpolation = .high
    if alreadyShaped {
        src.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    } else {
        // Apple's macOS icon grid: an 824px rounded square centered on a 1024px canvas, with a soft shadow.
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        shape.addClip()
        // Fill the tile (crop to square if the image isn't square).
        let s = min(src.size.width, src.size.height)
        let from = NSRect(x: (src.size.width - s) / 2, y: (src.size.height - s) / 2, width: s, height: s)
        src.draw(in: tile, from: from, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    exit(0)
}

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.93, green: 0.95, blue: 1.0, alpha: 1),
                    NSColor(calibratedRed: 0.70, green: 0.76, blue: 0.88, alpha: 1)])!.draw(in: bg, angle: -90)
bg.addClip()

// The black panel hanging from the top edge.
let panel = NSBezierPath(roundedRect: NSRect(x: 170, y: 360, width: 684, height: 700), xRadius: 80, yRadius: 80)
NSColor.black.setFill()
panel.fill()

// Camera dot.
NSColor(white: 0.22, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 497, y: 846, width: 30, height: 30)).fill()

func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ white: CGFloat) {
    NSColor(white: white, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 44), xRadius: 22, yRadius: 22).fill()
}
bar(240, 760, 500, 0.45)
bar(240, 670, 230, 1)
bar(240, 580, 380, 1)

// Orange box around a phrase.
let box = NSBezierPath(roundedRect: NSRect(x: 492, y: 656, width: 300, height: 72), xRadius: 18, yRadius: 18)
NSColor.systemOrange.withAlphaComponent(0.2).setFill()
box.fill()
NSColor.systemOrange.setStroke()
box.lineWidth = 9
box.stroke()
bar(514, 670, 256, 1)

// Speed pill.
NSColor(white: 0.18, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 382, y: 448, width: 260, height: 58), xRadius: 29, yRadius: 29).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 462, y: 456, width: 100, height: 42), xRadius: 21, yRadius: 21).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
