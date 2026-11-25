import Foundation
import Network
import UniformTypeIdentifiers

/// A small web server the phone opens in its browser (by scanning a QR code). It works over any
/// direct IP link, typically the phone's own hotspot with the Mac joined to it, so no router or
/// shared Wi-Fi is involved. The phone uploads files to the Mac and downloads what the Mac offers.
///
/// Every request must carry the random key from the QR code, so other devices on the same
/// network can't use it. Public methods are main-thread only; callbacks arrive on main.
public final class WebShare {
    public struct OfferedFile: Identifiable, Hashable {
        public let id: String
        public let url: URL
        /// Folder path inside what was picked, "" for files picked directly.
        public let folder: String
        public let size: Int64
        public var name: String { url.lastPathComponent }

        public init(id: String, url: URL, folder: String, size: Int64) {
            self.id = id
            self.url = url
            self.folder = folder
            self.size = size
        }
    }

    public enum State: Equatable {
        case off
        case running(port: UInt16)
        case failed(String)
    }

    public static let preferredPort: UInt16 = 8765

    public var onStateChange: ((State) -> Void)?
    public var onTransferUpdate: ((TransferSnapshot) -> Void)?
    public var onOffersChange: (([OfferedFile]) -> Void)?
    /// A phone reached the page (its IP address). Main thread.
    public var onPhoneContact: ((String) -> Void)?
    public var deviceName: String
    public var downloadDirectory: URL {
        get { lock.withLock { _downloadDirectory } }
        set { lock.withLock { _downloadDirectory = newValue } }
    }

    public private(set) var state: State = .off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public let key: String

    private let queue = DispatchQueue(label: "ferry.web")
    private var listener: NWListener?
    private let lock = NSLock()
    private var _downloadDirectory: URL
    private var _offered: [OfferedFile] = []
    private var batches: [String: TransferSnapshot] = [:] // touched on `queue`
    private var canceledBatches = Set<String>()            // under `lock`
    private var batchConnections: [String: [ObjectIdentifier: HTTPConnection]] = [:] // under `lock`
    private var lastPublished: [String: Date] = [:]

    /// Pass a saved `key` to keep the phone's bookmark working across launches.
    public init(deviceName: String, downloadDirectory: URL, key: String? = nil) {
        self.deviceName = deviceName
        _downloadDirectory = downloadDirectory
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        self.key = key ?? String((0..<16).map { _ in alphabet.randomElement()! })
    }

    public var offered: [OfferedFile] { lock.withLock { _offered } }

    // MARK: Lifecycle

    private var loopbackOnly = false

    public func start(loopbackOnly: Bool = false) {
        guard listener == nil else { return }
        self.loopbackOnly = loopbackOnly
        for port in [Self.preferredPort, 0] {
            do {
                let parameters = NWParameters.tcp
                if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any) }
                parameters.allowLocalEndpointReuse = true
                let listener = port == 0 ? try NWListener(using: parameters)
                                         : try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    DispatchQueue.main.async {
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            self.state = .running(port: listener.port?.rawValue ?? port)
                            Self.log("listening on port \(listener.port?.rawValue ?? port); addresses: \(Self.localAddresses().map { "\($0.interface)=\($0.address)" }.joined(separator: ", "))")
                        case .waiting(let e):
                            // Usually a network switch (e.g. joining the phone's hotspot); it recovers by itself.
                            Self.log("listener waiting: \(e)")
                        case .failed(let e):
                            // Don't stay down: start a fresh listener shortly.
                            Self.log("listener failed: \(e); restarting")
                            self.state = .failed(e.localizedDescription)
                            listener.cancel()
                            self.listener = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                                guard let self, self.listener == nil else { return }
                                self.start(loopbackOnly: self.loopbackOnly)
                            }
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    HTTPConnection(connection, share: self).start()
                }
                listener.start(queue: queue)
                self.listener = listener
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        state = .off
    }

    /// Adds files (and everything inside picked folders) to what the phone can download.
    public func offer(_ urls: [URL]) {
        let added = LocalTree.files(in: urls).map { entry in
            OfferedFile(id: UUID().uuidString.lowercased(), url: entry.url, folder: entry.folder,
                        size: LocalTree.size(of: entry.url))
        }
        let all: [OfferedFile] = lock.withLock {
            _offered.removeAll { old in added.contains { $0.url == old.url } }
            _offered.append(contentsOf: added)
            return _offered
        }
        onOffersChange?(all)
    }

    public func removeOffer(_ id: String) {
        let all: [OfferedFile] = lock.withLock {
            _offered.removeAll { $0.id == id }
            return _offered
        }
        onOffersChange?(all)
    }

    public func clearOffers() {
        lock.withLock { _offered.removeAll() }
        onOffersChange?([])
    }

    /// Addresses the phone can reach this Mac at, best first (Wi-Fi first).
    public static func localAddresses() -> [(interface: String, address: String)] {
        var result: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text.hasPrefix("169.254.") { continue }
            result.append((name, text))
        }
        return result.sorted { ($0.0 == "en0" ? 0 : 1, $0.0) < ($1.0 == "en0" ? 0 : 1, $1.0) }
    }

    public func pageURL(address: String) -> String? {
        guard case .running(let port) = state else { return nil }
        return "http://\(address):\(port)/?k=\(key)"
    }

    // MARK: Cancelling

    /// Stops an upload or download group: open connections are cut, a half-received file is
    /// deleted, and the page refuses the rest of that group.
    public func cancel(_ transferID: UUID) {
        queue.async { [self] in
            guard let batch = batches.first(where: { $0.value.id == transferID })?.key,
                  var snapshot = batches[batch], !snapshot.phase.isTerminal else { return }
            let connections: [HTTPConnection] = lock.withLock {
                canceledBatches.insert(batch)
                return Array((batchConnections[batch] ?? [:]).values)
            }
            connections.forEach { $0.abort() }
            snapshot.phase = .canceled
            batches[batch] = snapshot
            let s = snapshot
            DispatchQueue.main.async { [weak self] in self?.onTransferUpdate?(s) }
        }
    }

    func isCanceled(_ batch: String) -> Bool { lock.withLock { canceledBatches.contains(batch) } }

    fileprivate func track(_ connection: HTTPConnection, batch: String) {
        lock.withLock { batchConnections[batch, default: [:]][ObjectIdentifier(connection)] = connection }
    }

    fileprivate func untrack(_ connection: HTTPConnection, batch: String) {
        lock.withLock { batchConnections[batch]?[ObjectIdentifier(connection)] = nil }
    }

    // MARK: Diagnostics

    /// Every request goes to ~/Library/Logs/Ferry/web.log, so "the phone can't reach the Mac"
    /// can be told apart from "the phone reached it and something else failed".
    func noteRequest(from endpoint: NWEndpoint, method: String, path: String, authorized: Bool, status: String) {
        var host = "\(endpoint)"
        if case let .hostPort(h, _) = endpoint { host = "\(h)" }
        host = host.components(separatedBy: "%").first ?? host
        Self.log("\(host) \(method) \(path) -> \(status)\(authorized ? "" : " (missing or wrong key)")")
        if authorized && !host.hasPrefix("127.") && host != "::1" {
            DispatchQueue.main.async { [weak self] in self?.onPhoneContact?(host) }
        }
    }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ferry/web.log")

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    // MARK: Called by HTTPConnection on `queue`

    func offeredFile(_ id: String) -> OfferedFile? { lock.withLock { _offered.first { $0.id == id } } }

    func stateJSON() -> Data {
        let files = offered.map { ["id": $0.id, "name": $0.name, "folder": $0.folder, "size": $0.size] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: ["mac": deviceName, "files": files])) ?? Data("{}".utf8)
    }

    /// Progress for a group of uploads or downloads the page started together. Safe to call
    /// from any connection; updates reach the UI at most ten times a second per group.
    func batchProgress(_ batch: String, direction: TransferSnapshot.Direction, item: String, total: Int64,
                       addBytes: Int64, phase: TransferSnapshot.Phase?, savedFile: URL? = nil) {
        queue.async { [self] in
            var snapshot = batches[batch] ?? TransferSnapshot(id: UUID(), direction: direction, peerName: "Phone (browser)")
            if snapshot.phase == .canceled { return }
            let wasPhase = snapshot.phase
            if !snapshot.items.contains(item) { snapshot.items.append(item) }
            snapshot.totalBytes = max(snapshot.totalBytes, total)
            snapshot.bytesDone += addBytes
            if let savedFile { snapshot.savedFiles.append(savedFile) }
            if let phase { snapshot.phase = phase } else if !snapshot.phase.isTerminal { snapshot.phase = .transferring }
            if snapshot.phase == .transferring && snapshot.totalBytes > 0 && snapshot.bytesDone >= snapshot.totalBytes
                && (savedFile != nil || direction == .outgoing) {
                snapshot.phase = .done
            }
            batches[batch] = snapshot
            let now = Date()
            guard snapshot.phase != wasPhase || savedFile != nil || now.timeIntervalSince(lastPublished[batch] ?? .distantPast) > 0.1 else { return }
            lastPublished[batch] = now
            let s = snapshot
            DispatchQueue.main.async { [weak self] in self?.onTransferUpdate?(s) }
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

// MARK: - HTTP

/// One request per connection (we always answer with Connection: close).
final class HTTPConnection {
    private let connection: NWConnection
    private let share: WebShare
    private var buffer = Data()
    private var keepAlive: HTTPConnection?

    init(_ connection: NWConnection, share: WebShare) {
        self.connection = connection
        self.share = share
    }

    /// Cut the connection (used when the transfer is cancelled on the Mac).
    func abort() {
        connection.cancel()
    }

    func start() {
        keepAlive = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.keepAlive = nil
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "ferry.web.conn"))
        readHeader()
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: self.buffer[..<end.lowerBound], as: UTF8.self)
                let rest = Data(self.buffer[end.upperBound...])
                self.buffer = Data()
                self.handle(head: head, bodyStart: rest)
            } else if error != nil || complete || self.buffer.count > 32 * 1024 {
                self.connection.cancel()
            } else {
                self.readHeader()
            }
        }
    }

    private func handle(head: String, bodyStart: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return respond(400, text: "Bad request") }
        let method = String(parts[0])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let components = URLComponents(string: String(parts[1])) ?? URLComponents()
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = components.path

        let authorized = query["k"] == share.key
        share.noteRequest(from: connection.endpoint, method: method, path: path, authorized: authorized,
                          status: authorized ? "served" : "403")
        guard authorized else {
            return respond(403, html: WebPage.locked)
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(200, html: WebPage.html(macName: share.deviceName))
        case ("GET", "/api/state"):
            respond(200, json: share.stateJSON())
        case ("GET", let p) where p.hasPrefix("/api/file/"):
            serveFile(id: String(p.dropFirst("/api/file/".count)), batch: query["batch"] ?? UUID().uuidString,
                      batchTotal: Int64(query["total"] ?? "") ?? 0)
        case ("PUT", "/api/upload"), ("POST", "/api/upload"):
            guard let length = Int64(headers["content-length"] ?? "") else { return respond(411, text: "Length required") }
            receiveUpload(name: query["name"] ?? "file", length: length, batch: query["batch"] ?? UUID().uuidString,
                          batchTotal: Int64(query["total"] ?? "") ?? length, bodyStart: bodyStart)
        default:
            respond(404, text: "Not found")
        }
    }

    // MARK: Phone → Mac

    private func receiveUpload(name: String, length: Int64, batch: String, batchTotal: Int64, bodyStart: Data) {
        guard !share.isCanceled(batch) else { return respond(409, text: "Canceled on the Mac") }
        share.track(self, batch: batch)
        let url = FileNaming.uniqueURL(in: share.downloadDirectory, name: name)
        do {
            try FileManager.default.createDirectory(at: share.downloadDirectory, withIntermediateDirectories: true)
        } catch {
            return respond(500, text: "Couldn't open the download folder")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            return respond(500, text: "Couldn't save the file on the Mac")
        }
        let display = url.lastPathComponent
        share.batchProgress(batch, direction: .incoming, item: display, total: batchTotal, addBytes: 0, phase: .transferring)

        var received: Int64 = 0
        func write(_ data: Data) -> Bool {
            guard !data.isEmpty else { return true }
            let slice = data.prefix(Int(min(Int64(data.count), length - received)))
            do { try handle.write(contentsOf: slice) } catch { return false }
            received += Int64(slice.count)
            share.batchProgress(batch, direction: .incoming, item: display, total: batchTotal, addBytes: Int64(slice.count), phase: nil)
            return true
        }
        func fail(_ message: String) {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            share.untrack(self, batch: batch)
            if share.isCanceled(batch) { return connection.cancel() }
            share.batchProgress(batch, direction: .incoming, item: display, total: batchTotal, addBytes: 0, phase: .failed(message))
            respond(500, text: message)
        }
        func finish() {
            share.untrack(self, batch: batch)
            try? handle.close()
            InboundConnection.markQuarantined(url)
            share.batchProgress(batch, direction: .incoming, item: display, total: batchTotal, addBytes: 0, phase: nil, savedFile: url)
            respond(200, json: Data(#"{"ok":true}"#.utf8))
        }
        func readMore() {
            guard received < length else { return finish() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data, !write(data) { return fail("Couldn't write to the Mac's disk") }
                if received >= length { return finish() }
                if error != nil || complete { return fail("The upload was interrupted") }
                readMore()
            }
        }
        guard write(bodyStart) else { return fail("Couldn't write to the Mac's disk") }
        readMore()
    }

    // MARK: Mac → phone

    private func serveFile(id: String, batch: String, batchTotal: Int64) {
        guard let file = share.offeredFile(id), let handle = try? FileHandle(forReadingFrom: file.url) else {
            return respond(404, text: "That file is no longer shared")
        }
        let mime = UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let ascii = file.name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" ? String($0) : "_" }.joined()
        let encoded = file.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(file.size)\r\n"
            + "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        let total = max(batchTotal, file.size)
        guard !share.isCanceled(batch) else { try? handle.close(); return respond(409, text: "Canceled on the Mac") }
        share.track(self, batch: batch)
        share.batchProgress(batch, direction: .outgoing, item: file.name, total: total, addBytes: 0, phase: .transferring)

        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); return }
            self.sendChunks(handle, file: file, batch: batch, total: total)
        })
    }

    private func sendChunks(_ handle: FileHandle, file: WebShare.OfferedFile, batch: String, total: Int64) {
        let chunk = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        if chunk.isEmpty {
            try? handle.close()
            share.untrack(self, batch: batch)
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                self.share.untrack(self, batch: batch)
                if self.share.isCanceled(batch) { return }
                self.share.batchProgress(batch, direction: .outgoing, item: file.name, total: total, addBytes: 0,
                                         phase: .failed("The phone stopped the download."))
                self.connection.cancel()
                return
            }
            self.share.batchProgress(batch, direction: .outgoing, item: file.name, total: total, addBytes: Int64(chunk.count), phase: nil)
            self.sendChunks(handle, file: file, batch: batch, total: total)
        })
    }

    // MARK: Responses

    private func respond(_ status: Int, text: String) {
        respond(status, body: Data(text.utf8), type: "text/plain; charset=utf-8")
    }

    private func respond(_ status: Int, html: String) {
        respond(status, body: Data(html.utf8), type: "text/html; charset=utf-8")
    }

    private func respond(_ status: Int, json: Data) {
        respond(status, body: json, type: "application/json")
    }

    private func respond(_ status: Int, body: Data, type: String) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 411: "Length Required",
                      500: "Internal Server Error"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
    }
}
