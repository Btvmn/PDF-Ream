import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
