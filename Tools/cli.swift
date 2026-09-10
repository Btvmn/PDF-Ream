import Foundation
import PDFKit
import AppKit

/// Test harness around PDFEngine: same code path the app uses, without any UI.
@main
enum CLI {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: pdfream-cli split|combine|info|render …")
            exit(2)
        }
        do {
            switch args[1] {
            case "split":
                // split <source> <folder> <limitBytes>
                let started = Date()
                let result = try PDFEngine.split(source: URL(fileURLWithPath: args[2]),
                                                 into: URL(fileURLWithPath: args[3]),
                                                 pageLimit: Int(args[4])!) { _ in }
                print("files: \(result.files.count)")
                print("sizes: \(result.sizes.map { String($0) }.joined(separator: " "))")
                print("max: \(result.sizes.max() ?? 0)")
                print("recompressed: \(result.compressedPages)")
                print("over_limit: \(result.overLimitPages)")
                print(String(format: "seconds: %.2f", Date().timeIntervalSince(started)))
            case "combine":
                // combine <output> <limitBytes> <sources…>
                let started = Date()
                let sources = args[4...].map { URL(fileURLWithPath: $0) }
                let result = try PDFEngine.combine(sources: sources,
                                                   output: URL(fileURLWithPath: args[2]),
                                                   limit: Int(args[3])!) { _ in }
                print("pages: \(result.pageCount)")
                print("bytes: \(result.bytes)")
                print("input_bytes: \(result.inputBytes)")
                print("recompressed: \(result.recompressed)")
                print("fits: \(result.fitsLimit)")
                print(String(format: "seconds: %.2f", Date().timeIntervalSince(started)))
            case "info":
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
            case "render":
                // render <pdf> <pageIndex> <pixelWidth> <out.png>
                let url = URL(fileURLWithPath: args[2])
                guard let doc = PDFDocument(url: url), let page = doc.page(at: Int(args[3])!) else {
                    print("cannot open"); exit(1)
                }
                let display = PDFEngine.displaySize(of: page)
                let width = CGFloat(Int(args[4])!)
                let scale = width / display.width
                let size = NSSize(width: width, height: (display.height * scale).rounded())
                let image = page.thumbnail(of: size, for: .cropBox)
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); exit(1) }
                try png.write(to: URL(fileURLWithPath: args[5]))
                print("ok \(Int(size.width))x\(Int(size.height))")
            case "streams":
                // streams <pdf> — which image filters the file actually uses
                let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
                let text = String(decoding: data, as: UTF8.self)
                for filter in ["DCTDecode", "FlateDecode", "JPXDecode", "CCITTFaxDecode", "RunLengthDecode"] {
                    let count = text.components(separatedBy: filter).count - 1
                    if count > 0 { print("\(filter): \(count)") }
                }
            default:
                print("unknown command \(args[1])"); exit(2)
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
}
