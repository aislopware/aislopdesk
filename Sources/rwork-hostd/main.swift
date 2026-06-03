import Foundation
import RworkHost
import RworkInspector

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

// Inspector server (NWConnection #2, port + 1) — read-only structured companion.
// Constructed when --inspector / --claude / --transcript is set. The replay log is the
// replay-then-live fan-out; the engine feeds it. PIECE C (live per-PTY transcript-path
// discovery via the SessionStart hook) is DEFERRED — for now the path is the injected
// --transcript value (if any), tailed straight into the engine. Without a path the
// server still binds (so a client can connect) and the replay log stays empty until
// PIECE C wires the per-session tailer.
let inspectorEngine = InspectorEngine()
let inspectorReplayLog = InspectorReplayLog()
inspectorReplayLog.ingest(inspectorEngine.events)

let inspectorServer: InspectorServer?
if parsed.inspectorEnabled {
    let inspector = InspectorServer(
        terminalPort: parsed.port,
        replayLog: inspectorReplayLog,
        transcriptPath: parsed.transcriptPath
    )
    inspector.onLog = log
    inspectorServer = inspector

    // If a transcript path was injected, tail it into the engine now (PIECE C will
    // replace this with per-PTY discovery). The tailer tolerates the file not existing
    // yet, so it is safe to start before `claude` creates it.
    if let path = parsed.transcriptPath {
        let tailer = TranscriptTailer(path: path)
        inspectorEngine.run(tailer: tailer, subagents: nil)
        log("inspector tailing transcript \(path)")
    }
} else {
    inspectorServer = nil
}

// Install a SIGINT handler that stops the server and exits. Use a DispatchSource so
// the default SIGINT disposition does not kill us mid-shutdown.
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    log("SIGINT — shutting down")
    Task {
        inspectorServer?.stop()
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

        // Bring up the inspector listener (port + 1) once the terminal server is up.
        if let inspectorServer {
            try await inspectorServer.start()
        }
    } catch {
        log("failed to start: \(error)")
        exit(1)
    }
}

// Keep the process alive for the listener + relay tasks; SIGINT drives exit().
dispatchMain()
