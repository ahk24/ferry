import Foundation
import Network

/// Everything the receiving and sending sides share: framing, the encrypted channel,
/// keep-alives, payload reassembly, and publishing progress. Subclasses implement the
/// handshake (which differs by role) and the sharing conversation.
///
/// All state is touched only on `queue`.
class NearbyConnection {
    static let maxBytesPayload: Int64 = 5 * 1024 * 1024

    let id: UUID
    let queue: DispatchQueue
    let frames: FrameConnection
    weak var service: NearbyService?
    var snapshot: TransferSnapshot
    private(set) var channel: SecureChannel?
    private(set) var isClosed = false

    private var keepAliveTimer: DispatchSourceTimer?
    private var bytesBuffers: [Int64: Data] = [:]
    private var sentPairedKeyResult = false
    private var lastPublish = Date.distantPast

    init(connection: NWConnection, direction: TransferSnapshot.Direction, peerName: String, service: NearbyService) {
        let id = UUID()
        self.id = id
        queue = DispatchQueue(label: "ferry.connection.\(id.uuidString.prefix(8))")
        frames = FrameConnection(connection, queue: queue)
        self.service = service
        snapshot = TransferSnapshot(id: id, direction: direction, peerName: peerName)
    }

    func start() {
        frames.onReady = { [weak self] in self?.connectionReady() }
        frames.onFrame = { [weak self] data in self?.receive(data) }
        frames.onClose = { [weak self] error in self?.transportClosed(error) }
        frames.start()
    }

    // MARK: Subclass hooks

    func connectionReady() {}
    func handlePlainFrame(_ data: Data) throws {}
    func handleSharingFrame(_ frame: SharingFrame) throws {}
    /// Return true if the BYTES payload was user content (text) rather than a sharing frame.
    func consumeBytesPayload(id: Int64, data: Data) throws -> Bool { false }
    func handleFileChunk(header: PayloadHeader, chunk: PayloadChunk) throws {}
    func peerSentDisconnection() { close() }
    func peerCanceledPayload() {
        finish(.canceled)
        close()
    }
    func didFinish(_ phase: TransferSnapshot.Phase) {}
    func didClose(error: Error?) {}

    // MARK: Receiving

    private func receive(_ data: Data) {
        guard !isClosed else { return }
        do {
            if let channel {
                try handleOfflineFrame(OfflineFrame.decode(channel.open(data)))
            } else {
                try handlePlainFrame(data)
            }
        } catch {
            fail(error)
        }
    }

    private func handleOfflineFrame(_ frame: OfflineFrame) throws {
        switch frame.type {
        case .keepAlive:
            if frame.keepAliveAck != true {
                try sendOffline(OfflineFrame(type: .keepAlive, keepAliveAck: true))
            }
        case .disconnection:
            peerSentDisconnection()
        case .payloadTransfer:
            if let transfer = frame.payloadTransfer { try handlePayloadTransfer(transfer) }
        default:
            break // e.g. bandwidth upgrades: we are already on Wi-Fi, the best medium available here
        }
    }

    private func handlePayloadTransfer(_ transfer: PayloadTransfer) throws {
        if transfer.packetType == PayloadTransfer.control {
            if let event = transfer.controlEvent,
               event == PayloadTransfer.ControlEvent.payloadCanceled || event == PayloadTransfer.ControlEvent.payloadError {
                peerCanceledPayload()
            }
            return
        }
        guard let header = transfer.header, let chunk = transfer.chunk else { return }

        switch header.type {
        case PayloadHeader.bytes:
            guard header.totalSize <= Self.maxBytesPayload else {
                throw FerryError.protocolError("received an oversized message payload")
            }
            var buffer = bytesBuffers[header.id] ?? Data()
            guard chunk.offset == Int64(buffer.count) else {
                throw FerryError.protocolError("message payload arrived out of order")
            }
            buffer.append(chunk.body)
            guard buffer.count <= Self.maxBytesPayload else {
                throw FerryError.protocolError("received an oversized message payload")
            }
            if chunk.isLast {
                bytesBuffers[header.id] = nil
                if try !consumeBytesPayload(id: header.id, data: buffer) {
                    try handleSharingFrame(SharingFrame.decode(buffer))
                }
            } else {
                bytesBuffers[header.id] = buffer
            }
        case PayloadHeader.file:
            try handleFileChunk(header: header, chunk: chunk)
        default:
            break
        }
    }

    // MARK: Sending

    func sendPlain(_ data: Data) {
        frames.send(data)
    }

    func sendOffline(_ frame: OfflineFrame, completion: ((Error?) -> Void)? = nil) throws {
        guard let channel else { throw FerryError.protocolError("tried to send before encryption was set up") }
        frames.send(try channel.seal(frame.encode()), completion: completion)
    }

    /// Sharing messages travel as BYTES payloads: one chunk with everything, then an empty
    /// chunk flagged as the last one.
    func sendBytesPayload(_ data: Data) throws {
        let header = PayloadHeader(id: Int64.random(in: .min ... .max), type: PayloadHeader.bytes, totalSize: Int64(data.count))
        try sendOffline(.payload(header, PayloadChunk(flags: 0, offset: 0, body: data)))
        try sendOffline(.payload(header, PayloadChunk(flags: PayloadChunk.lastChunk, offset: Int64(data.count), body: Data())))
    }

    func sendSharing(_ frame: SharingFrame) throws {
        try sendBytesPayload(frame.encode())
    }

    /// Paired-key verification only works between devices signed in to the same Google
    /// account. We send placeholder values, and answer the peer's with UNABLE, which makes
    /// the phone fall back to asking its user.
    func sendPairedKeyEncryption(qrSignature: Data? = nil) throws {
        let pke = PairedKeyEncryption(signedData: Bytes.random(72), secretIDHash: Bytes.random(6), qrCodeHandshakeData: qrSignature)
        try sendSharing(SharingFrame(type: .pairedKeyEncryption, pairedKeyEncryption: pke))
    }

    func sendPairedKeyResultIfNeeded() throws {
        guard !sentPairedKeyResult else { return }
        sentPairedKeyResult = true
        try sendSharing(SharingFrame(type: .pairedKeyResult, pairedKeyResultStatus: PairedKeyResultStatus.unable))
    }

    func activateEncryption(_ keys: SessionKeys) {
        channel = SecureChannel(keys: keys)
        // Android sends a keep-alive every 10 seconds and drops connections that don't.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            try? self.sendOffline(OfflineFrame(type: .keepAlive, keepAliveAck: false))
        }
        timer.resume()
        keepAliveTimer = timer
    }

    // MARK: State

    func publish() {
        lastPublish = Date()
        let s = snapshot
        DispatchQueue.main.async { [weak service = self.service] in service?.transferDidUpdate(s) }
    }

    /// Progress updates, at most ten per second.
    func publishProgress() {
        if Date().timeIntervalSince(lastPublish) >= 0.1 { publish() }
    }

    func finish(_ phase: TransferSnapshot.Phase) {
        guard !snapshot.phase.isTerminal else { return }
        snapshot.phase = phase
        publish()
        didFinish(phase)
    }

    func fail(_ error: Error) {
        NSLog("Ferry: transfer with %@ failed: %@", snapshot.peerName, String(describing: error))
        finish(.failed(Self.describe(error)))
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        frames.close()
    }

    func close(after seconds: Double) {
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.close() }
    }

    func cancelByUser() {
        queue.async { [weak self] in
            guard let self, !self.snapshot.phase.isTerminal else { return }
            if self.channel != nil && !self.isClosed { try? self.sendSharing(SharingFrame(type: .cancel)) }
            self.finish(.canceled)
            self.close(after: 0.5)
        }
    }

    private func transportClosed(_ error: Error?) {
        isClosed = true
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        didClose(error: error)
        let id = self.id
        DispatchQueue.main.async { [weak service = self.service] in service?.connectionDidClose(id) }
    }

    static func describe(_ error: Error) -> String {
        if let ferry = error as? FerryError { return ferry.localizedDescription }
        if let nw = error as? NWError {
            switch nw {
            case .posix(let code) where code == .ECONNREFUSED: return "The other device refused the connection."
            case .posix(let code) where code == .ETIMEDOUT: return "The other device didn't respond."
            default: return nw.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
