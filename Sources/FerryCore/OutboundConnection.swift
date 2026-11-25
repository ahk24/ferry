import Foundation
import Network
import CryptoKit
import UniformTypeIdentifiers

/// We connect to a phone and send it files. The mirror image of InboundConnection:
///
/// Plain-text phase:  (we) ConnectionRequest, ClientInit → ServerInit → (we) ClientFinish,
///                    ConnectionResponse → their ConnectionResponse.
/// Encrypted phase:   paired-key frames → (we) Introduction → their Response
///                    → (we) file chunks → Disconnection.
final class OutboundConnection: NearbyConnection {
    static let chunkSize = 512 * 1024

    private enum Stage { case connecting, serverInit, connectionResponse, encrypted }

    private struct OutgoingFile {
        let url: URL
        let meta: FileMetadata
    }

    private var stage = Stage.connecting
    private let outgoing: [OutgoingFile]
    private let qrKey: QRCodeKey?
    private let endpointID: String
    private let deviceName: String
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var clientInitRaw = Data()
    private var clientFinishRaw = Data()
    private var keys: SessionKeys?
    private var introductionSent = false
    private var sendingStarted = false
    private var allSent = false

    init(peer: Peer, files: [URL], qrKey: QRCodeKey?, service: NearbyService) {
        // Folders are sent as the files inside them, each tagged with its folder path.
        outgoing = LocalTree.files(in: files).map { entry in
            var meta = Self.metadata(for: entry.url)
            meta.parentFolder = entry.folder.isEmpty ? nil : entry.folder
            return OutgoingFile(url: entry.url, meta: meta)
        }
        self.qrKey = qrKey
        endpointID = service.endpointID
        deviceName = service.deviceName
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let connection = NWConnection(to: peer.endpoint, using: NWParameters(tls: nil, tcp: tcp))
        super.init(connection: connection, direction: .outgoing, peerName: peer.name, service: service)
        snapshot.items = files.map(\.lastPathComponent)
        snapshot.totalBytes = outgoing.reduce(0) { $0 + $1.meta.size }
    }

    static func metadata(for url: URL) -> FileMetadata {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var kind = FileMetadata.Kind.unknown
        if mime.hasPrefix("image/") { kind = FileMetadata.Kind.image }
        else if mime.hasPrefix("video/") { kind = FileMetadata.Kind.video }
        else if mime.hasPrefix("audio/") { kind = FileMetadata.Kind.audio }
        else if url.pathExtension.lowercased() == "apk" { kind = FileMetadata.Kind.androidApp }
        // Characters Android's file systems reject.
        let name = url.lastPathComponent.unicodeScalars
            .map { "/\\?%*:|\"<>=".unicodeScalars.contains($0) ? "_" : String($0) }
            .joined()
        return FileMetadata(name: name, type: kind, payloadID: Int64.random(in: .min ... .max), size: Int64(size),
                            mimeType: mime, id: Int64.random(in: .min ... .max))
    }

    // MARK: Handshake

    override func connectionReady() {
        snapshot.phase = .securing
        publish()

        let info = EndpointInfo.encode(name: deviceName, deviceType: EndpointInfo.laptop)
        let request = ConnectionRequest(endpointID: endpointID, endpointName: deviceName, endpointInfo: info, mediums: [Medium.wifiLAN])
        sendPlain(OfflineFrame(type: .connectionRequest, connectionRequest: request).encode())

        // UKEY2: the ClientInit commits to the ClientFinish we'll send later (hash of its exact bytes).
        let clientFinished = Ukey2ClientFinished(publicKey: Ukey2Crypto.encodePublicKey(privateKey.publicKey))
        clientFinishRaw = Ukey2Message(type: .clientFinish, data: clientFinished.encode()).encode()
        let clientInit = Ukey2ClientInit(
            version: 1,
            random: Bytes.random(32),
            commitments: [CipherCommitment(cipher: Ukey2Crypto.cipherP256SHA512, commitment: Ukey2Crypto.sha512(clientFinishRaw))],
            nextProtocol: Ukey2Crypto.nextProtocol
        )
        clientInitRaw = Ukey2Message(type: .clientInit, data: clientInit.encode()).encode()
        sendPlain(clientInitRaw)
        stage = .serverInit
    }

    override func handlePlainFrame(_ data: Data) throws {
        switch stage {
        case .serverInit:
            let message = try Ukey2Message.decode(data, expecting: .serverInit)
            let serverInit = try Ukey2ServerInit.decode(message.data)
            guard serverInit.version == 1, serverInit.random.count == 32,
                  serverInit.cipher == Ukey2Crypto.cipherP256SHA512 else {
                throw FerryError.protocolError("the phone answered the key exchange with unsupported parameters")
            }
            let peerKey = try Ukey2Crypto.decodePublicKey(serverInit.publicKey)
            let keys = try SessionKeys.derive(privateKey: privateKey, peerKey: peerKey,
                                              clientInit: clientInitRaw, serverInit: data, isServer: false)
            self.keys = keys
            snapshot.pin = keys.pin
            sendPlain(clientFinishRaw)
            sendPlain(OfflineFrame(type: .connectionResponse,
                                   connectionResponse: ConnectionResponse(response: ConnectionResponse.accept, osType: OSType.apple)).encode())
            stage = .connectionResponse
            publish()

        case .connectionResponse:
            let frame = try OfflineFrame.decode(data)
            guard frame.type == .connectionResponse, let response = frame.connectionResponse, let keys else {
                throw FerryError.protocolError("expected a connection response")
            }
            guard response.response == ConnectionResponse.accept else {
                finish(.declined)
                close()
                return
            }
            stage = .encrypted
            activateEncryption(keys)
            let signature = try qrKey?.handshakeSignature(authString: keys.authString)
            try sendPairedKeyEncryption(qrSignature: signature)

        case .connecting, .encrypted:
            throw FerryError.protocolError("unexpected message")
        }
    }

    // MARK: Sharing conversation

    override func handleSharingFrame(_ frame: SharingFrame) throws {
        switch frame.type {
        case .pairedKeyEncryption:
            try sendPairedKeyResultIfNeeded()
        case .pairedKeyResult:
            guard !introductionSent else { return }
            introductionSent = true
            try sendSharing(SharingFrame(type: .introduction, introduction: Introduction(files: outgoing.map(\.meta))))
            snapshot.phase = .waitingForPeer
            publish()
        case .response:
            guard !sendingStarted, let status = frame.responseStatus else { return }
            switch status {
            case ResponseStatus.accept:
                sendingStarted = true
                snapshot.phase = .transferring
                publish()
                sendFile(at: 0)
            case ResponseStatus.reject:
                finish(.declined)
                close(after: 0.5)
            case ResponseStatus.notEnoughSpace:
                finishFailed("There isn't enough space on the phone.")
            case ResponseStatus.unsupportedAttachmentType:
                finishFailed("The phone doesn't accept this kind of file.")
            case ResponseStatus.timedOut:
                finishFailed("Nobody accepted on the phone in time.")
            default:
                finishFailed("The phone turned the transfer down.")
            }
        case .cancel:
            finish(.canceled)
            close()
        default:
            break
        }
    }

    private func finishFailed(_ reason: String) {
        finish(.failed(reason))
        close(after: 0.5)
    }

    // MARK: Sending files

    /// One chunk at a time, waiting until each is handed to the network before reading the
    /// next, so large files never sit in memory.
    private func sendFile(at index: Int) {
        guard !isClosed else { return }
        guard index < outgoing.count else { finishSending(); return }
        do {
            let handle = try FileHandle(forReadingFrom: outgoing[index].url)
            sendChunk(fileIndex: index, handle: handle, offset: 0)
        } catch {
            fail(error)
        }
    }

    private func sendChunk(fileIndex: Int, handle: FileHandle, offset: Int64) {
        guard !isClosed else { try? handle.close(); return }
        let meta = outgoing[fileIndex].meta
        let header = PayloadHeader(id: meta.payloadID, type: PayloadHeader.file, totalSize: meta.size)
        do {
            let body = try handle.read(upToCount: Self.chunkSize) ?? Data()
            if body.isEmpty {
                try? handle.close()
                try sendOffline(.payload(header, PayloadChunk(flags: PayloadChunk.lastChunk, offset: offset, body: Data()))) { [weak self] error in
                    if let error { self?.fail(error) } else { self?.sendFile(at: fileIndex + 1) }
                }
                return
            }
            let next = offset + Int64(body.count)
            try sendOffline(.payload(header, PayloadChunk(flags: 0, offset: offset, body: body))) { [weak self] error in
                guard let self else { return }
                if let error { self.fail(error); return }
                self.snapshot.bytesDone += Int64(body.count)
                self.publishProgress()
                self.sendChunk(fileIndex: fileIndex, handle: handle, offset: next)
            }
        } catch {
            try? handle.close()
            fail(error)
        }
    }

    private func finishSending() {
        allSent = true
        snapshot.bytesDone = snapshot.totalBytes
        do {
            try sendOffline(OfflineFrame(type: .disconnection)) { [weak self] _ in
                self?.finish(.done)
                self?.close(after: 2)
            }
        } catch {
            fail(error)
        }
    }

    // MARK: Endings

    override func peerSentDisconnection() {
        if allSent { finish(.done) } else { finish(.failed("The phone ended the transfer.")) }
        close()
    }

    override func didClose(error: Error?) {
        guard !snapshot.phase.isTerminal else { return }
        if stage == .connecting {
            finish(.failed(error.map(Self.describe) ?? "Couldn't reach the phone."))
        } else if allSent {
            finish(.done)
        } else {
            finish(.failed(error.map(Self.describe) ?? "The connection was lost."))
        }
    }
}
