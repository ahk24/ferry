import Foundation
import IOKit

public enum CableState: Equatable {
    case none
    case connecting
    /// Connected, but the phone isn't sharing its storage yet (locked, or "Allow access?" not answered).
    case waitingForPhone(String)
    case ready(String)
    case failed(String)

    public var phoneName: String? {
        switch self {
        case .waitingForPhone(let n), .ready(let n): return n
        default: return nil
        }
    }
}

/// Watches for an Android phone plugged in over USB in "File transfer" mode and moves files
/// both ways over MTP. Public methods are called on the main thread and call back on it.
public final class CableService {
    public var onStateChange: ((CableState) -> Void)?
    public var onTransferUpdate: ((TransferSnapshot) -> Void)?
    public private(set) var state: CableState = .none {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let watchQueue = DispatchQueue(label: "ferry.cable.watch")
    private let queue = DispatchQueue(label: "ferry.cable.io") // every MTP call runs here
    private var notifyPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0

    // Touched only on `queue`.
    private var device: MTPDevice?
    private var deviceEntryID: UInt64 = 0
    private var pendingService: (io_service_t, UInt64)?

    private let cancelLock = NSLock()
    private var canceled = Set<UUID>()
    private var activeTransfer: (id: UUID, device: MTPDevice)?

    public init() {}

    public func start() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, watchQueue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostInterface"),
                                         { refcon, iterator in
                                             Unmanaged<CableService>.fromOpaque(refcon!).takeUnretainedValue().interfacesAppeared(iterator)
                                         }, me, &attachIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostInterface"),
                                         { refcon, iterator in
                                             Unmanaged<CableService>.fromOpaque(refcon!).takeUnretainedValue().interfacesVanished(iterator)
                                         }, me, &detachIterator)
        watchQueue.async { [self] in
            interfacesAppeared(attachIterator)
            interfacesVanished(detachIterator)
        }
    }

    /// Try again after an error (for example after closing Image Capture).
    public func retry() {
        queue.async { [self] in
            if let (service, id) = pendingService { connect(service, entryID: id) }
            else if device != nil { checkStorage() }
        }
    }

    // MARK: Detecting the phone

    private func interfacesAppeared(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            guard Self.isFileTransferInterface(service) else { IOObjectRelease(service); continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            queue.async { [self] in connect(service, entryID: entryID) }
        }
    }

    private func interfacesVanished(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            IOObjectRelease(service)
            queue.async { [self] in
                guard entryID == deviceEntryID || entryID == pendingService?.1 else { return }
                device?.close()
                device = nil
                deviceEntryID = 0
                if let (s, _) = pendingService { IOObjectRelease(s) }
                pendingService = nil
                setState(.none)
            }
        }
    }

    /// Android's MTP interface is vendor-specific (class 0xFF) and named "MTP"; in PTP mode it is
    /// the standard still-image class 6/1/1.
    static func isFileTransferInterface(_ service: io_service_t) -> Bool {
        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        func string(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }
        let cls = number("bInterfaceClass"), sub = number("bInterfaceSubClass"), proto = number("bInterfaceProtocol")
        if cls == 6 && sub == 1 && proto == 1 { return true }
        let name = (string("kUSBString") ?? string("USB Interface Name") ?? "").uppercased()
        return cls == 0xFF && name.contains("MTP")
    }

    private func connect(_ service: io_service_t, entryID: UInt64) {
        if device != nil && deviceEntryID == entryID { return }
        if let (old, oldID) = pendingService, oldID != entryID { IOObjectRelease(old) }
        pendingService = (service, entryID)
        setState(.connecting)
        do {
            let opened = try MTPDevice(service: service)
            device = opened
            deviceEntryID = entryID
            checkStorage()
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    /// A Samsung phone only shares its storage with a session opened while it is unlocked
    /// (and, the first time, after "Allow access?"). So while it shows none, reopen the session
    /// every few seconds: once the user unlocks the phone, the next session gets the storage.
    private func checkStorage(attempt: Int = 0) {
        guard let current = device else { return }
        if !((try? current.storages()) ?? []).isEmpty {
            setState(.ready(current.displayName))
            return
        }
        setState(.waitingForPhone(current.displayName))
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let device = self.device, device === current, let (service, entryID) = self.pendingService else { return }
            if attempt % 2 == 1 {
                device.close()
                self.device = nil
                if let reopened = try? MTPDevice(service: service) {
                    self.device = reopened
                    self.deviceEntryID = entryID
                } else {
                    self.deviceEntryID = 0
                    self.connect(service, entryID: entryID)
                    return
                }
            }
            self.checkStorage(attempt: attempt + 1)
        }
    }

    private func setState(_ new: CableState) {
        DispatchQueue.main.async { [weak self] in self?.state = new }
    }

    // MARK: Browsing

    public func storages(_ completion: @escaping (Result<[PhoneStorage], Error>) -> Void) {
        run(completion) { device in try device.storages() }
    }

    public func list(storage: UInt32, folder: UInt32?, _ completion: @escaping (Result<[PhoneItem], Error>) -> Void) {
        run(completion) { device in
            try device.children(of: folder ?? PTP.root, storage: storage)
                .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
        }
    }

    private func run<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ body: @escaping (MTPDevice) throws -> T) {
        queue.async { [self] in
            let result: Result<T, Error>
            if let device {
                result = Result { try body(device) }
            } else {
                result = .failure(CableError.usb("No phone is connected by cable."))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Test hook: deletes the named item inside the phone's Download folder.
    func deleteFromDownloadForTest(_ name: String, _ completion: @escaping (Bool) -> Void) {
        run({ (r: Result<Bool, Error>) in completion((try? r.get()) ?? false) }) { device in
            guard let storage = try device.storages().first?.id,
                  let download = try device.children(of: PTP.root, storage: storage).first(where: { $0.isFolder && $0.name.lowercased() == "download" }),
                  let item = try device.children(of: download.id, storage: storage).first(where: { $0.name == name }) else { return false }
            try device.delete(item.id)
            return true
        }
    }

    // MARK: Transfers

    /// Stops a transfer right away, mid-file if need be. What was half-copied is removed.
    public func cancel(_ id: UUID) {
        let device: MTPDevice? = cancelLock.withLock {
            canceled.insert(id)
            return activeTransfer?.id == id ? activeTransfer?.device : nil
        }
        device?.cancelActive()
    }

    private func setActive(_ id: UUID, _ device: MTPDevice?) {
        cancelLock.withLock { activeTransfer = device.map { (id, $0) } }
    }

    private func isCanceled(_ id: UUID) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return canceled.contains(id)
    }

    /// Copies files and folders from the phone into `destination`, keeping folder structure.
    @discardableResult
    public func copyToMac(_ items: [PhoneItem], destination: URL) -> UUID {
        let id = UUID()
        let phoneName = state.phoneName ?? "Phone"
        var initial = TransferSnapshot(id: id, direction: .incoming, peerName: phoneName)
        initial.items = items.map(\.name)
        initial.phase = .connecting
        publish(initial)

        queue.async { [self, initial] in
            var snapshot = initial
            guard let device else { return finish(&snapshot, .failed("The phone was disconnected.")) }
            setActive(id, device)
            defer { setActive(id, nil) }
            var createdTargets: [URL] = []
            do {
                // Plan: every file with the local path it should land at.
                var plan: [(PhoneItem, URL)] = []
                var folders: [URL] = []
                var topLevelTargets: [URL] = []
                func walk(_ item: PhoneItem, into dir: URL, topLevel: Bool) throws {
                    let target = topLevel ? FileNaming.uniqueURL(in: dir, name: item.name)
                                          : dir.appendingPathComponent(FileNaming.sanitize(item.name))
                    if topLevel { topLevelTargets.append(target) }
                    if item.isFolder {
                        folders.append(target)
                        for child in try device.children(of: item.id, storage: item.storageID) {
                            try walk(child, into: target, topLevel: false)
                        }
                    } else {
                        plan.append((item, target))
                    }
                }
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for item in items { try walk(item, into: destination, topLevel: true) }
                createdTargets = topLevelTargets
                for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

                snapshot.totalBytes = plan.reduce(0) { $0 + Int64($1.0.size) }
                snapshot.phase = .transferring
                publish(snapshot)

                var done: Int64 = 0
                var lastPublish = Date.distantPast
                for (item, url) in plan {
                    if isCanceled(id) { throw CableError.canceled }
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let base = done
                    try device.download(item, to: url) { bytes in
                        snapshot.bytesDone = base + bytes
                        if Date().timeIntervalSince(lastPublish) > 0.1 { lastPublish = Date(); self.publish(snapshot) }
                        return true
                    }
                    done += Int64(item.size)
                    snapshot.bytesDone = done
                }
                snapshot.savedFiles = topLevelTargets
                finish(&snapshot, .done)
            } catch {
                if isCanceled(id) {
                    device.recoverAfterCancel()
                    createdTargets.forEach { try? FileManager.default.removeItem(at: $0) }
                    finish(&snapshot, .canceled)
                } else {
                    finish(&snapshot, .failed(error.localizedDescription))
                }
            }
        }
        return id
    }

    /// Copies Mac files and folders to the phone. With no folder given, they go to the phone's
    /// Download folder (shown as "Downloads" in the Files app).
    @discardableResult
    public func copyToPhone(_ urls: [URL], storage: UInt32? = nil, folder: UInt32? = nil) -> UUID {
        let id = UUID()
        let phoneName = state.phoneName ?? "Phone"
        var initial = TransferSnapshot(id: id, direction: .outgoing, peerName: phoneName)
        initial.items = urls.map(\.lastPathComponent)
        initial.totalBytes = LocalTree(urls).totalBytes
        initial.phase = .connecting
        publish(initial)

        queue.async { [self, initial] in
            var snapshot = initial
            guard let device else { return finish(&snapshot, .failed("The phone was disconnected.")) }
            setActive(id, device)
            defer { setActive(id, nil) }
            var createdOnPhone: [UInt32] = []
            do {
                guard let storageID = try storage ?? device.storages().first?.id else {
                    throw CableError.device("the phone isn't sharing its storage. Unlock it and tap Allow")
                }
                let target = try folder ?? device.children(of: PTP.root, storage: storageID)
                    .first { $0.isFolder && $0.name.lowercased() == "download" }?.id ?? PTP.root

                snapshot.phase = .transferring
                publish(snapshot)
                var done: Int64 = 0
                var lastPublish = Date.distantPast

                func send(_ url: URL, into parent: UInt32, existing: inout Set<String>) throws {
                    if isCanceled(id) { throw CableError.canceled }
                    let name = FileNaming.uniqueName(url.lastPathComponent, avoiding: existing)
                    existing.insert(name.lowercased())
                    if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        let folderID = try device.createFolder(named: name, in: parent, storage: storageID)
                        if parent == target { createdOnPhone.append(folderID) }
                        var inside = Set<String>()
                        for child in LocalTree.contents(of: url) { try send(child, into: folderID, existing: &inside) }
                    } else {
                        let base = done
                        let handle = try device.upload(url, as: name, to: parent, storage: storageID) { bytes in
                            snapshot.bytesDone = base + bytes
                            if Date().timeIntervalSince(lastPublish) > 0.1 { lastPublish = Date(); self.publish(snapshot) }
                            return true
                        }
                        if parent == target { createdOnPhone.append(handle) }
                        done += LocalTree.size(of: url)
                        snapshot.bytesDone = done
                    }
                }

                var existing = Set(try device.children(of: target, storage: storageID).map { $0.name.lowercased() })
                for url in urls { try send(url, into: target, existing: &existing) }
                finish(&snapshot, .done)
            } catch {
                if isCanceled(id) {
                    device.recoverAfterCancel() // also removes the half-sent file
                    createdOnPhone.forEach { try? device.delete($0) }
                    finish(&snapshot, .canceled)
                } else {
                    finish(&snapshot, .failed(error.localizedDescription))
                }
            }
        }
        return id
    }

    private func finish(_ snapshot: inout TransferSnapshot, _ phase: TransferSnapshot.Phase) {
        if phase == .done { snapshot.bytesDone = snapshot.totalBytes }
        snapshot.phase = phase
        publish(snapshot)
    }

    private func publish(_ snapshot: TransferSnapshot) {
        DispatchQueue.main.async { [weak self] in self?.onTransferUpdate?(snapshot) }
    }
}

/// Files and folders picked on the Mac, with their total size.
struct LocalTree {
    let totalBytes: Int64

    init(_ urls: [URL]) {
        totalBytes = urls.reduce(0) { $0 + LocalTree.size(of: $1) }
    }

    /// Visible contents of a folder (no .DS_Store and other hidden files).
    static func contents(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            return contents(of: url).reduce(0) { $0 + size(of: $1) }
        }
        return Int64(values?.fileSize ?? 0)
    }

    /// Every file under the given URLs, with the folder path it sits in relative to the picked item
    /// ("" for files picked directly, "Photos/2024" for a file inside a picked "Photos" folder).
    static func files(in urls: [URL]) -> [(url: URL, folder: String)] {
        var result: [(URL, String)] = []
        func walk(_ url: URL, folder: String) {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let path = folder.isEmpty ? url.lastPathComponent : folder + "/" + url.lastPathComponent
                contents(of: url).forEach { walk($0, folder: path) }
            } else {
                result.append((url, folder))
            }
        }
        urls.forEach { walk($0, folder: "") }
        return result
    }
}

/// Names coming from another device: keep them inside the target folder and visible.
public enum FileNaming {
    public static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "file" }
        while s.utf8.count > 200 { s.removeFirst() }
        return s
    }

    /// "name.ext", or "name (2).ext" etc. if that already exists in `directory`.
    public static func uniqueURL(in directory: URL, name: String) -> URL {
        let clean = sanitize(name)
        var url = directory.appendingPathComponent(clean)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = directory.appendingPathComponent(numbered(clean, n))
        }
        return url
    }

    /// Same, against a set of lower-cased names already present.
    static func uniqueName(_ name: String, avoiding existing: Set<String>) -> String {
        var candidate = name
        var n = 1
        while existing.contains(candidate.lowercased()) {
            n += 1
            candidate = numbered(name, n)
        }
        return candidate
    }

    static func numbered(_ name: String, _ n: Int) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
    }
}
