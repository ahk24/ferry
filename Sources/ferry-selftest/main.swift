import Foundation
import Network
import FerryCore

// `ferry-selftest` runs the checks.
// `ferry-selftest send <host> <port> <files...>` sends files over Quick Share to a running Ferry
// (or any receiver) and prints what happens, for testing the app's incoming window.
let args = CommandLine.arguments
if args.count >= 5, args[1] == "send", let port = NWEndpoint.Port(args[3]) {
    let service = NearbyService(deviceName: "Ferry test sender", downloadDirectory: FileManager.default.temporaryDirectory)
    let peer = Peer(id: "TEST", name: args[2], deviceType: 3, endpoint: .hostPort(host: NWEndpoint.Host(args[2]), port: port),
                    matchedQRCode: false)
    var finished = false
    service.onTransferUpdate = { s in
        print("[\(s.phase)] \(Int(s.fraction * 100))% pin=\(s.pin ?? "-")")
        if s.phase.isTerminal { finished = true }
    }
    service.send(files: args.dropFirst(4).map { URL(fileURLWithPath: $0) }, to: peer)
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(0)
}
if args.count >= 2, args[1] == "cable-cancel" {
    exit(SelfTest.cableCancelLive() ? 0 : 1)
}
if args.count >= 2, args[1] == "cable" {
    exit(SelfTest.cableLive() ? 0 : 1)
}
exit(SelfTest.run() ? 0 : 1)
