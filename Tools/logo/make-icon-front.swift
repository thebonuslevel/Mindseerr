// Places the mark, centered, on a transparent tvOS app-icon front layer.
// Usage: swift make-icon-front.swift <mark.png> <out.png> <width> <height>
import AppKit
let a = CommandLine.arguments
let mark = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = Int(a[3])!, h = Int(a[4])!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
// Same footprint as the original head: about 81% of the layer's height, centered.
let markH = CGFloat(h) * 0.81, markW = markH * CGFloat(mark.width) / CGFloat(mark.height)
ctx.draw(mark, in: CGRect(x: (CGFloat(w) - markW) / 2, y: (CGFloat(h) - markH) / 2, width: markW, height: markH))
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("wrote \(a[2]) (\(w)×\(h))")
