import Foundation
import Network
import CryptoKit
import CoreServices

/// The phone connected to us because the user picked this Mac in the Quick Share sheet.
///
/// Plain-text phase:  ConnectionRequest → UKEY2 ClientInit → (we) ServerInit → ClientFinish
///                    → (we) ConnectionResponse → their ConnectionResponse.
/// Encrypted phase:   paired-key frames, Introduction → (user decides) → Response
///                    → file chunks → Disconnection.
final class InboundConnection: NearbyConnection {
    private enum Stage { case connectionRequest, clientInit, clientFinish, connectionResponse, encrypted }

    private final class IncomingFile {
        let meta: FileMetadata
        var url: URL?
        var handle: FileHandle?
        var written: Int64 = 0
        var complete = false
        init(meta: FileMetadata) { self.meta = meta }
    }

    private var stage = Stage.connectionRequest
    private let privateKey = P256.KeyAgreement.PrivateKey()
    private var clientInitRaw = Data()
    private var serverInitRaw = Data()
    private var commitment = Data()
    private var pendingKeys: SessionKeys?
    private var files: [Int64: IncomingFile] = [:]
    private var texts: [Int64: TextMetadata] = [:]
    private var textsReceived = Set<Int64>()
    private var introductionReceived = false
    private var accepted = false
    private let downloadDirectory: URL

    init(connection: NWConnection, service: NearbyService) {
        downloadDirectory = service.downloadDirectory
        super.init(connection: connection, direction: .incoming, peerName: "Android device", service: service)
    }

    // MARK: Handshake

    override func handlePlainFrame(_ data: Data) throws {
        switch stage {
        case .connectionRequest:
            let frame = try OfflineFrame.decode(data)
            guard frame.type == .connectionRequest, let request = frame.connectionRequest else {
                throw FerryError.protocolError("expected a connection request")
            }
            if let infoData = request.endpointInfo, let info = EndpointInfo(infoData), let name = info.name, !name.isEmpty {
                snapshot.peerName = name
            } else if let name = request.endpointName, !name.isEmpty {
                snapshot.peerName = name
            }
            snapshot.phase = .securing
            stage = .clientInit
            publish()

        case .clientInit:
            let message = try Ukey2Message.decode(data, expecting: .clientInit)
            let clientInit: Ukey2ClientInit
            do { clientInit = try Ukey2ClientInit.decode(message.data) } catch {
                throw alert(Ukey2AlertType.badMessageData, "unreadable ClientInit")
            }
            guard clientInit.version == 1 else { throw alert(Ukey2AlertType.badVersion, "unsupported UKEY2 version") }
            guard clientInit.random.count == 32 else { throw alert(Ukey2AlertType.badRandom, "bad random") }
            guard let p256 = clientInit.commitments.first(where: { $0.cipher == Ukey2Crypto.cipherP256SHA512 }) else {
                throw alert(Ukey2AlertType.badHandshakeCipher, "the phone doesn't offer P-256")
            }
            if let next = clientInit.nextProtocol, next != Ukey2Crypto.nextProtocol {
                throw alert(Ukey2AlertType.badNextProtocol, "unsupported encryption \(next)")
            }
            commitment = p256.commitment
            clientInitRaw = data

            let serverInit = Ukey2ServerInit(version: 1, random: Bytes.random(32), cipher: Ukey2Crypto.cipherP256SHA512,
                                             publicKey: Ukey2Crypto.encodePublicKey(privateKey.publicKey))
            serverInitRaw = Ukey2Message(type: .serverInit, data: serverInit.encode()).encode()
            sendPlain(serverInitRaw)
            stage = .clientFinish

        case .clientFinish:
            let message = try Ukey2Message.decode(data, expecting: .clientFinish)
            // The ClientInit committed to this exact message; anything else means tampering.
            guard Ukey2Crypto.sha512(data) == commitment else {
                throw FerryError.protocolError("the key exchange didn't match its commitment")
            }
            let finished = try Ukey2ClientFinished.decode(message.data)
            let peerKey = try Ukey2Crypto.decodePublicKey(finished.publicKey)
            let keys = try SessionKeys.derive(privateKey: privateKey, peerKey: peerKey,
                                              clientInit: clientInitRaw, serverInit: serverInitRaw, isServer: true)
            pendingKeys = keys
            snapshot.pin = keys.pin
            sendPlain(OfflineFrame(type: .connectionResponse,
                                   connectionResponse: ConnectionResponse(response: ConnectionResponse.accept, osType: OSType.apple)).encode())
            stage = .connectionResponse
            publish()

        case .connectionResponse:
            let frame = try OfflineFrame.decode(data)
            guard frame.type == .connectionResponse, let response = frame.connectionResponse, let keys = pendingKeys else {
                throw FerryError.protocolError("expected a connection response")
            }
            guard response.response == ConnectionResponse.accept else {
                throw FerryError.protocolError("the phone closed the connection")
            }
            stage = .encrypted
            activateEncryption(keys)
            snapshot.phase = .waitingForPeer
            try sendPairedKeyEncryption()

        case .encrypted:
            break // unreachable: encrypted frames go through the channel
        }
    }

    private func alert(_ type: Int, _ message: String) -> Error {
        sendPlain(Ukey2Message(type: .alert, data: Ukey2Alert(type: type, message: message).encode()).encode())
        return FerryError.protocolError("key exchange failed: \(message)")
    }

    // MARK: Sharing conversation

    override func handleSharingFrame(_ frame: SharingFrame) throws {
        switch frame.type {
        case .pairedKeyEncryption:
            if let signature = frame.pairedKeyEncryption?.qrCodeHandshakeData, let auth = channel?.keys.authString {
                DispatchQueue.main.async { [weak service = self.service] in service?.debugQRSignatureHandler?(signature, auth) }
            }
            try sendPairedKeyResultIfNeeded()
        case .introduction:
            guard let introduction = frame.introduction, !introductionReceived else { return }
            introductionReceived = true
            try handleIntroduction(introduction)
        case .cancel:
            finish(.canceled)
            close()
        default:
            break
        }
    }

    private func handleIntroduction(_ introduction: Introduction) throws {
        guard !introduction.files.isEmpty || !introduction.texts.isEmpty else {
            try sendSharing(SharingFrame(type: .response, responseStatus: ResponseStatus.unsupportedAttachmentType))
            finish(.failed("The phone tried to send something Ferry can't receive, such as a Wi-Fi network or an app."))
            close(after: 1)
            return
        }
        for file in introduction.files { files[file.payloadID] = IncomingFile(meta: file) }
        for text in introduction.texts { texts[text.payloadID] = text }
        snapshot.items = introduction.files.map(\.name) + introduction.texts.map { Self.label(for: $0) }
        snapshot.totalBytes = introduction.files.reduce(0) { $0 + max(0, $1.size) }
            + introduction.texts.reduce(0) { $0 + max(0, $1.size) }
        snapshot.phase = .awaitingYourAccept
        publish()

        let request = snapshot
        DispatchQueue.main.async { [weak self, weak service = self.service] in
            guard let service else { return }
            service.requestDecision(request) { accept in
                self?.queue.async { self?.respond(accept: accept) }
            }
        }
    }

    private func respond(accept: Bool) {
        guard !isClosed, snapshot.phase == .awaitingYourAccept else { return }
        do {
            if accept {
                try createDestinationFiles()
                accepted = true
                try sendSharing(SharingFrame(type: .response, responseStatus: ResponseStatus.accept))
                snapshot.phase = .transferring
                publish()
                checkCompletion()
            } else {
                try sendSharing(SharingFrame(type: .response, responseStatus: ResponseStatus.reject))
                finish(.declined)
                close(after: 1)
            }
        } catch {
            fail(error)
        }
    }

    // MARK: Payloads

    override func consumeBytesPayload(id: Int64, data: Data) throws -> Bool {
        guard let meta = texts[id] else { return false }
        if !textsReceived.contains(id) {
            textsReceived.insert(id)
            let text = String(decoding: data, as: UTF8.self)
            snapshot.receivedText = snapshot.receivedText.map { $0 + "\n" + text } ?? text
            snapshot.receivedTextIsURL = meta.type == TextMetadata.Kind.url
            snapshot.bytesDone += Int64(data.count)
            checkCompletion()
        }
        return true
    }

    override func handleFileChunk(header: PayloadHeader, chunk: PayloadChunk) throws {
        guard accepted, let file = files[header.id] else { throw FerryError.protocolError("received file data that wasn't announced") }
        guard !file.complete else { return }
        guard chunk.offset == file.written else { throw FerryError.protocolError("file data arrived out of order") }
        if !chunk.body.isEmpty {
            try file.handle?.write(contentsOf: chunk.body)
            file.written += Int64(chunk.body.count)
            snapshot.bytesDone += Int64(chunk.body.count)
        }
        if chunk.isLast {
            try file.handle?.close()
            file.handle = nil
            file.complete = true
            if let url = file.url {
                Self.markQuarantined(url)
                // Show the folder, not each file inside it.
                let shown = topLevel(of: url)
                if !snapshot.savedFiles.contains(shown) { snapshot.savedFiles.append(shown) }
            }
            publish()
            checkCompletion()
        } else {
            publishProgress()
        }
    }

    private func checkCompletion() {
        guard accepted, !snapshot.phase.isTerminal,
              files.values.allSatisfy(\.complete),
              texts.keys.allSatisfy(textsReceived.contains) else { return }
        snapshot.bytesDone = snapshot.totalBytes
        finish(.done)
        close(after: 5) // the phone normally hangs up first
    }

    override func peerSentDisconnection() {
        endedEarly(reason: "The phone disconnected before the transfer finished.")
        close()
    }

    override func peerCanceledPayload() {
        endedEarly(reason: "The phone stopped the transfer.")
        close()
    }

    override func didClose(error: Error?) {
        endedEarly(reason: error.map(Self.describe) ?? "The connection was lost.")
    }

    private func endedEarly(reason: String) {
        guard !snapshot.phase.isTerminal else { return }
        if snapshot.phase == .awaitingYourAccept {
            finish(.canceled)
        } else if introductionReceived {
            finish(.failed(reason))
        } else {
            // The phone hung up before offering anything (the user backed out). The UI hides
            // terminal incoming transfers that never listed any items.
            finish(.canceled)
        }
    }

    override func didFinish(_ phase: TransferSnapshot.Phase) {
        guard phase != .done else { return }
        for file in files.values where !file.complete {
            try? file.handle?.close()
            file.handle = nil
            if let url = file.url { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Files

    private func createDestinationFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        // A shared folder arrives as files tagged "Folder/sub". Recreate it, renaming the top
        // folder if one with that name already exists.
        var topFolders: [String: URL] = [:]
        for file in files.values.sorted(by: { ($0.meta.parentFolder ?? "", $0.meta.name) < ($1.meta.parentFolder ?? "", $1.meta.name) }) {
            var directory = downloadDirectory
            let parts = (file.meta.parentFolder ?? "").split(separator: "/").map { FileNaming.sanitize(String($0)) }
            if let top = parts.first {
                let root = topFolders[top] ?? FileNaming.uniqueURL(in: downloadDirectory, name: top)
                topFolders[top] = root
                directory = parts.dropFirst().reduce(root) { $0.appendingPathComponent($1) }
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let url = FileNaming.uniqueURL(in: directory, name: file.meta.name)
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw FerryError.protocolError("Couldn't create \(url.lastPathComponent) in \(downloadDirectory.lastPathComponent).")
            }
            file.url = url
            file.handle = try FileHandle(forWritingTo: url)
        }
    }

    /// The item directly inside the download folder that contains `url`.
    private func topLevel(of url: URL) -> URL {
        var current = url
        while current.deletingLastPathComponent().standardizedFileURL != downloadDirectory.standardizedFileURL,
              current.pathComponents.count > downloadDirectory.pathComponents.count + 1 {
            current = current.deletingLastPathComponent()
        }
        return current
    }

    /// Like any download, so Gatekeeper checks received apps and scripts before they run.
    static func markQuarantined(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Ferry",
        ]
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    static func label(for text: TextMetadata) -> String {
        switch text.type {
        case TextMetadata.Kind.url: return text.title.map { "Link: \($0)" } ?? "Link"
        case TextMetadata.Kind.phoneNumber: return "Phone number"
        case TextMetadata.Kind.address: return "Address"
        default: return text.title ?? "Text"
        }
    }
}
