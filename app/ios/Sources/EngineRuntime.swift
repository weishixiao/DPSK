import Foundation

/// The Node runtime packed into the app bundle, when one has been prepared.
///
/// Stage one ships without it: `tooling/ios/prepare-engine.sh` has not run, so
/// `bundled()` answers nil and the app only connects to a remote host. The layout
/// it looks for is the one `app/ios/Engine/README.md` documents.
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
        return EngineRuntime(root: root, port: defaultPort)
    }

    var entryScript: URL { root.appendingPathComponent("host.mjs") }

    /// Why the app cannot boot a runtime yet, or the URL its Web UI would answer on.
    ///
    /// Booting Node inside the app needs the NodeMobile framework linked into this
    /// target; stage two adds it and fills this in. Until then the failure is stated
    /// rather than swallowed, so the settings screen can say what is missing.
    func start() throws -> URL {
        throw EngineError.notLinked
    }

    enum EngineError: LocalizedError {
        case notLinked

        var errorDescription: String? {
            switch self {
            case .notLinked:
                return "本机引擎还没接上：这个包没有链接 NodeMobile 运行时，只能连接远程主机。"
            }
        }
    }
}