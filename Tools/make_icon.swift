import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// A ream of paper on a dark violet slab: a stack of sheets, the top one lifted away.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: CGFloat) -> CGImage {
    let side = Int(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let u = size / 1024
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // MARK: slab
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let slab = roundedPath(body, 185 * u)
    ctx.saveGState()
    ctx.addPath(slab)
    ctx.clip()
    let base = CGGradient(colorsSpace: space,
                          colors: [rgb(86, 44, 170), rgb(38, 20, 74), rgb(20, 12, 38)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // glow behind the stack
    let glow = CGGradient(colorsSpace: space,
                          colors: [rgb(167, 110, 255, 0.55), rgb(167, 110, 255, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX - 40 * u, y: body.midY + 150 * u), startRadius: 0,
                           endCenter: CGPoint(x: body.midX - 40 * u, y: body.midY + 150 * u), endRadius: 470 * u,
                           options: [])
    // light falling from the top-left corner, fading out before it reaches the middle
    let sheen = CGGradient(colorsSpace: space,
                           colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0.04), rgb(255, 255, 255, 0)] as CFArray,
                           locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.midX + 60 * u, y: body.midY - 60 * u), options: [])
    ctx.restoreGState()

    // MARK: sheets
    /// One sheet drawn in its own rotated space, with a paper edge and optional content.
    func sheet(center: CGPoint, size sheetSize: CGSize, rotation: CGFloat,
               top: CGColor, bottom: CGColor, content: Bool, fold: Bool, shadow: CGFloat,
               simplified: Bool = false) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        let rect = CGRect(x: -sheetSize.width / 2, y: -sheetSize.height / 2, width: sheetSize.width, height: sheetSize.height)
        let radius = 22 * u
        let path = roundedPath(rect, radius)

        ctx.setShadow(offset: CGSize(width: 0, height: -14 * u * shadow), blur: 40 * u * shadow,
                      color: rgb(8, 4, 20, 0.55))
        ctx.addPath(path)
        ctx.setFillColor(top)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // paper gradient
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let paper = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

        if content {
            let rows: [CGFloat] = simplified ? [0.78, 0.58, 0.86] : [0.72, 0.52, 0.86, 0.62, 0.4]
            let step: CGFloat = simplified ? 0.2 : 0.132
            let thickness: CGFloat = simplified ? 46 * u : 24 * u
            ctx.setFillColor(rgb(124, 58, 237, simplified ? 1 : 0.85))
            for (index, width) in rows.enumerated() {
                let bar = CGRect(x: rect.minX + rect.width * 0.14,
                                 y: rect.maxY - rect.height * (0.30 + CGFloat(index) * step),
                                 width: rect.width * 0.72 * width, height: thickness)
                ctx.addPath(roundedPath(bar, thickness / 2))
            }
            ctx.fillPath()
            if !simplified {
                // heavier first line, like a heading
                ctx.setFillColor(rgb(76, 29, 149))
                ctx.addPath(roundedPath(CGRect(x: rect.minX + rect.width * 0.14, y: rect.maxY - rect.height * 0.20,
                                               width: rect.width * 0.44, height: 34 * u), 17 * u))
                ctx.fillPath()
            }
        }

        if fold {
            // folded corner: shading triangle plus a lighter flap
            let corner = CGPoint(x: rect.maxX, y: rect.maxY)
            let cut = 132 * u
            ctx.setFillColor(rgb(196, 181, 253))
            ctx.move(to: CGPoint(x: corner.x - cut, y: corner.y))
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y))
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - cut))
            ctx.closePath()
            ctx.fillPath()
            ctx.setFillColor(rgb(139, 92, 246))
            ctx.move(to: CGPoint(x: corner.x - cut, y: corner.y))
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - cut))
            ctx.addLine(to: CGPoint(x: corner.x - cut, y: corner.y - cut))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()

        // crisp edge
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(91, 33, 182, 0.35))
        ctx.setLineWidth(3 * u)
        ctx.strokePath()
        ctx.restoreGState()
    }

    let sheetSize = CGSize(width: 392 * u, height: 496 * u)
    if size <= 40 {
        // At 16-32 px the fan of sheets turns to mush: two sheets and three fat lines instead.
        sheet(center: CGPoint(x: 452 * u, y: 470 * u), size: sheetSize, rotation: -0.14,
              top: rgb(178, 155, 236), bottom: rgb(136, 110, 206), content: false, fold: false, shadow: 0.6)
        sheet(center: CGPoint(x: 546 * u, y: 522 * u), size: sheetSize, rotation: 0.06,
              top: rgb(253, 252, 255), bottom: rgb(226, 218, 250), content: true, fold: false, shadow: 0.9,
              simplified: true)
    } else {
        // back of the stack: three sheets peeking out
        sheet(center: CGPoint(x: 432 * u, y: 462 * u), size: sheetSize, rotation: -0.20,
              top: rgb(150, 122, 220), bottom: rgb(112, 84, 186), content: false, fold: false, shadow: 0.8)
        sheet(center: CGPoint(x: 456 * u, y: 480 * u), size: sheetSize, rotation: -0.125,
              top: rgb(186, 163, 240), bottom: rgb(140, 115, 210), content: false, fold: false, shadow: 0.7)
        sheet(center: CGPoint(x: 480 * u, y: 498 * u), size: sheetSize, rotation: -0.055,
              top: rgb(219, 205, 250), bottom: rgb(170, 148, 228), content: false, fold: false, shadow: 0.7)
        // the sheet being pulled out of the ream
        sheet(center: CGPoint(x: 556 * u, y: 538 * u), size: sheetSize, rotation: 0.075,
              top: rgb(253, 252, 255), bottom: rgb(226, 218, 250), content: true, fold: true, shadow: 1.0)
    }

    // MARK: slab rim
    ctx.addPath(roundedPath(body.insetBy(dx: 1.5 * u, dy: 1.5 * u), 183.5 * u))
    ctx.setStrokeColor(rgb(255, 255, 255, 0.16))
    ctx.setLineWidth(3 * u)
    ctx.strokePath()

    return ctx.makeImage()!
}

guard CommandLine.arguments.count > 1 else {
    print("usage: make_icon <output.iconset>")
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outputDirectory)
try! FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let image = drawIcon(size: CGFloat(pixels))
    let suffix = scale == 2 ? "@2x" : ""
    let url = outputDirectory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
print("iconset written to \(outputDirectory.path)")
