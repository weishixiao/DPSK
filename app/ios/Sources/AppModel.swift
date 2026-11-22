import SwiftUI

/// What the page area is showing and why.
///
/// This describes the *connection*, not the window. The window is always the app:
/// a boot that does not come up is a notice over the home screen, never a screen
/// that replaces it. Replacing the whole body with a failure is what made a missing
/// engine look like an app that would not open.
enum Phase: Equatable {
    /// Nothing attempted yet, or the user asked to stay disconnected.
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
    /// The last failure, kept apart from `phase` so the notice can be dismissed
    /// without forgetting what went wrong; `nil` means nothing to show.
    @Published var connectionNotice: String?

    private let store = SettingsStore()
    private let runtime = EngineRuntime.bundled()
    /// The connect attempt in flight, so a second tap does not start a second boot.
    private var connecting: Task<Void, Never>?

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

    // MARK: - Launch

    /// What the app does when it becomes visible.
    ///
    /// It does not connect. Opening the app is not a request to reach a host, and a
    /// host that is slow or absent must not hold the window: the home screen is
    /// shown, the saved settings are read, and the connection is offered rather than
    /// required. `connectInBackground()` is what the home screen calls once it is up.
    func started() {
        // A crash marker from a previous launch is reported on the home screen, not
        // by refusing to start.
        if crashedDuringBoot && !bootOnDemand && settings.mode == .engine {
            connectionNotice = "上次启动本机引擎时 App 崩溃了，所以这次没有自动重试。\n日志：\(engineLogPath)"
        }
    }

    /// Offer the saved configuration once the home screen is up.
    ///
    /// This is the launch attempt, so it honours the crash marker instead of
    /// clearing it: an engine that took the app down last time is not booted again
    /// without being asked. A boot waits on a loopback port, so it runs detached and
    /// the home screen stays usable throughout.
    func connectInBackground() {
        guard connecting == nil else { return }
        switch settings.mode {
        case .remote:
            guard let url = settings.resolvedRemoteURL else {
                phase = .idle
                connectionNotice = "还没有填主机地址。打开设置填入 `dsh web` 的地址，例如 192.168.1.20:8787。"
                return
            }
            phase = .ready(url)
        case .engine:
            guard !crashedDuringBoot || bootOnDemand else {
                phase = .idle
                return
            }
            startEngine()
        }
    }

    /// The user asked for the connection: the home screen's button, or a retry.
    ///
    /// Unlike the launch attempt this clears the crash marker, because the user
    /// saying "again" is the one answer that supersedes it.
    func connect() {
        bootOnDemand = true
        EnginePaths.clearBootMarker()
        connecting?.cancel()
        connecting = nil
        switch settings.mode {
        case .remote:
            guard let url = settings.resolvedRemoteURL else {
                phase = .idle
                connectionNotice = "还没有填主机地址。打开设置填入 `dsh web` 的地址，例如 192.168.1.20:8787。"
                return
            }
            phase = .ready(url)
        case .engine:
            startEngine()
        }
    }

    /// Boot again after a crash or a failure, on the user's word.
    func retry() {
        connect()
    }

    // MARK: - Engine

    private func startEngine() {
        guard let runtime else {
            phase = .idle
            connectionNotice = "这个包里没有本机引擎。先跑 tooling/ios/prepare-engine.sh 再重新构建，或改用远程主机（见 app/ios/Engine/README.md）。"
            return
        }
        phase = .connecting
        connectionNotice = nil
        // Booting Node waits for the loopback port, so the work is off the main
        // actor whatever the window is showing.
        connecting = Task { [weak self] in
            defer { self?.connecting = nil }
            do {
                let url = try await runtime.start()
                guard !Task.isCancelled else { return }
                self?.phase = .ready(url)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
                self?.connectionNotice = error.localizedDescription
            }
        }
    }

    // MARK: - Settings

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
        // A settings change is the user saying "use this one", so it connects now
        // rather than waiting for the home screen to be dismissed.
        connect()
    }

    func reload() {
        reloadToken &+= 1
    }

    /// A failure reported by the page itself (a load that never completed).
    func fail(_ message: String) {
        phase = .failed(message)
        connectionNotice = message
    }

    /// Put the page away and go back to the home screen, keeping the saved settings.
    func disconnect() {
        connecting?.cancel()
        connecting = nil
        phase = .idle
    }
}
