import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum PDFReamError: LocalizedError {
    case cannotOpen(String)
    case locked(String)
    case noPages(String)
    case pageFailed(String, Int)
    case assembleFailed
    case writeFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): return "“\(name)”: could not open it — the file is damaged or not a PDF."
        case .locked(let name): return "“\(name)”: the file is password-protected."
        case .noPages(let name): return "“\(name)”: the file has no pages."
        case .pageFailed(let name, let page): return "“\(name)”: could not process page \(page)."
        case .assembleFailed: return "Could not build the final PDF."
        case .writeFailed(let name, let reason): return "Could not save “\(name)”: \(reason)"
        }
    }
}

struct RenderQuality {
    let dpi: CGFloat
    let jpeg: CGFloat
}

struct SplitResult {
    let folder: URL
    let files: [URL]
    let sizes: [Int]
    /// 1-based numbers of pages that had to be recompressed to fit the limit.
    let compressedPages: [Int]
    /// 1-based numbers of pages that did not fit even at the lowest quality.
    let overLimitPages: [Int]
}

struct CombineResult {
    let output: URL
    let pageCount: Int
    let bytes: Int
    let inputBytes: Int
    let recompressed: Bool
    let fitsLimit: Bool
}

enum PDFEngine {
    /// Best to worst. Neither dpi nor JPEG quality ever goes up, so the output size shrinks step by step.
    static let ladder: [RenderQuality] = [
        .init(dpi: 300, jpeg: 0.85), .init(dpi: 300, jpeg: 0.75), .init(dpi: 250, jpeg: 0.72),
        .init(dpi: 220, jpeg: 0.70), .init(dpi: 200, jpeg: 0.65), .init(dpi: 175, jpeg: 0.62),
        .init(dpi: 150, jpeg: 0.60), .init(dpi: 130, jpeg: 0.55), .init(dpi: 110, jpeg: 0.50),
        .init(dpi: 96, jpeg: 0.45), .init(dpi: 80, jpeg: 0.40), .init(dpi: 72, jpeg: 0.35),
        .init(dpi: 60, jpeg: 0.30), .init(dpi: 50, jpeg: 0.25), .init(dpi: 40, jpeg: 0.20),
    ]

    // MARK: - Split

    /// Writes every page of `source` as its own PDF into `folder`, each no larger than `pageLimit` bytes.
    /// Pages already under the limit are copied untouched; heavier ones are re-rendered as JPEG.
    static func split(source: URL, into folder: URL, pageLimit: Int, progress: (Double) -> Void) throws -> SplitResult {
        let name = source.lastPathComponent
        let count = try validatedDocument(source).pageCount

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw PDFReamError.writeFailed(folder.lastPathComponent, error.localizedDescription)
        }

        struct PageOutput { let url: URL; let size: Int; let compressed: Bool; let fits: Bool }
        let base = source.deletingPathExtension().lastPathComponent
        let digits = max(2, String(count).count)
        let outputs = Locked([PageOutput?](repeating: nil, count: count))
        let failure = Locked<Error?>(nil)
        let done = Locked(0)

        parallelFor(count) { index in
            if failure.value != nil { return }
            guard let doc = makeDocument(source), let page = doc.page(at: index) else {
                failure.update { $0 = $0 ?? PDFReamError.pageFailed(name, index + 1) }
                return
            }
            var bytes = losslessPageData(page)
            var compressed = false
            var fits = true
            if bytes == nil || bytes!.count > pageLimit {
                guard let fitted = bestRaster(of: page, limit: pageLimit) else {
                    failure.update { $0 = $0 ?? PDFReamError.pageFailed(name, index + 1) }
                    return
                }
                bytes = fitted.data
                compressed = true
                fits = fitted.fits
            }
            let number = String(format: "%0\(digits)d", index + 1)
            let url = folder.appendingPathComponent("\(base)_\(number).pdf")
            do {
                try bytes!.write(to: url, options: .atomic)
            } catch {
                failure.update { $0 = $0 ?? PDFReamError.writeFailed(url.lastPathComponent, error.localizedDescription) }
                return
            }
            outputs.update { $0[index] = PageOutput(url: url, size: bytes!.count, compressed: compressed, fits: fits) }
            let finished = done.update { $0 += 1; return $0 }
            progress(Double(finished) / Double(count))
        }

        if let error = failure.value { throw error }
        let pages = outputs.value.compactMap { $0 }
        return SplitResult(
            folder: folder,
            files: pages.map(\.url),
            sizes: pages.map(\.size),
            compressedPages: pages.indices.filter { pages[$0].compressed }.map { $0 + 1 },
            overLimitPages: pages.indices.filter { !pages[$0].fits }.map { $0 + 1 }
        )
    }

    // MARK: - Merge / compress

    /// Joins all pages of `sources` (in order) into `output`, no larger than `limit` bytes.
    /// With a single source this is plain compression.
    static func combine(sources: [URL], output: URL, limit: Int, progress: (Double) -> Void) throws -> CombineResult {
        var refs: [PageRef] = []
        for (index, url) in sources.enumerated() {
            let doc = try validatedDocument(url)
            for page in 0..<doc.pageCount { refs.append(PageRef(doc: index, page: page)) }
        }
        let inputBytes = sources.reduce(0) { $0 + fileSize(of: $1) }

        func save(_ data: Data, recompressed: Bool) throws -> CombineResult {
            do {
                try data.write(to: output, options: .atomic)
            } catch {
                throw PDFReamError.writeFailed(output.lastPathComponent, error.localizedDescription)
            }
            progress(1)
            return CombineResult(output: output, pageCount: refs.count, bytes: data.count, inputBytes: inputBytes,
                                 recompressed: recompressed, fitsLimit: data.count <= limit)
        }

        if sources.count == 1, inputBytes <= limit {
            return try save(try read(sources[0]), recompressed: false)
        }
        guard let lossless = assemble(refs, sources, raster: nil) else { throw PDFReamError.assembleFailed }
        if lossless.count <= limit {
            return try save(lossless, recompressed: false)
        }
        progress(0.03)

        // Size of each page kept as is: light pages (text, vector) stay untouched when that is smaller.
        let unknownSize = 1 << 40
        let originalSizes = Locked([Int](repeating: unknownSize, count: refs.count))
        parallelFor(refs.count) { i in
            guard let doc = makeDocument(sources[refs[i].doc]), let page = doc.page(at: refs[i].page),
                  let data = losslessPageData(page) else { return }
            originalSizes.update { $0[i] = data.count }
        }
        let original = originalSizes.value

        // Every page is rendered at one shared quality level, so the document looks consistent.
        let expectedRenders = Double(refs.count * 5)
        let rendered = Locked(0)
        var levels: [Int: [Data?]] = [:]
        func pages(at level: Int) -> [Data?] {
            if let cached = levels[level] { return cached }
            let result = Locked([Data?](repeating: nil, count: refs.count))
            parallelFor(refs.count) { i in
                if let doc = makeDocument(sources[refs[i].doc]), let page = doc.page(at: refs[i].page),
                   let data = rasterPageData(page, ladder[level]), data.count < original[i] {
                    result.update { $0[i] = data }
                }
                let n = rendered.update { $0 += 1; return $0 }
                progress(min(0.95, 0.05 + 0.9 * Double(n) / expectedRenders))
            }
            levels[level] = result.value
            return result.value
        }
        func estimatedSize(_ pages: [Data?]) -> Int {
            zip(pages, original).reduce(0) { $0 + ($1.0?.count ?? $1.1) }
        }

        var low = 0, high = ladder.count - 1
        var best = ladder.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if estimatedSize(pages(at: mid)) <= limit {
                best = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        var level = best
        while true {
            guard let data = assemble(refs, sources, raster: pages(at: level)) else { throw PDFReamError.assembleFailed }
            if data.count <= limit || level == ladder.count - 1 {
                return try save(data, recompressed: true)
            }
            level += 1
        }
    }

    // MARK: - Page helpers

    struct PageRef {
        let doc: Int
        let page: Int
    }

    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw PDFReamError.cannotOpen(url.lastPathComponent)
        }
    }

    static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func validatedDocument(_ url: URL) throws -> PDFDocument {
        let name = url.lastPathComponent
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw PDFReamError.cannotOpen(name) }
        guard let doc = PDFDocument(url: url) else { throw PDFReamError.cannotOpen(name) }
        if doc.isLocked && !doc.unlock(withPassword: "") { throw PDFReamError.locked(name) }
        guard doc.pageCount > 0 else { throw PDFReamError.noPages(name) }
        return doc
    }

    /// PDFKit objects are not shared between threads: every task opens the file for itself.
    /// Opening by URL keeps memory flat — the file is mapped, not copied per worker.
    static func makeDocument(_ url: URL) -> PDFDocument? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if doc.isLocked && !doc.unlock(withPassword: "") { return nil }
        return doc
    }

    /// Page size as displayed, i.e. with /Rotate applied.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// The page on its own, without any recompression.
    static func losslessPageData(_ page: PDFPage) -> Data? {
        guard let copy = page.copy() as? PDFPage else { return nil }
        let doc = PDFDocument()
        doc.insert(copy, at: 0)
        return doc.dataRepresentation()
    }

    /// Highest-quality rendering that fits `limit`; if none does, the smallest one found.
    static func bestRaster(of page: PDFPage, limit: Int) -> (data: Data, fits: Bool)? {
        var cache: [Int: Data] = [:]
        var low = 0, high = ladder.count - 1
        var best: Int?
        while low <= high {
            let mid = (low + high) / 2
            guard let data = rasterPageData(page, ladder[mid]) else { return nil }
            cache[mid] = data
            if data.count <= limit {
                best = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        if let best { return (cache[best]!, true) }

        var smallest = cache[ladder.count - 1] ?? rasterPageData(page, ladder[ladder.count - 1])
        var dpi = ladder[ladder.count - 1].dpi
        while dpi > 10 {
            dpi *= 0.75
            guard let data = rasterPageData(page, RenderQuality(dpi: dpi, jpeg: 0.15)) else { break }
            if data.count <= limit { return (data, true) }
            if data.count < smallest?.count ?? .max { smallest = data }
        }
        return smallest.map { ($0, false) }
    }

    /// Renders the page (including annotations) to a JPEG and wraps it into a one-page PDF of the same size.
    static func rasterPageData(_ page: PDFPage, _ quality: RenderQuality) -> Data? {
        autoreleasepool {
            let size = displaySize(of: page)
            guard size.width >= 1, size.height >= 1 else { return nil }

            // Pages with odd huge dimensions are rendered as if they were at most 14 inches long.
            var scale = quality.dpi / 72
            let longSide = max(size.width, size.height)
            if longSide * scale > quality.dpi * 14 { scale = quality.dpi * 14 / longSide }
            let width = max(1, Int((size.width * scale).rounded()))
            let height = max(1, Int((size.height * scale).rounded()))

            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            bitmap.interpolationQuality = .high
            bitmap.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
            page.draw(with: .cropBox, to: bitmap)
            guard let image = bitmap.makeImage() else { return nil }

            let jpeg = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality.jpeg] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }

            // An image made from a JPEG provider is embedded into the PDF as is (DCTDecode), not re-encoded.
            let pdf = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil),
                  let provider = CGDataProvider(data: jpeg as CFData),
                  let jpegImage = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            context.beginPDFPage(nil)
            context.draw(jpegImage, in: mediaBox)
            context.endPDFPage()
            context.closePDF()
            return pdf as Data
        }
    }

    /// Builds one document from the referenced pages; a non-nil `raster[i]` replaces page i.
    static func assemble(_ refs: [PageRef], _ sources: [URL], raster: [Data?]?) -> Data? {
        let result = PDFDocument()
        var holders: [PDFDocument] = []
        var opened: [Int: PDFDocument] = [:]
        for (i, ref) in refs.enumerated() {
            let page: PDFPage?
            if let data = raster?[i] {
                guard let doc = PDFDocument(data: data) else { return nil }
                holders.append(doc)
                page = doc.page(at: 0)
            } else {
                if opened[ref.doc] == nil { opened[ref.doc] = makeDocument(sources[ref.doc]) }
                page = opened[ref.doc]?.page(at: ref.page)
            }
            guard let copy = page?.copy() as? PDFPage else { return nil }
            result.insert(copy, at: result.pageCount)
        }
        return withExtendedLifetime((holders, opened)) { result.dataRepresentation() }
    }

    // MARK: - Concurrency

    /// Runs `body` for 0..<count on a few threads (each page render holds a large bitmap in memory).
    static func parallelFor(_ count: Int, _ body: (Int) -> Void) {
        guard count > 0 else { return }
        // Each worker holds a full-page bitmap, so keep the number modest on small machines.
        let info = ProcessInfo.processInfo
        let byMemory = info.physicalMemory < 8 << 30 ? 2 : (info.physicalMemory < 16 << 30 ? 4 : 6)
        let override = info.environment["PDFREAM_WORKERS"].flatMap(Int.init)
        let workers = min(count, max(1, override ?? min(info.activeProcessorCount, byMemory)))
        let next = Locked(0)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                let index = next.update { value -> Int in
                    defer { value += 1 }
                    return value
                }
                if index >= count { break }
                autoreleasepool { body(index) }
            }
        }
    }
}

final class Locked<Value> {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func update<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
}
