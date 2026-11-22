import SwiftUI

/// One screen, no chrome the harness already provides, in whichever appearance the
/// settings ask for. Everything the shell draws goes through `Palette`, so a theme
/// change is a value change rather than a second layout.
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var editing = false

    private let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            // The window is always the app. A page, when there is one, covers the
            // home screen; a connection that has not happened is a property of the
            // home screen, not a different screen. Nothing here can refuse to open.
            if case .ready(let url) = model.phase {
                served(url)
            } else {
                home
            }
        }
        .preferredColorScheme(model.settings.theme.colorScheme)
        .tint(palette.accent)
        .sheet(isPresented: $editing) {
            SettingsSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        // A notice, not a gate: it can be dismissed, and the app stays usable.
        .alert("连不上", isPresented: noticeBinding, presenting: model.connectionNotice) { _ in
            Button("重试") { model.retry() }
            Button("设置") { editing = true }
            Button("好", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onAppear {
            // The window is on screen first; the connection is offered after.
            model.started()
            model.connectInBackground()
        }
    }

    /// The alert shows while there is something to say and the page is not up.
    private var noticeBinding: Binding<Bool> {
        Binding(
            get: {
                guard model.connectionNotice != nil else { return false }
                if case .ready = model.phase { return false }
                return true
            },
            set: { shown in
                if !shown { model.connectionNotice = nil }
            }
        )
    }

    /// The app's own screen: what this build is, and one way to open the page.
    @ViewBuilder
    private var home: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DPSK")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(palette.primary)
                Text(model.settings.mode == .engine ? "本机引擎" : "远程主机")
                    .font(mono)
                    .foregroundStyle(palette.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("地址")
                Text(destination)
                    .font(mono)
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if case .connecting = model.phase {
                HStack(spacing: 10) {
                    ProgressView().tint(palette.primary)
                    Text(model.settings.mode == .engine ? "正在启动本机引擎…" : "正在连接…")
                        .font(mono)
                        .foregroundStyle(palette.secondary)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button {
                    model.connect()
                } label: {
                    Text(connectTitle)
                        .font(mono)
                        .foregroundStyle(palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(palette.accent)
                }
                .disabled(isConnecting)

                Button {
                    editing = true
                } label: {
                    Text("设置")
                        .font(mono)
                        .foregroundStyle(palette.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(palette.primary.opacity(0.4), lineWidth: 0.5)
                        )
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What the saved settings point at, in one line.
    private var destination: String {
        switch model.settings.mode {
        case .remote:
            let typed = model.settings.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return typed.isEmpty ? "还没有填主机地址" : typed
        case .engine:
            return model.engineAvailable ? "包内 Node 运行时" : "这个包里没有本机引擎"
        }
    }

    private var isConnecting: Bool {
        if case .connecting = model.phase { return true }
        return false
    }

    private var connectTitle: String {
        switch model.settings.mode {
        case .remote: return "连接"
        case .engine: return model.engineAvailable ? "启动本机引擎" : "改用远程主机"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(palette.primary.opacity(0.45))
    }

    /// The colours of the current appearance. Read from the environment so
    /// `system` follows a device that switches at sunset without any extra wiring.
    @Environment(\.colorScheme) private var scheme

    private var palette: Palette { Palette(scheme: scheme) }

    private func served(_ url: URL) -> some View {
        WebContainer(url: url, reloadToken: model.reloadToken, theme: model.settings.theme) { model.fail($0) }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) { bar(url) }
    }

    private func bar(_ url: URL) -> some View {
        HStack(spacing: 14) {
            Text(url.absoluteString)
                .font(mono)
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .regular))
            }
            Button { editing = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .regular))
            }
        }
        .foregroundStyle(palette.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.barFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.hairline).frame(height: 0.5)
        }
    }

}

/// The shell's two appearances, named once.
struct Palette {
    let scheme: ColorScheme

    private var dark: Bool { scheme == .dark }

    /// Pure black in the dark appearance, a warm off-white in the light one: pure
    /// white behind text is harsher than any page the harness draws.
    var background: Color {
        dark ? .black : Color(red: 0.965, green: 0.965, blue: 0.972)
    }

    var primary: Color {
        dark ? .white : Color(red: 0.09, green: 0.09, blue: 0.11)
    }

    var secondary: Color { primary.opacity(dark ? 0.55 : 0.6) }

    var hairline: Color { primary.opacity(dark ? 0.14 : 0.12) }

    /// The strip above the page: opaque enough to read over a scrolled page.
    var barFill: Color {
        dark ? Color.black.opacity(0.92) : Color.white.opacity(0.94)
    }

    /// The one high-contrast element: it inverts with the appearance, so a primary
    /// button is always the heaviest thing on screen.
    var accent: Color { dark ? .white : .black }
}

/// Host, source and appearance.
private struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var host: String = ""
    @State private var mode: LaunchMode = .remote
    @State private var theme: AppTheme = .system

    private let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    private var palette: Palette { Palette(scheme: scheme) }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("设置")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(palette.primary)
                    Spacer()
                    Button("关闭") { dismiss() }
                        .font(mono)
                        .foregroundStyle(palette.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("主机地址")
                    TextField("192.168.1.20:8787", text: $host)
                        .font(mono)
                        .foregroundStyle(palette.primary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(palette.primary.opacity(0.25)).frame(height: 0.5)
                        }
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("来源")
                    ForEach(LaunchMode.allCases) { candidate in
                        choiceRow(
                            candidate.title,
                            selected: mode == candidate,
                            disabled: candidate == .engine && !model.engineAvailable,
                            note: candidate == .engine && !model.engineAvailable ? "未打包" : nil
                        ) { mode = candidate }
                    }
                    if model.engineAvailable {
                        // The engine logs where the sandbox lets it write; saying
                        // where saves guessing when a boot does not come up.
                        Text(model.engineLogPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.primary.opacity(0.35))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("外观")
                    ForEach(AppTheme.allCases) { candidate in
                        choiceRow(candidate.title, selected: theme == candidate, disabled: false) {
                            theme = candidate
                        }
                    }
                    Text("跟随系统时，iOS 切到深色，这个界面和里面的页面一起切。")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.primary.opacity(0.35))
                }

                Spacer(minLength: 0)

                Button {
                    var next = model.settings
                    next.mode = mode
                    next.remoteURL = host
                    next.theme = theme
                    model.apply(next)
                    dismiss()
                } label: {
                    Text("保存并连接")
                        .font(mono)
                        .foregroundStyle(palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(palette.accent)
                }
            }
            .padding(24)
        }
        .preferredColorScheme(theme.colorScheme ?? scheme)
        .onAppear {
            host = model.settings.remoteURL
            mode = model.settings.mode
            theme = model.settings.theme
        }
    }

    private func choiceRow(
        _ title: String,
        selected: Bool,
        disabled: Bool,
        note: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if !disabled { action() }
        } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .stroke(palette.primary.opacity(selected ? 0.9 : 0.3), lineWidth: 0.5)
                    .frame(width: 12, height: 12)
                    .overlay {
                        if selected {
                            Rectangle().fill(palette.primary).padding(3)
                        }
                    }
                Text(title)
                    .font(mono)
                    .foregroundStyle(palette.primary.opacity(disabled ? 0.3 : 0.9))
                Spacer(minLength: 0)
                if let note {
                    Text(note)
                        .font(mono)
                        .foregroundStyle(palette.primary.opacity(0.3))
                }
            }
            .padding(.vertical, 6)
        }
        .disabled(disabled)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(palette.primary.opacity(0.45))
    }
}
