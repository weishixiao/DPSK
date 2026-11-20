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

    /// True only when this build carries a packed Node runtime.
    var engineAvailable: Bool { runtime != nil }

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
            startEngine()
        }
    }

    private func startEngine() {
        guard let runtime else {
            phase = .failed("这个包里没有本机引擎。改用远程主机，或先按 app/ios/README.zh.md 准备引擎再重新构建。")
            return
        }
        phase = .connecting
        do {
            phase = .ready(try runtime.start())
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func apply(_ next: AppSettings) {
        settings = next
        store.save(next)
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