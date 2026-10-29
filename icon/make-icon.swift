// Draws the NetLens app icon to icon/icon.png (1024×1024).
// Run from the project folder: swift icon/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSGradient(colors: [NSColor(red: 0.07, green: 0.16, blue: 0.24, alpha: 1),
                        NSColor(red: 0.02, green: 0.05, blue: 0.09, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185), angle: -90)

    // A small network: nodes joined by links.
    let nodes: [NSPoint] = [NSPoint(x: 300, y: 690), NSPoint(x: 470, y: 760), NSPoint(x: 650, y: 700),
                            NSPoint(x: 330, y: 470), NSPoint(x: 560, y: 520), NSPoint(x: 720, y: 430)]
    let links = [(0, 1), (1, 2), (0, 3), (1, 4), (2, 4), (3, 4), (4, 5), (2, 5)]
    NSColor(red: 0.35, green: 0.80, blue: 1.0, alpha: 0.45).setStroke()
    for (a, b) in links {
        let path = NSBezierPath()
        path.move(to: nodes[a])
        path.line(to: nodes[b])
        path.lineWidth = 14
        path.stroke()
    }
    for (index, node) in nodes.enumerated() {
        (index == 4 ? NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1) : NSColor(red: 0.40, green: 0.85, blue: 1.0, alpha: 1)).setFill()
        let radius: CGFloat = index == 4 ? 38 : 28
        NSBezierPath(ovalIn: NSRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2)).fill()
    }

    // Magnifying lens over the highlighted node.
    let center = NSPoint(x: 560, y: 520)
    let lens = NSBezierPath(ovalIn: NSRect(x: center.x - 150, y: center.y - 150, width: 300, height: 300))
    NSColor(white: 1, alpha: 0.10).setFill()
    lens.fill()
    lens.lineWidth = 34
    NSColor.white.setStroke()
    lens.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: center.x + 108, y: center.y - 108))
    handle.line(to: NSPoint(x: center.x + 250, y: center.y - 250))
    handle.lineWidth = 58
    handle.lineCapStyle = .round
    handle.stroke()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon/icon.png"))
print("Wrote icon/icon.png")
