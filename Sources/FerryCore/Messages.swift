import Foundation

// Field numbers follow the .proto files that ship with Google's Nearby Connections and Nearby
// Sharing code: offline_wire_formats.proto, wire_format.proto, ukey.proto, securemessage.proto
// and securegcm.proto. Only the fields Ferry reads or writes are modelled.

// MARK: - Nearby Connections (package location.nearby.connections)

enum OfflineFrameType: Int {
    case unknown = 0
    case connectionRequest = 1
    case connectionResponse = 2
    case payloadTransfer = 3
    case bandwidthUpgradeNegotiation = 4
    case keepAlive = 5
    case disconnection = 6
    case pairedKeyEncryption = 7
}

enum Medium { static let wifiLAN = 5 }
enum OSType { static let apple = 4 }

struct ConnectionRequest {
    var endpointID: String?
    var endpointName: String?
    var endpointInfo: Data?
    var mediums: [Int] = []

    func encode() -> Data {
        var w = ProtoWriter()
        w.string(1, endpointID)
        w.string(2, endpointName)
        for medium in mediums { w.int(5, medium) }
        w.bytes(6, endpointInfo)
        return w.data
    }

    static func decode(_ data: Data) throws -> ConnectionRequest {
        let f = try ProtoFields(data)
        return ConnectionRequest(endpointID: f.string(1), endpointName: f.string(2), endpointInfo: f.data(6))
    }
}

struct ConnectionResponse {
    static let accept = 1
    static let reject = 2

    var response: Int?
    var osType: Int?

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, 0) // deprecated `status` field; 0 means success
        w.int(3, response)
        if let osType {
            var os = ProtoWriter()
            os.int(1, osType)
            w.bytes(4, os.data)
        }
        return w.data
    }

    static func decode(_ data: Data) throws -> ConnectionResponse {
        let f = try ProtoFields(data)
        var response = f.int(3)
        // Old peers only fill the deprecated status field, where 0 means accepted.
        if response == nil, let status = f.int(1) { response = status == 0 ? accept : reject }
        var os: Int?
        if let osData = f.data(4) { os = try ProtoFields(osData).int(1) }
        return ConnectionResponse(response: response, osType: os)
    }
}

struct PayloadHeader {
    static let bytes = 1
    static let file = 2

    var id: Int64
    var type: Int
    var totalSize: Int64

    func encode() -> Data {
        var w = ProtoWriter()
        w.int64(1, id)
        w.int(2, type)
        w.int64(3, totalSize)
        w.bool(4, false) // is_sensitive
        return w.data
    }

    static func decode(_ data: Data) throws -> PayloadHeader {
        let f = try ProtoFields(data)
        return PayloadHeader(id: f.int64(1) ?? 0, type: f.int(2) ?? 0, totalSize: f.int64(3) ?? 0)
    }
}

struct PayloadChunk {
    static let lastChunk = 0x1

    var flags: Int
    var offset: Int64
    var body: Data

    var isLast: Bool { flags & PayloadChunk.lastChunk != 0 }

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, flags)
        w.int64(2, offset)
        if !body.isEmpty { w.bytes(3, body) }
        return w.data
    }

    static func decode(_ data: Data) throws -> PayloadChunk {
        let f = try ProtoFields(data)
        return PayloadChunk(flags: f.int(1) ?? 0, offset: f.int64(2) ?? 0, body: f.data(3) ?? Data())
    }
}

struct PayloadTransfer {
    static let data = 1
    static let control = 2

    enum ControlEvent {
        static let payloadError = 1
        static let payloadCanceled = 2
    }

    var packetType: Int
    var header: PayloadHeader?
    var chunk: PayloadChunk?
    var controlEvent: Int?

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, packetType)
        w.bytes(2, header?.encode())
        w.bytes(3, chunk?.encode())
        return w.data
    }

    static func decode(_ data: Data) throws -> PayloadTransfer {
        let f = try ProtoFields(data)
        var control: Int?
        if let c = f.data(4) { control = try ProtoFields(c).int(1) }
        return PayloadTransfer(
            packetType: f.int(1) ?? 0,
            header: try f.data(2).map(PayloadHeader.decode),
            chunk: try f.data(3).map(PayloadChunk.decode),
            controlEvent: control
        )
    }
}

/// OfflineFrame and its V1Frame, flattened into one value.
struct OfflineFrame {
    var type: OfflineFrameType
    var connectionRequest: ConnectionRequest? = nil
    var connectionResponse: ConnectionResponse? = nil
    var payloadTransfer: PayloadTransfer? = nil
    var keepAliveAck: Bool? = nil

    static func payload(_ header: PayloadHeader, _ chunk: PayloadChunk) -> OfflineFrame {
        OfflineFrame(type: .payloadTransfer,
                     payloadTransfer: PayloadTransfer(packetType: PayloadTransfer.data, header: header, chunk: chunk))
    }

    func encode() -> Data {
        var v1 = ProtoWriter()
        v1.int(1, type.rawValue)
        v1.bytes(2, connectionRequest?.encode())
        v1.bytes(3, connectionResponse?.encode())
        v1.bytes(4, payloadTransfer?.encode())
        if type == .keepAlive {
            var k = ProtoWriter()
            k.bool(1, keepAliveAck ?? false)
            v1.bytes(6, k.data)
        }
        if type == .disconnection { v1.bytes(7, Data()) }

        var w = ProtoWriter()
        w.int(1, 1) // Version.V1
        w.bytes(2, v1.data)
        return w.data
    }

    static func decode(_ data: Data) throws -> OfflineFrame {
        let f = try ProtoFields(data)
        guard let v1Data = f.data(2) else { throw ProtoError.malformed("OfflineFrame has no v1 frame") }
        let v1 = try ProtoFields(v1Data)
        var frame = OfflineFrame(type: OfflineFrameType(rawValue: v1.int(1) ?? 0) ?? .unknown)
        if let d = v1.data(2) { frame.connectionRequest = try ConnectionRequest.decode(d) }
        if let d = v1.data(3) { frame.connectionResponse = try ConnectionResponse.decode(d) }
        if let d = v1.data(4) { frame.payloadTransfer = try PayloadTransfer.decode(d) }
        if let d = v1.data(6) { frame.keepAliveAck = try ProtoFields(d).bool(1) ?? false }
        return frame
    }
}

// MARK: - Nearby Sharing (package sharing.nearby)

enum SharingFrameType: Int {
    case unknown = 0
    case introduction = 1
    case response = 2
    case pairedKeyEncryption = 3
    case pairedKeyResult = 4
    case certificateInfo = 5
    case cancel = 6
    case progressUpdate = 7
}

enum ResponseStatus {
    static let accept = 1
    static let reject = 2
    static let notEnoughSpace = 3
    static let unsupportedAttachmentType = 4
    static let timedOut = 5
}

enum PairedKeyResultStatus {
    static let unable = 3
}

struct FileMetadata {
    enum Kind {
        static let unknown = 0
        static let image = 1
        static let video = 2
        static let androidApp = 3
        static let audio = 4
    }

    var name: String
    var type: Int
    var payloadID: Int64
    var size: Int64
    var mimeType: String
    var id: Int64
    /// Relative folder path ("Photos/2024") when the file is part of a shared folder.
    var parentFolder: String? = nil

    func encode() -> Data {
        var w = ProtoWriter()
        w.string(1, name)
        w.int(2, type)
        w.int64(3, payloadID)
        w.int64(4, size)
        w.string(5, mimeType)
        w.int64(6, id)
        w.string(7, parentFolder)
        return w.data
    }

    static func decode(_ data: Data) throws -> FileMetadata {
        let f = try ProtoFields(data)
        return FileMetadata(
            name: f.string(1) ?? "file",
            type: f.int(2) ?? Kind.unknown,
            payloadID: f.int64(3) ?? 0,
            size: f.int64(4) ?? 0,
            mimeType: f.string(5) ?? "application/octet-stream",
            id: f.int64(6) ?? 0,
            parentFolder: f.string(7).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

struct TextMetadata {
    enum Kind {
        static let text = 1
        static let url = 2
        static let address = 3
        static let phoneNumber = 4
    }

    var title: String?
    var type: Int
    var payloadID: Int64
    var size: Int64
    var id: Int64

    func encode() -> Data {
        var w = ProtoWriter()
        w.string(2, title)
        w.int(3, type)
        w.int64(4, payloadID)
        w.int64(5, size)
        w.int64(6, id)
        return w.data
    }

    static func decode(_ data: Data) throws -> TextMetadata {
        let f = try ProtoFields(data)
        return TextMetadata(title: f.string(2), type: f.int(3) ?? 0, payloadID: f.int64(4) ?? 0,
                            size: f.int64(5) ?? 0, id: f.int64(6) ?? 0)
    }
}

struct Introduction {
    var files: [FileMetadata] = []
    var texts: [TextMetadata] = []
    /// Wi-Fi credentials, apps and streams. Ferry doesn't receive these.
    var unsupportedAttachments = 0

    func encode() -> Data {
        var w = ProtoWriter()
        for file in files { w.bytes(1, file.encode()) }
        for text in texts { w.bytes(2, text.encode()) }
        return w.data
    }

    static func decode(_ data: Data) throws -> Introduction {
        let f = try ProtoFields(data)
        return Introduction(
            files: try f.all(1).map(FileMetadata.decode),
            texts: try f.all(2).map(TextMetadata.decode),
            unsupportedAttachments: f.count(4) + f.count(5) + f.count(7)
        )
    }
}

struct PairedKeyEncryption {
    var signedData: Data
    var secretIDHash: Data
    var qrCodeHandshakeData: Data?

    func encode() -> Data {
        var w = ProtoWriter()
        w.bytes(1, signedData)
        w.bytes(2, secretIDHash)
        w.bytes(4, qrCodeHandshakeData)
        return w.data
    }

    static func decode(_ data: Data) throws -> PairedKeyEncryption {
        let f = try ProtoFields(data)
        return PairedKeyEncryption(signedData: f.data(1) ?? Data(), secretIDHash: f.data(2) ?? Data(),
                                   qrCodeHandshakeData: f.data(4))
    }
}

/// sharing.nearby.Frame and its V1Frame, flattened into one value.
struct SharingFrame {
    var type: SharingFrameType
    var introduction: Introduction? = nil
    var responseStatus: Int? = nil
    var pairedKeyEncryption: PairedKeyEncryption? = nil
    var pairedKeyResultStatus: Int? = nil

    func encode() -> Data {
        var v1 = ProtoWriter()
        v1.int(1, type.rawValue)
        v1.bytes(2, introduction?.encode())
        if let responseStatus {
            var r = ProtoWriter()
            r.int(1, responseStatus)
            v1.bytes(3, r.data)
        }
        v1.bytes(4, pairedKeyEncryption?.encode())
        if let pairedKeyResultStatus {
            var r = ProtoWriter()
            r.int(1, pairedKeyResultStatus)
            v1.bytes(5, r.data)
        }

        var w = ProtoWriter()
        w.int(1, 1) // Version.V1
        w.bytes(2, v1.data)
        return w.data
    }

    static func decode(_ data: Data) throws -> SharingFrame {
        let f = try ProtoFields(data)
        guard let v1Data = f.data(2) else { throw ProtoError.malformed("sharing frame has no v1 frame") }
        let v1 = try ProtoFields(v1Data)
        var frame = SharingFrame(type: SharingFrameType(rawValue: v1.int(1) ?? 0) ?? .unknown)
        if let d = v1.data(2) { frame.introduction = try Introduction.decode(d) }
        if let d = v1.data(3) { frame.responseStatus = try ProtoFields(d).int(1) }
        if let d = v1.data(4) { frame.pairedKeyEncryption = try PairedKeyEncryption.decode(d) }
        if let d = v1.data(5) { frame.pairedKeyResultStatus = try ProtoFields(d).int(1) }
        return frame
    }
}

// MARK: - UKEY2 (package securegcm, ukey.proto)

enum Ukey2Type: Int {
    case unknown = 0
    case alert = 1
    case clientInit = 2
    case serverInit = 3
    case clientFinish = 4
}

enum Ukey2AlertType {
    static let badMessageType = 2
    static let badMessageData = 4
    static let badVersion = 100
    static let badRandom = 101
    static let badHandshakeCipher = 102
    static let badNextProtocol = 103
    static let badPublicKey = 104
}

struct Ukey2Message {
    var type: Ukey2Type
    var data: Data

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, type.rawValue)
        w.bytes(2, data)
        return w.data
    }

    static func decode(_ data: Data) throws -> Ukey2Message {
        let f = try ProtoFields(data)
        return Ukey2Message(type: Ukey2Type(rawValue: f.int(1) ?? 0) ?? .unknown, data: f.data(2) ?? Data())
    }

    /// Decodes a message and checks its type. A peer that gives up sends an ALERT instead.
    static func decode(_ data: Data, expecting expected: Ukey2Type) throws -> Ukey2Message {
        let message = try decode(data)
        if message.type == .alert {
            let alert = try? Ukey2Alert.decode(message.data)
            throw FerryError.protocolError("the other device ended the key exchange (UKEY2 alert \(alert?.type ?? 0)\(alert?.message.map { ": \($0)" } ?? ""))")
        }
        guard message.type == expected else {
            throw FerryError.protocolError("expected UKEY2 \(expected), got \(message.type)")
        }
        return message
    }
}

struct Ukey2Alert {
    var type: Int
    var message: String?

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, type)
        w.string(2, message)
        return w.data
    }

    static func decode(_ data: Data) throws -> Ukey2Alert {
        let f = try ProtoFields(data)
        return Ukey2Alert(type: f.int(1) ?? 0, message: f.string(2))
    }
}

struct CipherCommitment {
    var cipher: Int
    var commitment: Data

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, cipher)
        w.bytes(2, commitment)
        return w.data
    }

    static func decode(_ data: Data) throws -> CipherCommitment {
        let f = try ProtoFields(data)
        return CipherCommitment(cipher: f.int(1) ?? 0, commitment: f.data(2) ?? Data())
    }
}

struct Ukey2ClientInit {
    var version: Int
    var random: Data
    var commitments: [CipherCommitment]
    var nextProtocol: String?

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, version)
        w.bytes(2, random)
        for c in commitments { w.bytes(3, c.encode()) }
        w.string(4, nextProtocol)
        return w.data
    }

    static func decode(_ data: Data) throws -> Ukey2ClientInit {
        let f = try ProtoFields(data)
        return Ukey2ClientInit(version: f.int(1) ?? 0, random: f.data(2) ?? Data(),
                               commitments: try f.all(3).map(CipherCommitment.decode), nextProtocol: f.string(4))
    }
}

struct Ukey2ServerInit {
    var version: Int
    var random: Data
    var cipher: Int
    var publicKey: Data

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, version)
        w.bytes(2, random)
        w.int(3, cipher)
        w.bytes(4, publicKey)
        return w.data
    }

    static func decode(_ data: Data) throws -> Ukey2ServerInit {
        let f = try ProtoFields(data)
        return Ukey2ServerInit(version: f.int(1) ?? 0, random: f.data(2) ?? Data(),
                               cipher: f.int(3) ?? 0, publicKey: f.data(4) ?? Data())
    }
}

struct Ukey2ClientFinished {
    var publicKey: Data

    func encode() -> Data {
        var w = ProtoWriter()
        w.bytes(1, publicKey)
        return w.data
    }

    static func decode(_ data: Data) throws -> Ukey2ClientFinished {
        Ukey2ClientFinished(publicKey: try ProtoFields(data).data(1) ?? Data())
    }
}

/// securemessage.GenericPublicKey, EC_P256 only. Coordinates are big-endian two's complement.
struct GenericPublicKey {
    static let ecP256 = 1

    var x: Data
    var y: Data

    func encode() -> Data {
        var ec = ProtoWriter()
        ec.bytes(1, x)
        ec.bytes(2, y)
        var w = ProtoWriter()
        w.int(1, GenericPublicKey.ecP256)
        w.bytes(2, ec.data)
        return w.data
    }

    static func decode(_ data: Data) throws -> GenericPublicKey {
        let f = try ProtoFields(data)
        guard f.int(1) == ecP256, let ecData = f.data(2) else {
            throw FerryError.protocolError("peer public key is not EC P-256")
        }
        let ec = try ProtoFields(ecData)
        guard let x = ec.data(1), let y = ec.data(2) else { throw FerryError.protocolError("peer public key is incomplete") }
        return GenericPublicKey(x: x, y: y)
    }
}

// MARK: - SecureMessage (packages securemessage and securegcm)

struct SecureMessage {
    var headerAndBody: Data
    var signature: Data

    func encode() -> Data {
        var w = ProtoWriter()
        w.bytes(1, headerAndBody)
        w.bytes(2, signature)
        return w.data
    }

    static func decode(_ data: Data) throws -> SecureMessage {
        let f = try ProtoFields(data)
        guard let hb = f.data(1), let sig = f.data(2) else { throw ProtoError.malformed("SecureMessage is incomplete") }
        return SecureMessage(headerAndBody: hb, signature: sig)
    }
}

struct HeaderAndBody {
    static let hmacSHA256 = 1
    static let aes256CBC = 2

    var iv: Data
    var publicMetadata: Data?
    var body: Data

    func encode() -> Data {
        var header = ProtoWriter()
        header.int(1, HeaderAndBody.hmacSHA256)
        header.int(2, HeaderAndBody.aes256CBC)
        header.bytes(5, iv)
        header.bytes(6, publicMetadata)
        var w = ProtoWriter()
        w.bytes(1, header.data)
        w.bytes(2, body)
        return w.data
    }

    static func decode(_ data: Data) throws -> HeaderAndBody {
        let f = try ProtoFields(data)
        guard let headerData = f.data(1), let body = f.data(2) else { throw ProtoError.malformed("HeaderAndBody is incomplete") }
        let header = try ProtoFields(headerData)
        guard let iv = header.data(5), iv.count == 16 else { throw ProtoError.malformed("SecureMessage IV missing") }
        return HeaderAndBody(iv: iv, publicMetadata: header.data(6), body: body)
    }
}

struct GcmMetadata {
    static let deviceToDeviceMessage = 13

    func encode() -> Data {
        var w = ProtoWriter()
        w.int(1, GcmMetadata.deviceToDeviceMessage)
        w.int(2, 1) // version
        return w.data
    }
}

struct DeviceToDeviceMessage {
    var message: Data
    var sequenceNumber: Int32

    func encode() -> Data {
        var w = ProtoWriter()
        w.bytes(1, message)
        w.int(2, Int(sequenceNumber))
        return w.data
    }

    static func decode(_ data: Data) throws -> DeviceToDeviceMessage {
        let f = try ProtoFields(data)
        guard let message = f.data(1), let seq = f.int(2) else { throw ProtoError.malformed("DeviceToDeviceMessage is incomplete") }
        return DeviceToDeviceMessage(message: message, sequenceNumber: Int32(truncatingIfNeeded: seq))
    }
}
