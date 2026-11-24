import Foundation

/// Runs command-line tools (orca, gh, claude) off the main thread.
enum Shell {
    struct Result {
        var status: Int32
        var out: Data
        var err: Data
        /// True when the command was ended because it ran past its time limit.
        var timedOut = false
    }

    /// What a finished command left behind, filled in from several queues at once.
    private final class Collected: @unchecked Sendable {
        var out = Data()
        var err = Data()
        var timedOut = false
    }

    /// The first of the usual install places that holds `name`. An app started from the Dock has a
    /// short PATH, so the places are checked directly.
    static func find(_ name: String, also extra: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)", "\(home)/.local/bin/\(name)"] + extra
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a command and returns its exit status and output.
    /// The end is learnt from the process's termination handler. `waitUntilExit` was used before and
    /// sometimes never returned for a command that had already finished; every later refresh then
    /// waited behind it, and the cards kept showing what was true at that moment.
    /// `environment` is added to this app's own; `input` is written to the command's standard input.
    static func run(_ executable: String, _ args: [String], environment: [String: String] = [:],
                    input: Data? = nil, directory: URL? = nil, timeout: TimeInterval = 180) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            // Outside any repository by default, so a tool never infers a checkout from where this app was started.
            process.currentDirectoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            let outPipe = Pipe(), errPipe = Pipe()
            let inPipe = input == nil ? nil : Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe ?? FileHandle.nullDevice

            let collected = Collected()
            let finished = DispatchGroup()
            finished.enter()
            process.terminationHandler = { _ in finished.leave() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            // Both pipes are drained while the command runs; a full pipe would block it forever.
            let queue = DispatchQueue.global(qos: .userInitiated)
            finished.enter()
            queue.async {
                collected.out = outPipe.fileHandleForReading.readDataToEndOfFile()
                finished.leave()
            }
            finished.enter()
            queue.async {
                collected.err = errPipe.fileHandleForReading.readDataToEndOfFile()
                finished.leave()
            }
            if let input, let inPipe {
                // On its own queue: a long input fills the pipe and waits for the command to read it.
                queue.async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            // A command that hangs must not hold up everything after it.
            queue.asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    collected.timedOut = true
                    process.terminate()
                }
            }
            finished.notify(queue: queue) {
                continuation.resume(returning: Result(status: process.terminationStatus, out: collected.out,
                                                      err: collected.err, timedOut: collected.timedOut))
            }
        }
    }
}
