import Foundation
import SwiftUI

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

/// Which appearance the shell uses.
///
/// The shell and the Web UI have to agree, or the seam between them shows: a light
/// page under a black status bar reads as a bug. `system` follows iOS, which is what
/// most people expect; the two explicit cases exist for anyone who wants the app to
/// stay put while the device switches at sunset.
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// What to hand SwiftUI; `nil` means "let iOS decide".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// What to hand the WKWebView, so the page's `prefers-color-scheme` matches.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What the user chose, persisted between launches.
struct AppSettings: Codable, Equatable {
    var mode: LaunchMode = .remote
    /// Host as typed: `192.168.1.20:8787`, `box.local:8787` or a full URL.
    var remoteURL: String = ""
    /// Appearance of the shell and of the page it hosts.
    var theme: AppTheme = .system

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
