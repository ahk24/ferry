import AppKit
import SwiftUI
import Network
import FerryCore

/// `Ferry --render-previews <dir>` draws every window with sample data to PNGs and quits.
/// It uses real AppKit controls in an off-screen window, so what you see is what ships.
@MainActor
enum PreviewRender {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-previews"), flag + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = AppModel()
        func snap(_ direction: TransferSnapshot.Direction, _ peer: String, _ items: [String], _ total: Int64,
                  _ phase: TransferSnapshot.Phase, done: Int64 = 0, pin: String? = nil) -> TransferSnapshot {
            var s = TransferSnapshot(id: UUID(), direction: direction, peerName: peer)
            s.items = items; s.totalBytes = total; s.bytesDone = done; s.phase = phase; s.pin = pin
            if phase == .done && direction == .incoming { s.savedFiles = [URL(fileURLWithPath: "/tmp/\(items[0])")] }
            return s
        }
        let phone = "Samsung SM-A546B"
        let asking = snap(.incoming, "Galaxy A54", ["PXL_20261125_093012.jpg", "Boarding pass.pdf"], 12_400_000, .awaitingYourAccept, pin: "4821")
        let copying = snap(.incoming, phone, ["Camera"], 2_410_000_000, .transferring, done: 1_300_000_000)
        let uploaded = snap(.incoming, "Phone (browser)", ["IMG_2026.heic", "notes.pdf"], 5_100_000, .done)
        let sent = snap(.outgoing, phone, ["thesis-draft-v7.pdf", "figures"], 9_800_000, .done)
        let files = [URL(fileURLWithPath: "/tmp/thesis-draft-v7.pdf"), URL(fileURLWithPath: "/tmp/figures")]
        let qr = QRCode.image(for: "https://quickshare.google/qrcode#key=AAACexample")
        let offered = [
            WebShare.OfferedFile(id: "1", url: URL(fileURLWithPath: "/tmp/thesis-draft-v7.pdf"), folder: "", size: 2_300_000),
            WebShare.OfferedFile(id: "2", url: URL(fileURLWithPath: "/tmp/fig1.png"), folder: "figures", size: 640_000),
            WebShare.OfferedFile(id: "3", url: URL(fileURLWithPath: "/tmp/fig2.png"), folder: "figures", size: 720_000),
        ]

        model.loadPreviewState(transfers: [copying, uploaded, sent], peers: [], session: nil, cable: .ready(phone))
        render(MenuContentView(model: model), "menu-cable-ready")
        model.loadPreviewState(transfers: [], peers: [], session: nil, cable: .none)
        render(MenuContentView(model: model), "menu-no-cable")

        model.loadPreviewState(transfers: [], peers: [], session: SendSession(files: files, quickShareQR: qr), cable: .ready(phone))
        render(SendView(model: model), "send-cable-ready")
        model.loadPreviewState(transfers: [], peers: [], session: SendSession(files: []), cable: .ready(phone))
        render(SendView(model: model), "send-empty")
        model.loadPreviewState(transfers: [], peers: [], session: SendSession(files: files, quickShareQR: qr), cable: .none)
        render(SendView(model: model), "send-no-cable")

        model.loadPreviewState(transfers: [uploaded], peers: [], session: nil, cable: .none, offered: offered)
        render(WirelessView(model: model), "wireless")

        model.loadPreviewState(transfers: [asking], peers: [], session: nil, cable: .none)
        render(IncomingView(model: model, transferID: asking.id), "incoming")

        let browser = PhoneBrowser(cable: model.cable)
        let now = Date()
        browser.loadPreview(
            storages: [PhoneStorage(id: 65537, name: "Internal storage", capacity: 128_000_000_000, free: 41_000_000_000)],
            path: [PhoneItem(id: 1, storageID: 65537, parent: 0xFFFF_FFFF, name: "DCIM", isFolder: true, size: 0, modified: now),
                   PhoneItem(id: 2, storageID: 65537, parent: 1, name: "Camera", isFolder: true, size: 0, modified: now)],
            items: [
                PhoneItem(id: 10, storageID: 65537, parent: 2, name: "20261125_093012.jpg", isFolder: false, size: 3_400_000, modified: now),
                PhoneItem(id: 11, storageID: 65537, parent: 2, name: "20261124_181500.mp4", isFolder: false, size: 482_000_000, modified: now.addingTimeInterval(-60_000)),
                PhoneItem(id: 12, storageID: 65537, parent: 2, name: "20261124_170233.jpg", isFolder: false, size: 2_900_000, modified: now.addingTimeInterval(-63_000)),
            ],
            selected: [10, 11])
        model.loadPreviewState(transfers: [copying], peers: [], session: nil, cable: .ready(phone))
        render(PhoneBrowserView(model: model, browser: browser).frame(width: 720, height: 420), "browse")
        return true
    }

    private static func render<V: View>(_ view: V, _ name: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // let List and async views settle
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let dir = URL(fileURLWithPath: CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--render-previews")! + 1])
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

extension PhoneBrowser {
    func loadPreview(storages: [PhoneStorage], path: [PhoneItem], items: [PhoneItem], selected: Set<UInt32>) {
        setPreview(storages: storages, path: path, items: items)
        selection = selected
    }
}
