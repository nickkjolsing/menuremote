import SwiftUI

/// Siri Remote style click pad plus Back / TV / Play-Pause buttons.
struct DPadView: View {
    @EnvironmentObject var model: RemoteModel

    var body: some View {
        HStack(spacing: 22) {
            pad
            VStack(spacing: 12) {
                PillButton(systemName: "chevron.backward", label: "Back") { model.press("menu") }
                PillButton(systemName: "tv", label: "TV") { model.press("home") }
                PillButton(systemName: "playpause.fill", label: "Play/Pause") { model.playPause() }
            }
        }
        .disabled(!model.isConnected)
        .opacity(model.isConnected ? 1 : 0.4)
        .padding(.vertical, 4)
    }

    private var pad: some View {
        ZStack {
            Circle().fill(.primary.opacity(0.08))
            Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            VStack {
                arrow("chevron.up", key: "up")
                Spacer()
                arrow("chevron.down", key: "down")
            }
            .padding(6)
            HStack {
                arrow("chevron.left", key: "left")
                Spacer()
                arrow("chevron.right", key: "right")
            }
            .padding(6)
            Button { model.press("select") } label: {
                Circle().fill(.primary.opacity(0.14))
                    .frame(width: 50, height: 50)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Select (Return)")
        }
        .frame(width: 140, height: 140)
    }

    private func arrow(_ symbol: String, key: String) -> some View {
        Button { model.press(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("\(key.capitalized) (arrow key)")
    }
}

private struct PillButton: View {
    var systemName: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 36)
                .background(Capsule().fill(.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(label)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
