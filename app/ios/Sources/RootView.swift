import SwiftUI

/// Black and white, one screen, no chrome the harness already provides.
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var editing = false

    private let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .idle:
                waiting("正在连接…")
            case .connecting:
                waiting("正在启动本机引擎…")
            case .ready(let url):
                served(url)
            case .failed(let message):
                failure(message)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .sheet(isPresented: $editing) {
            SettingsSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .onAppear { model.start() }
    }

    private func served(_ url: URL) -> some View {
        WebContainer(url: url, reloadToken: model.reloadToken) { model.fail($0) }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) { bar(url) }
    }

    private func bar(_ url: URL) -> some View {
        HStack(spacing: 14) {
            Text(url.absoluteString)
                .font(mono)
                .foregroundStyle(.white.opacity(0.55))
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
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5)
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white)
            Text(text)
                .font(mono)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("连不上")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white)
            Text(message)
                .font(mono)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                outlineButton("重试") { model.start() }
                outlineButton("设置") { editing = true }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
    }

    private func outlineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(mono)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(.white.opacity(0.4), lineWidth: 0.5)
                )
        }
    }
}

/// Host and mode, in the same black and white as the rest.
private struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host: String = ""
    @State private var mode: LaunchMode = .remote

    private let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("连接")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("关闭") { dismiss() }
                        .font(mono)
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("主机地址")
                    TextField("192.168.1.20:8787", text: $host)
                        .font(mono)
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(.white.opacity(0.25)).frame(height: 0.5)
                        }
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("来源")
                    ForEach(LaunchMode.allCases) { candidate in
                        modeRow(candidate)
                    }
                    if model.engineAvailable {
                        // The engine logs where the sandbox lets it write; saying
                        // where saves guessing when a boot does not come up.
                        Text(model.engineLogPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    var next = model.settings
                    next.mode = mode
                    next.remoteURL = host
                    model.apply(next)
                    dismiss()
                } label: {
                    Text("保存并连接")
                        .font(mono)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white)
                }
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            host = model.settings.remoteURL
            mode = model.settings.mode
        }
    }

    private func modeRow(_ candidate: LaunchMode) -> some View {
        let unavailable = candidate == .engine && !model.engineAvailable
        return Button {
            if !unavailable { mode = candidate }
        } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .stroke(.white.opacity(mode == candidate ? 0.9 : 0.3), lineWidth: 0.5)
                    .frame(width: 12, height: 12)
                    .overlay {
                        if mode == candidate {
                            Rectangle().fill(.white).padding(3)
                        }
                    }
                Text(candidate.title)
                    .font(mono)
                    .foregroundStyle(unavailable ? .white.opacity(0.3) : .white.opacity(0.9))
                Spacer(minLength: 0)
                if unavailable {
                    Text("未打包")
                        .font(mono)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.vertical, 6)
        }
        .disabled(unavailable)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
    }
}