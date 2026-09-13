import AdrafinilShared
import Foundation

// A SIGPIPE (daemon closed the socket mid-write, MCP client closed stdout) would kill the
// process by signal — which an agent hook reports as a hard failure. Write errors are handled
// at the call sites instead.
signal(SIGPIPE, SIG_IGN)
exit(WakeLeaseCLI.execute(Array(CommandLine.arguments.dropFirst())))
