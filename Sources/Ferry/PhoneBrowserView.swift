import SwiftUI
import AppKit
import FerryCore

/// Navigation state for browsing the phone's storage over the cable.
@MainActor
final class PhoneBrowser: ObservableObject {
    @Published private(set) var storages: [PhoneStorage] = []
    @Published var storageID: UInt32?
    @Published private(set) var path: [PhoneItem] = [] // folders from the top of the storage
    @Published private(set) var items: [PhoneItem] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var selection = Set<UInt32>()

    private let cable: CableService
    private var loadToken = 0

    init(cable: CableService) { self.cable = cable }

    var currentFolder: UInt32? { path.last?.id }

    func load() {
        loading = true
        error = nil
        cable.storages { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let storages) where !storages.isEmpty:
                self.storages = storages
                if self.storageID == nil || !storages.contains(where: { $0.id == self.storageID }) {
                    self.storageID = storages.first?.id
                }
                self.open(path: [])
            case .success:
                self.loading = false
                self.error = "The phone isn't sharing its files yet. Unlock it, and if it asks “Allow access to phone data?”, tap Allow."
            case .failure(let e):
                self.loading = false
                self.error = e.localizedDescription
            }
        }
    }

    func open(path newPath: [PhoneItem]) {
        guard let storageID else { return }
        path = newPath
        selection = []
        loading = true
        error = nil
        loadToken += 1
        let token = loadToken
        cable.list(storage: storageID, folder: newPath.last?.id) { [weak self] result in
            guard let self, token == self.loadToken else { return }
            self.loading = false
            switch result {
            case .success(let items):
                // Hide dot-files like Finder does. Folders first; newest first inside each
                // group (what you want for photos).
                self.items = items.filter { !$0.name.hasPrefix(".") }.sorted {
                    if $0.isFolder != $1.isFolder { return $0.isFolder }
                    if $0.isFolder { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast)
                }
            case .failure(let e):
                self.items = []
                self.error = e.localizedDescription
            }
        }
    }

    func enter(_ folder: PhoneItem) {
        guard folder.isFolder else { return }
        open(path: path + [folder])
    }

    /// Follows folder names from the top of the storage, as far as they exist.
    func jump(to names: [String]) {
        guard let storageID else { return }
        var resolved: [PhoneItem] = []
        func step(_ remaining: ArraySlice<String>) {
            guard let name = remaining.first else { return open(path: resolved) }
            cable.list(storage: storageID, folder: resolved.last?.id) { [weak self] result in
                guard let self else { return }
                if case .success(let items) = result,
                   let match = items.first(where: { $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    resolved.append(match)
                    step(remaining.dropFirst())
                } else {
                    self.open(path: resolved)
                }
            }
        }
        step(names[...])
    }

    var selectedItems: [PhoneItem] { items.filter { selection.contains($0.id) } }

    /// For `--render-previews` only.
    func setPreview(storages: [PhoneStorage], path: [PhoneItem], items: [PhoneItem]) {
        self.storages = storages
        storageID = storages.first?.id
        self.path = path
        self.items = items
        loading = false
        error = nil
    }
}

struct PhoneBrowserView: View {
    @ObservedObject var model: AppModel
    @StateObject var browser: PhoneBrowser
    @State private var dropTargeted = false

    init(model: AppModel, browser: PhoneBrowser) {
        self.model = model
        _browser = StateObject(wrappedValue: browser)
    }

    private let shortcuts: [(String, String, [String])] = [
        ("Camera", "camera", ["DCIM", "Camera"]),
        ("Screenshots", "camera.viewfinder", ["DCIM", "Screenshots"]),
        ("Downloads", "arrow.down.circle", ["Download"]),
        ("Documents", "doc.text", ["Documents"]),
        ("Pictures", "photo", ["Pictures"]),
        ("WhatsApp", "message", ["Android", "media", "com.whatsapp", "WhatsApp", "Media"]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if model.cableState.phoneName == nil {
                notConnected
            } else {
                toolbar
                Divider()
                content
                Divider()
                bottomBar
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 460, idealHeight: 560)
        .onAppear { if model.cableState.phoneName != nil && browser.items.isEmpty { browser.load() } }
        .onChange(of: model.cableState) { _, state in
            if case .ready = state { browser.load() }
        }
    }

    private var notConnected: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No phone connected by cable").font(.title3.weight(.semibold))
            Text("Plug your phone into this Mac with a USB cable. On the phone, pull down the notifications, tap the USB notification, and choose “File transfer”.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if case .failed(let message) = model.cableState {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 380)
                Button("Try Again") { model.retryCable() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(shortcuts, id: \.0) { title, icon, names in
                    Button { browser.jump(to: names) } label: { Label(title, systemImage: icon) }
                        .controlSize(.small)
                }
                Spacer()
                if browser.storages.count > 1 {
                    Picker("Storage", selection: $browser.storageID) {
                        ForEach(browser.storages) { s in Text(s.name).tag(Optional(s.id)) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                    .onChange(of: browser.storageID) { _, _ in browser.open(path: []) }
                }
            }
            HStack(spacing: 4) {
                Button { browser.open(path: Array(browser.path.dropLast())) } label: { Image(systemName: "chevron.left") }
                    .disabled(browser.path.isEmpty)
                    .buttonStyle(.borderless)
                Button(storageName) { browser.open(path: []) }.buttonStyle(.link)
                ForEach(Array(browser.path.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    Button(folder.name) { browser.open(path: Array(browser.path.prefix(index + 1))) }
                        .buttonStyle(.link)
                        .lineLimit(1)
                }
                Spacer()
                if browser.loading { ProgressView().controlSize(.small) }
            }
            .font(.callout)
        }
        .padding(10)
    }

    private var storageName: String {
        browser.storages.first { $0.id == browser.storageID }?.name ?? "Phone"
    }

    @ViewBuilder private var content: some View {
        if let error = browser.error {
            VStack(spacing: 10) {
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                Button("Try Again") { browser.load() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $browser.selection) {
                ForEach(browser.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isFolder ? "folder.fill" : Self.icon(for: item.name))
                            .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(item.isFolder ? "" : Wording.size(Int64(item.size)))
                            .foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                        Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .trailing)
                    }
                    .tag(item.id)
                }
            }
            .contextMenu(forSelectionType: UInt32.self) { ids in
                if !ids.isEmpty {
                    Button("Copy to Mac") { copy(ids) }
                }
            } primaryAction: { ids in
                // Double-click: open a folder, or copy a file.
                if ids.count == 1, let item = browser.items.first(where: { ids.contains($0.id) }), item.isFolder {
                    browser.enter(item)
                } else {
                    copy(ids)
                }
            }
            .overlay {
                if !browser.loading && browser.items.isEmpty {
                    Text("This folder is empty.").foregroundStyle(.secondary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: dropTargeted ? 3 : 0))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for p in providers { if let url = await p.loadFileURL() { urls.append(url) } }
                    if !urls.isEmpty { upload(urls) }
                }
                return true
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            let active = model.visibleTransfers.first { !$0.phase.isTerminal && $0.peerName == model.cableState.phoneName }
            if let active {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Wording.title(active)).font(.caption.weight(.medium))
                    ProgressView(value: active.fraction).frame(width: 200)
                    Text(Wording.status(active)).font(.caption2).foregroundStyle(.secondary)
                }
                Button("Cancel") { model.cancel(active.id) }.controlSize(.small)
            } else if let last = model.visibleTransfers.first(where: { $0.peerName == model.cableState.phoneName }) {
                Text("\(Wording.title(last)): \(Wording.status(last))")
                    .font(.caption)
                    .foregroundStyle(Wording.statusColor(last))
                    .lineLimit(1)
                if last.direction == .incoming && last.phase == .done {
                    Button("Show in Finder") { model.reveal(last) }.buttonStyle(.link).font(.caption)
                }
            } else {
                Text("Select files and click Copy to Mac, or drop files from the Mac into this window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Send Files Here…") { chooseAndUpload() }
            Button("Copy to Mac") { copy(browser.selection) }
                .buttonStyle(.borderedProminent)
                .disabled(browser.selection.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private func copy(_ ids: Set<UInt32>) {
        let items = browser.items.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        _ = model.copyFromPhone(items)
    }

    private func upload(_ urls: [URL]) {
        _ = model.copyToPhone(urls, storage: browser.storageID, folder: browser.currentFolder ?? 0xFFFF_FFFF)
        // Show the new files once the copy finishes.
        let folder = browser.path
        Task { @MainActor in
            while model.visibleTransfers.contains(where: { !$0.phase.isTerminal && $0.direction == .outgoing }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if browser.path == folder { browser.open(path: folder) }
        }
    }

    private func chooseAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Send"
        panel.message = "Choose files or folders to copy to \(browser.path.last?.name ?? storageName) on the phone"
        panel.begin { response in
            if response == .OK { upload(panel.urls) }
        }
    }

    static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "dng": return "photo"
        case "mp4", "mov", "mkv", "3gp", "webm": return "film"
        case "mp3", "m4a", "aac", "wav", "ogg", "opus", "flac": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z": return "doc.zipper"
        case "apk": return "app.badge"
        default: return "doc"
        }
    }
}
