import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders the real window content offscreen, so the layout can be inspected without a screen.
@main
enum Snapshot {
    static let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
    static let output = URL(fileURLWithPath: CommandLine.arguments[2])

    static func main() {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count > 2 else {
            print("usage: snapshot <fixtures-dir> <png-out-dir>")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let model = AppModel.shared

            model.mode = .split
            model.limitText = "2"
            await shoot(model, name: "1-split")

            model.mode = .merge
            model.limitText = "10"
            model.status = nil
            let pages = (try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "pdf" && !$0.lastPathComponent.contains("broken") && !$0.lastPathComponent.contains("locked") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []
            model.enqueue(Array(pages.prefix(5)), at: nil)
            model.status = nil
            await shoot(model, name: "2-merge")

            model.mode = .split
            await shoot(model, name: "6-split-queue")

            model.mode = .merge
            model.isWorking = true
            model.progress = 0.42
            model.progressLabel = "Merging…"
            await shoot(model, name: "3-progress")
            model.isWorking = false

            model.mode = .split
            model.queue.removeAll()
            model.status = Status(kind: .success,
                                  text: "Done! 20 pages → “Notes Scan (pages)”\nCompressed pages: 15. Largest file: 1.95 MB.",
                                  actions: [StatusAction(title: "Open Folder") {}])
            await shoot(model, name: "4-done")

            model.status = Status(kind: .failure, text: "“Contract.pdf”: the file is password-protected.")
            await shoot(model, name: "5-error")

            model.status = nil
            model.mode = .split
            model.enqueue([fixtures.appendingPathComponent("scan20.pdf")], at: nil)
            model.status = nil
            await shoot(model, name: "7-split-dark", appearance: .darkAqua)

            // The README pictures: real-looking names over the fixtures (hard links, no copies).
            model.queue.removeAll()
            model.status = nil
            model.mode = .split
            model.limitText = "2"
            let named = FileManager.default.temporaryDirectory.appendingPathComponent("pdfream-readme-\(getpid())")
            try? FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
            var shown: [URL] = []
            for (name, fixture) in [("Notes Scan.pdf", "scan20.pdf"), ("Lease Agreement.pdf", "rotated.pdf"), ("Passport.pdf", "single.pdf")] {
                let link = named.appendingPathComponent(name)
                let source = fixtures.appendingPathComponent(fixture)
                if (try? FileManager.default.linkItem(at: source, to: link)) == nil {
                    try? FileManager.default.copyItem(at: source, to: link)
                }
                shown.append(link)
            }
            model.enqueue(shown, at: nil)
            model.status = nil
            await shoot(model, name: "readme-light")
            await shoot(model, name: "readme-dark", appearance: .darkAqua)
            try? FileManager.default.removeItem(at: named)

            // Built with -DUITEST, so preferences went to the test domain: leave nothing behind.
            AppModel.removeTestDefaults()
            exit(0)
        }
        app.run()
    }



    @MainActor
    static func shoot(_ model: AppModel, name: String, appearance: NSAppearance.Name = .aqua,
                      size: NSSize = NSSize(width: 560, height: 560)) async {
        // A real window: SwiftUI needs one to lay out AppKit-backed pieces such as List.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "PDF Ream"
        window.appearance = NSAppearance(named: appearance)
        // An offscreen window is never the active one; draw controls as in the frontmost window
        // (accent-coloured action button), which is how people see the app.
        let hosting = NSHostingView(rootView: ContentView(model: model).environment(\.controlActiveState, .key))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFront(nil)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Layer tree capture: SwiftUI draws into CALayers, which cacheDisplay(in:) misses.
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let background = appearance == .darkAqua ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.96, alpha: 1)
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: scale, y: -scale)
            if let layer = hosting.layer {
                layer.render(in: ctx)
            }
            if let image = ctx.makeImage() {
                let rep = NSBitmapImageRep(cgImage: image)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: output.appendingPathComponent("\(name).png"))
                    print("wrote \(name).png  \(width)x\(height)")
                }
            }
        }
        window.orderOut(nil)
    }
}
