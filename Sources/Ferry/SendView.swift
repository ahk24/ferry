import SwiftUI
import FerryCore

/// Opens when files are dropped or chosen: shows the ways to get them to the phone.
struct SendView: View {
    @ObservedObject var model: AppModel
    @State private var showQuickShare = false
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let session = model.sendSession {
                if let id = session.transferID, let transfer = model.transfer(id) {
                    progress(transfer)
                } else if session.files.isEmpty {
                    dropArea
                } else {
                    choices(session)
                }
            } else {
                dropArea
            }
        }
        .frame(width: 420)
        // The whole window takes drops: more files are added to the list.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await provider.loadFileURL() { urls.append(url) }
                }
                if !urls.isEmpty { model.beginSend(urls) }
            }
            return true
        }
    }

    private var dropArea: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc").font(.system(size: 34))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                Text("Drop files or folders here").font(.title3.weight(.semibold))
                Text("Any type of file, and whole folders.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.45))
            )
            Button("Choose Files or Folders…") { model.chooseFilesToSend() }
                .controlSize(.large)
            Text("Tip: you can also drag files straight onto the ⇄ icon in the menu bar, without opening Ferry first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func choices(_ session: SendSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ItemList(items: session.files.map(\.lastPathComponent),
                         totalBytes: session.files.reduce(0) { $0 + Self.size(of: $1) })
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: dropTargeted ? 2 : 0))
                HStack {
                    Text("Drop more files here to add them.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add More…") { model.chooseFilesToSend() }.controlSize(.small)
                    Button("Clear") { model.sendMore() }.controlSize(.small)
                }
            }

            // 1. Cable
            Method(icon: "cable.connector", title: "By USB cable", tint: cableReady ? .green : .secondary) {
                switch model.cableState {
                case .ready(let name):
                    Text("\(name) is connected. Files and folders go to its Downloads folder.")
                        .methodNote()
                    Button("Send to \(name)") { model.sendByCable() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .waitingForPhone(let name):
                    Text("\(name) is plugged in. Unlock it and tap Allow if it asks for access.")
                        .methodNote()
                case .connecting:
                    Text("Connecting to the phone…").methodNote()
                case .failed(let message):
                    Text(message).methodNote().foregroundStyle(.red)
                    Button("Try again") { model.retryCable() }
                case .none:
                    Text("Plug the phone in with a USB cable and choose “File transfer” on it. This window updates when it's connected.")
                        .methodNote()
                }
            }

            // 2. Phone's browser
            Method(icon: "qrcode", title: "Wireless, in the phone's browser", tint: .accentColor) {
                Text("No shared Wi-Fi needed: connect this Mac to your phone's hotspot, then scan a code with the phone.")
                    .methodNote()
                Button("Share to Phone's Browser…") { model.sendToBrowser() }
            }

            // 3. Quick Share
            DisclosureGroup(isExpanded: $showQuickShare) {
                quickShare(session)
                    .padding(.top, 6)
            } label: {
                Text("Quick Share (phone and Mac on the same Wi-Fi)").font(.callout)
            }
            .onChange(of: showQuickShare) { _, open in if open { model.startQuickShareDiscovery() } }

            HStack {
                Spacer()
                Button("Cancel") { model.closeSendWindow() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    private var cableReady: Bool {
        if case .ready = model.cableState { return true }
        return false
    }

    @ViewBuilder
    private func quickShare(_ session: SendSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let image = session.quickShareQR {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 110, height: 110)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                }
                Text("Scan with the phone's camera; Quick Share then picks up the files. If a phone is listed below, you can click it instead.")
                    .methodNote()
            }
            ForEach(model.peers) { peer in
                Button {
                    model.sendByQuickShare(to: peer)
                } label: {
                    Label(peer.name, systemImage: peer.symbolName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func progress(_ t: TransferSnapshot) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            Text("Sending to \(t.peerName)").font(.headline)
            ItemList(items: t.items, totalBytes: t.totalBytes)
            if let pin = t.pin, !t.phase.isTerminal {
                PinRow(pin: pin)
            }
            if t.phase == .transferring {
                ProgressView(value: t.fraction)
            } else if !t.phase.isTerminal {
                ProgressView().controlSize(.small)
            }
            Text(Wording.status(t))
                .font(.callout)
                .foregroundStyle(Wording.statusColor(t))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if t.phase.isTerminal {
                    Button("Send More") { model.sendMore() }
                    Button("Done") { model.closeSendWindow() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { model.cancel(t.id) }
                }
            }
        }
        .padding(20)
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory == true else { return Int64(values?.fileSize ?? 0) }
        let items = (try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []
        return items.reduce(0) { total, sub in
            total + Int64((try? url.appendingPathComponent(sub).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// One way of sending, as a titled box.
struct Method<Content: View>: View {
    let icon: String
    let title: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                content
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

extension Text {
    func methodNote() -> some View {
        self.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
