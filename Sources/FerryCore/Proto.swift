import Foundation

// A deliberately small protobuf (proto2) codec. Quick Share only uses varints (int32, int64,
// enum, bool) and length-delimited fields (bytes, string, sub-messages), so that is all this
// handles. Writing it by hand keeps the project free of dependencies and code generation.

enum ProtoError: Error, CustomStringConvertible {
    case truncated
    case unsupportedWireType(UInt64)
    case malformed(String)

    var description: String {
        switch self {
        case .truncated: return "protobuf: message is truncated"
        case .unsupportedWireType(let w): return "protobuf: unsupported wire type \(w)"
        case .malformed(let s): return "protobuf: \(s)"
        }
    }
}

struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func key(_ field: Int, _ wireType: UInt64) {
        varint(UInt64(field) << 3 | wireType)
    }

    /// int32 / enum. Negative values are sign-extended to ten bytes, as protobuf requires.
    mutating func int(_ field: Int, _ value: Int?) {
        guard let value else { return }
        key(field, 0)
        varint(UInt64(bitPattern: Int64(value)))
    }

    mutating func int64(_ field: Int, _ value: Int64?) {
        guard let value else { return }
        key(field, 0)
        varint(UInt64(bitPattern: value))
    }

    mutating func bool(_ field: Int, _ value: Bool?) {
        guard let value else { return }
        key(field, 0)
        varint(value ? 1 : 0)
    }

    mutating func bytes(_ field: Int, _ value: Data?) {
        guard let value else { return }
        key(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String?) {
        bytes(field, value.map { Data($0.utf8) })
    }
}

/// Every field of one message, keyed by field number. Scalars read the last occurrence
/// (proto2 semantics); repeated fields read all of them.
struct ProtoFields {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    private(set) var values: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let b = [UInt8](data)
        var i = 0

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < b.count else { throw ProtoError.truncated }
                let byte = b[i]
                i += 1
                if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 + 7 { throw ProtoError.malformed("varint longer than 10 bytes") }
            }
        }

        while i < b.count {
            let key = try readVarint()
            let field = Int(truncatingIfNeeded: key >> 3)
            guard field > 0 else { throw ProtoError.malformed("field number 0") }
            let value: Value
            switch key & 7 {
            case 0:
                value = .varint(try readVarint())
            case 1:
                guard b.count - i >= 8 else { throw ProtoError.truncated }
                var v: UInt64 = 0
                for j in 0..<8 { v |= UInt64(b[i + j]) << (8 * UInt64(j)) }
                i += 8
                value = .fixed64(v)
            case 2:
                let length = try readVarint()
                guard length <= UInt64(b.count - i) else { throw ProtoError.truncated }
                let end = i + Int(length)
                value = .bytes(Data(b[i..<end]))
                i = end
            case 5:
                guard b.count - i >= 4 else { throw ProtoError.truncated }
                var v: UInt32 = 0
                for j in 0..<4 { v |= UInt32(b[i + j]) << (8 * UInt32(j)) }
                i += 4
                value = .fixed32(v)
            case let wire:
                throw ProtoError.unsupportedWireType(wire)
            }
            values[field, default: []].append(value)
        }
    }

    func has(_ field: Int) -> Bool { values[field] != nil }

    func uint64(_ field: Int) -> UInt64? {
        if case .varint(let v)? = values[field]?.last { return v }
        return nil
    }

    func int64(_ field: Int) -> Int64? { uint64(field).map { Int64(bitPattern: $0) } }

    /// int32 and enum fields.
    func int(_ field: Int) -> Int? { int64(field).map { Int(truncatingIfNeeded: $0) } }

    func bool(_ field: Int) -> Bool? { uint64(field).map { $0 != 0 } }

    func data(_ field: Int) -> Data? {
        if case .bytes(let d)? = values[field]?.last { return d }
        return nil
    }

    func string(_ field: Int) -> String? {
        data(field).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Repeated sub-messages or bytes.
    func all(_ field: Int) -> [Data] {
        (values[field] ?? []).compactMap {
            if case .bytes(let d) = $0 { return d }
            return nil
        }
    }

    func count(_ field: Int) -> Int { values[field]?.count ?? 0 }
}
