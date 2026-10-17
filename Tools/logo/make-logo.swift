// Draws the Mindseerr mark: a cute mind-flayer head (tall cranium, glossy eyes, heavy brow,
// four curling face tentacles, high crimson collar) in the style of the original logo.
// Usage: swift make-logo.swift <out.png> [height]   — 874×1200 at the default height.
import AppKit
import CoreGraphics

let W: CGFloat = 874, H: CGFloat = 1200
let outHeight = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1200) : 1200
let scale = outHeight / H

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
let ink = rgb(0x180828)
let outline: CGFloat = 20

let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: 0, y: H)      // draw with a top-left origin
ctx.scaleBy(x: 1, y: -1)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)

func mirrored(_ p: CGPoint) -> CGPoint { CGPoint(x: W - p.x, y: p.y) }
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func fillGradient(_ path: CGPath, _ top: CGColor, _ bottom: CGColor, from y0: CGFloat, to y1: CGFloat) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: P(0, y0), end: P(0, y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
    ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.strokePath()
}

// MARK: Collar — two stiff crimson wings flaring up behind the head.
func collarWing(_ m: (CGPoint) -> CGPoint) -> CGPath {
    let p = CGMutablePath()
    p.move(to: m(P(437, 1000)))
    p.addCurve(to: m(P(95, 830)), control1: m(P(300, 1000)), control2: m(P(150, 940)))
    p.addCurve(to: m(P(28, 330)), control1: m(P(45, 700)), control2: m(P(20, 480)))
    p.addCurve(to: m(P(300, 640)), control1: m(P(130, 420)), control2: m(P(230, 520)))
    p.addLine(to: m(P(437, 700)))
    p.closeSubpath()
    return p
}
func collarInner(_ m: (CGPoint) -> CGPoint) -> CGPath {
    let p = CGMutablePath()
    p.move(to: m(P(437, 930)))
    p.addCurve(to: m(P(130, 790)), control1: m(P(320, 930)), control2: m(P(185, 880)))
    p.addCurve(to: m(P(75, 420)), control1: m(P(90, 680)), control2: m(P(70, 520)))
    p.addCurve(to: m(P(310, 690)), control1: m(P(160, 500)), control2: m(P(240, 590)))
    p.closeSubpath()
    return p
}
let sides: [(CGPoint) -> CGPoint] = [{ $0 }, mirrored]
for m in sides { stroke(collarWing(m), ink, outline * 2) }
for m in sides { fillGradient(collarWing(m), rgb(0xC22E4A), rgb(0x7A1230), from: 330, to: 1000) }
for m in sides { fillGradient(collarInner(m), rgb(0x5A0B24), rgb(0x2E0614), from: 420, to: 930) }

// MARK: Head + tentacles share one outline, so draw every outline first, then every fill.
let head: CGPath = {
    let p = CGMutablePath()
    p.move(to: P(437, 55))
    p.addCurve(to: P(738, 385), control1: P(665, 55), control2: P(750, 215))
    p.addCurve(to: P(598, 640), control1: P(728, 520), control2: P(650, 590))
    p.addCurve(to: P(437, 700), control1: P(555, 680), control2: P(500, 700))
    p.addCurve(to: P(276, 640), control1: P(374, 700), control2: P(319, 680))
    p.addCurve(to: P(136, 385), control1: P(224, 590), control2: P(146, 520))
    p.addCurve(to: P(437, 55), control1: P(124, 215), control2: P(209, 55))
    p.closeSubpath()
    return p
}()

/// A tapering tentacle along a cubic curve, ending in a small curl.
struct Tentacle { let a, c1, c2, b: CGPoint; let curl: CGFloat; let r0: CGFloat }
func point(_ t: Tentacle, _ u: CGFloat) -> CGPoint {
    let v = 1 - u
    let x = v*v*v*t.a.x + 3*v*v*u*t.c1.x + 3*v*u*u*t.c2.x + u*u*u*t.b.x
    let y = v*v*v*t.a.y + 3*v*v*u*t.c1.y + 3*v*u*u*t.c2.y + u*u*u*t.b.y
    return P(x, y)
}
func samples(_ t: Tentacle) -> [(CGPoint, CGFloat)] {
    var out: [(CGPoint, CGFloat)] = []
    let n = 120
    for i in 0...n {
        let u = CGFloat(i) / CGFloat(n)
        out.append((point(t, u), t.r0 * (1 - 0.72 * u)))
    }
    // The curl: a tightening arc past the end, turning toward `curl` (+1 clockwise, -1 counter).
    let end = point(t, 1), before = point(t, 0.97)
    var angle = atan2(end.y - before.y, end.x - before.x)
    var p = end, r = t.r0 * 0.28, step: CGFloat = 5
    for _ in 0..<26 {
        angle += t.curl * 0.16
        p = P(p.x + cos(angle) * step, p.y + sin(angle) * step)
        r *= 0.955; step *= 0.97
        out.append((p, r))
    }
    return out
}
let tentacles: [Tentacle] = {
    let innerL = Tentacle(a: P(400, 610), c1: P(385, 780), c2: P(425, 900), b: P(372, 1015), curl: 1, r0: 46)
    let outerL = Tentacle(a: P(318, 590), c1: P(250, 690), c2: P(168, 750), b: P(160, 870), curl: -1, r0: 40)
    let m = { (t: Tentacle) in Tentacle(a: mirrored(t.a), c1: mirrored(t.c1), c2: mirrored(t.c2), b: mirrored(t.b), curl: -t.curl, r0: t.r0) }
    return [outerL, m(outerL), innerL, m(innerL)]
}()
func dabs(_ t: Tentacle, extra: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    for (p, r) in samples(t) {
        let e = extra > 0 ? max(11, min(extra, r * 0.75)) : 0
        ctx.fillEllipse(in: CGRect(x: p.x - r - e, y: p.y - r - e, width: 2 * (r + e), height: 2 * (r + e)))
    }
}

// Outlines
for t in tentacles { dabs(t, extra: outline, color: ink) }
stroke(head, ink, outline * 2)
// Fills: tentacles, then head over their roots.
for (i, t) in tentacles.enumerated() {
    dabs(t, extra: 0, color: i < 2 ? rgb(0x8C70CC) : rgb(0x9B80D8))
    // a lighter ridge down each tentacle
    ctx.setFillColor(rgb(0xC6B4F0, 0.55))
    for (k, (p, r)) in samples(t).enumerated() where k % 2 == 0 && k < 110 {
        ctx.fillEllipse(in: CGRect(x: p.x - r * 0.35 - r * 0.25, y: p.y - r * 0.35, width: r * 0.5, height: r * 0.5))
    }
}
for t in tentacles[2...] {
    let pts = samples(t)
    for k in stride(from: 40, to: 112, by: 14) {
        let (p, r) = pts[k], q = pts[k + 2].0
        // offset toward the middle of the face
        let len = max(hypot(q.x - p.x, q.y - p.y), 0.001)
        var nx = -(q.y - p.y) / len, ny = (q.x - p.x) / len
        if (P(437, 0).x - p.x) * nx < 0 { nx = -nx; ny = -ny }
        let c = P(p.x + nx * r * 0.45, p.y + ny * r * 0.45), sr = r * 0.26
        ctx.setFillColor(rgb(0xE48AB8, 0.9)); ctx.fillEllipse(in: CGRect(x: c.x - sr, y: c.y - sr, width: 2 * sr, height: 2 * sr))
    }
}
fillGradient(head, rgb(0xD3C3F3), rgb(0x9E84DA), from: 55, to: 700)

// MARK: Head details
ctx.saveGState(); ctx.addPath(head); ctx.clip()
// Cranium shine, like the original mark.
ctx.setFillColor(rgb(0xFFFFFF, 0.38))
ctx.fillEllipse(in: CGRect(x: 270, y: 150, width: 170, height: 70))
// Faint brain ridges on the dome.
for (a, c, b) in [(P(470, 120), P(560, 170), P(600, 270)), (P(500, 230), P(590, 260), P(640, 360)),
                  (P(330, 250), P(390, 300), P(370, 380))] {
    let p = CGMutablePath(); p.move(to: a); p.addQuadCurve(to: b, control: c)
    stroke(p, rgb(0x6F54B0, 0.28), 10)
}
// Cheek shadow toward the tentacle roots.
let shade = CGGradient(colorsSpace: nil, colors: [rgb(0x5C3FA0, 0), rgb(0x5C3FA0, 0.35)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shade, start: P(0, 560), end: P(0, 700), options: [])
ctx.restoreGState()

// Eyes: big, glossy and dark, with a lid angled down toward the middle for the mind flayer's glare.
for (m, sign) in [({ (p: CGPoint) in p }, CGFloat(1)), (mirrored, CGFloat(-1))] {
    let c = m(P(322, 505))
    let eye = CGRect(x: c.x - 82, y: c.y - 62, width: 164, height: 124)
    ctx.setFillColor(rgb(0xE06AA8, 0.5)); ctx.fillEllipse(in: eye.insetBy(dx: -12, dy: -12))   // soft pink rim
    ctx.setFillColor(ink); ctx.fillEllipse(in: eye)
    let iris = CGGradient(colorsSpace: nil, colors: [rgb(0x523087), rgb(0x12061F)] as CFArray, locations: [0, 1])!
    ctx.saveGState(); ctx.addEllipse(in: eye.insetBy(dx: 9, dy: 9)); ctx.clip()
    ctx.drawRadialGradient(iris, startCenter: P(c.x + 10 * sign, c.y + 18), startRadius: 0,
                           endCenter: P(c.x, c.y), endRadius: 90, options: [])
    ctx.restoreGState()
    // Highlights.
    ctx.setFillColor(rgb(0xFFFFFF, 0.95))
    ctx.fillEllipse(in: CGRect(x: c.x - 30 * sign - 22, y: c.y - 22, width: 44, height: 40))
    ctx.fillEllipse(in: CGRect(x: c.x + 26 * sign - 8, y: c.y + 22, width: 16, height: 16))
    // Lid: skin over the top of the eye, lower toward the nose, with a dark crease along its edge.
    let outer = m(P(214, 452)), inner = m(P(430, 492))
    let lid = CGMutablePath()
    lid.move(to: P(outer.x, outer.y - 80)); lid.addLine(to: P(inner.x, inner.y - 120))
    lid.addLine(to: inner)
    lid.addQuadCurve(to: outer, control: m(P(322, 452)))
    lid.closeSubpath()
    fillGradient(lid, rgb(0xD3C3F3), rgb(0x9E84DA), from: 55, to: 700)
    let crease = CGMutablePath(); crease.move(to: outer); crease.addQuadCurve(to: inner, control: m(P(322, 452)))
    stroke(crease, ink, 16)
    // Brow ridge shading just above the crease.
    let ridge = CGMutablePath(); ridge.move(to: m(P(230, 420))); ridge.addQuadCurve(to: m(P(420, 452)), control: m(P(330, 400)))
    stroke(ridge, rgb(0x6F54B0, 0.35), 14)
}

let full = ctx.makeImage()!
let image: CGImage = {
    // Content spans roughly y 30…1070 (top-left coords); crop to 1080 tall around it, same width.
    let cropH = 1080 * scale, top = 10 * scale
    return full.cropping(to: CGRect(x: 0, y: top, width: CGFloat(full.width), height: min(cropH, CGFloat(full.height) - top)))!
}()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
print("wrote \(url.path) (\(image.width)×\(image.height))")
