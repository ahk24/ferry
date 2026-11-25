import Foundation
import Network

/// Makes this Mac show up in Android's Quick Share sheet, receives what phones send, and sends
/// files to phones. Use it from the main thread; every callback is delivered on the main thread.
public final class NearbyService {
    /// "_" + the first 6 bytes of SHA-256("NearbySharing"), the Quick Share service ID.
    public static let serviceType = "_FC9F5ED42C8A._tcp"

    /// Four random alphanumeric characters identifying this device for the session.
    public let endpointID: String
    public var deviceName: String {
        didSet { if listener != nil { restartAdvertising() } }
    }
    public var downloadDirectory: URL

    public var onAdvertisingStateChange: ((AdvertisingState) -> Void)?
    public var onPeersChange: (([Peer]) -> Void)?
    public var onTransferUpdate: ((TransferSnapshot) -> Void)?
    /// Called when a phone offers something. Call the handler with true to accept.
    public var onIncomingRequest: ((TransferSnapshot, @escaping (Bool) -> Void) -> Void)?
    /// Called when a phone that scanned the QR code was found and sending to it started.
    public var onQRTransferStarted: ((UUID) -> Void)?
    /// Test hook: (signature, auth string) from a sender's QR handshake.
    var debugQRSignatureHandler: ((Data, Data) -> Void)?

    public private(set) var advertisingState: AdvertisingState = .off {
        didSet { if advertisingState != oldValue { onAdvertisingStateChange?(advertisingState) } }
    }
    public private(set) var peers: [Peer] = []

    private var listener: NWListener?
    private var listenerOptions = (bonjour: true, loopbackOnly: false)
    private var browser: NWBrowser?
    private var connections: [UUID: NearbyConnection] = [:]
    private var qrSession: (key: QRCodeKey, files: [URL])?

    public init(deviceName: String, downloadDirectory: URL) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        endpointID = String((0..<4).map { _ in alphabet.randomElement()! })
        self.deviceName = deviceName
        self.downloadDirectory = downloadDirectory
    }

    // MARK: Receiving

    /// Listens for phones. `bonjour: false, loopbackOnly: true` is for tests.
    public func startAdvertising(bonjour: Bool = true, loopbackOnly: Bool = false) {
        guard listener == nil else { return }
        listenerOptions = (bonjour, loopbackOnly)
        advertisingState = .starting
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            if loopbackOnly {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            }
            let listener = try NWListener(using: parameters)
            if bonjour {
                listener.service = NWListener.Service(name: instanceName, type: Self.serviceType, domain: nil, txtRecord: txtRecord)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.advertisingState = .visible(port: listener.port?.rawValue ?? 0)
                case .waiting(let error):
                    self.advertisingState = .failed(error.localizedDescription)
                case .failed(let error):
                    self.advertisingState = .failed(error.localizedDescription)
                    listener.cancel()
                    self.listener = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.listener == nil, case .failed = self.advertisingState else { return }
                        self.startAdvertising(bonjour: self.listenerOptions.bonjour, loopbackOnly: self.listenerOptions.loopbackOnly)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.register(InboundConnection(connection: connection, service: self))
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            advertisingState = .failed(error.localizedDescription)
        }
    }

    public func stopAdvertising() {
        listener?.cancel()
        listener = nil
        advertisingState = .off
    }

    private func restartAdvertising() {
        let options = listenerOptions
        stopAdvertising()
        startAdvertising(bonjour: options.bonjour, loopbackOnly: options.loopbackOnly)
    }

    /// 0x23, the endpoint ID, the first 3 bytes of the service ID, two zero bytes; base64url.
    private var instanceName: String {
        Data([0x23] + Array(endpointID.utf8) + [0xFC, 0x9F, 0x5E, 0x00, 0x00]).base64URL
    }

    private var txtRecord: Data {
        let value = EndpointInfo.encode(name: deviceName, deviceType: EndpointInfo.laptop).base64URL
        let entry = Array("n=\(value)".utf8)
        return Data([UInt8(entry.count)] + entry)
    }

    // MARK: Discovering phones

    public func startDiscovery() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.updatePeers(results) }
        self.browser = browser
        browser.start(queue: .main)
    }

    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        peers = []
        onPeersChange?([])
    }

    private func updatePeers(_ results: Set<NWBrowser.Result>) {
        var found: [String: Peer] = [:]
        for result in results {
            guard case let .service(name, _, _, interface) = result.endpoint, interface?.type != .loopback,
                  let nameBytes = Data(base64URL: name).map(Array.init), nameBytes.count >= 10,
                  nameBytes[0] == 0x23, nameBytes[5] == 0xFC, nameBytes[6] == 0x9F, nameBytes[7] == 0x5E else { continue }
            let id = String(decoding: nameBytes[1..<5], as: UTF8.self)
            guard id != endpointID,
                  case let .bonjour(txt) = result.metadata,
                  let encodedInfo = txt.dictionary["n"],
                  let infoData = Data(base64URL: encodedInfo),
                  let info = EndpointInfo(infoData) else { continue }

            var displayName = info.name
            var matchedQR = false
            if let qr = qrSession, let qrData = info.qrData, let qrName = qr.key.match(qrData) {
                matchedQR = true
                displayName = qrName.isEmpty ? (info.name ?? "Phone") : qrName
            }
            // Hidden devices only become usable through our QR code.
            guard let displayName, !displayName.isEmpty else { continue }
            if found[id]?.matchedQRCode == true { continue }
            found[id] = Peer(id: id, name: displayName, deviceType: info.deviceType, endpoint: result.endpoint, matchedQRCode: matchedQR)
        }
        peers = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onPeersChange?(peers)

        if let qr = qrSession, let phone = peers.first(where: \.matchedQRCode) {
            qrSession = nil
            let id = send(files: qr.files, to: phone, qrKey: qr.key)
            onQRTransferStarted?(id)
        }
    }

    // MARK: Sending

    @discardableResult
    public func send(files: [URL], to peer: Peer) -> UUID {
        send(files: files, to: peer, qrKey: nil)
    }

    @discardableResult
    func send(files: [URL], to peer: Peer, qrKey: QRCodeKey?) -> UUID {
        let connection = OutboundConnection(peer: peer, files: files, qrKey: qrKey, service: self)
        register(connection)
        transferDidUpdate(connection.snapshot)
        return connection.id
    }

    /// Starts watching for a phone that scans the returned URL as a QR code, and sends `files`
    /// to the first one that does. Needs discovery running.
    public func beginQRSend(files: [URL]) -> String {
        let key = QRCodeKey()
        qrSession = (key, files)
        return key.url
    }

    public func endQRSend() {
        qrSession = nil
    }

    public func cancelTransfer(_ id: UUID) {
        connections[id]?.cancelByUser()
    }

    // MARK: Connection plumbing

    private func register(_ connection: NearbyConnection) {
        connections[connection.id] = connection
        connection.start()
    }

    func transferDidUpdate(_ snapshot: TransferSnapshot) {
        onTransferUpdate?(snapshot)
    }

    func requestDecision(_ snapshot: TransferSnapshot, completion: @escaping (Bool) -> Void) {
        if let onIncomingRequest {
            onIncomingRequest(snapshot, completion)
        } else {
            completion(false)
        }
    }

    func connectionDidClose(_ id: UUID) {
        connections[id] = nil
    }
}
