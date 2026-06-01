import Foundation
import RworkClient
import RworkTerminal

// rwork-client — headless Rwork CLI test client.
//
// WF-1 ships only the entry point. The connect/reconnect loop and wiring the
// HeadlessTerminalSurface to the byte pipeline land in WF-4.

let programName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "rwork-client"

let surface = HeadlessTerminalSurface()
let connection = ClientConnection()
_ = surface     // headless sink for received output (WF-4)
_ = connection  // session driver (WF-4)

print("\(programName): not yet wired (WF-4)")
