// Draws TabWM's app icon: the menu bar's "rectangle.stack" symbol, white on a Catppuccin
// Mocha squircle with a mauve-to-blue glow, in every size an .icns needs.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: alpha)
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon grid: an 824 pt squircle centred in 1024, leaving room for the shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    hex(0x1e1e2e).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Depth: Mocha crust to base, then a soft mauve/blue glow behind the symbol.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [hex(0x313244), hex(0x11111b)])!.draw(in: tile, angle: -90)
    NSGradient(colors: [hex(0xcba6f7, 0.55), hex(0x89b4fa, 0.0)])!.draw(fromCenter: NSPoint(x: 512, y: 560), radius: 0, toCenter: NSPoint(x: 512, y: 560), radius: 420, options: [])
    // Thin inner highlight along the top edge, like the glass strip.
    hex(0xffffff, 0.10).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182); rim.lineWidth = 6; rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The menu bar symbol, large and white.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [hex(0xcdd6f4)]))
    if let symbol = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let rect = NSRect(x: 512 - size.width / 2, y: 512 - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowColor = hex(0xcba6f7, 0.6); glow.shadowBlurRadius = 40; glow.set()
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(points * scale).write(to: output.appendingPathComponent(name))
}
