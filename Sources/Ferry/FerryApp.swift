import SwiftUI
import AppKit

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar item and every window are AppKit-managed (see StatusItemController and
    // WindowPresenter); this empty scene only satisfies SwiftUI's App protocol.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if PreviewRender.runIfRequested() { exit(0) }
        let model = AppModel.shared
        model.start()
        statusItem = StatusItemController(model: model)
        // `--open send|wireless|browse` opens a window directly (used for testing).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            switch args[i + 1] {
            case "wireless": model.showWireless()
            case "browse": model.showPhoneBrowser()
            case "menu": statusItem?.togglePopover()
            case "send": model.beginSend(args.dropFirst(i + 2).map { URL(fileURLWithPath: $0) })
            case "offer":
                model.web.offer(args.dropFirst(i + 2).map { URL(fileURLWithPath: $0) })
                model.showWireless()
            default: break
            }
        }
    }

    /// Finder's "Open With → Ferry" and dropping files on the app's icon land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { AppModel.shared.beginSend(files) }
    }
}
