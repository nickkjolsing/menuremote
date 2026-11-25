import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: RemoteModel
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let pairing = model.pairing {
                    PairingView(pairing: pairing)
                } else {
                    switch model.phase {
                    case .settingUp(let message):
                        StatusView(icon: nil, title: message)
                    case .setupFailed(let message):
                        StatusView(icon: "exclamationmark.triangle", title: "Setup failed", detail: message) {
                            Button("Retry") { model.retrySetup() }
                        }
                    case .choosingDevice:
                        DevicePickerView()
                    default:
                        PlayerView()
                    }
                }
            }
            if !model.isConnected || model.pairing != nil {
                AppActionsBar(
                    canCheckForUpdates: updater.canCheckForUpdates,
                    checkForUpdates: updater.checkForUpdates,
                    quit: model.quit
                )
            }
        }
        .frame(width: 340)
    }
}

/// App actions stay available independently of helper setup, scanning, or pairing.
struct AppActionsBar: View {
    var canCheckForUpdates: Bool
    var checkForUpdates: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                Button(action: checkForUpdates) {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canCheckForUpdates)
                .help("Update MenuRemote without connecting to an Apple TV")
                Spacer(minLength: 8)
                Button("Quit", action: quit)
                    .keyboardShortcut("q")
                    .help("Quit MenuRemote")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

struct StatusView<Actions: View>: View {
    var icon: String?
    var title: String
    var detail: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).font(.title).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

extension StatusView where Actions == EmptyView {
    init(icon: String?, title: String, detail: String? = nil) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}
