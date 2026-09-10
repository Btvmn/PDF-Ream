import SwiftUI
import AppKit

@main
struct PDFReamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("PDF Ream", id: "main") {
            ContentView(model: AppModel.shared)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Files…") { AppModel.shared.chooseFiles() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {}
        }
    }
}
