import Foundation
import Network

/// A TCP connection carrying length-prefixed messages: each message is preceded by its length
/// as a 4-byte big-endian integer. All callbacks run on `queue`.
final class FrameConnection {
    static let maxFrameLength = 5 * 1024 * 1024

    let connection: NWConnection
    let queue: DispatchQueue
    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    private var finished = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.readLength()
            case .waiting(let error), .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: Data, completion: ((Error?) -> Void)? = nil) {
        let n = UInt32(frame.count)
        var out = Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                        UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        out.append(frame)
        connection.send(content: out, completion: .contentProcessed { error in completion?(error) })
    }

    func close() {
        connection.cancel()
    }

    private func readLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let error { self.finish(error); return }
            guard let data, data.count == 4 else {
                if isComplete { self.finish(nil) }
                return
            }
            let b = [UInt8](data)
            let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard length <= Self.maxFrameLength else {
                self.finish(FerryError.protocolError("received an oversized message (\(length) bytes)"))
                return
            }
            if length == 0 {
                self.deliver(Data())
            } else {
                self.readBody(length)
            }
        }
    }

    private func readBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let error { self.finish(error); return }
            guard let data, data.count == length else {
                self.finish(isComplete ? nil : FerryError.protocolError("connection closed mid-message"))
                return
            }
            self.deliver(data)
        }
    }

    private func deliver(_ frame: Data) {
        onFrame?(frame)
        if !finished { readLength() }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onClose?(error)
    }
}
