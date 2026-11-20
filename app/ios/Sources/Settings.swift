import Foundation

/// How the app reaches a harness host.
enum LaunchMode: String, Codable, CaseIterable, Identifiable {
    /// A `dsh web` host somewhere the device can reach.
    case remote
    /// A Node runtime packed into this app: `Engine/host.mjs` plus the embedded
    /// `libnode.dylib`. Choosing it when the engine was never staged reports why
    /// instead of pretending to start.
    case engine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remote: return "远程主机"
        case .engine: return "本机引擎"
        }
    }
}

/// What the user chose, persisted between launches.
struct AppSettings: Codable, Equatable {
    var mode: LaunchMode = .remote
    /// Host as typed: `192.168.1.20:8787`, `box.local:8787` or a full URL.
    var remoteURL: String = ""

    static let fallback = AppSettings()

    /// The address to open, or nil when what was typed is not an http(s) URL.
    var resolvedRemoteURL: URL? {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let candidate = text.contains("://") ? text : "http://" + text
        guard
            let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

/// Reads and writes `AppSettings` in the app's own defaults.
@MainActor
final class SettingsStore {
    private let key = "app.settings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .fallback }
        return value
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}