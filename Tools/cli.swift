import Foundation
import PDFKit
import AppKit

/// Test harness around PDFEngine: same code path the app uses, without any UI.
@main
enum CLI {
    static let usage = """
        usage: pdfream-cli <command> …
          split <source.pdf> <folder> <limitBytes>
          combine <output.pdf> <limitBytes> <source.pdf>…
          info <file.pdf>…
          structure <file.pdf>          title, bookmarks, link targets, annotation count
          streams <file.pdf>            which image filters the file uses
          render <file.pdf> <pageIndex> <pixelWidth> <out.png>
          pixel <file.pdf> <pageIndex> <x> <y>   colour at a point of the displayed page
        """

    static func fail(_ message: String? = nil) -> Never {
        if let message { print(message) }
        print(usage)
        exit(2)
    }

    static func int(_ text: String) -> Int {
        guard let value = Int(text) else { fail("not a whole number: \(text)") }
        return value
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else { fail() }
        do {
            switch args[1] {
            case "split":
                guard args.count == 5 else { fail() }
                let started = Date()
                let result = try PDFEngine.split(source: URL(fileURLWithPath: args[2]),
                                                 into: URL(fileURLWithPath: args[3]),
                                                 pageLimit: int(args[4])) { _ in }
                print("files: \(result.files.count)")
                print("sizes: \(result.sizes.map { String($0) }.joined(separator: " "))")
                print("max: \(result.sizes.max() ?? 0)")
                print("recompressed: \(result.compressedPages)")
                print("over_limit: \(result.overLimitPages)")
                print(String(format: "seconds: %.2f", Date().timeIntervalSince(started)))
            case "combine":
                guard args.count >= 5 else { fail() }
                let started = Date()
                let sources = args[4...].map { URL(fileURLWithPath: $0) }
                let result = try PDFEngine.combine(sources: sources,
                                                   output: URL(fileURLWithPath: args[2]),
                                                   limit: int(args[3])) { _ in }
                print("pages: \(result.pageCount)")
                print("bytes: \(result.bytes)")
                print("input_bytes: \(result.inputBytes)")
                print("recompressed: \(result.recompressed)")
                print("fits: \(result.fitsLimit)")
                print(String(format: "seconds: %.2f", Date().timeIntervalSince(started)))
            case "info":
                guard args.count >= 3 else { fail() }
                for path in args[2...] {
                    let url = URL(fileURLWithPath: path)
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard let doc = PDFDocument(url: url) else {
                        print("\(url.lastPathComponent): NOT A PDF (\(size) bytes)")
                        continue
                    }
                    let locked = doc.isLocked ? " LOCKED" : ""
                    print("\(url.lastPathComponent): \(doc.pageCount) pages, \(size) bytes\(locked)")
                    for i in 0..<doc.pageCount {
                        guard let page = doc.page(at: i) else { continue }
                        let box = page.bounds(for: .cropBox)
                        let display = PDFEngine.displaySize(of: page)
                        let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let snippet = text.isEmpty ? "-" : String(text.prefix(40)).replacingOccurrences(of: "\n", with: " ")
                        print(String(format: "  p%d box=%.0fx%.0f rot=%d display=%.0fx%.0f text=%@",
                                     i + 1, box.width, box.height, page.rotation, display.width, display.height, snippet))
                    }
                }
            case "structure":
                guard args.count == 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[2])) else { fail() }
                let attributes = doc.documentAttributes ?? [:]
                print("title: \(attributes[PDFDocumentAttribute.titleAttribute] as? String ?? "-")")
                print("author: \(attributes[PDFDocumentAttribute.authorAttribute] as? String ?? "-")")
                func target(_ destination: PDFDestination?) -> String {
                    guard let page = destination?.page else { return "?" }
                    let index = doc.index(for: page)
                    return index == NSNotFound ? "?" : String(index + 1)
                }
                var items: [String] = []
                func walk(_ item: PDFOutline, depth: Int) {
                    for i in 0..<item.numberOfChildren {
                        guard let child = item.child(at: i) else { continue }
                        let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                        items.append(String(repeating: "-", count: depth) + "\(child.label ?? "")@\(target(destination))")
                        walk(child, depth: depth + 1)
                    }
                }
                if let root = doc.outlineRoot { walk(root, depth: 0) }
                print("outline: \(items.joined(separator: ", "))")
                var links: [String] = []
                var annotations = 0
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    annotations += page.annotations.count
                    for annotation in page.annotations {
                        let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                        if destination != nil { links.append("p\(i + 1)>\(target(destination))") }
                    }
                }
                print("links: \(links.joined(separator: " "))")
                print("annotations: \(annotations)")
            case "render":
                guard args.count == 6 else { fail() }
                let url = URL(fileURLWithPath: args[2])
                guard let doc = PDFDocument(url: url), let page = doc.page(at: int(args[3])) else {
                    print("cannot open"); exit(1)
                }
                let display = PDFEngine.displaySize(of: page)
                let width = CGFloat(int(args[4]))
                let scale = width / display.width
                let size = NSSize(width: width, height: (display.height * scale).rounded())
                let image = page.thumbnail(of: size, for: .cropBox)
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); exit(1) }
                try png.write(to: URL(fileURLWithPath: args[5]))
                print("ok \(Int(size.width))x\(Int(size.height))")
            case "pixel":
                // One bitmap pixel per point, white paper, annotations drawn: what a viewer shows.
                guard args.count == 6, let x = Double(args[4]), let y = Double(args[5]) else { fail() }
                guard let doc = PDFDocument(url: URL(fileURLWithPath: args[2])), let page = doc.page(at: int(args[3])) else {
                    print("cannot open"); exit(1)
                }
                let display = PDFEngine.displaySize(of: page)
                let width = max(1, Int(display.width.rounded())), height = max(1, Int(display.height.rounded()))
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                      let raw = context.data else { print("render failed"); exit(1) }
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                page.draw(with: .cropBox, to: context)
                let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
                let column = min(max(Int(x), 0), width - 1)
                let row = height - 1 - min(max(Int(y), 0), height - 1)   // bitmap rows run top-down
                let offset = (row * width + column) * 4
                print("\(pixels[offset]) \(pixels[offset + 1]) \(pixels[offset + 2])")
            case "streams":
                guard args.count == 3 else { fail() }
                let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
                let text = String(decoding: data, as: UTF8.self)
                for filter in ["DCTDecode", "FlateDecode", "JPXDecode", "CCITTFaxDecode", "RunLengthDecode"] {
                    let count = text.components(separatedBy: filter).count - 1
                    if count > 0 { print("\(filter): \(count)") }
                }
            default:
                fail("unknown command \(args[1])")
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
}
