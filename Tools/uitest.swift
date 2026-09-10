import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Drives the real AppModel (the code behind the window) without a human clicking.
@main
enum UITest {
    static let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
    static let work = URL(fileURLWithPath: CommandLine.arguments[2])
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0

    static func main() {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count > 2 else {
            print("usage: uitest <fixtures-dir> <work-dir>")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await runAll()
            print("\npassed: \(passed)   failed: \(failed)")
            exit(failed == 0 ? 0 : 1)
        }
        app.run()
    }

    // MARK: - Harness

    static func check(_ name: String, _ condition: Bool) {
        if condition { passed += 1; print("  ok   \(name)") }
        else { failed += 1; print("  FAIL \(name)") }
    }

    /// Let queued main-actor work run without waiting for a result.
    static func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    static func reset(_ model: AppModel) {
        model.queue.removeAll()
        model.status = nil
        AppModel.scriptedSaveURL = nil
        AppModel.scriptedDirectory = nil
        AppModel.scriptedCancel = false
        AppModel.panelRequests = 0
    }

    @MainActor
    static func waitForResult(_ model: AppModel, seconds: Double = 180) async -> Status? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !model.isWorking, let status = model.status { return status }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    @MainActor
    static func runAndWait(_ model: AppModel) async -> Status? {
        model.status = nil
        model.run()
        return await waitForResult(model)
    }

    /// A file drag the way Finder delivers it: a promise for a file URL.
    static func fileProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }

    @MainActor
    static func drop(_ urls: [URL], into model: AppModel) async {
        let providers = urls.map(fileProvider)
        let resolved: [URL] = await withCheckedContinuation { continuation in
            FileDrop.load(providers) { continuation.resume(returning: $0) }
        }
        model.handle(resolved)
    }

    static func pdfPageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }
    static func size(_ url: URL) -> Int { PDFEngine.fileSize(of: url) }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func pdfs(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func copyFixture(_ name: String, to destination: URL) -> URL {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: destination)
        return destination
    }

    // MARK: - Tests

    @MainActor
    static func runAll() async {
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: AppModel.scriptedURLFile)
        let model = AppModel.shared
        let scan20 = fixtures.appendingPathComponent("scan20.pdf")
        let rotated = fixtures.appendingPathComponent("rotated.pdf")
        let vector6 = fixtures.appendingPathComponent("vector6.pdf")

        print("== a drop only queues: no panel, no work, in every mode")
        for mode in Mode.allCases {
            reset(model)
            model.mode = mode
            await drop([scan20], into: model)
            await settle()
            check("\(mode.title): queued without a panel",
                  AppModel.panelRequests == 0 && !model.isWorking && model.queue.count == 1)
            check("\(mode.title): row carries pages and size",
                  model.queue.first?.pages == 20 && (model.queue.first?.bytes ?? 0) > 1_000_000)
        }

        print("== several files in one drop, and successive drops accumulate")
        reset(model)
        model.mode = .split
        await drop([vector6, scan20, rotated], into: model)
        check("three files land in one drop", model.queue.count == 3)
        check("sorted by name", model.queue.map(\.url.lastPathComponent) == ["rotated.pdf", "scan20.pdf", "vector6.pdf"])
        check("no panel for a multi-file drop", AppModel.panelRequests == 0)
        await drop([fixtures.appendingPathComponent("single.pdf")], into: model)
        check("second drop appends", model.queue.count == 4 && model.queue.last?.url.lastPathComponent == "single.pdf")
        check("earlier rows keep their place", model.queue.first?.url.lastPathComponent == "rotated.pdf")

        print("== split: one Run processes the whole queue")
        reset(model)
        model.mode = .split
        model.limitText = "2"
        let splitOut = work.appendingPathComponent("split-batch")
        try? FileManager.default.createDirectory(at: splitOut, withIntermediateDirectories: true)
        AppModel.scriptedDirectory = splitOut
        await drop([scan20, rotated, vector6], into: model)
        check("queue holds 3 before Run", model.queue.count == 3 && AppModel.panelRequests == 0)
        var status = await runAndWait(model)
        check("one destination panel for the batch", AppModel.panelRequests == 1)
        check("run succeeded", status?.kind == .success)
        let folders = ["scan20 (pages)", "rotated (pages)", "vector6 (pages)"].map { splitOut.appendingPathComponent($0) }
        check("a folder per source file", folders.allSatisfy { exists($0) })
        check("page counts per folder",
              pdfs(in: folders[0]).count == 20 && pdfs(in: folders[1]).count == 4 && pdfs(in: folders[2]).count == 6)
        check("every page file <= 2 MB",
              folders.flatMap { pdfs(in: $0) }.allSatisfy { size($0) <= 2_000_000 })
        check("every page file is one page",
              pdfs(in: folders[1]).allSatisfy { pdfPageCount($0) == 1 })
        check("queue emptied after a clean run", model.queue.isEmpty)
        print("     status: \(status?.text.replacingOccurrences(of: "\n", with: " | ") ?? "-")")

        print("== compress: one Run for the whole queue")
        reset(model)
        model.mode = .compress
        model.limitText = "5"
        let compressOut = work.appendingPathComponent("compress-batch")
        try? FileManager.default.createDirectory(at: compressOut, withIntermediateDirectories: true)
        AppModel.scriptedDirectory = compressOut
        await drop([scan20, rotated], into: model)
        status = await runAndWait(model)
        let compressed = ["scan20 (compressed).pdf", "rotated (compressed).pdf"].map { compressOut.appendingPathComponent($0) }
        check("compress succeeded", status?.kind == .success)
        check("one output per input", compressed.allSatisfy { exists($0) })
        check("each output <= 5 MB", compressed.allSatisfy { size($0) <= 5_000_000 })
        check("page counts preserved", pdfPageCount(compressed[0]) == 20 && pdfPageCount(compressed[1]) == 4)
        check("queue emptied", model.queue.isEmpty)

        print("== a single queued file uses the named panel")
        reset(model)
        model.mode = .split
        let namedFolder = work.appendingPathComponent("Named pages")
        AppModel.scriptedSaveURL = namedFolder
        await drop([rotated], into: model)
        status = await runAndWait(model)
        check("saved exactly where the named panel said", pdfs(in: namedFolder).count == 4)
        check("offers Open Folder", status?.actions.first?.title == "Open Folder")

        print("== merge: order follows the list")
        reset(model)
        model.mode = .merge
        model.limitText = "10"
        let mergedURL = work.appendingPathComponent("Merged.pdf")
        AppModel.scriptedSaveURL = mergedURL
        await drop([vector6, rotated], into: model)
        check("merge queue sorted by name", model.queue.map(\.url.lastPathComponent) == ["rotated.pdf", "vector6.pdf"])
        model.queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        check("row moved to the end", model.queue.last?.url.lastPathComponent == "rotated.pdf")
        status = await runAndWait(model)
        check("merge succeeded", status?.kind == .success)
        check("merged page count", pdfPageCount(mergedURL) == 10)
        check("merged file <= 10 MB", size(mergedURL) <= 10_000_000)
        if let merged = PDFDocument(url: mergedURL) {
            let firstText = merged.page(at: 0)?.string ?? ""
            check("reordered: vector pages first", firstText.contains("Vector page 1"))
        } else {
            check("reordered: vector pages first", false)
        }

        print("== Run with an empty queue does nothing")
        for mode in Mode.allCases {
            reset(model)
            model.mode = mode
            model.status = Status(kind: .success, text: "previous result")
            check("\(mode.title): canRun is false", !model.canRun)
            model.run()
            await settle()
            check("\(mode.title): no panel, no work, status kept",
                  AppModel.panelRequests == 0 && !model.isWorking && model.status?.text == "previous result")
        }

        print("== cancelling the panel keeps the queue")
        reset(model)
        model.mode = .split
        AppModel.scriptedCancel = true
        await drop([scan20, rotated], into: model)
        model.run()
        await settle()
        check("panel was requested", AppModel.panelRequests == 1)
        check("queue survives a cancel", model.queue.count == 2 && !model.isWorking)
        check("cancel is not an error", model.status == nil)
        AppModel.scriptedCancel = false
        AppModel.scriptedDirectory = work.appendingPathComponent("after-cancel")
        try? FileManager.default.createDirectory(at: AppModel.scriptedDirectory!, withIntermediateDirectories: true)
        status = await runAndWait(model)
        check("second Run goes through", status?.kind == .success && model.queue.isEmpty)

        print("== pressing Run twice starts one job")
        reset(model)
        model.mode = .split
        let doubleOut = work.appendingPathComponent("double-run")
        try? FileManager.default.createDirectory(at: doubleOut, withIntermediateDirectories: true)
        AppModel.scriptedDirectory = doubleOut
        await drop([scan20, rotated], into: model)
        model.status = nil
        model.run()
        model.run()
        status = await waitForResult(model)
        check("only one panel request", AppModel.panelRequests == 1)
        check("one set of outputs", pdfs(in: doubleOut.appendingPathComponent("rotated (pages)")).count == 4)

        print("== same base name from different folders")
        reset(model)
        model.mode = .split
        let a = copyFixture("rotated.pdf", to: work.appendingPathComponent("dirA/Scan.pdf"))
        let b = copyFixture("vector6.pdf", to: work.appendingPathComponent("dirB/Scan.pdf"))
        let sameOut = work.appendingPathComponent("same-name")
        try? FileManager.default.createDirectory(at: sameOut, withIntermediateDirectories: true)
        AppModel.scriptedDirectory = sameOut
        await drop([a, b], into: model)
        status = await runAndWait(model)
        check("both files produced their own folder",
              pdfs(in: sameOut.appendingPathComponent("Scan (pages)")).count > 0 &&
              pdfs(in: sameOut.appendingPathComponent("Scan (pages) 2")).count > 0)
        check("no pages lost to a collision",
              pdfs(in: sameOut.appendingPathComponent("Scan (pages)")).count
                + pdfs(in: sameOut.appendingPathComponent("Scan (pages) 2")).count == 10)

        print("== names that differ only by case are still two outputs")
        reset(model)
        model.mode = .compress
        model.limitText = "10"
        let lower = copyFixture("annotated.pdf", to: work.appendingPathComponent("caseA/scan.pdf"))
        let upper = copyFixture("rotated.pdf", to: work.appendingPathComponent("caseB/Scan.pdf"))
        let caseOut = work.appendingPathComponent("case-out")
        try? FileManager.default.createDirectory(at: caseOut, withIntermediateDirectories: true)
        AppModel.scriptedDirectory = caseOut
        await drop([lower, upper], into: model)
        check("both cases queued", model.queue.count == 2)
        status = await runAndWait(model)
        let caseFiles = pdfs(in: caseOut)
        check("two separate files on disk, nothing overwritten", caseFiles.count == 2)
        check("both documents survived intact",
              caseFiles.map { pdfPageCount($0) }.sorted() == [1, 4])
        check("run reported success", status?.kind == .success)

        print("== running the same batch twice does not overwrite")
        reset(model)
        model.mode = .split
        AppModel.scriptedDirectory = sameOut
        await drop([a, b], into: model)
        status = await runAndWait(model)
        check("a repeat batch is suffixed, not overwritten",
              exists(sameOut.appendingPathComponent("Scan (pages) 3")) &&
              exists(sameOut.appendingPathComponent("Scan (pages) 4")))
        check("the first run's output is untouched",
              pdfs(in: sameOut.appendingPathComponent("Scan (pages)")).count > 0)

        print("== bad files are rejected at drop time, in every mode")
        for mode in Mode.allCases {
            reset(model)
            model.mode = mode
            await drop([fixtures.appendingPathComponent("broken.pdf"), scan20], into: model)
            check("\(mode.title): only the good file queued", model.queue.count == 1)
            check("\(mode.title): warning names the bad file",
                  model.status?.kind == .warning && model.status?.text.contains("cannot be opened") == true)
            reset(model)
            model.mode = mode
            await drop([fixtures.appendingPathComponent("locked.pdf")], into: model)
            check("\(mode.title): password-protected refused",
                  model.queue.isEmpty && model.status?.text.contains("password-protected") == true)
            check("\(mode.title): still no panel", AppModel.panelRequests == 0)
        }

        print("== non-PDFs and folders")
        reset(model)
        model.mode = .merge
        await drop([fixtures.appendingPathComponent("notes.txt")], into: model)
        check("only a non-PDF: failure, nothing queued",
              model.queue.isEmpty && model.status?.kind == .failure)
        reset(model)
        await drop([splitOut.appendingPathComponent("scan20 (pages)"), fixtures.appendingPathComponent("notes.txt")], into: model)
        check("folder expands to its PDFs", model.queue.count == 20)
        check("skipped non-PDF is reported", model.status?.text.contains("Skipped non-PDF files: 1.") == true)

        print("== a file that disappears between drop and Run")
        reset(model)
        model.mode = .split
        let vanishing = copyFixture("rotated.pdf", to: work.appendingPathComponent("vanishing/Gone.pdf"))
        AppModel.scriptedDirectory = work.appendingPathComponent("vanishing")
        await drop([vanishing, vector6], into: model)
        try? FileManager.default.removeItem(at: vanishing)
        model.run()
        await settle()
        check("no panel, no job", AppModel.panelRequests == 0 && !model.isWorking)
        check("the vanished row is dropped", model.queue.count == 1)
        check("warning explains why", model.status?.text.contains("No longer available") == true)

        print("== failures inside a batch")
        reset(model)
        model.mode = .split
        let good = copyFixture("vector6.pdf", to: work.appendingPathComponent("partial/Good.pdf"))
        let bad = copyFixture("vector6.pdf", to: work.appendingPathComponent("partial/Bad.pdf"))
        let partialOut = work.appendingPathComponent("partial-out")
        try? FileManager.default.createDirectory(at: partialOut, withIntermediateDirectories: true)
        AppModel.scriptedDirectory = partialOut
        await drop([good, bad], into: model)
        try? Data("not a pdf any more".utf8).write(to: bad)
        status = await runAndWait(model)
        check("partial failure warns", status?.kind == .warning)
        check("the good file still produced output", pdfs(in: partialOut.appendingPathComponent("Good (pages)")).count == 6)
        check("queue kept after a failure", model.queue.count == 2)

        reset(model)
        model.mode = .compress
        AppModel.scriptedDirectory = partialOut
        let bad2 = copyFixture("vector6.pdf", to: work.appendingPathComponent("partial/Bad2.pdf"))
        let bad3 = copyFixture("vector6.pdf", to: work.appendingPathComponent("partial/Bad3.pdf"))
        await drop([bad2, bad3], into: model)
        try? Data("broken".utf8).write(to: bad2)
        try? Data("broken".utf8).write(to: bad3)
        status = await runAndWait(model)
        check("total failure reports failure", status?.kind == .failure)
        check("no actions offered on total failure", status?.actions.isEmpty == true)
        check("queue intact after total failure", model.queue.count == 2)

        print("== the queue survives mode switches")
        reset(model)
        model.mode = .split
        model.limitText = "1.5"
        await drop([scan20, rotated, vector6], into: model)
        let order = model.queue.map(\.url.lastPathComponent)
        model.mode = .merge
        check("rows kept switching to Merge", model.queue.map(\.url.lastPathComponent) == order)
        check("limit field follows the mode", model.limitText == "10")
        model.mode = .compress
        model.mode = .split
        check("rows kept after three switches", model.queue.map(\.url.lastPathComponent) == order)
        check("limit field switches back", model.limitText == "1.5")
        model.limitText = "2"

        print("== remove, clear, and reordering drive the run")
        reset(model)
        model.mode = .split
        let removeOut = work.appendingPathComponent("remove-out")
        try? FileManager.default.createDirectory(at: removeOut, withIntermediateDirectories: true)
        AppModel.scriptedDirectory = removeOut
        await drop([rotated, vector6], into: model)
        if let first = model.queue.first { model.removeFromQueue(first) }
        check("row removed", model.queue.count == 1)
        AppModel.scriptedDirectory = nil
        AppModel.scriptedSaveURL = removeOut.appendingPathComponent("vector6 (pages)")
        status = await runAndWait(model)
        check("only the kept file was processed",
              pdfs(in: removeOut.appendingPathComponent("vector6 (pages)")).count == 6 &&
              !exists(removeOut.appendingPathComponent("rotated (pages)")))
        reset(model)
        await drop([rotated, vector6], into: model)
        model.clearQueue()
        check("Clear empties the queue and the status", model.queue.isEmpty && model.status == nil)

        print("== Finder / Dock open queues instead of processing")
        reset(model)
        model.mode = .split
        let delegate = AppDelegate()
        delegate.application(NSApp, open: [scan20])
        await settle()
        check("opened file was queued", model.queue.count == 1 && AppModel.panelRequests == 0)
        check("nothing started", !model.isWorking)
        delegate.application(NSApp, open: [rotated])
        await settle()
        check("a second open appends", model.queue.count == 2)

        print("== input is refused while a job runs")
        reset(model)
        model.mode = .split
        let busyOut = work.appendingPathComponent("busy-out")
        try? FileManager.default.createDirectory(at: busyOut, withIntermediateDirectories: true)
        AppModel.scriptedDirectory = busyOut
        await drop([fixtures.appendingPathComponent("big60.pdf"), scan20], into: model)
        model.status = nil
        model.run()
        await settle(0.4)
        check("job is running", model.isWorking)
        let queuedDuringRun = model.queue.count
        await drop([vector6], into: model)
        delegate.application(NSApp, open: [vector6])
        await settle()
        check("drops during a run are refused", model.queue.count == queuedDuringRun)
        status = await waitForResult(model)
        check("the run itself finished cleanly", status?.kind == .success)
        check("late files are not in the output", !exists(busyOut.appendingPathComponent("vector6 (pages)")))

        print("== a status stays until the next run starts")
        reset(model)
        model.mode = .split
        model.status = Status(kind: .success, text: "earlier result", actions: [StatusAction(title: "Open Folder") {}])
        await drop([vector6], into: model)
        check("dropping keeps the previous result on screen",
              model.status?.text == "earlier result" && model.status?.actions.isEmpty == false)

        print("== settings persist")
        model.mode = .split
        model.limitText = "3.5"
        check("page limit written through to preferences", AppModel.defaults.double(forKey: "pageLimitMB") == 3.5)
        model.limitText = "2"
        check("and updated again", AppModel.defaults.double(forKey: "pageLimitMB") == 2)
    }
}
