import AppKit
import SwiftUI
import FerryCore

struct SendSession {
    var files: [URL]
    var quickShareQR: NSImage?
    var transferID: UUID?
}

struct NetAddress: Hashable {
    let interface: String
    let address: String
}

/// Everything the UI shows, fed by the three ways Ferry moves files:
/// cable (USB file transfer), the phone's browser (hotspot or shared Wi-Fi), and Quick Share.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private enum Source { case quickShare, cable, web }

    // Cable
    @Published private(set) var cableState: CableState = .none
    // Phone's browser
    @Published private(set) var webState: WebShare.State = .off
    @Published private(set) var offered: [WebShare.OfferedFile] = []
    @Published private(set) var addresses: [NetAddress] = []
    @Published private(set) var phoneContact: (address: String, date: Date)?
    // Quick Share
    @Published private(set) var advertising: AdvertisingState = .off
    @Published private(set) var peers: [Peer] = []
    @Published var quickShareEnabled: Bool {
        didSet {
            UserDefaults.standard.set(quickShareEnabled, forKey: "receiveEnabled")
            applyQuickShareSetting()
        }
    }
    // Shared
    @Published private(set) var transfers: [TransferSnapshot] = []
    @Published private(set) var sendSession: SendSession?
    @Published private(set) var downloadDirectory: URL

    let deviceName: String
    let cable = CableService()
    let web: WebShare
    private let quickShare: NearbyService
    private var sources: [UUID: Source] = [:]
    private var decisions: [UUID: (Bool) -> Void] = [:]
    private var copiedText = Set<UUID>()
    let windows = WindowPresenter()

    init() {
        let defaults = UserDefaults.standard
        let name = Host.current().localizedName ?? "Mac"
        deviceName = name
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let saveTo = defaults.string(forKey: "downloadDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? downloads
        downloadDirectory = saveTo
        quickShareEnabled = defaults.object(forKey: "receiveEnabled") as? Bool ?? true
        quickShare = NearbyService(deviceName: name, downloadDirectory: saveTo)
        web = WebShare(deviceName: name, downloadDirectory: saveTo, key: defaults.string(forKey: "webKey"))
        defaults.set(web.key, forKey: "webKey")
    }

    func start() {
        windows.model = self
        cable.onStateChange = { [weak self] in self?.cableState = $0 }
        cable.onTransferUpdate = { [weak self] in self?.update($0, from: .cable) }
        cable.start()

        web.onStateChange = { [weak self] in self?.webState = $0 }
        web.onOffersChange = { [weak self] in self?.offered = $0 }
        web.onTransferUpdate = { [weak self] in self?.update($0, from: .web) }
        web.onPhoneContact = { [weak self] address in self?.phoneContact = (address, Date()) }
        web.start() // always on, so a bookmarked page on the phone works whenever Ferry runs

        quickShare.onAdvertisingStateChange = { [weak self] in self?.advertising = $0 }
        quickShare.onPeersChange = { [weak self] in self?.peers = $0 }
        quickShare.onTransferUpdate = { [weak self] in self?.update($0, from: .quickShare) }
        quickShare.onIncomingRequest = { [weak self] snapshot, decide in
            guard let self else { decide(false); return }
            self.incomingRequest(snapshot, decide: decide)
        }
        quickShare.onQRTransferStarted = { [weak self] id in self?.sendSession?.transferID = id }
        applyQuickShareSetting()
    }

    // MARK: Status

    var visibleTransfers: [TransferSnapshot] {
        transfers.filter { !($0.direction == .incoming && $0.phase.isTerminal && $0.items.isEmpty) }
    }

    func transfer(_ id: UUID) -> TransferSnapshot? { transfers.first { $0.id == id } }

    var quickShareStatus: String {
        switch advertising {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .visible: return "On: phones on the same Wi-Fi see “\(deviceName)”"
        case .failed(let message): return "Not working: \(message). Check System Settings → Privacy & Security → Local Network."
        }
    }

    private func applyQuickShareSetting() {
        if quickShareEnabled { quickShare.startAdvertising() } else { quickShare.stopAdvertising() }
    }

    private func update(_ snapshot: TransferSnapshot, from source: Source) {
        sources[snapshot.id] = source
        if let index = transfers.firstIndex(where: { $0.id == snapshot.id }) {
            transfers[index] = snapshot
        } else {
            transfers.insert(snapshot, at: 0)
            if transfers.count > 40 { transfers.removeLast(transfers.count - 40) }
        }
        guard snapshot.phase.isTerminal else { return }
        decisions[snapshot.id] = nil
        if snapshot.direction == .incoming, snapshot.phase == .done, let text = snapshot.receivedText,
           !copiedText.contains(snapshot.id) {
            copiedText.insert(snapshot.id)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func cancel(_ id: UUID) {
        switch sources[id] {
        case .quickShare: quickShare.cancelTransfer(id)
        case .cable: cable.cancel(id)
        case .web: web.cancel(id)
        default: break
        }
    }

    // MARK: Quick Share: incoming

    private func incomingRequest(_ snapshot: TransferSnapshot, decide: @escaping (Bool) -> Void) {
        decisions[snapshot.id] = decide
        update(snapshot, from: .quickShare)
        let id = snapshot.id
        windows.show("incoming-\(id)", title: "Incoming from \(snapshot.peerName)", floating: true) {
            IncomingView(model: self, transferID: id)
        }
        NSSound(named: "Glass")?.play()
    }

    func respond(_ id: UUID, accept: Bool) {
        decisions.removeValue(forKey: id)?(accept)
    }

    func closeIncoming(_ id: UUID) { windows.close("incoming-\(id)") }

    // MARK: Sending

    func chooseFilesToSend() {
        windows.onWillShow?() // close the menu so it can't cover the file chooser
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose files or folders to send to your phone"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            if response == .OK { self?.beginSend(panel.urls) }
        }
    }

    /// Opens the send window, empty, ready for files to be dropped into it.
    func openSendWindow() { beginSend([]) }

    /// Opens (or brings forward) the send window and adds these files and folders to it.
    func beginSend(_ urls: [URL]) {
        let items = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        var files = items
        if let session = sendSession, session.transferID == nil {
            files = session.files + items.filter { !session.files.contains($0) }
        }
        setSendFiles(files)
        windows.show("send", title: "Send to Phone", onClose: { [weak self] in self?.endSendSession() }) {
            SendView(model: self)
        }
    }

    func removeFromSend(_ url: URL) {
        guard let session = sendSession, session.transferID == nil else { return }
        setSendFiles(session.files.filter { $0 != url })
    }

    /// After a transfer: start over in the same window.
    func sendMore() { setSendFiles([]) }

    private func setSendFiles(_ files: [URL]) {
        quickShare.endQRSend()
        let qr = files.isEmpty ? nil : QRCode.image(for: quickShare.beginQRSend(files: files))
        sendSession = SendSession(files: files, quickShareQR: qr, transferID: nil)
    }

    func sendByCable() {
        guard var session = sendSession, session.transferID == nil else { return }
        session.transferID = cable.copyToPhone(session.files)
        sendSession = session
    }

    func sendToBrowser() {
        guard let session = sendSession else { return }
        web.offer(session.files)
        windows.close("send")
        showWireless()
    }

    func startQuickShareDiscovery() { quickShare.startDiscovery() }

    func sendByQuickShare(to peer: Peer) {
        guard var session = sendSession, session.transferID == nil else { return }
        quickShare.endQRSend()
        session.transferID = quickShare.send(files: session.files, to: peer)
        sendSession = session
    }

    func closeSendWindow() { windows.close("send") }

    private func endSendSession() {
        quickShare.endQRSend()
        quickShare.stopDiscovery()
        sendSession = nil
    }

    // MARK: Phone's browser

    func showWireless() {
        web.start()
        refreshAddresses()
        windows.show("wireless", title: "Phone's Browser") { WirelessView(model: self) }
    }

    func refreshAddresses() {
        let now = WebShare.localAddresses().map { NetAddress(interface: $0.interface, address: $0.address) }
        if now != addresses { addresses = now }
    }

    func pageURL(_ address: NetAddress) -> String? {
        guard case .running(let port) = webState else { return nil }
        return "http://\(address.address):\(port)/?k=\(web.key)"
    }

    func addFilesForBrowser() {
        windows.onWillShow?() // close the menu so it can't cover the file chooser
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Share"
        panel.message = "Choose files or folders your phone can download"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            if response == .OK { self?.web.offer(panel.urls) }
        }
    }

    func stopSharing(_ id: String) { web.removeOffer(id) }
    func stopSharingAll() { web.clearOffers() }

    // MARK: Cable

    func showPhoneBrowser() {
        windows.show("browse", title: cableState.phoneName ?? "Phone", resizable: true, size: NSSize(width: 760, height: 560)) {
            PhoneBrowserView(model: self, browser: PhoneBrowser(cable: self.cable))
        }
    }

    func retryCable() { cable.retry() }

    func copyFromPhone(_ items: [PhoneItem]) -> UUID {
        cable.copyToMac(items, destination: downloadDirectory)
    }

    func copyToPhone(_ urls: [URL], storage: UInt32?, folder: UInt32?) -> UUID {
        cable.copyToPhone(urls, storage: storage, folder: folder)
    }

    // MARK: Settings and actions

    func chooseDownloadDirectory() {
        windows.onWillShow?() // close the menu so it can't cover the file chooser
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloadDirectory
        panel.prompt = "Save Here"
        panel.message = "Choose where Ferry saves files from your phone"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.urls.first else { return }
            self.downloadDirectory = url
            self.quickShare.downloadDirectory = url
            self.web.downloadDirectory = url
            UserDefaults.standard.set(url.path, forKey: "downloadDirectory")
        }
    }

    func reveal(_ transfer: TransferSnapshot) {
        let existing = transfer.savedFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(downloadDirectory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    func openReceivedLink(_ transfer: TransferSnapshot) {
        guard let text = transfer.receivedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// Sample state for `Ferry --render-previews`.
    func loadPreviewState(transfers: [TransferSnapshot], peers: [Peer], session: SendSession?, cable: CableState,
                          offered: [WebShare.OfferedFile] = []) {
        self.transfers = transfers
        self.peers = peers
        self.sendSession = session
        self.cableState = cable
        self.advertising = .visible(port: 1)
        self.webState = .running(port: 8765)
        self.offered = offered
        self.addresses = [NetAddress(interface: "en0", address: "192.168.43.27")]
    }
}
