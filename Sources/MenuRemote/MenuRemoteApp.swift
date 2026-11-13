import SwiftUI

@main
struct MenuRemoteApp: App {
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var controller

    var body: some Scene {
        // The UI lives in StatusItemController's panel; SwiftUI's MenuBarExtra
        // window doesn't shrink back when its content gets smaller.
        Settings { EmptyView() }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: RemoteModel

    var body: some View {
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
                        CheckForUpdatesButton()
                    }
                case .choosingDevice:
                    DevicePickerView()
                default:
                    PlayerView()
                }
            }
        }
        .frame(width: 340)
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
