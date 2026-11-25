import Foundation
import IOKit

public struct PhoneStorage: Identifiable, Hashable {
    public let id: UInt32
    public let name: String
    public let capacity: UInt64
    public let free: UInt64

    public init(id: UInt32, name: String, capacity: UInt64, free: UInt64) {
        self.id = id; self.name = name; self.capacity = capacity; self.free = free
    }
}

public struct PhoneItem: Identifiable, Hashable {
    public let id: UInt32 // object handle
    public let storageID: UInt32
    public let parent: UInt32
    public let name: String
    public let isFolder: Bool
    public let size: UInt64
    public let modified: Date?

    public init(id: UInt32, storageID: UInt32, parent: UInt32, name: String, isFolder: Bool, size: UInt64, modified: Date?) {
        self.id = id; self.storageID = storageID; self.parent = parent; self.name = name
        self.isFolder = isFolder; self.size = size; self.modified = modified
    }
}

/// One open MTP session with a phone. Not thread-safe: CablePhone serializes all calls.
final class MTPDevice {
    let manufacturer: String
    let model: String

    private let transport: USBTransport
    private var nextTransactionID: UInt32 = 0
    private let activeLock = NSLock()
    private var activeTransaction: UInt32?
    /// Set between SendObjectInfo and a completed SendObject, so a cancelled upload can be removed.
    private(set) var incompleteUpload: UInt32?
    private let timeout: TimeInterval = 20

    /// Called with the running byte count; return false to cancel.
    typealias Progress = (Int64) -> Bool

    private enum Outgoing {
        case bytes(Data)
        case file(FileHandle, size: UInt64, progress: Progress)
    }

    init(service: io_service_t) throws {
        transport = try USBTransport(service: service)
        transport.drain()
        var manufacturer = "Android"
        var model = "phone"
        do {
            // GetDeviceInfo is allowed before a session and tells us what to call the phone.
            var info = Data()
            try Self.run(transport, transactionID: 0, op: PTP.Op.getDeviceInfo, params: [], outgoing: nil) { info.append($0) }
            var r = PTPReader(info)
            _ = try r.u16(); _ = try r.u32(); _ = try r.u16(); _ = try r.string(); _ = try r.u16()
            _ = try r.u16Array(); _ = try r.u16Array(); _ = try r.u16Array(); _ = try r.u16Array(); _ = try r.u16Array()
            manufacturer = try r.string()
            model = try r.string()
        } catch {
            transport.close()
            throw error
        }
        self.manufacturer = manufacturer
        self.model = model
        nextTransactionID = 0

        // OpenSession uses transaction ID 0; numbering continues from 1.
        do {
            try transaction(PTP.Op.openSession, [1])
        } catch CableError.device(let message) where message.contains("0x201E") {
            // A session left open by an earlier run is fine to reuse.
        } catch {
            transport.close()
            throw error
        }
    }

    var displayName: String {
        let m = manufacturer.trimmingCharacters(in: .whitespaces)
        let n = model.trimmingCharacters(in: .whitespaces)
        if n.lowercased().hasPrefix(m.lowercased()) || m.isEmpty { return n }
        return "\(m.capitalized) \(n)"
    }

    func close() {
        _ = try? transaction(PTP.Op.closeSession)
        transport.close()
    }

    /// Stops the transaction in flight, if any. Any thread; the blocked call then throws.
    /// Returns whether there was one to stop.
    @discardableResult
    func cancelActive() -> Bool {
        guard let id = activeLock.withLock({ activeTransaction }) else { return false }
        transport.requestCancel(transactionID: id)
        return true
    }

    /// Call on the I/O queue after a cancelled transaction, before the next one.
    func recoverAfterCancel() {
        transport.recoverAfterCancel()
        if let handle = incompleteUpload {
            try? delete(handle)
            incompleteUpload = nil
        }
    }

    // MARK: Operations

    func storages() throws -> [PhoneStorage] {
        var idReader = PTPReader(try dataIn(PTP.Op.getStorageIDs))
        let ids = try idReader.u32Array()
        return try ids.compactMap { id in
            var r = PTPReader(try dataIn(PTP.Op.getStorageInfo, [id]))
            _ = try r.u16(); _ = try r.u16(); _ = try r.u16()
            let capacity = try r.u64()
            let free = try r.u64()
            _ = try r.u32()
            let description = try r.string()
            let label = try r.string()
            let name = description.isEmpty ? (label.isEmpty ? "Storage" : label) : description
            return PhoneStorage(id: id, name: name, capacity: capacity, free: free)
        }
    }

    func children(of parent: UInt32, storage: UInt32) throws -> [PhoneItem] {
        var handleReader = PTPReader(try dataIn(PTP.Op.getObjectHandles, [storage, 0, parent]))
        let handles = try handleReader.u32Array()
        return handles.compactMap { try? item($0) }
    }

    func item(_ handle: UInt32) throws -> PhoneItem {
        var r = PTPReader(try dataIn(PTP.Op.getObjectInfo, [handle]))
        let storage = try r.u32()
        let format = try r.u16()
        _ = try r.u16()
        var size = UInt64(try r.u32())
        _ = try r.u16() // thumb format
        _ = try r.u32() // thumb size
        for _ in 0..<5 { _ = try r.u32() } // thumb width/height, image width/height/bit depth
        let parent = try r.u32()
        let associationType = try r.u16()
        _ = try r.u32(); _ = try r.u32()
        let name = try r.string()
        _ = try r.string()
        let modified = try r.string()
        if size == 0xFFFF_FFFF, let exact = try? objectSize(handle) { size = exact }
        let isFolder = format == PTP.Format.association || associationType == 1
        return PhoneItem(id: handle, storageID: storage, parent: parent, name: name, isFolder: isFolder,
                         size: isFolder ? 0 : size, modified: Date(ptpString: modified))
    }

    private func objectSize(_ handle: UInt32) throws -> UInt64 {
        var r = PTPReader(try dataIn(PTP.Op.getObjectPropValue, [handle, UInt32(PTP.objectSizeProperty)]))
        return try r.u64()
    }

    /// Streams a file from the phone to `url`.
    func download(_ item: PhoneItem, to url: URL, progress: @escaping Progress) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw CableError.usb("Couldn't create \(url.lastPathComponent) on the Mac.")
        }
        var written: Int64 = 0
        do {
            try transaction(PTP.Op.getObject, [item.id]) { chunk in
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                _ = progress(written)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Deletes a file or folder (with its contents) on the phone. Used to clean up after tests.
    func delete(_ handle: UInt32) throws {
        try transaction(0x100B, [handle, 0])
    }

    /// Creates a folder and returns its handle.
    func createFolder(named name: String, in parent: UInt32, storage: UInt32) throws -> UInt32 {
        let info = objectInfo(name: name, format: PTP.Format.association, size: 0, storage: storage, modified: Date())
        let reply = try transaction(PTP.Op.sendObjectInfo, [storage, parent], outgoing: .bytes(info))
        guard reply.count >= 3 else { throw CableError.device("the phone didn't confirm the new folder") }
        return reply[2]
    }

    /// Copies a Mac file to the phone and returns the new object's handle.
    func upload(_ url: URL, as name: String, to parent: UInt32, storage: UInt32, progress: @escaping Progress) throws -> UInt32 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? Date()
        let info = objectInfo(name: name, format: PTP.Format.undefined, size: size, storage: storage, modified: modified)
        let reply = try transaction(PTP.Op.sendObjectInfo, [storage, parent], outgoing: .bytes(info))
        guard reply.count >= 3 else { throw CableError.device("the phone didn't accept the file") }
        incompleteUpload = reply[2]
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw CableError.usb("Couldn't read \(url.lastPathComponent).") }
        defer { try? handle.close() }
        try transaction(PTP.Op.sendObject, outgoing: .file(handle, size: size, progress: progress))
        incompleteUpload = nil
        return reply[2]
    }

    private func objectInfo(name: String, format: UInt16, size: UInt64, storage: UInt32, modified: Date) -> Data {
        var w = PTPWriter()
        w.u32(storage)
        w.u16(format)
        w.u16(0) // protection
        w.u32(size >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(size))
        w.u16(0); w.u32(0) // thumb format, thumb size
        for _ in 0..<5 { w.u32(0) } // thumb width/height, image width/height/depth
        w.u32(0) // parent: the SendObjectInfo parameter decides
        w.u16(format == PTP.Format.association ? 1 : 0) // association type: generic folder
        w.u32(0); w.u32(0) // association description, sequence number
        w.string(name)
        w.string(modified.ptpString) // created
        w.string(modified.ptpString) // modified
        w.string("") // keywords
        return w.data
    }

    // MARK: Transactions

    private func dataIn(_ op: UInt16, _ params: [UInt32] = []) throws -> Data {
        var data = Data()
        try transaction(op, params) { data.append($0) }
        return data
    }

    @discardableResult
    private func transaction(_ op: UInt16, _ params: [UInt32] = [], outgoing: Outgoing? = nil,
                             incoming: ((Data) throws -> Void)? = nil) throws -> [UInt32] {
        let id = nextTransactionID
        nextTransactionID &+= 1
        activeLock.withLock { activeTransaction = id }
        defer { activeLock.withLock { activeTransaction = nil } }
        guard Self.debug else {
            return try Self.run(transport, transactionID: id, op: op, params: params, outgoing: outgoing, incoming: incoming)
        }
        var received = 0
        do {
            let reply = try Self.run(transport, transactionID: id, op: op, params: params, outgoing: outgoing) { chunk in
                received += chunk.count
                try incoming?(chunk)
            }
            FileHandle.standardError.write(Data(String(format: "mtp: op 0x%04X tid %u params %@ -> OK, %d data bytes, reply %@\n",
                                                        op, id, params.description, received, reply.description).utf8))
            return reply
        } catch {
            FileHandle.standardError.write(Data(String(format: "mtp: op 0x%04X tid %u params %@ -> %@\n", op, id, params.description,
                                                        String(describing: error)).utf8))
            throw error
        }
    }

    static let debug = ProcessInfo.processInfo.environment["FERRY_MTP_DEBUG"] != nil

    @discardableResult
    private static func run(_ transport: USBTransport, transactionID: UInt32, op: UInt16, params: [UInt32],
                            outgoing: Outgoing?, timeout: TimeInterval = 20,
                            incoming: ((Data) throws -> Void)? = nil) throws -> [UInt32] {
        // Command phase
        var command = PTPWriter()
        command.u32(UInt32(12 + 4 * params.count))
        command.u16(PTP.ContainerType.command)
        command.u16(op)
        command.u32(transactionID)
        params.forEach { command.u32($0) }
        try transport.write(command.data, timeout: timeout)

        // Data phase, computer → phone
        if let outgoing {
            try send(outgoing, transport: transport, op: op, transactionID: transactionID, timeout: timeout)
        }

        // Data phase, phone → computer, then the response
        while true {
            var chunk = try transport.read(timeout: timeout)
            while chunk.isEmpty { chunk = try transport.read(timeout: timeout) } // a stray zero-length packet
            guard chunk.count >= 12 else { throw CableError.device("the phone sent a malformed reply") }
            var header = PTPReader(chunk.prefix(12))
            let length = try header.u32()
            let type = try header.u16()
            let code = try header.u16()
            let containerTransaction = try header.u32()
            // A leftover from an interrupted earlier exchange: read past it and keep waiting.
            let stale = containerTransaction != transactionID && type != PTP.ContainerType.event
            let sink: ((Data) throws -> Void)? = stale ? nil : incoming

            switch type {
            case PTP.ContainerType.data:
                let unknownLength = length == 0xFFFF_FFFF
                var remaining = unknownLength ? Int64.max : Int64(length) - Int64(chunk.count)
                if chunk.count > 12 { try sink?(chunk.dropFirst(12)) }
                var lastWasShort = chunk.count < USBTransport.chunkSize
                while remaining > 0 && !(unknownLength && lastWasShort) {
                    let next = try transport.read(timeout: timeout)
                    if !next.isEmpty { try sink?(next) }
                    remaining -= Int64(next.count)
                    lastWasShort = next.count < USBTransport.chunkSize
                    if next.isEmpty && !unknownLength { break }
                }
            case PTP.ContainerType.response where stale:
                continue
            case PTP.ContainerType.response:
                guard code == PTP.Response.ok || (op == PTP.Op.openSession && code == PTP.Response.sessionAlreadyOpen) else {
                    if code == PTP.Response.sessionAlreadyOpen { throw CableError.device("session already open (0x201E)") }
                    throw CableError.device(PTP.Response.describe(code))
                }
                var r = PTPReader(chunk.dropFirst(12))
                var replyParams: [UInt32] = []
                while let p = try? r.u32() { replyParams.append(p) }
                return replyParams
            default:
                continue // events on the bulk pipe: ignore
            }
        }
    }

    private static func send(_ outgoing: Outgoing, transport: USBTransport, op: UInt16, transactionID: UInt32,
                             timeout: TimeInterval) throws {
        let payloadSize: UInt64
        switch outgoing {
        case .bytes(let d): payloadSize = UInt64(d.count)
        case .file(_, let size, _): payloadSize = size
        }
        let total = payloadSize + 12
        var header = PTPWriter()
        header.u32(total > 0xFFFF_FFFE ? 0xFFFF_FFFF : UInt32(total))
        header.u16(PTP.ContainerType.data)
        header.u16(op)
        header.u32(transactionID)

        switch outgoing {
        case .bytes(let d):
            try transport.write(header.data + d, timeout: timeout)
        case .file(let handle, _, let progress):
            // First request carries the header so every request but the last is a full chunk.
            var buffer = header.data
            var sent: Int64 = 0
            while true {
                let want = USBTransport.chunkSize - buffer.count
                let body = try handle.read(upToCount: want) ?? Data()
                buffer.append(body)
                if buffer.isEmpty { break }
                try transport.write(buffer, timeout: timeout)
                sent += Int64(body.count)
                if !progress(sent) { throw CableError.canceled }
                if body.count < want { break }
                buffer = Data()
            }
        }
        if total % UInt64(transport.maxPacketSize) == 0 {
            try transport.writeZeroLengthPacket()
        }
    }
}
