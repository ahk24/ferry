import Foundation
import Network

/// A point-in-time view of one transfer, published to the UI on the main thread.
public struct TransferSnapshot: Identifiable, Equatable {
    public enum Direction: Equatable {
        case incoming
        case outgoing
    }

    public enum Phase: Equatable {
        case connecting
        case securing
        case waitingForPeer
        case awaitingYourAccept
        case transferring
        case done
        case failed(String)
        case declined
        case canceled

        public var isTerminal: Bool {
            switch self {
            case .done, .failed, .declined, .canceled: return true
            default: return false
            }
        }
    }

    public let id: UUID
    public let direction: Direction
    public var peerName: String
    public var pin: String?
    public var items: [String] = []
    public var totalBytes: Int64 = 0
    public var bytesDone: Int64 = 0
    public var phase: Phase = .connecting
    public var savedFiles: [URL] = []
    public var receivedText: String?
    public var receivedTextIsURL = false

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytesDone) / Double(totalBytes)) : (phase == .done ? 1 : 0)
    }

    public init(id: UUID, direction: Direction, peerName: String) {
        self.id = id
        self.direction = direction
        self.peerName = peerName
    }
}

/// A phone found on the local network that can receive files.
public struct Peer: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let deviceType: Int
    public let endpoint: NWEndpoint
    /// True when the phone appeared because it scanned our QR code.
    public let matchedQRCode: Bool

    public init(id: String, name: String, deviceType: Int, endpoint: NWEndpoint, matchedQRCode: Bool) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.endpoint = endpoint
        self.matchedQRCode = matchedQRCode
    }

    public var symbolName: String {
        switch deviceType {
        case EndpointInfo.tablet: return "ipad"
        case EndpointInfo.laptop: return "laptopcomputer"
        default: return "iphone"
        }
    }
}

public enum AdvertisingState: Equatable {
    case off
    case starting
    case visible(port: UInt16)
    case failed(String)
}

enum Wording {
    static func gb(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}
