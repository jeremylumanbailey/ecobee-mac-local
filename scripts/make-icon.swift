import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let edge = CGFloat(size)
    let frame = NSRect(x: edge * 0.06, y: edge * 0.06, width: edge * 0.88, height: edge * 0.88)
    let shape = NSBezierPath(roundedRect: frame, xRadius: edge * 0.2, yRadius: edge * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.18, green: 0.29, blue: 0.22, alpha: 1), ending: NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.09, alpha: 1))!.draw(in: shape, angle: -60)
    let ring = NSBezierPath(ovalIn: NSRect(x: edge * 0.24, y: edge * 0.24, width: edge * 0.52, height: edge * 0.52))
    ring.lineWidth = edge * 0.018
    NSColor(calibratedRed: 0.58, green: 0.87, blue: 0.71, alpha: 0.45).setStroke(); ring.stroke()
    if let symbol = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: edge * 0.32, weight: .medium)) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor(calibratedRed: 0.65, green: 0.94, blue: 0.78, alpha: 1).setFill()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let ratio = symbol.size.width / symbol.size.height
        let height = edge * 0.35, width = height * ratio
        tinted.draw(in: NSRect(x: (edge-width)/2, y: (edge-height)/2, width: width, height: height))
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if [16, 32, 128, 256, 512].contains(size) { try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size).png")) }
    if [32, 64, 256, 512, 1024].contains(size) { try data.write(to: destination.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
