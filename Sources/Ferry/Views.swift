import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FerryCore

// MARK: - Menu bar popover

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ferry").font(.headline)

            CableCard(model: model)

            sendArea

            HStack(spacing: 8) {
                Button {
                    model.showWireless()
                } label: {
                    Label("Phone's browser", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .help("Wireless, no shared Wi-Fi needed: join your phone's hotspot, scan a code, send or receive in the phone's browser")
                Button {
                    model.showPhoneBrowser()
                } label: {
                    Label("Browse phone", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.cableState.phoneName == nil)
                .help("Copy photos and files from your phone over the USB cable")
            }
            .controlSize(.large)

            let transfers = model.visibleTransfers
            if !transfers.isEmpty {
                Divider()
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(transfers.prefix(4)) { transfer in
                    TransferRow(model: model, transfer: transfer)
                }
            }

            Divider()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Receive with Quick Share", isOn: $model.quickShareEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text(model.quickShareStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Only works when the phone and the Mac are on the same Wi-Fi network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text("Quick Share (same Wi-Fi)").font(.callout)
            }

            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text("Saves to \(model.downloadDirectory.lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.downloadDirectory.path)
                Button("Change…") { model.chooseDownloadDirectory() }
                    .buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 360)
    }

    private var sendArea: some View {
        Button {
            model.openSendWindow()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "arrow.up.doc.on.clipboard").font(.title2)
                Text("Send files or folders to your phone").font(.callout.weight(.medium))
                Text("Opens a window you can drop files into. You can also drag files straight onto the ⇄ icon in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.45))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
}

/// The phone-by-cable status, with what to do next.
struct CableCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cable.connector")
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed = model.cableState {
                    Button("Try again") { model.retryCable() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var title: String {
        switch model.cableState {
        case .none: return "Phone by cable"
        case .connecting: return "Phone found…"
        case .waitingForPhone(let name), .ready(let name): return name
        case .failed: return "Phone by cable"
        }
    }

    private var detail: String {
        switch model.cableState {
        case .none:
            return "Plug your phone into this Mac with a USB cable, then on the phone choose “File transfer” (or tap the USB notification)."
        case .connecting:
            return "Opening the connection…"
        case .waitingForPhone:
            return "Unlock your phone. If it asks “Allow access to phone data?”, tap Allow."
        case .ready:
            return "Connected by cable. Drop files here to send them, or browse the phone to copy files to the Mac."
        case .failed(let message):
            return message
        }
    }

    private var isError: Bool {
        if case .failed = model.cableState { return true }
        return false
    }

    private var iconColor: Color {
        switch model.cableState {
        case .ready: return .green
        case .waitingForPhone, .connecting: return .orange
        case .failed: return .red
        case .none: return .secondary
        }
    }
}

struct TransferRow: View {
    @ObservedObject var model: AppModel
    let transfer: TransferSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: transfer.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title3)
                .foregroundStyle(transfer.phase == .done ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(Wording.title(transfer)).font(.callout.weight(.medium)).lineLimit(1)
                Text(Wording.summary(transfer))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if transfer.phase == .transferring {
                    ProgressView(value: transfer.fraction).controlSize(.small)
                }
                Text(Wording.status(transfer))
                    .font(.caption)
                    .foregroundStyle(Wording.statusColor(transfer))
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var actions: some View {
        switch transfer.phase {
        case .awaitingYourAccept:
            HStack {
                Button("Decline") { model.respond(transfer.id, accept: false) }
                Button("Accept") { model.respond(transfer.id, accept: true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        case .done where transfer.direction == .incoming && !transfer.savedFiles.isEmpty:
            Button("Show in Finder") { model.reveal(transfer) }
                .buttonStyle(.link).font(.caption)
        case .done where transfer.receivedTextIsURL:
            Button("Open link") { model.openReceivedLink(transfer) }
                .buttonStyle(.link).font(.caption)
        case let phase where !phase.isTerminal:
            Button("Cancel") { model.cancel(transfer.id) }
                .buttonStyle(.link).font(.caption)
        default:
            EmptyView()
        }
    }
}

// MARK: - Quick Share incoming prompt

struct IncomingView: View {
    @ObservedObject var model: AppModel
    let transferID: UUID

    var body: some View {
        Group {
            if let transfer = model.transfer(transferID) {
                content(transfer)
            } else {
                Text("This transfer is no longer available.").padding(24)
            }
        }
        .frame(width: 380)
    }

    private func content(_ t: TransferSnapshot) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 3) {
                Text(t.peerName).font(.title3.weight(.semibold))
                Text(t.phase == .awaitingYourAccept ? "wants to send you" : (t.phase == .done ? "sent you" : "is sending you"))
                    .foregroundStyle(.secondary)
            }

            ItemList(items: t.items, totalBytes: t.totalBytes)

            if let text = t.receivedText, t.phase == .done {
                Text(text)
                    .font(.callout)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            }

            if let pin = t.pin, !t.phase.isTerminal {
                PinRow(pin: pin)
            }

            switch t.phase {
            case .awaitingYourAccept:
                HStack(spacing: 10) {
                    Button("Decline") { model.respond(t.id, accept: false) }
                        .keyboardShortcut(.cancelAction)
                        .frame(maxWidth: .infinity)
                    Button("Accept") { model.respond(t.id, accept: true) }
                        .keyboardShortcut(.defaultAction)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            case .done:
                Label(Wording.status(t), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    if !t.savedFiles.isEmpty {
                        Button("Show in Finder") { model.reveal(t) }
                    }
                    if t.receivedTextIsURL {
                        Button("Open Link") { model.openReceivedLink(t) }
                    }
                    Spacer()
                    Button("Done") { model.closeIncoming(t.id) }.keyboardShortcut(.defaultAction)
                }
            case .failed, .declined, .canceled:
                Text(Wording.status(t))
                    .foregroundStyle(Wording.statusColor(t))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Close") { model.closeIncoming(t.id) }.keyboardShortcut(.defaultAction)
            default:
                ProgressView(value: t.fraction)
                HStack {
                    Text(Wording.status(t)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancel(t.id) }.controlSize(.small)
                }
            }
        }
        .padding(22)
    }
}

// MARK: - Pieces

struct ItemList: View {
    let items: [String]
    let totalBytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "doc")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if items.count > 4 {
                Text("and \(items.count - 4) more").foregroundStyle(.secondary)
            }
            if totalBytes > 0 {
                Text(Wording.size(totalBytes)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

struct PinRow: View {
    let pin: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text("Code").foregroundStyle(.secondary)
                Text(pin).font(.title3.monospacedDigit().weight(.semibold))
            }
            Text("If your phone shows a code, it should match.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
