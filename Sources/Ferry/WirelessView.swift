import SwiftUI
import FerryCore

/// Hotspot mode: the phone scans a code and uses Ferry's page in its browser to send and receive.
struct WirelessView: View {
    @ObservedObject var model: AppModel
    @State private var chosen: NetAddress?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                qr
                VStack(alignment: .leading, spacing: 10) {
                    Step(n: 1, text: "On your phone, turn on Mobile Hotspot (Settings → Connections → Mobile Hotspot and Tethering).")
                    Step(n: 2, text: "On this Mac, join that hotspot from the Wi-Fi menu.")
                    Step(n: 3, text: "Scan this code with the phone's camera. Ferry opens in the phone's browser.")
                    Text("Phone and Mac already on the same Wi-Fi? Skip steps 1 and 2.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Shared with the phone").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Add Files…") { model.addFilesForBrowser() }
                    if !model.offered.isEmpty {
                        Button("Clear") { model.stopSharingAll() }
                    }
                }
                if model.offered.isEmpty {
                    Text("Nothing yet. Add files or folders here, or drop them on Ferry's menu bar icon and choose the browser. They appear on the phone's page for download. Files the phone sends arrive in \(model.downloadDirectory.lastPathComponent).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.offered) { file in
                                HStack {
                                    Image(systemName: "doc").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.name).lineLimit(1).truncationMode(.middle)
                                        Text(file.folder.isEmpty ? Wording.size(file.size) : "\(file.folder) · \(Wording.size(file.size))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        model.stopSharing(file.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Stop sharing this file")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }

            let activity = model.visibleTransfers.filter { $0.peerName == "Phone (browser)" }.prefix(3)
            if !activity.isEmpty {
                Divider()
                ForEach(Array(activity)) { TransferRow(model: model, transfer: $0) }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.refreshAddresses() }
        .onReceive(tick) { _ in model.refreshAddresses() }
    }

    private var address: NetAddress? {
        if let chosen, model.addresses.contains(chosen) { return chosen }
        return model.addresses.first
    }

    @ViewBuilder private var qr: some View {
        VStack(spacing: 8) {
            if let address, let url = model.pageURL(address), let image = QRCode.image(for: url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 170, height: 170)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                connectionStatus
                Text(url)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .help("If scanning doesn't work, type this address into the phone's browser")
                if model.addresses.count > 1 {
                    Picker("Network", selection: Binding(get: { address }, set: { chosen = $0 })) {
                        ForEach(model.addresses, id: \.self) { a in
                            Text("\(a.address) (\(a.interface))").tag(Optional(a))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 186)
                }
            } else if model.addresses.isEmpty {
                placeholder("This Mac isn't on any network yet. Join your phone's hotspot (steps 1–2) and the code appears here.")
            } else {
                placeholder(webStatus)
            }
        }
        .frame(width: 186)
    }

    /// Whether the phone has actually reached the page recently.
    @ViewBuilder private var connectionStatus: some View {
        if let contact = model.phoneContact, Date().timeIntervalSince(contact.date) < 8 {
            Label("Phone connected (\(contact.address))", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        } else {
            Label("Waiting for the phone…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var webStatus: String {
        switch model.webState {
        case .failed(let message): return "Couldn't start: \(message)"
        default: return "Starting…"
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(width: 170, height: 170)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
    }
}

private struct Step: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
