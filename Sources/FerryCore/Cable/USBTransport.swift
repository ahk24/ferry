import Foundation
import IOKit
import IOUSBHost

/// The phone's MTP interface: one bulk pipe out, one bulk pipe in. Calls are synchronous and
/// must come from one thread at a time (MTPDevice runs them on its own serial queue).
final class USBTransport {
    /// Transfer size per request. A multiple of every USB max packet size (512, 1024), so only
    /// the last request of a container can end in a short packet.
    static let chunkSize = 1 << 20

    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let readBuffer: NSMutableData
    private let writeBuffer: NSMutableData
    let maxPacketSize: Int
    let interfaceNumber: UInt16

    init(service: io_service_t) throws {
        interface = try Self.open(service)
        interfaceNumber = UInt16(interface.interfaceDescriptor.pointee.bInterfaceNumber)

        var inAddress: Int?
        var outAddress: Int?
        var packetSize = 512
        var current: UnsafePointer<IOUSBDescriptorHeader>?
        while let endpoint = IOUSBGetNextEndpointDescriptor(interface.configurationDescriptor, interface.interfaceDescriptor, current) {
            if IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointTypeBulk.rawValue) {
                let address = Int(IOUSBGetEndpointAddress(endpoint))
                if address & 0x80 != 0 {
                    inAddress = address
                    packetSize = Int(UInt16(littleEndian: endpoint.pointee.wMaxPacketSize) & 0x7FF)
                } else {
                    outAddress = address
                }
            }
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard let inAddress, let outAddress else {
            interface.destroy()
            throw CableError.usb("The phone's file-transfer interface has no data endpoints.")
        }
        maxPacketSize = max(64, packetSize)
        do {
            bulkIn = try interface.copyPipe(withAddress: inAddress)
            bulkOut = try interface.copyPipe(withAddress: outAddress)
            readBuffer = try interface.ioData(withCapacity: Self.chunkSize)
            writeBuffer = try interface.ioData(withCapacity: Self.chunkSize)
        } catch {
            interface.destroy()
            throw CableError.usb("Couldn't set up the USB pipes: \(error.localizedDescription)")
        }
    }

    /// macOS's Image Capture helper (ptpcamerad, a per-user agent that launchd restarts on demand)
    /// claims every phone in file-transfer mode as soon as it's plugged in, and ignores requests
    /// to let go. When it holds the phone, stop it and take the interface before it comes back.
    private static func open(_ service: io_service_t) throws -> IOUSBHostInterface {
        var lastError: Error?
        for attempt in 0..<8 {
            do {
                return try IOUSBHostInterface(__ioService: service, options: [.deviceSeize], queue: nil, interestHandler: nil)
            } catch {
                lastError = error
                let owners = userClientOwners(of: service)
                for owner in owners where owner.name == "ptpcamerad" {
                    kill(owner.pid, SIGKILL)
                }
                if owners.isEmpty && attempt > 2 { break }
                usleep(owners.isEmpty ? 300_000 : 60_000)
            }
        }
        let holder = userClientOwners(of: service).map(\.name).first
        throw CableError.usb("Couldn't open the phone's USB connection\(holder.map { " (it's in use by \($0))" } ?? ""). Quit Image Capture, Photos or Android File Transfer if they're open, then click Try again. (\(lastError?.localizedDescription ?? "unknown error"))")
    }

    /// Processes holding a user-space connection to this interface, from the I/O Registry.
    static func userClientOwners(of service: io_service_t) -> [(pid: pid_t, name: String)] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var owners: [(pid_t, String)] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            // Looks like "pid 3169, ptpcamerad".
            guard let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
                  creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ","),
                  let pid = pid_t(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]) else { continue }
            let name = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if pid != getpid() { owners.append((pid, name)) }
        }
        return owners
    }

    /// One bulk-in request of up to `chunkSize` bytes. Returns early on a short packet.
    func read(timeout: TimeInterval) throws -> Data {
        // I/O buffers from ioData(withCapacity:) have a fixed length (their capacity).
        var transferred = 0
        do {
            try bulkIn.__sendIORequest(with: readBuffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            try? bulkIn.clearStall()
            throw CableError.usb("Lost contact with the phone while reading (\(error.localizedDescription)).")
        }
        return Data(bytes: readBuffer.bytes, count: transferred)
    }

    /// Writes `data` as part of the current bulk-out transfer. Every call except a container's
    /// last must be a multiple of the packet size.
    func write(_ data: Data, timeout: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            let n = min(Self.chunkSize, data.count - offset)
            // Full chunks reuse the pre-mapped buffer; a shorter tail needs a buffer of its exact size.
            let buffer: NSMutableData
            if n == Self.chunkSize {
                buffer = writeBuffer
            } else {
                buffer = (try? interface.ioData(withCapacity: n)) ?? NSMutableData(length: n)!
            }
            data.copyBytes(to: buffer.mutableBytes.assumingMemoryBound(to: UInt8.self),
                           from: data.startIndex + offset ..< data.startIndex + offset + n)
            var transferred = 0
            do {
                try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
            } catch {
                try? bulkOut.clearStall()
                throw CableError.usb("Lost contact with the phone while writing (\(error.localizedDescription)).")
            }
            offset += n
        }
    }

    /// PTP's class-specific "Cancel Request" for the transaction in flight, then abort our pending
    /// I/O so the blocked read or write returns at once. Safe to call from any thread.
    func requestCancel(transactionID: UInt32) {
        let request = IOUSBDeviceRequest(bmRequestType: 0x21, bRequest: 0x64, wValue: 0, wIndex: interfaceNumber, wLength: 6)
        let data = NSMutableData(length: 6)!
        let b = data.mutableBytes.assumingMemoryBound(to: UInt8.self)
        b[0] = 0x01; b[1] = 0x40 // cancellation code 0x4001
        for i in 0..<4 { b[2 + i] = UInt8(truncatingIfNeeded: transactionID >> (8 * UInt32(i))) }
        var transferred = 0
        try? interface.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 2)
        try? bulkIn.__abort(with: .asynchronous)
        try? bulkOut.__abort(with: .asynchronous)
    }

    /// After a cancel: clear the pipes and wait until the phone reports it is ready again
    /// ("Get Device Status" returns OK), then drop anything it still had queued.
    func recoverAfterCancel() {
        try? bulkIn.clearStall()
        try? bulkOut.clearStall()
        for _ in 0..<50 {
            let request = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0x67, wValue: 0, wIndex: interfaceNumber, wLength: 32)
            let data = NSMutableData(length: 32)!
            var transferred = 0
            if (try? interface.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 1)) != nil, transferred >= 4 {
                let b = data.bytes.assumingMemoryBound(to: UInt8.self)
                if (UInt16(b[2]) | UInt16(b[3]) << 8) == PTP.Response.ok { break }
            }
            usleep(100_000)
        }
        drain()
    }

    /// Throws away anything the phone still had queued from an earlier, interrupted session.
    func drain() {
        for _ in 0..<64 {
            var transferred = 0
            do {
                try bulkIn.__sendIORequest(with: readBuffer, bytesTransferred: &transferred, completionTimeout: 0.15)
            } catch {
                try? bulkIn.clearStall()
                return
            }
            if transferred == 0 { return }
        }
    }

    /// Ends a transfer whose length was an exact multiple of the packet size.
    func writeZeroLengthPacket() throws {
        var transferred = 0
        try bulkOut.__sendIORequest(with: nil, bytesTransferred: &transferred, completionTimeout: 5)
    }

    func close() {
        interface.destroy()
    }
}
