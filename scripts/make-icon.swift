// Genera l'icona dell'app: swift scripts/make-icon.swift <cartella-di-output>
// Produce AppIcon-1024.png e AppIcon.icns (tramite iconutil).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size: CGFloat = 1024

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / size, y: CGFloat(px) / size)

    // Griglia macOS: forma di 824 pt centrata, raggio 185, ombra leggera.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(red: 0.04, green: 0.10, blue: 0.24, alpha: 1).cgColor,
                                 NSColor(red: 0.05, green: 0.33, blue: 0.62, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Griglia di misura sullo sfondo.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
    ctx.setLineWidth(3)
    for i in stride(from: 100.0, through: 924.0, by: 103.0) {
        ctx.move(to: CGPoint(x: i, y: 100)); ctx.addLine(to: CGPoint(x: i, y: 924))
        ctx.move(to: CGPoint(x: 100, y: i)); ctx.addLine(to: CGPoint(x: 924, y: i))
    }
    ctx.strokePath()

    // Archi Wi-Fi.
    let center = CGPoint(x: 512, y: 330)
    ctx.setLineCap(.round)
    for (i, r) in [150.0, 270.0, 390.0].enumerated() {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(1.0 - Double(i) * 0.18).cgColor)
        ctx.setLineWidth(62)
        ctx.addArc(center: center, radius: r, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        ctx.strokePath()
    }
    // Punto sorgente.
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 46, y: center.y - 46, width: 92, height: 92))

    // Traccia di latenza che attraversa il segnale.
    let trace = CGMutablePath()
    let pts: [(CGFloat, CGFloat)] = [(150, 210), (300, 210), (350, 170), (400, 280), (450, 210), (874, 210)]
    trace.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for p in pts.dropFirst() { trace.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.addPath(trace)
    ctx.setStrokeColor(NSColor(red: 0.30, green: 0.95, blue: 0.55, alpha: 0.9).cgColor)
    ctx.setLineWidth(18); ctx.setLineJoin(.round)
    ctx.strokePath()

    // LED verde di stato attivo.
    let led = CGRect(x: 744, y: 744, width: 90, height: 90)
    ctx.setShadow(offset: .zero, blur: 40, color: NSColor(red: 0.3, green: 1, blue: 0.5, alpha: 1).cgColor)
    ctx.setFillColor(NSColor(red: 0.25, green: 0.92, blue: 0.45, alpha: 1).cgColor)
    ctx.fillEllipse(in: led)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: out.appendingPathComponent("AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
