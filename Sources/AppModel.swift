import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum Mode: Int, CaseIterable, Identifiable {
    case split, merge, compress

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .split: return "Split"
        case .merge: return "Merge"
        case .compress: return "Compress"
        }
    }

    var hint: String {
        switch self {
        case .split: return "Drop PDFs, then press Split: every page becomes its own PDF. Pages heavier than the limit are compressed, the rest are copied untouched."
        case .merge: return "Drop PDFs, then press Merge: several files become one. Sorted by name; drag the rows to change the order."
        case .compress: return "Drop PDFs, then press Compress: each file is shrunk to the size you set. All pages stay in one file."
        }
    }

    /// The action button says what will happen, because it is the last thing read before the save panel opens.
    var actionTitle: String { title }

    var progressLabel: String {
        switch self {
        case .split: return "Splitting…"
        case .merge: return "Merging…"
        case .compress: return "Compressing…"
        }
    }

    var runHelp: String {
        switch self {
        case .split: return "Choose where to save, then split every page"
        case .merge: return "Choose where to save, then merge the list"
        case .compress: return "Choose where to save, then compress"
        }
    }

    /// Row order drives processing everywhere, but only merge turns it into page order.
    var showsOrder: Bool { self == .merge }

    var icon: String {
        switch self {
        case .split: return "scissors"
        case .merge: return "doc.on.doc"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        }
    }
}

struct StatusAction: Identifiable {
    let id = UUID()
    let title: String
    let run: () -> Void
}

struct Status {
    enum Kind {
        case success, warning, failure

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: return .green
            case .warning: return .orange
            case .failure: return .red
            }
        }
    }

    let kind: Kind
    let text: String
    var actions: [StatusAction] = []
}

struct QueuedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let pages: Int
    let bytes: Int
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var mode: Mode = .split {
        didSet {
            guard mode != oldValue else { return }
            status = nil
            syncLimitText()
        }
    }
    /// Files wait here until the action button is pressed; dropping never starts a job.
    @Published var queue: [QueuedFile] = []
    /// A modal panel pumps the runloop, so guard against drops and a second Run landing mid-panel.
    @Published var isPresentingPanel = false
    /// While a job runs the window cannot be closed: closing the last window quits the app,
    /// and that would stop the job halfway. Quitting asks first (see AppDelegate).
    @Published var isWorking = false {
        didSet { Self.setWindowsClosable(!isWorking) }
    }
    @Published var progress: Double = 0
    @Published var progressLabel = ""
    @Published var status: Status?
    @Published var dropTargeted = false

    @Published var pageLimitMB: Double = 2 {
        didSet { Self.defaults.set(pageLimitMB, forKey: "pageLimitMB") }
    }
    @Published var fileLimitMB: Double = 10 {
        didSet { Self.defaults.set(fileLimitMB, forKey: "fileLimitMB") }
    }
    /// What the size field shows; parsed on every keystroke so a drop right after typing uses the new value.
    /// Out-of-range numbers are clamped; the field shows the clamped value on Return and on Run.
    @Published var limitText = "" {
        didSet {
            guard limitText != oldValue, let parsed = Self.parseNumber(limitText), parsed.isFinite, parsed > 0 else { return }
            setLimit(min(max(parsed, Self.limitRange.lowerBound), Self.limitRange.upperBound))
        }
    }

    nonisolated static let limitRange: ClosedRange<Double> = 0.1...2000

    #if UITEST
    /// Test runs keep their preferences in a file of their own in the per-user temporary folder
    /// (a suite named by an absolute path), so they never touch ~/Library/Preferences.
    static let defaults = UserDefaults(suiteName: AppModel.testDefaultsName) ?? .standard
    nonisolated static let testDefaultsName = NSTemporaryDirectory() + "pdfream-uitest-defaults"
    #else
    static let defaults = UserDefaults.standard
    #endif

    init() {
        let defaults = Self.defaults
        pageLimitMB = Self.validLimit(defaults.object(forKey: "pageLimitMB") as? Double) ?? 2
        fileLimitMB = Self.validLimit(defaults.object(forKey: "fileLimitMB") as? Double) ?? 10
        limitText = Self.formatNumber(pageLimitMB)
    }

    /// A stored limit is used only if it is a sane number; anything else falls back to the default.
    nonisolated static func validLimit(_ value: Double?) -> Double? {
        guard let value, value.isFinite, limitRange.contains(value) else { return nil }
        return value
    }

    private static func setWindowsClosable(_ closable: Bool) {
        guard let app = NSApp else { return }
        for window in app.windows where window.canBecomeMain {
            window.standardWindowButton(.closeButton)?.isEnabled = closable
        }
    }

    var activeLimitMB: Double { mode == .split ? pageLimitMB : fileLimitMB }

    var isBusy: Bool { isWorking || isPresentingPanel }

    var canRun: Bool { !isBusy && !queue.isEmpty }

    func setLimit(_ value: Double) {
        if mode == .split { pageLimitMB = value } else { fileLimitMB = value }
    }

    /// Called when the field is not the source of the change (mode switch, stepper).
    func syncLimitText() {
        let text = Self.formatNumber(activeLimitMB)
        if text != limitText { limitText = text }
    }

    nonisolated static func parseNumber(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    nonisolated static func formatNumber(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Input

    /// Dropped or chosen files only ever land in the queue — the destination is asked for in `run()`.
    func handle(_ urls: [URL], at index: Int? = nil) {
        guard !isBusy else { NSSound.beep(); return }
        let (pdfs, skipped) = Self.collectPDFs(urls)
        guard !pdfs.isEmpty else {
            status = Status(kind: .failure, text: skipped > 0 ? "That is not a PDF. Drop files with a .pdf extension." : "No PDF files found.")
            return
        }
        enqueue(pdfs, at: index, note: skipped > 0 ? "Skipped non-PDF files: \(skipped)." : nil)
    }

    func chooseFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose PDFs"
        panel.prompt = "Choose"
        isPresentingPanel = true
        let response = panel.runModal()
        isPresentingPanel = false
        guard response == .OK else { return }
        handle(panel.urls)
    }

    func enqueue(_ urls: [URL], at index: Int?, note: String? = nil) {
        var added: [QueuedFile] = []
        var rejected: [String] = []
        var restricted: [String] = []
        for url in urls {
            guard let doc = PDFDocument(url: url) else {
                rejected.append("“\(url.lastPathComponent)” cannot be opened")
                continue
            }
            if doc.isLocked && !doc.unlock(withPassword: "") {
                rejected.append("“\(url.lastPathComponent)” is password-protected")
                continue
            }
            guard doc.pageCount > 0 else {
                rejected.append("“\(url.lastPathComponent)” has no pages")
                continue
            }
            // Opens without a password but carries an owner password: the rewritten files will not keep its limits.
            if doc.isEncrypted && (!doc.allowsPrinting || !doc.allowsCopying) {
                restricted.append("“\(url.lastPathComponent)”")
            }
            added.append(QueuedFile(url: url, pages: doc.pageCount, bytes: PDFEngine.fileSize(of: url)))
        }
        let position = min(max(index ?? queue.count, 0), queue.count)
        queue.insert(contentsOf: added, at: position)

        // Separate sentences: rejected files, restricted files and skipped non-PDFs are different matters.
        var parts: [String] = []
        if !rejected.isEmpty { parts.append("Not added: " + rejected.joined(separator: ", ") + ".") }
        if !restricted.isEmpty {
            parts.append("Printing and copying restrictions in " + restricted.joined(separator: ", ")
                         + " are not kept in files PDF Ream rewrites.")
        }
        if let note { parts.append(note) }
        if !parts.isEmpty { status = Status(kind: .warning, text: parts.joined(separator: " ")) }
    }

    func removeFromQueue(_ item: QueuedFile) {
        queue.removeAll { $0.id == item.id }
    }

    func clearQueue() {
        queue.removeAll()
        status = nil
    }

    // MARK: - Actions

    private func runSplit(_ files: [URL]) {
        /// `replacing`: an existing folder the save panel was told to replace. The pages go into a
        /// sibling folder first, and the swap happens only once they are all written.
        var jobs: [(source: URL, folder: URL, replacing: URL?)] = []
        if files.count == 1 {
            let source = files[0]
            guard let folder = chooseFolderURL(name: "\(source.deletingPathExtension().lastPathComponent) (pages)",
                                               near: source) else { return }
            if let problem = Self.replacementProblem(folder, holding: source) {
                status = Status(kind: .failure, text: problem)
                return
            }
            if FileManager.default.fileExists(atPath: folder.path) {
                var taken = Set<String>()
                let staging = Self.uniqueURL(folder.deletingLastPathComponent()
                    .appendingPathComponent("\(folder.lastPathComponent) (in progress)"), isFolder: true, taken: &taken)
                jobs = [(source, staging, folder)]
            } else {
                jobs = [(source, folder, nil)]
            }
        } else {
            guard let directory = chooseDirectory(near: files[0],
                                                  message: "Each file gets its own folder of pages.")
            else { return }
            var taken = Set<String>()
            jobs = files.map { source in
                (source, Self.uniqueURL(directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) (pages)"),
                                        isFolder: true, taken: &taken), nil)
            }
        }

        let limit = Self.bytes(pageLimitMB)
        let limitText = Self.formatSize(limit)
        begin(Mode.split.progressLabel)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lines: [String] = []
            var errors: [String] = []
            var folders: [URL] = []
            var processed: [URL] = []
            var warning = false
            for (index, job) in jobs.enumerated() {
                do {
                    let result = try PDFEngine.split(source: job.source, into: job.folder, pageLimit: limit) { value in
                        self?.report((Double(index) + value) / Double(jobs.count))
                    }
                    var folder = result.folder
                    if let target = job.replacing {
                        do {
                            try Self.moveToTrash(target)
                            try FileManager.default.moveItem(at: job.folder, to: target)
                            folder = target
                        } catch {
                            errors.append("Could not replace “\(target.lastPathComponent)”: \(error.localizedDescription) "
                                          + "The new pages are in “\(job.folder.lastPathComponent)”.")
                        }
                    }
                    folders.append(folder)
                    processed.append(job.source)
                    let largest = result.sizes.max() ?? 0
                    var line = "\(Self.plural(result.files.count, "page", "pages")) → “\(folder.lastPathComponent)”"
                    if jobs.count > 1 { line = "“\(job.source.lastPathComponent)”: " + line }
                    lines.append(line)
                    if jobs.count == 1 {
                        // Detail lines only for a single file: a 20-file batch would bury the window.
                        if !result.compressedPages.isEmpty {
                            lines.append("Compressed pages: \(result.compressedPages.count). Largest file: \(Self.formatSize(largest)).")
                        } else if result.overLimitPages.isEmpty {
                            lines.append("Every page was already under \(limitText) — copied without recompression.")
                        }
                    }
                    if !result.overLimitPages.isEmpty {
                        warning = true
                        let pages = result.overLimitPages.map(String.init).joined(separator: ", ")
                        lines.append("Could not fit within \(limitText): pages \(pages) — saved as small as they would go.")
                    }
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            let reveal = folders
            let done = processed
            Task { @MainActor in
                self?.finish(lines: lines, errors: errors, warning: warning, processed: done,
                             actions: reveal.isEmpty ? [] : [
                                StatusAction(title: reveal.count == 1 ? "Open Folder" : "Show in Finder") {
                                    if reveal.count == 1 {
                                        NSWorkspace.shared.open(reveal[0])
                                    } else {
                                        NSWorkspace.shared.activateFileViewerSelecting(reveal)
                                    }
                                }
                             ])
            }
        }
    }

    private func runCompress(_ files: [URL]) {
        var jobs: [(source: URL, output: URL)] = []
        if files.count == 1 {
            let source = files[0]
            guard let output = chooseSaveURL(name: "\(source.deletingPathExtension().lastPathComponent) (compressed).pdf",
                                             near: source, title: "Where to save the compressed PDF") else { return }
            jobs = [(source, output)]
        } else {
            guard let directory = chooseDirectory(near: files[0], message: "Each file is compressed separately.") else { return }
            var taken = Set<String>()
            jobs = files.map { source in
                (source, Self.uniqueURL(directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) (compressed).pdf"), taken: &taken))
            }
        }
        execute(jobs: jobs.map { (sources: [$0.source], output: $0.output) },
                label: Mode.compress.progressLabel, combinesSources: false)
    }

    /// The action button: this is the only place that asks for a destination and starts work.
    func run() {
        guard canRun else { return }
        syncLimitText()

        // The queue may have been staged long ago; a file can be gone by now.
        let missing = queue.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        if !missing.isEmpty {
            let names = missing.map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", ")
            queue.removeAll { item in missing.contains { $0.id == item.id } }
            status = Status(kind: .warning, text: "No longer available and removed from the list: \(names).")
            return
        }

        let files = queue.map(\.url)
        switch mode {
        case .split: runSplit(files)
        case .compress: runCompress(files)
        case .merge: runMerge(files)
        }
    }

    private func runMerge(_ sources: [URL]) {
        guard let output = chooseSaveURL(name: "Merged.pdf", near: sources[0], title: "Where to save the merged PDF")
        else { return }
        execute(jobs: [(sources: sources, output: output)], label: Mode.merge.progressLabel, combinesSources: true)
    }

    private func execute(jobs: [(sources: [URL], output: URL)], label: String, combinesSources: Bool) {
        let limit = Self.bytes(fileLimitMB)
        let limitText = Self.formatSize(limit)
        begin(label)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lines: [String] = []
            var errors: [String] = []
            var outputs: [URL] = []
            var processed: [URL] = []
            var warning = false
            for (index, job) in jobs.enumerated() {
                do {
                    let result = try PDFEngine.combine(sources: job.sources, output: job.output, limit: limit) { value in
                        self?.report((Double(index) + value) / Double(jobs.count))
                    }
                    outputs.append(result.output)
                    processed += job.sources
                    let name = "“\(result.output.lastPathComponent)”"
                    if combinesSources {
                        lines.append("\(Self.plural(job.sources.count, "file", "files")) → \(name): \(Self.plural(result.pageCount, "page", "pages")), \(Self.formatSize(result.bytes)).")
                    } else {
                        lines.append("\(name): \(Self.formatSize(result.inputBytes)) → \(Self.formatSize(result.bytes)).")
                    }
                    if result.fitsLimit && !result.recompressed {
                        lines.append("Already within \(limitText) — nothing was recompressed.")
                    }
                    if !result.fitsLimit {
                        warning = true
                        lines.append(result.recompressed
                            ? "Even at the lowest quality it does not fit within \(limitText)."
                            : "It does not fit within \(limitText), and recompressing would not make it smaller, so the pages were kept as they are.")
                    }
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            let saved = outputs
            let done = processed
            Task { @MainActor in
                var actions: [StatusAction] = []
                if saved.count == 1 {
                    actions.append(StatusAction(title: "Open") { NSWorkspace.shared.open(saved[0]) })
                }
                if !saved.isEmpty {
                    actions.append(StatusAction(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(saved) })
                }
                self?.finish(lines: lines, errors: errors, warning: warning, processed: done, actions: actions)
            }
        }
    }

    // MARK: - Progress plumbing

    private func begin(_ label: String) {
        isWorking = true
        progress = 0
        progressLabel = label
        status = nil
    }

    nonisolated private func report(_ value: Double) {
        Task { @MainActor in
            if value > self.progress { self.progress = min(value, 1) }
        }
    }

    /// Files that were processed leave the queue; the ones that failed stay, so a second press
    /// retries only them instead of redoing the whole batch.
    private func finish(lines: [String], errors: [String], warning: Bool, processed: [URL], actions: [StatusAction]) {
        isWorking = false
        progress = 1
        let done = Set(processed)
        queue.removeAll { done.contains($0.url) }
        var text = lines.joined(separator: "\n")
        if !errors.isEmpty {
            let problems = errors.joined(separator: "\n")
            text = text.isEmpty ? problems : text + "\n" + problems
        }
        let kind: Status.Kind = lines.isEmpty ? .failure : (warning || !errors.isEmpty ? .warning : .success)
        let prefix = kind == .success ? "Done! " : ""
        status = Status(kind: kind, text: prefix + text, actions: lines.isEmpty ? [] : actions)
    }

    // MARK: - Panels

    #if UITEST
    /// Test builds answer the save panels from a script instead of showing them.
    nonisolated(unsafe) static var scriptedSaveURL: URL?
    nonisolated(unsafe) static var scriptedDirectory: URL?
    /// How many times a destination panel was requested — lets a test prove a drop opened none.
    nonisolated(unsafe) static var panelRequests = 0
    /// Makes a scripted panel behave as if the user pressed Cancel.
    nonisolated(unsafe) static var scriptedCancel = false

    /// Drops the test preferences and their file once a test run is over.
    static func removeTestDefaults() {
        defaults.removePersistentDomain(forName: testDefaultsName)
        defaults.synchronize()
        try? FileManager.default.removeItem(atPath: testDefaultsName + ".plist")
    }

    /// Runs while a scripted panel is "open", so a test can try to drop files or press Run behind it.
    nonisolated(unsafe) static var duringPanel: (@MainActor () -> Void)?
    /// Test runs move replaced folders here instead of into the user's Trash.
    nonisolated(unsafe) static var scriptedTrash: URL?

    /// Lets a test drive an app launched by Finder, which cannot set properties in-process.
    /// NSTemporaryDirectory() is per-user, unlike a shared /tmp path.
    nonisolated static let scriptedURLFile = ProcessInfo.processInfo.environment["PDFREAM_UITEST_SAVE"]
        ?? NSTemporaryDirectory() + "pdfream-uitest-save.txt"

    static func scriptedURLFromFile() -> URL? {
        guard let text = try? String(contentsOfFile: Self.scriptedURLFile, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Stands in for a modal panel: the window is busy for as long as it is "open".
    private func scriptedPanel(_ answer: @autoclosure () -> URL?) -> URL? {
        Self.panelRequests += 1
        isPresentingPanel = true
        defer { isPresentingPanel = false }
        Self.duringPanel?()
        return Self.scriptedCancel ? nil : answer()
    }
    #endif

    /// The save panel has already asked "Replace?". Replacing a folder of pages means starting
    /// afresh: once the new pages are complete the old folder goes to the Trash, instead of having
    /// new pages mixed into it. Typed over the source itself, or over a folder that holds it, the
    /// answer is no — that would send the file being split to the Trash.
    nonisolated static func replacementProblem(_ folder: URL, holding source: URL) -> String? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let target = folder.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
        let original = source.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
        if original == target || original.hasPrefix(target + "/") {
            return "“\(folder.lastPathComponent)” is or contains the file being split, so it cannot be replaced. Choose another name."
        }
        return nil
    }

    nonisolated static func moveToTrash(_ url: URL) throws {
        #if UITEST
        if let bin = scriptedTrash {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            var taken = Set<String>()
            let destination = uniqueURL(bin.appendingPathComponent(url.lastPathComponent), isFolder: true, taken: &taken)
            try FileManager.default.moveItem(at: url, to: destination)
            return
        }
        #endif
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Save panel whose file name becomes a new folder for the pages.
    private func chooseFolderURL(name: String, near source: URL) -> URL? {
        #if UITEST
        return scriptedPanel(Self.scriptedSaveURL ?? Self.scriptedURLFromFile())
        #else
        isPresentingPanel = true
        defer { isPresentingPanel = false }
        let panel = NSSavePanel()
        panel.title = "Where to save the pages"
        panel.message = "A folder will be created with one PDF per page."
        panel.nameFieldLabel = "Folder:"
        panel.nameFieldStringValue = name
        panel.directoryURL = source.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.prompt = "Save"
        return panel.runModal() == .OK ? panel.url : nil
        #endif
    }

    private func chooseSaveURL(name: String, near source: URL, title: String) -> URL? {
        #if UITEST
        return scriptedPanel(Self.scriptedSaveURL ?? Self.scriptedURLFromFile())
        #else
        isPresentingPanel = true
        defer { isPresentingPanel = false }
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name
        panel.directoryURL = source.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.prompt = "Save"
        return panel.runModal() == .OK ? panel.url : nil
        #endif
    }

    private func chooseDirectory(near source: URL, message: String) -> URL? {
        #if UITEST
        return scriptedPanel(Self.scriptedDirectory ?? Self.scriptedURLFromFile())
        #else
        isPresentingPanel = true
        defer { isPresentingPanel = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Save Here"
        panel.directoryURL = source.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
        #endif
    }

    // MARK: - Helpers

    nonisolated static func bytes(_ megabytes: Double) -> Int {
        max(20_000, Int(megabytes * 1_000_000))
    }

    nonisolated static func collectPDFs(_ urls: [URL]) -> ([URL], Int) {
        var pdfs: [URL] = []
        var skipped = 0
        let manager = FileManager.default
        for dropped in urls {
            // A Finder alias or a symbolic link counts as the file or folder it points to.
            let url = (try? URL(resolvingAliasFileAt: dropped)) ?? dropped
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                skipped += 1
                continue
            }
            if isDirectory.boolValue {
                let folder = url.resolvingSymlinksInPath()
                let contents = manager.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                    .compactMap { $0 as? URL }
                    .filter { $0.pathExtension.lowercased() == "pdf" } ?? []
                pdfs += contents.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if url.pathExtension.lowercased() == "pdf" {
                pdfs.append(url)
            } else {
                skipped += 1
            }
        }
        // Finder hands over a drag in arbitrary order; "Scan 2" must still land before "Scan 10".
        pdfs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (pdfs, skipped)
    }

    /// A name is free only if it is neither on disk nor already planned for this batch —
    /// two folders can each hold a "Scan.pdf".
    ///
    /// Reservations are matched the way the volume matches names: Mac disks are normally
    /// case- and normalization-insensitive, so "scan.pdf" and "Scan.pdf" would otherwise be
    /// planned as two outputs that are one file on disk, and the second would silently
    /// overwrite the first while the report claimed both were saved.
    nonisolated static func uniqueURL(_ url: URL, isFolder: Bool = false, taken: inout Set<String>) -> URL {
        let manager = FileManager.default
        func key(_ candidate: URL) -> String {
            candidate.path.precomposedStringWithCanonicalMapping.lowercased()
        }
        func isFree(_ candidate: URL) -> Bool {
            !manager.fileExists(atPath: candidate.path) && !taken.contains(key(candidate))
        }
        if isFree(url) {
            taken.insert(key(url))
            return url
        }
        // A folder such as "Scan 2024.01.15 (pages)" has no extension to keep apart from the number.
        let ext = isFolder ? "" : url.pathExtension
        let base = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        func named(_ tail: String) -> URL {
            folder.appendingPathComponent(ext.isEmpty ? "\(base) \(tail)" : "\(base) \(tail).\(ext)")
        }
        for suffix in 2...9999 {
            let candidate = named(String(suffix))
            if isFree(candidate) {
                taken.insert(key(candidate))
                return candidate
            }
        }
        // Out of numbers: a random tail still never lands on an existing name.
        let candidate = named(UUID().uuidString)
        taken.insert(key(candidate))
        return candidate
    }

    nonisolated static func formatSize(_ bytes: Int) -> String {
        if bytes < 1_000_000 {
            return "\(max(1, bytes / 1000)) KB"
        }
        let megabytes = Double(bytes) / 1_000_000
        let text = megabytes < 100 ? String(format: "%.2f", floor(megabytes * 100) / 100) : String(format: "%.0f", megabytes)
        return text + " MB"
    }

    nonisolated static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
