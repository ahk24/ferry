// Draws Ferry's app icon and writes an .iconset folder; build-app.sh turns it into AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the rounded square sits inside a ~10% margin.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.05, green: 0.55, blue: 0.62, alpha: 1),
                        NSColor(red: 0.13, green: 0.32, blue: 0.78, alpha: 1)])!
        .draw(in: shape, angle: -60)

    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let r = NSRect(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2,
                       width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: r)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
