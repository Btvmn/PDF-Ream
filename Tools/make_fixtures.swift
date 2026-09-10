import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import AppKit

/// Builds test PDFs that behave like heavy iPhone Notes scans (one big JPEG per page).
struct RNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 10_000) / 10_000 }
}

func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

/// A page of "handwriting" on grainy paper: grain is what makes real scans heavy.
func scanImage(width: Int, height: Int, grain: Int, seed: UInt64, title: String, pureNoise: Bool = false) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var rng = RNG(state: seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407)

    ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let w = CGFloat(width), h = CGFloat(height)
    let gap = h / 32

    ctx.setStrokeColor(CGColor(red: 0.62, green: 0.74, blue: 0.88, alpha: 1))
    ctx.setLineWidth(max(1, w / 900))
    for line in 1..<32 {
        let y = CGFloat(line) * gap
        ctx.move(to: CGPoint(x: w * 0.05, y: y))
        ctx.addLine(to: CGPoint(x: w * 0.95, y: y))
    }
    ctx.strokePath()

    ctx.setStrokeColor(CGColor(red: 0.10, green: 0.14, blue: 0.42, alpha: 1))
    ctx.setLineWidth(max(1, w / 450))
    ctx.setLineCap(.round)
    for line in 2..<29 {
        var x = w * 0.08
        let y = CGFloat(line) * gap + gap * 0.28
        ctx.move(to: CGPoint(x: x, y: y))
        while x < w * 0.9 {
            let dx = (rng.unit() * 0.05 + 0.01) * w
            let dy = (rng.unit() - 0.5) * gap * 0.7
            ctx.addQuadCurve(to: CGPoint(x: x + dx, y: y + dy),
                             control: CGPoint(x: x + dx / 2, y: y + (rng.unit() - 0.5) * gap))
            x += dx
        }
        ctx.strokePath()
    }

    // Orientation marker: readable only when the page is the right way up.
    drawText("\(title)  ^ TOP ^", in: ctx, at: CGPoint(x: w * 0.08, y: h - gap * 1.6), size: h / 26,
             color: CGColor(red: 0.75, green: 0.1, blue: 0.1, alpha: 1))
    drawText("bottom", in: ctx, at: CGPoint(x: w * 0.08, y: gap * 0.5), size: h / 40,
             color: CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))

    if grain > 0, let raw = ctx.data {
        let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in 0..<(width * height) {
            if pureNoise {
                for channel in 0..<3 { pixels[i * 4 + channel] = UInt8(rng.next() % 256) }
            } else {
                let delta = Int(rng.next() % UInt64(2 * grain + 1)) - grain
                for channel in 0..<3 {
                    pixels[i * 4 + channel] = UInt8(clamping: Int(pixels[i * 4 + channel]) + delta)
                }
            }
        }
    }
    return ctx.makeImage()!
}

func jpegData(_ image: CGImage, quality: CGFloat) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func writeScanPDF(to url: URL, pages: [(size: CGSize, image: CGImage, quality: CGFloat)]) {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: pages[0].size)
    let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    for page in pages {
        var pageBox = CGRect(origin: .zero, size: page.size)
        let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        let jpeg = jpegData(page.image, quality: page.quality)
        let provider = CGDataProvider(data: jpeg as CFData)!
        let embedded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        ctx.draw(embedded, in: pageBox)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    try! (data as Data).write(to: url)
}

func writeVectorPDF(to url: URL, pageCount: Int) {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    for page in 1...pageCount {
        ctx.beginPDFPage(nil)
        drawText("Vector page \(page) — текстовая страница", in: ctx, at: CGPoint(x: 60, y: 760), size: 22,
                 color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for line in 0..<25 {
            drawText("Строка \(line + 1): quick brown fox 0123456789", in: ctx, at: CGPoint(x: 60, y: 700 - CGFloat(line) * 26),
                     size: 13, color: CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    try! (data as Data).write(to: url)
}

/// A long text document: every page saved on its own repeats the embedded font, which is what
/// makes a naive per-page size estimate several times too high.
func writeBookPDF(to url: URL, pageCount: Int) {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Georgia" as CFString, 11, nil)
    for page in 1...pageCount {
        ctx.beginPDFPage(nil)
        for line in 0..<48 {
            let text = "Page \(page) line \(line + 1): Sphinx of black quartz, judge my vow; \(page * 97 + line * 13) — ÄÖÜ àéî ßø"
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 54, y: 740 - CGFloat(line) * 14.5)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    try! (data as Data).write(to: url)
}

guard CommandLine.arguments.count > 1 else {
    print("usage: make_fixtures <output-dir>")
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let a4 = CGSize(width: 595.28, height: 841.89)
let letter = CGSize(width: 612, height: 792)
let a4Landscape = CGSize(width: 841.89, height: 595.28)

// 20-page "scan": heavy grainy pages plus a few light ones that must survive untouched.
var pages: [(size: CGSize, image: CGImage, quality: CGFloat)] = []
for i in 1...20 {
    let heavy = i <= 15
    let size: CGSize = i == 7 ? letter : (i == 9 ? a4Landscape : a4)
    let px = Int((size.width / 72 * 300).rounded())
    let py = Int((size.height / 72 * 300).rounded())
    let image = scanImage(width: px, height: py, grain: heavy ? 16 : 1, seed: UInt64(i), title: "Page \(i)")
    pages.append((size, image, heavy ? 0.92 : 0.6))
}
writeScanPDF(to: out.appendingPathComponent("scan20.pdf"), pages: pages)

// Worst case: incompressible noise.
var noisePages: [(size: CGSize, image: CGImage, quality: CGFloat)] = []
for i in 1...2 {
    let image = scanImage(width: 2480, height: 3508, grain: 255, seed: UInt64(100 + i), title: "Noise \(i)", pureNoise: true)
    noisePages.append((a4, image, 0.95))
}
writeScanPDF(to: out.appendingPathComponent("noise2.pdf"), pages: noisePages)

// Rotation + shifted crop box.
var rotatedPages: [(size: CGSize, image: CGImage, quality: CGFloat)] = []
for i in 1...4 {
    let image = scanImage(width: 1700, height: 2400, grain: 14, seed: UInt64(200 + i), title: "Rot \(i)")
    rotatedPages.append((a4, image, 0.9))
}
let rotatedURL = out.appendingPathComponent("rotated.pdf")
writeScanPDF(to: rotatedURL, pages: rotatedPages)
if let doc = PDFDocument(url: rotatedURL) {
    doc.page(at: 1)?.rotation = 90
    doc.page(at: 2)?.rotation = 180
    doc.page(at: 3)?.rotation = 270
    doc.page(at: 0)?.setBounds(CGRect(x: 20, y: 30, width: 500, height: 700), for: .cropBox)
    doc.write(to: rotatedURL)
}

writeVectorPDF(to: out.appendingPathComponent("vector6.pdf"), pageCount: 6)

// Annotated page: annotations must survive recompression.
let annotatedURL = out.appendingPathComponent("annotated.pdf")
writeScanPDF(to: annotatedURL, pages: [(a4, scanImage(width: 2480, height: 3508, grain: 16, seed: 300, title: "Annot"), 0.92)])
if let doc = PDFDocument(url: annotatedURL), let page = doc.page(at: 0) {
    let square = PDFAnnotation(bounds: CGRect(x: 60, y: 420, width: 470, height: 220), forType: .square, withProperties: nil)
    square.color = .red
    square.border = PDFBorder()
    square.border?.lineWidth = 6
    page.addAnnotation(square)
    let note = PDFAnnotation(bounds: CGRect(x: 70, y: 300, width: 460, height: 60), forType: .freeText, withProperties: nil)
    note.contents = "ANNOTATION TEXT"
    note.font = NSFont.boldSystemFont(ofSize: 28)
    note.fontColor = .systemBlue
    note.color = .clear
    page.addAnnotation(note)
    doc.write(to: annotatedURL)
}

// A single 1-page file and a broken one.
writeScanPDF(to: out.appendingPathComponent("single.pdf"),
             pages: [(a4, scanImage(width: 2480, height: 3508, grain: 16, seed: 400, title: "Single"), 0.92)])
try! Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: out.appendingPathComponent("broken.pdf"))
try! "not a pdf".data(using: .utf8)!.write(to: out.appendingPathComponent("notes.txt"))

// Bookmarks, internal links and document information: they must survive Merge and Compress.
// Four text pages around one heavy scan, so compressing it under a few MB has to re-render a page.
// Pages: 1 text, 2 text, 3 scan, 4 text, 5 text.
let structuredURL = out.appendingPathComponent("structured.pdf")
writeVectorPDF(to: structuredURL, pageCount: 4)
if let doc = PDFDocument(url: structuredURL),
   let scan = PDFDocument(url: out.appendingPathComponent("single.pdf"))?.page(at: 0)?.copy() as? PDFPage {
    doc.insert(scan, at: 2)
    func page(_ number: Int) -> PDFPage { doc.page(at: number - 1)! }
    func destination(_ number: Int) -> PDFDestination { PDFDestination(page: page(number), at: CGPoint(x: 0, y: 842)) }
    func link(from: Int, to: Int, asAction: Bool) {
        let annotation = PDFAnnotation(bounds: CGRect(x: 60, y: 40, width: 240, height: 24), forType: .link, withProperties: nil)
        if asAction { annotation.action = PDFActionGoTo(destination: destination(to)) } else { annotation.destination = destination(to) }
        page(from).addAnnotation(annotation)
    }
    link(from: 1, to: 4, asAction: false)
    link(from: 2, to: 3, asAction: true)
    link(from: 5, to: 1, asAction: false)

    let root = PDFOutline()
    func bookmark(_ label: String, _ number: Int, under parent: PDFOutline) -> PDFOutline {
        let item = PDFOutline()
        item.label = label
        item.destination = destination(number)
        parent.insertChild(item, at: parent.numberOfChildren)
        return item
    }
    _ = bookmark("Intro", 1, under: root)
    let scanItem = bookmark("Scan", 3, under: root)
    _ = bookmark("Details", 4, under: scanItem)
    _ = bookmark("End", 5, under: root)
    doc.outlineRoot = root
    doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Structured fixture",
                              PDFDocumentAttribute.authorAttribute: "PDF Ream tests"]
    doc.write(to: structuredURL)
}

writeBookPDF(to: out.appendingPathComponent("text40.pdf"), pageCount: 40)

for name in ["scan20.pdf", "noise2.pdf", "rotated.pdf", "vector6.pdf", "annotated.pdf", "single.pdf", "structured.pdf", "text40.pdf"] {
    let url = out.appendingPathComponent(name)
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    print("\(name): \(size) bytes, \(PDFDocument(url: url)?.pageCount ?? 0) pages")
}
