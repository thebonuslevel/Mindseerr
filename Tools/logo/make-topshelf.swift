// Draws the tvOS Top Shelf banner: black-to-violet backdrop, drifting bubbles, the wordmark, and the mark.
// Usage: swift make-topshelf.swift <mark.png> <out.png> <width> <height> <scale>
//   Standard: 1920×720, wide: 2320×720 (points); scale 1 or 2.
import AppKit

let a = CommandLine.arguments
let mark = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let W = CGFloat(Double(a[3])!), H = CGFloat(Double(a[4])!), S = CGFloat(Double(a[5])!)

let ctx = CGContext(data: nil, width: Int(W * S), height: Int(H * S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: S, y: S)
ctx.interpolationQuality = .high
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
// CoreGraphics is bottom-left; helpers take top-left y.
func Y(_ y: CGFloat) -> CGFloat { H - y }

// Layout (top-left coordinates, in points).
let markCenter = CGPoint(x: W * 0.655, y: 345)
let markH: CGFloat = 520, markW = markH * CGFloat(mark.width) / CGFloat(mark.height)
let wordX = W * 0.124, wordTop: CGFloat = 62, wordSize: CGFloat = 92

// Background: black, a violet glow behind the mark, and a faint light from above.
ctx.setFillColor(rgb(0x000000)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let glow = CGGradient(colorsSpace: nil, colors: [rgb(0x3A2160, 0.95), rgb(0x1A0B2C, 0.6), rgb(0x000000, 0)] as CFArray, locations: [0, 0.45, 1])!
let gc = CGPoint(x: markCenter.x, y: Y(markCenter.y))
ctx.drawRadialGradient(glow, startCenter: gc, startRadius: 0, endCenter: gc, endRadius: 760, options: [])
let beam = CGGradient(colorsSpace: nil, colors: [rgb(0x5B3A8C, 0.35), rgb(0x5B3A8C, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(beam, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.45), options: [])

// Bubbles: scattered with a fixed seed, kept off the wordmark and the mark.
var seed: UInt64 = 0x0BB5_2026
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
let markBox = CGRect(x: markCenter.x - markW / 2 - 40, y: markCenter.y - markH / 2 - 30, width: markW + 80, height: markH + 60)
let wordBox = CGRect(x: wordX - 40, y: wordTop - 30, width: 640, height: wordSize + 70)
var placed: [(CGPoint, CGFloat)] = []
var tries = 0
while placed.count < Int(W / 52) && tries < 4000 {
    tries += 1
    let r = 6 + pow(rnd(), 1.6) * 30
    let c = CGPoint(x: rnd() * W, y: rnd() * H)
    let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    if box.intersects(markBox) || box.intersects(wordBox) { continue }
    if placed.contains(where: { hypot($0.0.x - c.x, $0.0.y - c.y) < $0.1 + r + 40 }) { continue }
    placed.append((c, r))
}
for (c, r) in placed {
    let rect = CGRect(x: c.x - r, y: Y(c.y) - r, width: 2 * r, height: 2 * r)
    // closer to the glow = a touch more violet
    let near = max(0, 1 - hypot(c.x - markCenter.x, c.y - markCenter.y) / 900)
    ctx.setFillColor(rgb(0x2A1840, 0.25 + 0.25 * near)); ctx.fillEllipse(in: rect)
    ctx.setStrokeColor(rgb(0xB9A6E6, 0.28 + 0.2 * near)); ctx.setLineWidth(max(1.5, r * 0.12)); ctx.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
    ctx.setFillColor(rgb(0xFFFFFF, 0.5))
    let h = r * 0.22
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.42 - h, y: Y(c.y - r * 0.42) - h, width: 2 * h, height: 2 * h))
}

// Wordmark.
let font = NSFont.systemFont(ofSize: wordSize, weight: .semibold)
let word = NSAttributedString(string: "mindseerr", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: 0.5])
word.draw(at: CGPoint(x: wordX, y: Y(wordTop) - font.ascender))

// The mark, with a soft shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: rgb(0x000000, 0.6))
ctx.draw(mark, in: CGRect(x: markCenter.x - markW / 2, y: Y(markCenter.y) - markH / 2, width: markW, height: markH))
ctx.restoreGState()

try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("wrote \(a[2]) (\(Int(W * S))×\(Int(H * S)))")
