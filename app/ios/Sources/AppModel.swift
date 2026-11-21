import SwiftUI

/// What the window is showing and why.
enum Phase: Equatable {
    case idle
    case connecting
    case ready(URL)
    case failed(String)
}

/// The one place the app decides which Web UI it opens.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var settings: AppSettings
    /// Bumped when the user asks for the page again; the WebView reloads on it.
    @Published private(set) var reloadToken = 0

    private let store = SettingsStore()
    private let runtime = EngineRuntime.bundled()

    /// A boot attempt that never reached a serving port, left over from a previous
    /// launch: Node took the process down with it. Booting again on launch would
    /// crash-loop before Settings is reachable, so this stops the automatic attempt
    /// and says so.
    private var crashedDuringBoot = EnginePaths.pendingBootMarker() != nil
    /// Set by `retry()`, the one way past the safety stop.
    private var bootOnDemand = false

    /// True only when this build carries a packed Node runtime.
    var engineAvailable: Bool { runtime != nil }

    /// Where the engine writes its log, for the settings screen to name.
    var engineLogPath: String { EnginePaths.logs.appendingPathComponent("engine.log").path }

    init() {
        settings = store.load()
    }

    func start() {
        if case .connecting = phase { return }
        switch settings.mode {
        case .remote:
            guard let url = settings.resolvedRemoteURL else {
                phase = .failed("还没有填主机地址。点右上角设置，填入 dsh web 的地址，例如 192.168.1.20:8787。")
                return
            }
            phase = .ready(url)
        case .engine:
            if crashedDuringBoot && !bootOnDemand {
                phase = .failed(
                    "上次启动本机引擎时 App 崩溃了，所以这次没有自动重试。\n"
                        + "日志：\(engineLogPath)\n"
                        + "点「重试」再试一次，或在「设置」里改用远程主机。"
                )
                return
            }
            startEngine()
        }
    }

    /// Boot again after a crash, once, on the user's word.
    func retry() {
        bootOnDemand = true
        EnginePaths.clearBootMarker()
        start()
    }

    private func startEngine() {
        guard let runtime else {
            phase = .failed("这个包里没有本机引擎。先跑 tooling/ios/prepare-engine.sh 再重新构建，或改用远程主机（见 app/ios/Engine/README.md）。")
            return
        }
        phase = .connecting
        // Booting Node waits for the loopback port, so the work is off the main
        // actor while the window shows what is happening.
        Task {
            do {
                let url = try await runtime.start()
                phase = .ready(url)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Adopt a settings change.
    ///
    /// Only a change to where the page comes from costs a reconnect: switching the
    /// appearance republishes `settings`, which is enough for the shell to repaint
    /// and for the web view to be told a new interface style. Tearing the page down
    /// to change a colour would lose the conversation's scroll position.
    func apply(_ next: AppSettings) {
        let reconnects = next.mode != settings.mode || next.remoteURL != settings.remoteURL
        settings = next
        store.save(next)
        guard reconnects else { return }
        phase = .idle
        start()
    }

    func reload() {
        reloadToken &+= 1
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }
}
