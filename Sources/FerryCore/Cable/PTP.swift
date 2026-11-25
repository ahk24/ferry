import Foundation

// PTP/MTP: the protocol Android phones speak over USB in "File transfer" mode. Every exchange
// is a transaction: the computer sends a command container, optionally a data container goes
// one way, and the phone answers with a response container. Containers are little-endian:
//   UInt32 length (header included) | UInt16 type | UInt16 code | UInt32 transaction ID | payload

enum PTP {
    enum ContainerType {
        static let command: UInt16 = 1
        static let data: UInt16 = 2
        static let response: UInt16 = 3
        static let event: UInt16 = 4
    }

    enum Op {
        static let getDeviceInfo: UInt16 = 0x1001
        static let openSession: UInt16 = 0x1002
        static let closeSession: UInt16 = 0x1003
        static let getStorageIDs: UInt16 = 0x1004
        static let getStorageInfo: UInt16 = 0x1005
        static let getObjectHandles: UInt16 = 0x1007
        static let getObjectInfo: UInt16 = 0x1008
        static let getObject: UInt16 = 0x1009
        static let sendObjectInfo: UInt16 = 0x100C
        static let sendObject: UInt16 = 0x100D
        static let getObjectPropValue: UInt16 = 0x9803
    }

    enum Response {
        static let ok: UInt16 = 0x2001
        static let sessionAlreadyOpen: UInt16 = 0x201E

        static func describe(_ code: UInt16) -> String {
            switch code {
            case 0x2002: return "the phone reported a general error"
            case 0x2003: return "the phone closed the session"
            case 0x2005: return "the phone doesn't support that operation"
            case 0x2008: return "that storage isn't available"
            case 0x2009: return "that file no longer exists on the phone"
            case 0x200C: return "the phone's storage is full"
            case 0x200D: return "that file is read-only"
            case 0x200F: return "the phone denied access (is it unlocked?)"
            case 0x2013: return "the storage isn't available (unlock the phone)"
            case 0x2019: return "the phone is busy"
            case 0x201A: return "that folder no longer exists on the phone"
            default: return String(format: "the phone answered with error 0x%04X", code)
            }
        }
    }

    enum Format {
        static let undefined: UInt16 = 0x3000
        static let association: UInt16 = 0x3001 // a folder
    }

    static let objectSizeProperty: UInt16 = 0xDC04
    /// "No parent": the top level of a storage.
    static let root: UInt32 = 0xFFFF_FFFF
}

public enum CableError: Error, LocalizedError {
    case usb(String)
    case device(String)
    case canceled

    public var errorDescription: String? {
        switch self {
        case .usb(let message): return message
        case .device(let message): return message.prefix(1).uppercased() + message.dropFirst() + "."
        case .canceled: return "Canceled."
        }
    }
}

struct PTPWriter {
    private(set) var data = Data()

    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

    /// A count byte (characters including the terminating NUL), then UTF-16LE. Empty = one 0 byte.
    mutating func string(_ s: String) {
        var units = Array(s.utf16)
        if units.isEmpty { data.append(0); return }
        if units.count > 254 { units = Array(units.prefix(254)) }
        data.append(UInt8(units.count + 1))
        for unit in units + [0] { u16(unit) }
    }
}

struct PTPReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard offset + n <= bytes.count else { throw CableError.device("the phone sent a truncated reply") }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u16() throws -> UInt16 { try take(2).reversed().reduce(0) { $0 << 8 | UInt16($1) } }
    mutating func u32() throws -> UInt32 { try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) } }

    mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func u16Array() throws -> [UInt16] {
        let n = Int(try u32())
        return try (0..<n).map { _ in try u16() }
    }

    mutating func u32Array() throws -> [UInt32] {
        let n = Int(try u32())
        return try (0..<n).map { _ in try u32() }
    }
}

extension Date {
    /// PTP's "YYYYMMDDThhmmss", in local time.
    var ptpString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: self)
    }

    init?(ptpString s: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        guard s.count >= 15, let d = f.date(from: String(s.prefix(15))) else { return nil }
        self = d
    }
}
