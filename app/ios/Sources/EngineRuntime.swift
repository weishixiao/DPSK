import Foundation

/// The Node runtime packed into the app bundle, when one has been prepared.
///
/// `tooling/ios/prepare-engine.sh` writes the layout this type looks for (see
/// `app/ios/Engine/README.md`). Node itself is linked into the app as an embedded
/// `libnode.dylib` (see project.yml), so "starting the engine" means calling
/// `node::Start` on a thread of its own and waiting for the loopback port to
/// answer. There is no child process and nothing is dyloaded by hand.
struct EngineRuntime {
    /// Directory holding the packed runtime.
    let root: URL
    /// Loopback port to ask for; 0 lets the system pick one, and the harness
    /// prints the address it actually bound.
    let port: Int

    /// 0 rather than a fixed 8799: a previous run's socket cannot collide, and
    /// two engine processes (or a Mac-side smoke test) do not fight over a port.
    static let defaultPort = 0

    static func bundled() -> EngineRuntime? {
        guard let root = Bundle.main.url(forResource: "Engine", withExtension: nil) else { return nil }
        let script = root.appendingPathComponent("host.mjs")
        guard FileManager.default.isReadableFile(atPath: script.path) else { return nil }
        let harness = root.appendingPathComponent("runtime/harness/lib/bin.js")
        guard FileManager.default.isReadableFile(atPath: harness.path) else { return nil }
        return EngineRuntime(root: root, port: defaultPort)
    }

    var entryScript: URL { root.appendingPathComponent("host.mjs") }

    /// The engine log's tail. The failure screens show it, so a boot that never
    /// reached the port names its own reason instead of only a path.
    static func logTail(_ lines: Int = 12) -> String { EngineBoot.logTail(lines) }

    /// Boot the engine and answer the URL its Web UI serves, or throw why not.
    ///
    /// Node boots once per process: a failed boot is reported as such, because a
    /// second `node::Start` in the same process is not supported and pretending
    /// otherwise would hang the UI instead of explaining itself.
    func start() async throws -> URL {
        try await EngineBoot.shared.start(runtime: self)
    }

    enum EngineError: LocalizedError {
        case alreadyBooting
        case bootFailed(String)
        case timedOut(Int)
        case stopped

        var errorDescription: String? {
            switch self {
            case .alreadyBooting:
                return "引擎正在启动，稍等。"
            case let .bootFailed(reason):
                return "本机引擎启动失败：\(reason)。重启 App 后再试；日志在 设置 ▸ 本机引擎 里能看到路径。"
            case let .timedOut(seconds):
                return "等了 \(seconds) 秒，本机引擎的界面还没起来。重启 App 后再试。"
            case .stopped:
                return "本机引擎已退出。重启 App 后再试。"
            }
        }
    }
}

/// One process-wide boot: Node cannot be started twice, so this owns the only
/// attempt and remembers how it went.
///
/// The *platform* is initialized once per process, but a run is not: each start
/// builds a fresh Environment on it (NodeBridge.mm, following dsh-Go's iOS host).
/// So `failed` is not terminal -- a retry starts a new run, and `stop()` ends
/// one without ending the app. Before that split, one failed boot meant the user
/// had to quit and reopen the app.
actor EngineBoot {
    static let shared = EngineBoot()

    private enum State {
        case idle
        case booting
        case ready(URL)
        /// A previous run ended. Retrying is allowed: it starts a new Environment.
        case failed(String)
    }

    private var state: State = .idle

    /// The engine thread of the current run, so a stop can wait for it to unwind
    /// before another start builds an Environment. Node allows one at a time.
    private var engineThread: Thread?

    /// How the engine thread's `node::Start` call ended, if it has.
    ///
    /// Node returns 0 from a script that finished or threw before it could
    /// serve, and a wait that only knows about the port reports that as a
    /// minute-long timeout with no reason attached.
    private final class ExitStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?

        func record(_ value: Int32) {
            lock.lock()
            status = value
            lock.unlock()
        }

        var value: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return status
        }
    }

    func start(runtime: EngineRuntime) async throws -> URL {
        switch state {
        case let .ready(url):
            return url
        case .booting:
            throw EngineRuntime.EngineError.alreadyBooting
        case let .failed(reason):
            // Retrying is the point of the Environment split. A previous failure
            // says why *that* run ended, not that this one will.
            Self.appendLine("[engine] retrying after: \(reason)\n", to: EnginePaths.logs.appendingPathComponent("engine.log"))
        case .idle:
            break
        }

        state = .booting
        do {
            try prepareDirectories()
            let exit = ExitStatus()
            launch(runtime: runtime, exit: exit)
            let url = try await waitForReady(runtime.port, exit: exit)
            EnginePaths.clearBootMarker()
            state = .ready(url)
            return url
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(reason)
            throw error
        }
    }

    /// Ask the engine to stop and wait for its thread to unwind.
    ///
    /// The run is ended with `node::Stop` on its Environment, not by killing the
    /// process: the app shares it. The state goes back to `idle`, so the next
    /// `start` builds a new Environment instead of being told to restart the app.
    /// Returns whether a run was actually active.
    @discardableResult
    func stop() async -> Bool {
        let thread = engineThread
        engineThread = nil
        state = .idle
        let stopped = DPSKNodeStop() == 1
        guard let thread else { return stopped }
        // Poll instead of blocking: this actor must not hold the cooperative
        // pool while Node unwinds its event loop.
        let deadline = Date().addingTimeInterval(5)
        while !thread.isFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        EnginePaths.clearBootMarker()
        return stopped
    }

    // MARK: - Directories

    /// Where the harness keeps its state: `DSH_HOME` under Application Support,
    /// and a writable workspace it uses as `process.cwd()` — the app bundle is
    /// read-only, so neither can be inside `Engine/`.
    private func prepareDirectories() throws {
        let manager = FileManager.default
        for directory in [EnginePaths.home, EnginePaths.workspace, EnginePaths.logs] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Boot

    private func launch(runtime: EngineRuntime, exit: ExitStatus) {
        setenv("DPSK_ENGINE_ROOT", runtime.root.path, 1)
        setenv("DPSK_PORT", String(runtime.port), 1)
        setenv("DSH_HOME", EnginePaths.home.path, 1)
        setenv("HOME", EnginePaths.container.path, 1)
        // Node asks for a writable TMPDIR; the app's own is the only one it may use.
        setenv("TMPDIR", NSTemporaryDirectory(), 1)
        // The two paths `host.mjs` must not re-derive: `HOME` is the container
        // root, so a `..` from it lands outside the sandbox, and the workspace it
        // computes that way cannot even be created (`EPERM`).
        setenv("DPSK_WORKSPACE", EnginePaths.workspace.path, 1)
        setenv("DPSK_LOG", EnginePaths.logs.appendingPathComponent("engine.log").path, 1)

        var arguments = [Bundle.main.executablePath ?? "dpsk"]
        // V8 only JITs when the signature grants it; a sideloaded build cannot,
        // so interpret unless the Info.plist opts in for an entitled signer. The
        // flag has to precede the script: Node stops parsing its own options at
        // the first non-option argument.
        if !EnginePaths.jitEntitled {
            arguments.append("--jitless")
        }
        // Keep V8 inside an iPhone's memory budget. Without these it sizes the
        // heap from the device's RAM, and a large session log can reach jetsam
        // before the app gets a chance to stop the run.
        arguments.append(contentsOf: [
            "--max-old-space-size=256",
            "--max-semi-space-size=4",
        ])
        arguments.append(runtime.entryScript.path)
        // Everything else — profile, patch, host, port, --no-open — is argv
        // `host.mjs` builds for the harness CLI itself, so one file owns it.

        let logURL = EnginePaths.logs.appendingPathComponent("engine.log")
        // Create it so the settings screen can point at an existing file even when
        // `host.mjs` never got far enough to write one.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let thread = Thread { [arguments, logURL, exit] in
            let started = Date()
            // Written before the call, and without buffering: if `node::Start`
            // aborts the process (a signature iOS will not accept on
            // libnode.dylib, a V8 failure at startup) this line is the only proof
            // the engine was reached at all, and the absence of the line below it
            // says the crash happened inside Node.
            Self.appendLine("boot: calling node::Start, jit=\(EnginePaths.jitEntitled) args=\(arguments.joined(separator: " "))\n", to: logURL)
            let status = DPSKNodeStart(arguments)
            // Recorded before the log write: the port wait reads it to report a
            // boot that ended rather than one that is still working.
            exit.record(status)
            let line = "[engine] exited with \(status) after \(Int(Date().timeIntervalSince(started)))s\n"
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            }
        }
        // Recorded before the call, cleared once the port answers: a marker that
        // outlives the process is the only reliable sign of a crash inside Node.
        EnginePaths.markBoot("args=\(arguments.joined(separator: " "))")
        // Node's main thread needs room for deep JSON and V8 recursion; the
        // default secondary-thread stack is too small for a large session log.
        thread.stackSize = 8 << 20
        thread.name = "dpsk-engine"
        engineThread = thread
        thread.start()
    }

    /// Append one line to a file, creating it if needed.
    static func appendLine(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// The last lines of the engine log, for the error the UI shows when boot
    /// fails: the reason is usually inside Node's own output, not in this process.
    static func logTail(_ lines: Int = 12) -> String {
        let url = EnginePaths.logs.appendingPathComponent("engine.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
        return tail.isEmpty ? "" : "\n" + tail.joined(separator: "\n")
    }

    /// Wait for the harness to print the address it bound.
    ///
    /// With `--port 0` the CLI picks the port. It prints
    /// `dsh web: http://127.0.0.1:<port>/?token=<token>` once the listener is
    /// ready; reading that line is also how the WebView gets the token the
    /// server requires, without either side guessing.
    private func waitForReady(_ port: Int, exit: ExitStatus) async throws -> URL {
        let deadline = Date().addingTimeInterval(90)
        let logURL = EnginePaths.logs.appendingPathComponent("engine.log")
        // `let`: URLSessionConfiguration is a class, so setting its properties is
        // not a mutation of this binding. With -warnings-as-errors the archive
        // fails on the "never mutated" warning, which is how this line was found.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        while Date() < deadline {
            // Node returning is the one failure that is not a timeout: report it
            // now with the reason it printed, rather than sitting out the rest
            // of the wait.
            if let status = exit.value {
                throw EngineRuntime.EngineError.bootFailed(
                    "Node 退出了（状态 \(status)）。日志尾部：\(EngineRuntime.logTail())")
            }
            if let url = EngineBoot.readyURL(in: logURL) {
                var request = URLRequest(url: url)
                request.timeoutInterval = 2
                if let (_, response) = try? await session.data(for: request),
                   let http = response as? HTTPURLResponse,
                   http.statusCode < 500 {
                    return url
                }
            }
            // A caller that pinned a port is answered even if the ready line was
            // unreadable; the app itself always asks for 0.
            if port != 0, let url = URL(string: "http://127.0.0.1:\(port)/") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 2
                if let (_, response) = try? await session.data(for: request),
                   let http = response as? HTTPURLResponse,
                   http.statusCode < 500 {
                    return url
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw EngineRuntime.EngineError.bootFailed(
            "等了 90 秒，引擎没有打印可用的地址。日志尾部：\(EngineRuntime.logTail())")
    }

    /// The last `dsh web: <url>` line in the log, if there is one.
    ///
    /// The line arrives through `host.mjs`'s log mirror, so it may carry that
    /// file's prefix; only the address after the marker is read.
    static func readyURL(in url: URL) -> URL? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Only lines this launch wrote count. The log outlives relaunches, and
        // an old ready line would send the WebView to a port nobody listens on.
        let scope: Substring
        if let boot = text.range(of: "boot: calling node::Start", options: .backwards) {
            scope = text[boot.upperBound...]
        } else {
            scope = text[...]
        }
        var found: URL?
        for line in scope.split(separator: "\n") {
            let textLine = String(line)
            guard let marker = textLine.range(of: "dsh web: http://") else { continue }
            var rest = String(textLine[marker.upperBound...])
            // Drop a terminal escape sequence if anything coloured the output.
            if let escape = rest.range(of: "\u{1B}") {
                rest = String(rest[..<escape.lowerBound])
            }
            let address = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map { String($0) } ?? ""
            if let parsed = URL(string: address), parsed.host == "127.0.0.1", parsed.port != nil {
                found = parsed
            }
        }
        return found
    }
}

/// The paths the engine uses, resolved once.
enum EnginePaths {
    /// The app's container — `HOME` for the harness, which is as far as its
    /// sandbox lets it write anyway.
    static var container: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].deletingLastPathComponent()
    }

    static var home: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("dsh", isDirectory: true)
    }

    static var workspace: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("workspace", isDirectory: true)
    }

    static var logs: URL {
        // Documents, not Library/Logs: `UIFileSharingEnabled` puts this folder in
        // Files, which is the only way to read the log when the UI never got past
        // the boot screen.
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }

    /// Written before `node::Start` and removed once the port answers. One left
    /// behind means the process died inside Node during boot — and because the
    /// chosen mode is persisted, booting again on the next launch would crash the
    /// app before the user can reach Settings. `AppModel` reads this to stop
    /// auto-booting after such a crash.
    static var bootMarker: URL {
        logs.appendingPathComponent("booting")
    }

    static func markBoot(_ text: String) {
        try? Data(text.utf8).write(to: bootMarker)
    }

    static func clearBootMarker() {
        try? FileManager.default.removeItem(at: bootMarker)
    }

    /// The marker's contents when a previous boot never finished.
    static func pendingBootMarker() -> String? {
        guard let text = try? String(contentsOf: bootMarker, encoding: .utf8) else { return nil }
        return text.isEmpty ? "(空)" : text
    }

    /// Whether the signature grants V8 the JIT entitlement. Info.plist declares
    /// the intent; a sideload signature drops it, so this defaults to false and
    /// an entitled build opts in with `DPSKEngineJIT`.
    static var jitEntitled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "DPSKEngineJIT") as? Bool) ?? false
    }
}
