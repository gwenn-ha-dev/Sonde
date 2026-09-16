import AppKit

// Renders the DMG window background (600×420 pt, @2x for retina).
// Usage: dmg-background <logo.png> <out.png>
// Light palette on purpose: Finder draws icon labels in black in light
// appearance, so a dark background would make them unreadable.

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: dmg-background <logo.png> <out.png>\n".utf8))
    exit(1)
}
let logoPath = args[1], outPath = args[2]

let W: CGFloat = 600, H: CGFloat = 420, scale: CGFloat = 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .calibratedRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
gctx.cgContext.scaleBy(x: scale, y: scale)

// Soft vertical gradient
NSGradient(colors: [NSColor(calibratedRed: 0.925, green: 0.925, blue: 0.935, alpha: 1),
                    NSColor(calibratedRed: 0.975, green: 0.975, blue: 0.98, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

// Thin baseline under the icons area
NSColor(calibratedWhite: 0, alpha: 0.06).setFill()
NSRect(x: 60, y: 118, width: W - 120, height: 1).fill()

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight,
          color: NSColor, centerX: CGFloat, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let sz = s.size()
    s.draw(at: NSPoint(x: centerX - sz.width / 2, y: y))
}

// Header: logo + app name
var titleX = W / 2
if let logo = NSImage(contentsOfFile: logoPath) {
    let side: CGFloat = 30
    let title = "Sonde"
    let titleFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    let titleW = (title as NSString).size(withAttributes: [.font: titleFont]).width
    let total = side + 12 + titleW
    let x0 = (W - total) / 2
    logo.draw(in: NSRect(x: x0, y: 346, width: side, height: side),
              from: .zero, operation: .sourceOver, fraction: 1)
    titleX = x0 + side + 12 + titleW / 2
    draw(title, size: 22, weight: .semibold,
         color: NSColor(calibratedWhite: 0.12, alpha: 1), centerX: titleX, y: 350)
} else {
    draw("Sonde", size: 22, weight: .semibold,
         color: NSColor(calibratedWhite: 0.12, alpha: 1), centerX: W / 2, y: 350)
}
draw("Télécommande de l'amplificateur Abyss / AMP 240 S", size: 12, weight: .regular,
     color: NSColor(calibratedWhite: 0.45, alpha: 1), centerX: W / 2, y: 326)

// Arrow between the two icon slots (icons sit at Finder y≈190 → AppKit y≈230)
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 240, y: 230))
arrow.line(to: NSPoint(x: 356, y: 230))
arrow.move(to: NSPoint(x: 334, y: 252))
arrow.line(to: NSPoint(x: 360, y: 230))
arrow.line(to: NSPoint(x: 334, y: 208))
NSColor(calibratedWhite: 0.55, alpha: 0.9).setStroke()
arrow.stroke()

// Bottom hint
draw("Glissez l'application dans le dossier Applications pour l'installer",
     size: 13, weight: .medium,
     color: NSColor(calibratedWhite: 0.35, alpha: 1), centerX: W / 2, y: 78)
draw("Au premier lancement : clic droit → Ouvrir, puis autoriser l'accès au réseau local",
     size: 11, weight: .regular,
     color: NSColor(calibratedWhite: 0.55, alpha: 1), centerX: W / 2, y: 56)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
try! png.write(to: URL(fileURLWithPath: outPath))
