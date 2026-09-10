import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// There is no cancel button, so quitting mid-job would silently leave half a folder of pages behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isWorking else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "PDF Ream is still working"
        alert.informativeText = "Quitting now stops the job, and the files it was writing will be incomplete."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Files dropped on the Dock icon or opened from Finder are queued, never processed:
    /// bring the window forward so the staged files are visible.
    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            AppModel.shared.handle(urls)
            if let window = NSApp.windows.first(where: \.canBecomeMain) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
