import Foundation
import RworkHost

// rwork-hostd — headless Rwork host daemon (PTY + transport).
//
// Wires up HostServer: bind a TCP listener (0.0.0.0 / OS-chosen — no interface pin,
// per [13]), spawn the user's login shell per session, relay PTY bytes over the dual
// data/control channels with replay-buffer reconnect, and survive client disconnects.
// Runs until SIGINT.

let arguments = CommandLine.arguments
let programName = (arguments.first as NSString?)?.lastPathComponent ?? "rwork-hostd"

func parseArgs(_ args: [String]) -> (port: UInt16, shell: String?)? {
    var port: UInt16 = 7420
    var shell: String?
    var iterator = args.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--port", "-p":
            guard let value = iterator.next(), let p = UInt16(value) else { return nil }
            port = p
        case "--shell", "-s":
            guard let value = iterator.next() else { return nil }
            shell = value
        case "--help", "-h":
            return nil
        default:
            return nil
        }
    }
    return (port, shell)
}

guard let parsed = parseArgs(arguments) else {
    FileHandle.standardError.write(Data(
        "usage: \(programName) [--port N] [--shell /path/to/shell]\n".utf8))
    exit(2)
}

let log: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
}

let server = HostServer(port: parsed.port, shellPath: parsed.shell)
server.onLog = log

// Install a SIGINT handler that stops the server and exits. Use a DispatchSource so
// the default SIGINT disposition does not kill us mid-shutdown.
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    log("SIGINT — shutting down")
    Task {
        await server.stop()
        exit(0)
    }
}
sigintSource.resume()

Task {
    do {
        try await server.start()
        let bound = await server.boundPort() ?? parsed.port
        log("listening on 0.0.0.0:\(bound) (shell=\(server.shellPath))")
    } catch {
        log("failed to start: \(error)")
        exit(1)
    }
}

// Keep the process alive for the listener + relay tasks; SIGINT drives exit().
dispatchMain()
