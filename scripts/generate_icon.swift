// Generates the 1024x1024 App Store icon: concert stage lights over a deep
// gradient with a music note and waveform. Run:
//   swift scripts/generate_icon.swift <output.png>
import AppKit

let canvas = 1024
guard CommandLine.arguments.count > 1 else {
    fatalError("Usage: swift generate_icon.swift <output.png>")
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

// Opaque CGBitmapContext (alpha skipped) — App Store marketing icons must
// not contain transparency.
guard let ctx = CGContext(
    data: nil,
    width: canvas,
    height: canvas,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("no context") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let size = CGFloat(canvas)

// Background: deep violet-to-midnight vertical gradient.
let bgColors = [
    NSColor(calibratedRed: 0.22, green: 0.07, blue: 0.45, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.22, alpha: 1).cgColor
]
let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: bgColors as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(bgGradient, start: CGPoint(x: size / 2, y: size), end: CGPoint(x: size / 2, y: 0), options: [])

// Stage light beams sweeping down from the top corners.
func beam(fromX: CGFloat, spread: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    let path = CGMutablePath()
    path.move(to: CGPoint(x: fromX, y: size + 20))
    path.addLine(to: CGPoint(x: fromX - spread, y: -40))
    path.addLine(to: CGPoint(x: fromX + spread, y: -40))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: alpha).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}
beam(fromX: size * 0.18, spread: size * 0.28, alpha: 0.07)
beam(fromX: size * 0.50, spread: size * 0.22, alpha: 0.05)
beam(fromX: size * 0.82, spread: size * 0.28, alpha: 0.07)

// Soft radial glow behind the note.
let glowColors = [
    NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.95, alpha: 0.35).cgColor,
    NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.95, alpha: 0.0).cgColor
]
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: size / 2, y: size * 0.58),
    startRadius: 0,
    endCenter: CGPoint(x: size / 2, y: size * 0.58),
    endRadius: size * 0.42,
    options: []
)

// Waveform bars across the lower third (like audio levels).
let barCount = 13
let barAreaWidth = size * 0.72
let barSpacing = barAreaWidth / CGFloat(barCount)
let barWidth = barSpacing * 0.45
let baselineY = size * 0.175
let heights: [CGFloat] = [0.30, 0.52, 0.40, 0.72, 0.55, 0.95, 0.65, 0.95, 0.55, 0.72, 0.40, 0.52, 0.30]
for index in 0..<barCount {
    let barHeight = heights[index] * size * 0.135
    let x = (size - barAreaWidth) / 2 + CGFloat(index) * barSpacing + (barSpacing - barWidth) / 2
    let barRect = CGRect(x: x, y: baselineY, width: barWidth, height: barHeight)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    ctx.addPath(barPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.85, green: 0.75, blue: 1.0, alpha: 0.9).cgColor)
    ctx.fillPath()
}

// Music note glyph, centered and large.
let noteFont = NSFont.systemFont(ofSize: size * 0.46, weight: .semibold)
let noteAttributes: [NSAttributedString.Key: Any] = [
    .font: noteFont,
    .foregroundColor: NSColor.white
]
let note = NSAttributedString(string: "\u{266B}", attributes: noteAttributes)
let noteSize = note.size()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 46, color: NSColor(calibratedWhite: 0, alpha: 0.5).cgColor)
note.draw(at: NSPoint(x: (size - noteSize.width) / 2, y: size * 0.40))
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let cgImage = ctx.makeImage() else { fatalError("image failed") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
try! png.write(to: outputURL)
print("Wrote \(outputURL.path)")
