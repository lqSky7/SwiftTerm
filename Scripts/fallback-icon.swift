// Draws a flat 1024px PNG of the app icon (dark gradient + the package's SVG layer) for machines
// without Xcode's `actool`. Usage: swift fallback-icon.swift <icon.svg> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("cannot load svg\n".utf8)); exit(1)
}
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let full = NSRect(x: 0, y: 0, width: size, height: size)
let tile = full.insetBy(dx: 100, dy: 100)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
path.addClip()
NSGradient(starting: NSColor(red: 0.02, green: 0.005, blue: 0.005, alpha: 1),
           ending: NSColor(red: 0.04, green: 0.015, blue: 0.02, alpha: 1))!.draw(in: tile, angle: -90)
let inner = tile.insetBy(dx: 120, dy: 120)
let s = min(inner.width / svg.size.width, inner.height / svg.size.height)
let w = svg.size.width * s, h = svg.size.height * s
svg.draw(in: NSRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
