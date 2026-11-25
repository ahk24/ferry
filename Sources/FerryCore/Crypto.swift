import Foundation
import CryptoKit
import CommonCrypto

public enum FerryError: Error, LocalizedError {
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .protocolError(let message): return message
        }
    }
}

enum Bytes {
    /// Uses the system CSPRNG.
    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

extension Data {
    /// URL-safe base64 without padding, as Quick Share uses in mDNS names and TXT records.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}

// MARK: - UKEY2 key exchange

enum Ukey2Crypto {
    static let nextProtocol = "AES_256_CBC-HMAC_SHA256"
    static let cipherP256SHA512 = 100

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func sha512(_ data: Data) -> Data { Data(SHA512.hash(data: data)) }

    static func hkdf(_ ikm: Data, salt: Data, info: String, count: Int = 32) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                               info: Data(info.utf8), outputByteCount: count).data
    }

    static func hkdf(_ ikm: Data, salt: Data, info: Data, count: Int = 32) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                               info: info, outputByteCount: count).data
    }

    /// What Java's BigInteger.toByteArray() produces for a positive number: minimal big-endian
    /// two's complement, so a leading 0x00 appears when the top bit is set. Android parses the
    /// coordinates as signed integers, so a bare 32-byte value with the top bit set would read
    /// as negative.
    static func javaSigned(_ magnitude: Data) -> Data {
        var b = [UInt8](magnitude)
        while b.count > 1 && b[0] == 0 { b.removeFirst() }
        if let first = b.first, first & 0x80 != 0 { b.insert(0, at: 0) }
        return Data(b)
    }

    /// The inverse: any-length signed big-endian back to a 32-byte unsigned coordinate.
    static func unsigned32(_ signed: Data) throws -> Data {
        var b = [UInt8](signed)
        while b.count > 32 && b[0] == 0 { b.removeFirst() }
        guard b.count <= 32 else { throw FerryError.protocolError("peer public key coordinate is too long") }
        return Data(repeating: 0, count: 32 - b.count) + Data(b)
    }

    /// A GenericPublicKey message for our ECDH key.
    static func encodePublicKey(_ key: P256.KeyAgreement.PublicKey) -> Data {
        let raw = [UInt8](key.rawRepresentation) // x || y, 32 bytes each
        return GenericPublicKey(x: javaSigned(Data(raw[0..<32])), y: javaSigned(Data(raw[32..<64]))).encode()
    }

    static func decodePublicKey(_ data: Data) throws -> P256.KeyAgreement.PublicKey {
        let key = try GenericPublicKey.decode(data)
        do {
            return try P256.KeyAgreement.PublicKey(rawRepresentation: try unsigned32(key.x) + unsigned32(key.y))
        } catch {
            throw FerryError.protocolError("peer public key is not a valid P-256 point")
        }
    }

    /// The 4-digit code both devices can show so the user can check they're talking to each other.
    static func pinCode(_ authString: Data) -> String {
        var hash = 0
        var multiplier = 1
        for byte in authString {
            hash = (hash + Int(Int8(bitPattern: byte)) * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        return String(format: "%04d", abs(hash))
    }
}

/// The keys both ends derive once the UKEY2 handshake is complete.
struct SessionKeys {
    let authString: Data
    let encryptKey: Data
    let decryptKey: Data
    let sendHMACKey: SymmetricKey
    let receiveHMACKey: SymmetricKey

    var pin: String { Ukey2Crypto.pinCode(authString) }

    /// `clientInit` and `serverInit` are the complete serialized Ukey2Message bytes,
    /// without the 4-byte length prefix.
    static func derive(privateKey: P256.KeyAgreement.PrivateKey, peerKey: P256.KeyAgreement.PublicKey,
                       clientInit: Data, serverInit: Data, isServer: Bool) throws -> SessionKeys {
        typealias C = Ukey2Crypto
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let dhs = C.sha256(shared.withUnsafeBytes { Data($0) }) // the 32-byte X coordinate, hashed
        let transcript = clientInit + serverInit

        let authString = C.hkdf(dhs, salt: Data("UKEY2 v1 auth".utf8), info: transcript)
        let nextSecret = C.hkdf(dhs, salt: Data("UKEY2 v1 next".utf8), info: transcript)

        let d2dSalt = C.sha256(Data("D2D".utf8))
        let clientD2D = C.hkdf(nextSecret, salt: d2dSalt, info: "client")
        let serverD2D = C.hkdf(nextSecret, salt: d2dSalt, info: "server")

        let smSalt = C.sha256(Data("SecureMessage".utf8))
        let clientEncrypt = C.hkdf(clientD2D, salt: smSalt, info: "ENC:2")
        let clientHMAC = C.hkdf(clientD2D, salt: smSalt, info: "SIG:1")
        let serverEncrypt = C.hkdf(serverD2D, salt: smSalt, info: "ENC:2")
        let serverHMAC = C.hkdf(serverD2D, salt: smSalt, info: "SIG:1")

        if isServer {
            return SessionKeys(authString: authString, encryptKey: serverEncrypt, decryptKey: clientEncrypt,
                               sendHMACKey: SymmetricKey(data: serverHMAC), receiveHMACKey: SymmetricKey(data: clientHMAC))
        }
        return SessionKeys(authString: authString, encryptKey: clientEncrypt, decryptKey: serverEncrypt,
                           sendHMACKey: SymmetricKey(data: clientHMAC), receiveHMACKey: SymmetricKey(data: serverHMAC))
    }
}

// MARK: - Encrypted channel

/// After the handshake every frame is an OfflineFrame inside a DeviceToDeviceMessage, encrypted
/// with AES-256-CBC and signed with HMAC-SHA256 as a SecureMessage. Each direction numbers its
/// messages from 1.
final class SecureChannel {
    let keys: SessionKeys
    private var sendSequence: Int32 = 0
    private var receiveSequence: Int32 = 0

    init(keys: SessionKeys) { self.keys = keys }

    func seal(_ offlineFrame: Data) throws -> Data {
        sendSequence += 1
        let d2d = DeviceToDeviceMessage(message: offlineFrame, sequenceNumber: sendSequence).encode()
        let iv = Bytes.random(16)
        let body = try Self.aes(CCOperation(kCCEncrypt), key: keys.encryptKey, iv: iv, input: d2d)
        let headerAndBody = HeaderAndBody(iv: iv, publicMetadata: GcmMetadata().encode(), body: body).encode()
        let signature = Data(HMAC<SHA256>.authenticationCode(for: headerAndBody, using: keys.sendHMACKey))
        return SecureMessage(headerAndBody: headerAndBody, signature: signature).encode()
    }

    func open(_ secureMessage: Data) throws -> Data {
        let message = try SecureMessage.decode(secureMessage)
        guard HMAC<SHA256>.isValidAuthenticationCode(message.signature, authenticating: message.headerAndBody,
                                                     using: keys.receiveHMACKey) else {
            throw FerryError.protocolError("a message failed its integrity check")
        }
        let hb = try HeaderAndBody.decode(message.headerAndBody)
        let plain = try Self.aes(CCOperation(kCCDecrypt), key: keys.decryptKey, iv: hb.iv, input: hb.body)
        let d2d = try DeviceToDeviceMessage.decode(plain)
        receiveSequence += 1
        guard d2d.sequenceNumber == receiveSequence else {
            throw FerryError.protocolError("message out of sequence (expected \(receiveSequence), got \(d2d.sequenceNumber))")
        }
        return d2d.message
    }

    static func aes(_ operation: CCOperation, key: Data, iv: Data, input: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    input.withUnsafeBytes { i in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                i.baseAddress, input.count,
                                out.baseAddress, outputCapacity, &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw FerryError.protocolError("AES failed (\(status))") }
        return output.prefix(outputLength)
    }
}

// MARK: - QR code pairing (Mac → phone)

/// Android only advertises itself on Wi-Fi after it hears a Bluetooth "wake up" broadcast, which
/// macOS apps can't send. Scanning a quickshare.google QR code wakes the phone instead: it then
/// advertises a token derived from the key in the QR code, and accepts the transfer without a
/// prompt when we sign the session's auth string with that key.
public struct QRCodeKey {
    let signingKey: P256.Signing.PrivateKey
    /// 0x00 0x00, then the compressed public key (0x02 || X).
    let keyData: Data
    let advertisingToken: Data
    let nameKey: SymmetricKey

    public init() {
        // The QR format only carries an X coordinate with a fixed 0x02 prefix, so keep a key whose Y is even.
        var key = P256.Signing.PrivateKey()
        while key.publicKey.compressedRepresentation.first != 0x02 { key = P256.Signing.PrivateKey() }
        signingKey = key
        keyData = Data([0, 0]) + key.publicKey.compressedRepresentation
        advertisingToken = Ukey2Crypto.hkdf(keyData, salt: Data(), info: "advertisingContext", count: 16)
        nameKey = SymmetricKey(data: Ukey2Crypto.hkdf(keyData, salt: Data(), info: "encryptionKey", count: 16))
    }

    public var url: String { "https://quickshare.google/qrcode#key=\(keyData.base64URL)" }

    /// Checks the QR field of a phone's advertisement. Returns nil if it wasn't our QR code;
    /// otherwise the phone's name if it sent one encrypted (hidden devices), or "" if not.
    func match(_ qrData: Data) -> String? {
        if qrData == advertisingToken { return "" }
        guard qrData.count > 28,
              let box = try? AES.GCM.SealedBox(combined: qrData),
              let plain = try? AES.GCM.open(box, using: nameKey, authenticating: advertisingToken) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    /// Goes in PairedKeyEncryption.qr_code_handshake_data: an ECDSA P-256 / SHA-256 signature of
    /// the UKEY2 auth string, as raw R || S.
    func handshakeSignature(authString: Data) throws -> Data {
        try signingKey.signature(for: authString).rawRepresentation
    }
}

// MARK: - Endpoint info

/// The device description carried in the mDNS TXT record ("n") and in the connection request.
/// Byte 0: version (3 bits) | hidden (1 bit) | device type (3 bits) | reserved (1 bit).
/// Then 16 bytes of salt + encrypted metadata key (random is fine), then, for visible devices,
/// a length byte and the UTF-8 name. Optional TLVs follow (type 1 = QR data, 2 = vendor).
struct EndpointInfo {
    static let phone = 1
    static let tablet = 2
    static let laptop = 3

    var name: String?
    var deviceType: Int
    var qrData: Data?

    static func encode(name: String, deviceType: Int) -> Data {
        // Keep the base64 TXT entry under its 255-byte limit.
        var trimmed = name
        while trimmed.utf8.count > 150 { trimmed.removeLast() }
        var d = Data([UInt8(deviceType << 1)])
        d.append(Bytes.random(16))
        d.append(UInt8(trimmed.utf8.count))
        d.append(Data(trimmed.utf8))
        return d
    }

    init(name: String?, deviceType: Int, qrData: Data? = nil) {
        self.name = name
        self.deviceType = deviceType
        self.qrData = qrData
    }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 17 else { return nil }
        deviceType = Int((b[0] >> 1) & 7)
        var offset = 17
        if b[0] & 0x10 == 0 {
            guard b.count >= 18 else { return nil }
            let length = Int(b[17])
            guard b.count >= 18 + length else { return nil }
            name = String(decoding: b[18..<(18 + length)], as: UTF8.self)
            offset = 18 + length
        }
        while offset + 2 <= b.count {
            let type = b[offset], length = Int(b[offset + 1])
            guard offset + 2 + length <= b.count else { break }
            if type == 1 { qrData = Data(b[(offset + 2)..<(offset + 2 + length)]) }
            offset += 2 + length
        }
    }
}
