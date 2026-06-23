// Renders the ClaudeWatch app icon (purple squircle, code brackets framing an eye with
// a coral iris + white spark) into an .iconset directory using CoreGraphics.
// Usage: swift Tools/make_icon.swift <output.iconset dir>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let purple = CGColor(red: 110/255, green: 86/255, blue: 207/255, alpha: 1)
let coral  = CGColor(red: 217/255, green: 119/255, blue: 87/255, alpha: 1)
let white  = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

func draw(size s: CGFloat, into ctx: CGContext) {
    func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: fx * s, y: fy * s) }

    // Rounded-rect "squircle" with transparent margin, ~82% of the canvas.
    let inset = 0.09 * s
    let box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = 0.2237 * box.width
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(purple)
    ctx.fillPath()

    // Code brackets ‹  › framing the eye.
    ctx.setStrokeColor(white)
    ctx.setLineWidth(0.035 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let left = CGMutablePath()
    left.move(to: p(0.30, 0.40)); left.addLine(to: p(0.22, 0.50)); left.addLine(to: p(0.30, 0.60))
    let right = CGMutablePath()
    right.move(to: p(0.70, 0.40)); right.addLine(to: p(0.78, 0.50)); right.addLine(to: p(0.70, 0.60))
    ctx.addPath(left); ctx.addPath(right); ctx.strokePath()

    // Coral disc between the brackets.
    let irisR = 0.088 * s
    ctx.setFillColor(coral)
    ctx.fillEllipse(in: CGRect(x: 0.5 * s - irisR, y: 0.5 * s - irisR, width: 2 * irisR, height: 2 * irisR))

    // White 4-point spark as the pupil.
    let R = 0.055 * s, w = 0.42 * R, cx = 0.5 * s, cy = 0.5 * s
    let spark = CGMutablePath()
    spark.move(to: CGPoint(x: cx, y: cy - R))
    spark.addQuadCurve(to: CGPoint(x: cx + R, y: cy), control: CGPoint(x: cx + w, y: cy - w))
    spark.addQuadCurve(to: CGPoint(x: cx, y: cy + R), control: CGPoint(x: cx + w, y: cy + w))
    spark.addQuadCurve(to: CGPoint(x: cx - R, y: cy), control: CGPoint(x: cx - w, y: cy + w))
    spark.addQuadCurve(to: CGPoint(x: cx, y: cy - R), control: CGPoint(x: cx - w, y: cy - w))
    ctx.addPath(spark); ctx.setFillColor(white); ctx.fillPath()
}

func render(_ px: Int, to url: URL) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.interpolationQuality = .high
    draw(size: CGFloat(px), into: ctx)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: make_icon.swift <out.iconset>\n", stderr); exit(1) }
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants {
    render(px, to: outDir.appendingPathComponent(name))
}
print("wrote \(variants.count) PNGs to \(outDir.path)")
