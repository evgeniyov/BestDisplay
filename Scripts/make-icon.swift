// Generates Resources/AppIcon.icns. Run: swift Scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.055
    let tile = NSBezierPath(roundedRect: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                            xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.20, blue: 0.45, alpha: 1),
                        NSColor(red: 0.36, green: 0.22, blue: 0.75, alpha: 1)])!.draw(in: tile, angle: -55)

    // Monitor body
    let body = CGRect(x: s * 0.2, y: s * 0.34, width: s * 0.6, height: s * 0.4)
    NSColor(white: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: s * 0.04, yRadius: s * 0.04).fill()
    // Screen with a soft gradient
    let screen = body.insetBy(dx: s * 0.025, dy: s * 0.025)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.02, yRadius: s * 0.02)
    NSGradient(colors: [NSColor(red: 0.30, green: 0.80, blue: 0.95, alpha: 1),
                        NSColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 1)])!.draw(in: screenPath, angle: 35)
    // Stand
    NSColor(white: 0.97, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: s * 0.46, y: s * 0.25, width: s * 0.08, height: s * 0.09)).fill()
    NSBezierPath(roundedRect: CGRect(x: s * 0.35, y: s * 0.22, width: s * 0.30, height: s * 0.04),
                 xRadius: s * 0.02, yRadius: s * 0.02).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(task.terminationStatus)
