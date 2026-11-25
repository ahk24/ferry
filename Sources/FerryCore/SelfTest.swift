import Foundation
import Network
import CryptoKit

/// Checks that need no phone: protocol constants, the protobuf codec, key encodings, the QR
/// matching, and complete transfers between two in-process endpoints over loopback TCP.
/// A loopback transfer proves both roles agree with each other; it can't prove they agree with
/// Android. The constants section is what ties this implementation to the published protocol.
public enum SelfTest {
    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        print(condition ? "  ok    \(label)" : "  FAIL  \(label)")
        if !condition { failures += 1 }
    }

    @discardableResult
    private static func spin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    public static func run() -> Bool {
        failures = 0
        constants()
        protobuf()
        keyEncoding()
        endpointInfoAndQR()
        cableEncoding()
        loopbackTransfers()
        webShare()
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0
    }

    private static func constants() {
        print("Protocol constants")
        check(Ukey2Crypto.sha256(Data("NearbySharing".utf8)).hex.hasPrefix("fc9f5ed42c8a"), "service type is SHA-256(\"NearbySharing\")[0..6]")
        check(Ukey2Crypto.sha256(Data("D2D".utf8)).hex == "82aa55a0d397f88346ca1cee8d3909b95f13fa7deb1d4ab38376b8256da85510", "D2D salt")
        check(Ukey2Crypto.sha256(Data("SecureMessage".utf8)).hex == "bf9d2a53c63616d75db0a7165b91c1ef73e537f2427405fa23610a4be657642e", "SecureMessage salt")
        // RFC 5869 test case 3: HKDF-SHA256 with empty salt and info (the QR derivation relies on empty salt).
        let okm = Ukey2Crypto.hkdf(Data(repeating: 0x0b, count: 22), salt: Data(), info: Data(), count: 42)
        check(okm.hex == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8", "HKDF with empty salt matches RFC 5869")
    }

    private static func protobuf() {
        print("Protobuf codec")
        var w = ProtoWriter()
        w.int(1, 150)
        check(w.data.hex == "089601", "varint 150 encodes as 08 96 01")
        var neg = ProtoWriter()
        neg.int(1, -1)
        check(neg.data.count == 11, "negative int32 is sign-extended to 10 bytes")

        let file = FileMetadata(name: "photo.jpg", type: FileMetadata.Kind.image, payloadID: -42, size: 123_456,
                                mimeType: "image/jpeg", id: Int64.min)
        let text = TextMetadata(title: "example.com", type: TextMetadata.Kind.url, payloadID: 7, size: 19, id: 8)
        let intro = SharingFrame(type: .introduction, introduction: Introduction(files: [file], texts: [text]))
        if let back = try? SharingFrame.decode(intro.encode()), let f = back.introduction?.files.first, let t = back.introduction?.texts.first {
            check(back.type == .introduction && f.name == "photo.jpg" && f.payloadID == -42 && f.size == 123_456 && f.id == Int64.min,
                  "introduction with file metadata round-trips")
            check(t.type == TextMetadata.Kind.url && t.payloadID == 7 && t.title == "example.com", "text metadata round-trips")
        } else {
            check(false, "introduction round-trips")
        }

        let chunk = OfflineFrame.payload(PayloadHeader(id: 99, type: PayloadHeader.file, totalSize: 3),
                                         PayloadChunk(flags: 1, offset: 3, body: Data()))
        if let back = try? OfflineFrame.decode(chunk.encode()), let pt = back.payloadTransfer {
            check(back.type == .payloadTransfer && pt.header?.id == 99 && pt.chunk?.isLast == true && pt.chunk?.offset == 3,
                  "payload transfer frame round-trips")
        } else {
            check(false, "payload transfer frame round-trips")
        }
        check((try? ProtoFields(Data([0x0a, 0x05, 0x01]))) == nil, "truncated message is rejected")
    }

    private static func keyEncoding() {
        print("Key encoding")
        check(Ukey2Crypto.javaSigned(Data([0x80] + [UInt8](repeating: 1, count: 31))).count == 33, "high-bit coordinate gets a 0x00 prefix")
        check(Ukey2Crypto.javaSigned(Data([0x00, 0x7f] + [UInt8](repeating: 1, count: 30))).count == 31, "leading zero is dropped like BigInteger")
        let key = P256.KeyAgreement.PrivateKey()
        let decoded = try? Ukey2Crypto.decodePublicKey(Ukey2Crypto.encodePublicKey(key.publicKey))
        check(decoded?.rawRepresentation == key.publicKey.rawRepresentation, "GenericPublicKey round-trips")
        check(Ukey2Crypto.pinCode(Data(repeating: 0xff, count: 32)).count == 4, "PIN is four digits")
    }

    private static func endpointInfoAndQR() {
        print("Endpoint info and QR matching")
        let info = EndpointInfo(EndpointInfo.encode(name: "MacBook Pro", deviceType: EndpointInfo.laptop))
        check(info?.name == "MacBook Pro" && info?.deviceType == EndpointInfo.laptop, "our endpoint info parses back")

        let qr = QRCodeKey()
        check(qr.keyData.count == 35 && qr.keyData.prefix(3) == Data([0, 0, 2]), "QR key is 00 00 02 || X")
        check(qr.url.hasPrefix("https://quickshare.google/qrcode#key=") && !qr.url.contains("="+"="), "QR URL format")

        // A visible phone advertises the token; a hidden one advertises its name sealed with AES-GCM.
        var visible = Data([UInt8(EndpointInfo.phone << 1)]) + Bytes.random(16) + Data([5]) + Data("Pixel".utf8)
        visible += Data([1, 16]) + qr.advertisingToken
        check(EndpointInfo(visible).flatMap { $0.qrData.flatMap(qr.match) } == "", "visible phone matches by token")

        let sealed = try! AES.GCM.seal(Data("Galaxy S25".utf8), using: qr.nameKey, authenticating: qr.advertisingToken).combined!
        let hidden = Data([0x10 | UInt8(EndpointInfo.phone << 1)]) + Bytes.random(16) + Data([1, UInt8(sealed.count)]) + sealed
        check(EndpointInfo(hidden).flatMap { $0.qrData.flatMap(qr.match) } == "Galaxy S25", "hidden phone's name decrypts")
        check(QRCodeKey().match(qr.advertisingToken) == nil, "another QR code's token doesn't match")
    }

    private static func loopbackTransfers() {
        print("Loopback transfers")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ferry-selftest-\(UUID().uuidString)")
        let outbox = root.appendingPathComponent("outbox")
        let inbox = root.appendingPathComponent("inbox")
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: outbox, withIntermediateDirectories: true)

        let originals: [(String, Data)] = [
            ("big.bin", Bytes.random(3 * 1024 * 1024 + 123)), // several 512 KiB chunks plus a partial one
            ("empty.txt", Data()),
            ("notes ü.txt", Data("hello from the self-test\n".utf8)),
        ]
        var urls = originals.map { name, data -> URL in
            let url = outbox.appendingPathComponent(name)
            try? data.write(to: url)
            return url
        }
        // A folder with a subfolder, sent as one item.
        let album = outbox.appendingPathComponent("album")
        let albumFiles: [(String, Data)] = [("cover.jpg", Bytes.random(70_000)), ("tracks/01 intro.mp3", Bytes.random(900_000))]
        for (path, data) in albumFiles {
            let url = album.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        urls.append(album)
        let totalBytes = Int64(originals.reduce(0) { $0 + $1.1.count } + albumFiles.reduce(0) { $0 + $1.1.count })

        let receiver = NearbyService(deviceName: "Receiver", downloadDirectory: inbox)
        var acceptNext = true
        var received: [UUID: TransferSnapshot] = [:]
        var qrSignature: (Data, Data)?
        receiver.onIncomingRequest = { _, decide in decide(acceptNext) }
        receiver.onTransferUpdate = { received[$0.id] = $0 }
        receiver.debugQRSignatureHandler = { qrSignature = ($0, $1) }
        receiver.startAdvertising(bonjour: false, loopbackOnly: true)
        var port: UInt16 = 0
        spin(timeout: 5) {
            if case .visible(let p) = receiver.advertisingState { port = p }
            return port != 0
        }
        check(port != 0, "receiver listens on loopback")
        guard port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let sender = NearbyService(deviceName: "Sender", downloadDirectory: root.appendingPathComponent("unused"))
        var sent: [UUID: TransferSnapshot] = [:]
        sender.onTransferUpdate = { sent[$0.id] = $0 }
        let peer = Peer(id: "TEST", name: "Receiver", deviceType: EndpointInfo.laptop,
                        endpoint: .hostPort(host: "127.0.0.1", port: nwPort), matchedQRCode: false)

        // 1. Accepted transfer, with a QR signature riding along.
        let qr = QRCodeKey()
        let started = Date()
        let id = sender.send(files: urls, to: peer, qrKey: qr)
        spin(timeout: 30) {
            (sent[id]?.phase.isTerminal ?? false) && (received.values.first?.phase.isTerminal ?? false)
        }
        let outcome = sent[id]
        let inbound = received.values.first
        check(outcome?.phase == .done, "sender finished (\(outcome.map { "\($0.phase)" } ?? "no result"))")
        check(inbound?.phase == .done, "receiver finished (\(inbound.map { "\($0.phase)" } ?? "no result"))")
        check(outcome?.pin != nil && outcome?.pin == inbound?.pin, "both sides derived the same PIN (\(outcome?.pin ?? "-"))")
        check(inbound?.bytesDone == inbound?.totalBytes && inbound?.totalBytes == totalBytes, "receiver counted every byte")
        for (name, data) in originals {
            let saved = (try? Data(contentsOf: inbox.appendingPathComponent(name))) ?? Data([0xde, 0xad])
            check(saved == data, "\(name) arrived intact (\(data.count) bytes)")
        }
        for (path, data) in albumFiles {
            let saved = (try? Data(contentsOf: inbox.appendingPathComponent("album").appendingPathComponent(path))) ?? Data([0xde])
            check(saved == data, "folder kept its structure: album/\(path)")
        }
        check(inbound?.savedFiles.contains { $0.lastPathComponent == "album" } == true, "the folder is listed as one saved item")
        let mbps = Double(originals[0].1.count) / 1_048_576 / Date().timeIntervalSince(started)
        print(String(format: "        (%.0f MB/s over loopback)", mbps))
        if let (signature, auth) = qrSignature, let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            check(qr.signingKey.publicKey.isValidSignature(sig, for: auth), "QR handshake signature verifies against the session")
        } else {
            check(false, "QR handshake signature was sent")
        }

        // 2. Declined transfer: sender is told, nothing is written.
        acceptNext = false
        received = [:]
        let beforeDecline = (try? fm.contentsOfDirectory(atPath: inbox.path).count) ?? 0
        let declinedID = sender.send(files: [urls[2]], to: peer)
        spin(timeout: 15) { (sent[declinedID]?.phase.isTerminal ?? false) && (received.values.first?.phase.isTerminal ?? false) }
        check(sent[declinedID]?.phase == .declined, "sender sees the decline (\(sent[declinedID].map { "\($0.phase)" } ?? "no result"))")
        check(((try? fm.contentsOfDirectory(atPath: inbox.path).count) ?? 0) == beforeDecline, "declined transfer leaves no files")

        // 3. Same name again: saved alongside, not over, the first copy.
        acceptNext = true
        received = [:]
        let againID = sender.send(files: [urls[2]], to: peer)
        spin(timeout: 15) { (sent[againID]?.phase.isTerminal ?? false) && (received.values.first?.phase.isTerminal ?? false) }
        check(fm.fileExists(atPath: inbox.appendingPathComponent("notes ü (2).txt").path), "duplicate name gets \" (2)\"")

        receiver.stopAdvertising()
    }

    /// Live test against a phone plugged in by USB: browse, copy a folder there and back, clean up.
    public static func cableLive() -> Bool {
        failures = 0
        print("Cable mode, live")
        let cable = CableService()
        var states: [CableState] = []
        cable.onStateChange = { state in
            states.append(state)
            print("        state: \(state)")
        }
        var transfers: [UUID: TransferSnapshot] = [:]
        cable.onTransferUpdate = { transfers[$0.id] = $0 }
        cable.start()
        spin(timeout: 300) {
            if case .ready = cable.state { return true }
            if case .failed = cable.state { return true }
            return false
        }
        guard case .ready(let name) = cable.state else {
            check(false, "phone connected and sharing storage (state: \(cable.state))")
            return false
        }
        check(true, "connected to \(name)")

        func wait<T>(_ call: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error>? {
            var result: Result<T, Error>?
            call { result = $0 }
            spin(timeout: 60) { result != nil }
            return result
        }

        guard case .success(let storages)? = wait({ cable.storages($0) }), let storage = storages.first else {
            check(false, "phone lists its storage"); return false
        }
        check(true, "storage: " + storages.map { "\($0.name), \(Wording.gb($0.free)) free of \(Wording.gb($0.capacity))" }.joined(separator: "; "))
        guard case .success(let root)? = wait({ cable.list(storage: storage.id, folder: nil, $0) }) else {
            check(false, "phone lists its top folder"); return false
        }
        check(!root.isEmpty, "top folder: \(root.prefix(8).map(\.name).joined(separator: ", "))\(root.count > 8 ? ", …" : "") (\(root.count) items)")
        if let dcim = root.first(where: { $0.name == "DCIM" }), case .success(let inside)? = wait({ cable.list(storage: storage.id, folder: dcim.id, $0) }) {
            check(true, "DCIM: \(inside.map(\.name).joined(separator: ", "))")
        }

        // Round trip: a folder with a subfolder and a 20 MB file.
        let fm = FileManager.default
        let root2 = fm.temporaryDirectory.appendingPathComponent("ferry-cable-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root2) }
        let folderName = "Ferry cable test \(Int(Date().timeIntervalSince1970) % 100000)"
        let local = root2.appendingPathComponent(folderName)
        let big = Bytes.random(20 * 1024 * 1024 + 77)
        let small = Data("hello from the Mac\n".utf8)
        try? fm.createDirectory(at: local.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? big.write(to: local.appendingPathComponent("sub/big.bin"))
        try? small.write(to: local.appendingPathComponent("hello.txt"))

        var start = Date()
        let up = cable.copyToPhone([local])
        spin(timeout: 300) { transfers[up]?.phase.isTerminal == true }
        let upSeconds = Date().timeIntervalSince(start)
        check(transfers[up]?.phase == .done, "copied a folder to the phone's Download (\(transfers[up].map { "\($0.phase)" } ?? "no result"), \(String(format: "%.1f MB/s", 20 / upSeconds)))")

        guard case .success(let rootAgain)? = wait({ cable.list(storage: storage.id, folder: nil, $0) }),
              let download = rootAgain.first(where: { $0.isFolder && $0.name.lowercased() == "download" }),
              case .success(let downloads)? = wait({ cable.list(storage: storage.id, folder: download.id, $0) }),
              let uploaded = downloads.first(where: { $0.name == folderName }) else {
            check(false, "uploaded folder appears in Download"); return false
        }
        check(uploaded.isFolder, "it's a folder on the phone")

        let back = root2.appendingPathComponent("back")
        start = Date()
        let down = cable.copyToMac([uploaded], destination: back)
        spin(timeout: 300) { transfers[down]?.phase.isTerminal == true }
        let downSeconds = Date().timeIntervalSince(start)
        check(transfers[down]?.phase == .done, "copied it back to the Mac (\(transfers[down].map { "\($0.phase)" } ?? "no result"), \(String(format: "%.1f MB/s", 20 / downSeconds)))")
        check((try? Data(contentsOf: back.appendingPathComponent("\(folderName)/sub/big.bin"))) == big, "20 MB file identical after the round trip")
        check((try? Data(contentsOf: back.appendingPathComponent("\(folderName)/hello.txt"))) == small, "small file identical, folder structure kept")

        let deleted = wait({ (done: @escaping (Result<Bool, Error>) -> Void) in cable.deleteFromDownloadForTest(folderName) { done(.success($0)) } })
        check((try? deleted?.get()) == true, "test folder removed from the phone")
        print(failures == 0 ? "\nCable checks passed." : "\n\(failures) cable check(s) failed.")
        return failures == 0
    }

    /// Live: cancel mid-file in both directions; nothing half-copied may remain, and the
    /// connection must keep working afterwards.
    public static func cableCancelLive() -> Bool {
        failures = 0
        print("Cable cancel, live")
        let cable = CableService()
        var transfers: [UUID: TransferSnapshot] = [:]
        cable.onTransferUpdate = { transfers[$0.id] = $0 }
        cable.start()
        print("        (unlock the phone if it's locked)")
        spin(timeout: 180) { if case .ready = cable.state { return true }; return false }
        guard case .ready = cable.state else { check(false, "phone ready (\(cable.state))"); return false }

        func wait<T>(_ call: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error>? {
            var result: Result<T, Error>?
            call { result = $0 }
            spin(timeout: 60) { result != nil }
            return result
        }
        func downloadFolder() -> [PhoneItem] {
            guard case .success(let storages)? = wait({ cable.storages($0) }), let storage = storages.first,
                  case .success(let root)? = wait({ cable.list(storage: storage.id, folder: nil, $0) }),
                  let download = root.first(where: { $0.isFolder && $0.name.lowercased() == "download" }),
                  case .success(let items)? = wait({ cable.list(storage: storage.id, folder: download.id, $0) }) else { return [] }
            return items
        }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ferry-cancel-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func zeros(_ name: String, _ bytes: Int64) -> URL {
            let url = dir.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: nil)
            let h = try! FileHandle(forWritingTo: url)
            try? h.truncate(atOffset: UInt64(bytes))
            try? h.close()
            return url
        }

        // 1. Mac → phone, cancelled 2 s in.
        let bigName = "ferry-cancel-test-\(Int(Date().timeIntervalSince1970) % 100000).bin"
        let big = zeros(bigName, 400_000_000)
        let up = cable.copyToPhone([big])
        spin(timeout: 30) { transfers[up]?.phase == .transferring && (transfers[up]?.bytesDone ?? 0) > 0 }
        spin(timeout: 2) { false }
        let sentBefore = transfers[up]?.bytesDone ?? 0
        var t0 = Date()
        cable.cancel(up)
        spin(timeout: 30) { transfers[up]?.phase.isTerminal == true }
        check(transfers[up]?.phase == .canceled, String(format: "upload stopped mid-file (%@ after %.1f s, at %@ of 400 MB)",
              "\(transfers[up].map { "\($0.phase)" } ?? "?")", Date().timeIntervalSince(t0), Wording.gb(UInt64(sentBefore))))
        check(!downloadFolder().contains { $0.name == bigName }, "no partial file left on the phone")

        // 2. Phone → Mac, cancelled mid-file. First put a 120 MB file there.
        let mediumName = "ferry-cancel-test-dl-\(Int(Date().timeIntervalSince1970) % 100000).bin"
        let medium = zeros(mediumName, 120_000_000)
        let put = cable.copyToPhone([medium])
        spin(timeout: 120) { transfers[put]?.phase.isTerminal == true }
        check(transfers[put]?.phase == .done, "connection still works after the cancel (sent 120 MB)")
        guard let onPhone = downloadFolder().first(where: { $0.name == mediumName }) else {
            check(false, "120 MB file is on the phone"); return false
        }
        let back = dir.appendingPathComponent("back")
        let down = cable.copyToMac([onPhone], destination: back)
        spin(timeout: 30) { (transfers[down]?.bytesDone ?? 0) > 5_000_000 }
        t0 = Date()
        cable.cancel(down)
        spin(timeout: 30) { transfers[down]?.phase.isTerminal == true }
        check(transfers[down]?.phase == .canceled, String(format: "download stopped mid-file (%@ after %.1f s)",
              "\(transfers[down].map { "\($0.phase)" } ?? "?")", Date().timeIntervalSince(t0)))
        check(!fm.fileExists(atPath: back.appendingPathComponent(mediumName).path), "no partial file left on the Mac")

        // 3. Still healthy: list, then clean up the 120 MB file.
        check(!downloadFolder().isEmpty, "phone still answers after both cancels")
        let removed = wait({ (done: @escaping (Result<Bool, Error>) -> Void) in cable.deleteFromDownloadForTest(mediumName) { done(.success($0)) } })
        check((try? removed?.get()) == true, "test file removed from the phone")
        print(failures == 0 ? "\nCancel checks passed." : "\n\(failures) cancel check(s) failed.")
        return failures == 0
    }

    private static func cableEncoding() {
        print("USB (MTP) encoding")
        var w = PTPWriter()
        w.string("Download")
        w.string("")
        w.string("Ünïcödé 📷.jpg")
        w.u32(0xDEADBEEF)
        var r = PTPReader(w.data)
        check((try? r.string()) == "Download", "PTP string round-trips")
        check((try? r.string()) == "", "empty PTP string is one zero byte")
        check((try? r.string()) == "Ünïcödé 📷.jpg", "non-ASCII file names round-trip (UTF-16)")
        check((try? r.u32()) == 0xDEADBEEF, "little-endian integers")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        check(Date(ptpString: date.ptpString).map { abs($0.timeIntervalSince(date)) < 1 } == true, "PTP dates round-trip")
        check(FileNaming.uniqueName("IMG.jpg", avoiding: ["img.jpg", "img (2).jpg"]) == "IMG (3).jpg", "phone-side duplicate names are numbered")
        check(FileNaming.sanitize("../../etc/passwd") == "_.._etc_passwd", "names can't climb out of the folder")
    }

    private static func webShare() {
        print("Phone browser page (hotspot mode)")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ferry-web-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        let shared = root.appendingPathComponent("shared")
        try? fm.createDirectory(at: shared.appendingPathComponent("trip/day 1"), withIntermediateDirectories: true)
        let photo = Bytes.random(2_500_000)
        try? photo.write(to: shared.appendingPathComponent("trip/day 1/beach.jpg"))
        try? Data("itinerary".utf8).write(to: shared.appendingPathComponent("trip/plan.txt"))

        let web = WebShare(deviceName: "Test Mac", downloadDirectory: inbox)
        var updates: [UUID: TransferSnapshot] = [:]
        web.onTransferUpdate = { updates[$0.id] = $0 }
        web.start(loopbackOnly: true)
        var port: UInt16 = 0
        spin(timeout: 5) {
            if case .running(let p) = web.state { port = p }
            return port != 0
        }
        check(port != 0, "page server listens")
        guard port != 0 else { return }
        let base = "http://127.0.0.1:\(port)"

        func request(_ path: String, method: String = "GET", body: Data? = nil) -> (Int, Data) {
            var req = URLRequest(url: URL(string: base + path)!)
            req.httpMethod = method
            req.httpBody = body
            var result: (Int, Data)?
            URLSession.shared.dataTask(with: req) { data, response, _ in
                result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            }.resume()
            spin(timeout: 20) { result != nil }
            return result ?? (0, Data())
        }

        check(request("/").0 == 403, "no key: refused")
        check(request("/?k=wrong").0 == 403, "wrong key: refused")
        let page = request("/?k=\(web.key)")
        check(page.0 == 200 && String(decoding: page.1, as: UTF8.self).contains("Test Mac"), "right key: page served")

        web.offer([shared.appendingPathComponent("trip")])
        let state = request("/api/state?k=\(web.key)")
        let json = (try? JSONSerialization.jsonObject(with: state.1)) as? [String: Any]
        let files = json?["files"] as? [[String: Any]] ?? []
        check(files.count == 2, "a shared folder lists every file inside it (\(files.count))")
        if let beach = files.first(where: { $0["name"] as? String == "beach.jpg" }), let id = beach["id"] as? String {
            check(beach["folder"] as? String == "trip/day 1", "files keep their folder path")
            let download = request("/api/file/\(id)?k=\(web.key)")
            check(download.0 == 200 && download.1 == photo, "download is byte-identical (2.5 MB)")
        } else {
            check(false, "shared file is listed")
        }

        let upload = Bytes.random(3_000_000)
        let name = "IMG 2026 ü.heic".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let put = request("/api/upload?k=\(web.key)&name=\(name)&batch=b1&total=\(upload.count)", method: "PUT", body: upload)
        check(put.0 == 200, "upload accepted")
        check((try? Data(contentsOf: inbox.appendingPathComponent("IMG 2026 ü.heic"))) == upload, "upload saved byte-identical (3 MB)")
        spin(timeout: 2) { updates.values.contains { $0.direction == .incoming && $0.phase == .done } }
        check(updates.values.contains { $0.direction == .incoming && $0.phase == .done }, "upload shows as a finished transfer")
        check(request("/api/upload?k=wrong&name=x", method: "PUT", body: Data("x".utf8)).0 == 403, "upload with a wrong key: refused")

        // Cancel from the Mac in the middle of a 300 MB upload.
        var cancelled: Int?
        var big = URLRequest(url: URL(string: base + "/api/upload?k=\(web.key)&name=big.bin&batch=cx&total=300000000")!)
        big.httpMethod = "PUT"
        URLSession.shared.uploadTask(with: big, from: Data(count: 300_000_000)) { _, response, _ in
            cancelled = (response as? HTTPURLResponse)?.statusCode ?? -1
        }.resume()
        spin(timeout: 20) { updates.values.contains { $0.items.contains("big.bin") && $0.bytesDone > 0 } }
        let bigID = updates.values.first { $0.items.contains("big.bin") }?.id
        if let bigID { web.cancel(bigID) }
        spin(timeout: 15) { cancelled != nil }
        spin(timeout: 2) { bigID.flatMap { updates[$0] }?.phase == .canceled }
        let finalBytes = bigID.flatMap { updates[$0] }?.bytesDone ?? 0
        check(bigID.flatMap { updates[$0] }?.phase == .canceled && finalBytes < 300_000_000,
              "upload cancelled from the Mac mid-way (\(finalBytes / 1_000_000) of 300 MB)")
        spin(timeout: 2) { !FileManager.default.fileExists(atPath: inbox.appendingPathComponent("big.bin").path) }
        check(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("big.bin").path), "half-received file deleted")
        check(request("/api/upload?k=\(web.key)&name=next.bin&batch=cx", method: "PUT", body: Data("x".utf8)).0 == 409,
              "the rest of a cancelled batch is refused")
        web.stop()
    }
}
