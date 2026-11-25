import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import FerryCore

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 10, y: 10)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

// MARK: - Wording shared by the views

enum Wording {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func title(_ t: TransferSnapshot) -> String {
        t.direction == .incoming ? "From \(t.peerName)" : "To \(t.peerName)"
    }

    static func items(_ names: [String]) -> String {
        switch names.count {
        case 0: return "…"
        case 1: return names[0]
        default: return "\(names[0]) and \(names.count - 1) more"
        }
    }

    static func summary(_ t: TransferSnapshot) -> String {
        t.totalBytes > 0 ? "\(items(t.items)) · \(size(t.totalBytes))" : items(t.items)
    }

    static func status(_ t: TransferSnapshot) -> String {
        switch t.phase {
        case .connecting: return "Connecting…"
        case .securing: return "Setting up an encrypted connection…"
        case .waitingForPeer: return t.direction == .outgoing ? "Accept on your phone to start." : "Waiting for the phone…"
        case .awaitingYourAccept: return "Wants to send you this."
        case .transferring: return "\(Int(t.fraction * 100))% · \(size(t.bytesDone)) of \(size(t.totalBytes))"
        case .done:
            if t.direction == .outgoing { return "Sent." }
            return t.savedFiles.isEmpty && t.receivedText != nil ? "Copied to the clipboard." : "Saved."
        case .failed(let message): return message
        case .declined: return t.direction == .outgoing ? "Declined on the phone." : "Declined."
        case .canceled: return "Canceled."
        }
    }

    static func statusColor(_ t: TransferSnapshot) -> Color {
        switch t.phase {
        case .done: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
