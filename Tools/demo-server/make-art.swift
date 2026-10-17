// Draws simple poster and backdrop art for the fictional demo titles in catalog.json.
// Usage: swift make-art.swift <catalog.json> <output dir>
import AppKit
import CoreGraphics

struct Catalog: Decodable {
    struct Title: Decodable { let id: Int; let title: String; let year: Int; let colors: [String]; let type: String }
    let titles: [Title]
}

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    let v = Int(hex, radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                   blue: CGFloat(v & 255) / 255, alpha: alpha)
}

func render(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// A soft vertical gradient with a few glowing orbs, seeded by the title's id so each looks different.
func background(_ ctx: CGContext, _ t: Catalog.Title, _ w: CGFloat, _ h: CGFloat) {
    let gradient = CGGradient(colorsSpace: nil, colors: [color(t.colors[0]), color(t.colors[1])] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    var seed = UInt64(t.id)
    func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
    for _ in 0..<5 {
        let r = (0.08 + next() * 0.22) * min(w, h) * 1.4
        let c = CGPoint(x: next() * w, y: h * (0.35 + next() * 0.6))
        let glow = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }
    // Darken the bottom so the title reads.
    let shade = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.55)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: h * 0.55), end: CGPoint(x: 0, y: 0), options: [])
}

func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, in rect: CGRect, align: NSTextAlignment) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byWordWrapping
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 8
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: style, .shadow: shadow, .kern: size * 0.02,
    ]
    NSAttributedString(string: text, attributes: attrs).draw(with: rect, options: [.usesLineFragmentOrigin])
}

let args = CommandLine.arguments
let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for t in catalog.titles {
    // Poster 500×750: title near the bottom, year and kind underneath.
    render(width: 500, height: 750, to: out.appendingPathComponent("p\(t.id).png")) { ctx in
        background(ctx, t, 500, 750)
        drawText(t.title.uppercased(), size: 50, weight: .heavy, alpha: 1, in: CGRect(x: 36, y: 110, width: 428, height: 220), align: .center)
        drawText("\(t.year)  ·  \(t.type == "tv" ? "SERIES" : "FILM")", size: 20, weight: .semibold, alpha: 0.75,
                 in: CGRect(x: 36, y: 60, width: 428, height: 34), align: .center)
    }
    // Backdrop 1280×720: no text (the app draws the title over it).
    render(width: 1280, height: 720, to: out.appendingPathComponent("b\(t.id).png")) { ctx in
        background(ctx, t, 1280, 720)
    }
}
print("drew art for \(catalog.titles.count) titles in \(out.path)")
