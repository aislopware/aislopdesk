import Foundation
import RworkHost

// rwork-hostd — headless Rwork host daemon (PTY + transport).
//
// WF-1 ships only the argument-parsing shell. The PTY spawn, transport listener,
// and relay are wired in WF-3 via HostServer.

let arguments = CommandLine.arguments
let programName = (arguments.first as NSString?)?.lastPathComponent ?? "rwork-hostd"

func parsePort(_ args: [String]) -> UInt16? {
    // Accept `--port N` or `-p N`.
    var iterator = args.dropFirst().makeIterator()
    while let arg = iterator.next() {
        if arg == "--port" || arg == "-p" {
            guard let value = iterator.next(), let port = UInt16(value) else { return nil }
            return port
        }
    }
    return nil
}

let port = parsePort(arguments) ?? 7420

let server = HostServer(port: port)
_ = server // constructed to prove the type wires up; run() is WF-3.

print("\(programName): listening config port=\(port) — not yet wired (WF-3)")
