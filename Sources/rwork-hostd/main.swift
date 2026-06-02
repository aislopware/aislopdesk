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

guard let parsed = HostdArguments.parse(arguments) else {
    FileHandle.standardError.write(Data(
        (HostdArguments.usage(programName: programName) + "\n").utf8))
    exit(2)
}

let log: @Sendable (String) -> Void = { message in
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
}

let server = HostServer(
    port: parsed.port,
    shellPath: parsed.shell,
    launchMode: parsed.launchMode
)
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
        let mode: String
        switch parsed.launchMode {
        case .shell:
            mode = "shell"
        case let .claudeCode(profile):
            mode = "claude (TERM=\(profile.term.rawValue))"
        }
        log("listening on 0.0.0.0:\(bound) (shell=\(server.shellPath), mode=\(mode))")
    } catch {
        log("failed to start: \(error)")
        exit(1)
    }
}

// Keep the process alive for the listener + relay tasks; SIGINT drives exit().
dispatchMain()
