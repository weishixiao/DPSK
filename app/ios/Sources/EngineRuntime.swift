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
    /// Loopback port the packed host serves the Web UI on.
    let port: Int

    static let defaultPort = 8799

    static func bundled() -> EngineRuntime? {
        guard let root = Bundle.main.url(forResource: "Engine", withExtension: nil) else { return nil }
        let script = root.appendingPathComponent("host.mjs")
        guard FileManager.default.isReadableFile(atPath: script.path) else { return nil }
        let harness = root.appendingPathComponent("runtime/harness/lib/bin.js")
        guard FileManager.default.isReadableFile(atPath: harness.path) else { return nil }
        return EngineRuntime(root: root, port: defaultPort)
    }

    var entryScript: URL { root.appendingPathComponent("host.mjs") }

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
actor EngineBoot {
    static let shared = EngineBoot()

    private enum State {
        case idle
        case booting
        case ready(URL)
        case failed(String)
    }

    private var state: State = .idle

    func start(runtime: EngineRuntime) async throws -> URL {
        switch state {
        case let .ready(url):
            return url
        case .booting:
            throw EngineRuntime.EngineError.alreadyBooting
        case let .failed(reason):
            throw EngineRuntime.EngineError.bootFailed(reason)
        case .idle:
            break
        }

        state = .booting
        do {
            try prepareDirectories()
            launch(runtime: runtime)
            let url = try await waitForPort(runtime.port)
            state = .ready(url)
            return url
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(reason)
            throw error
        }
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

    private func launch(runtime: EngineRuntime) {
        setenv("DPSK_ENGINE_ROOT", runtime.root.path, 1)
        setenv("DPSK_PORT", String(runtime.port), 1)
        setenv("DSH_HOME", EnginePaths.home.path, 1)
        setenv("HOME", EnginePaths.container.path, 1)
        // Node asks for a writable TMPDIR; the app's own is the only one it may use.
        setenv("TMPDIR", NSTemporaryDirectory(), 1)

        var arguments = [Bundle.main.executablePath ?? "dpsk"]
        // V8 only JITs when the signature grants it; a sideloaded build cannot,
        // so interpret unless the Info.plist opts in for an entitled signer. The
        // flag has to precede the script: Node stops parsing its own options at
        // the first non-option argument.
        if !EnginePaths.jitEntitled {
            arguments.append("--jitless")
        }
        arguments.append(runtime.entryScript.path)
        // Everything else — profile, patch, host, port, --no-open — is argv
        // `host.mjs` builds for the harness CLI itself, so one file owns it.

        let logURL = EnginePaths.logs.appendingPathComponent("engine.log")
        // Create it so the settings screen can point at an existing file even when
        // `host.mjs` never got far enough to write one.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let thread = Thread { [arguments, logURL] in
            let started = Date()
            let status = DPSKNodeStart(arguments)
            let line = "[engine] exited with \(status) after \(Int(Date().timeIntervalSince(started)))s\n"
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            }
        }
        // Node's main thread needs room for deep JSON and V8 recursion; the
        // default secondary-thread stack is too small for a large session log.
        thread.stackSize = 8 << 20
        thread.name = "dpsk-engine"
        thread.start()
    }

    /// Wait for the loopback port to answer anything at all.
    private func waitForPort(_ port: Int) async throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
            throw EngineRuntime.EngineError.bootFailed("端口号无效")
        }
        let deadline = Date().addingTimeInterval(60)
        // `let`: URLSessionConfiguration is a class, so setting its properties is
        // not a mutation of this binding. With -warnings-as-errors the archive
        // fails on the "never mutated" warning, which is how this line was found.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        while Date() < deadline {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode < 500 {
                session.finishTasksAndInvalidate()
                return url
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        session.finishTasksAndInvalidate()
        throw EngineRuntime.EngineError.timedOut(60)
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
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs", isDirectory: true)
    }

    /// Whether the signature grants V8 the JIT entitlement. Info.plist declares
    /// the intent; a sideload signature drops it, so this defaults to false and
    /// an entitled build opts in with `DPSKEngineJIT`.
    static var jitEntitled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "DPSKEngineJIT") as? Bool) ?? false
    }
}
