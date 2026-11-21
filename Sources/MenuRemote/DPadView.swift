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
            Circle().fill(.primary.opacity(0.045))
            Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.7)
            VStack {
                arrow("chevron.up", key: "up")
                Spacer()
                arrow("chevron.down", key: "down")
            }
            .padding(2)
            HStack {
                arrow("chevron.left", key: "left")
                Spacer()
                arrow("chevron.right", key: "right")
            }
            .padding(2)
            Button { model.press("select") } label: {
                Circle().fill(LinearGradient(colors: [.primary.opacity(0.14), .primary.opacity(0.09)],
                                             startPoint: .top, endPoint: .bottom))
                    .frame(width: 52, height: 52)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.7))
                    .contentShape(Circle())
            }
            .buttonStyle(SelectButtonStyle { model.press("select", hold: true) })
            .accessibilityLabel("Select")
            .help("Select (Return); press and hold for the context menu")
        }
        .frame(width: 144, height: 144)
    }

    private func arrow(_ symbol: String, key: String) -> some View {
        Button { model.press(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.65))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("\(key.capitalized) (arrow key)")
    }
}

/// Resolve the hold before the tap so releasing a hold never sends a second Select.
private struct SelectButtonStyle: PrimitiveButtonStyle {
    var onHold: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        SelectButtonBody(configuration: configuration, onHold: onHold)
    }

    private struct SelectButtonBody: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let onHold: () -> Void
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @GestureState private var isPressed = false

        var body: some View {
            configuration.label
                .scaleEffect(!reduceMotion && isPressed ? 0.97 : 1)
                .opacity(isPressed ? 0.9 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.23, dampingFraction: 0.8), value: isPressed)
                .gesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .exclusively(before: TapGesture())
                        .updating($isPressed) { _, pressed, _ in pressed = true }
                        .onEnded { result in
                            guard isEnabled else { return }
                            switch result {
                            case .first(true): onHold()
                            case .second: configuration.trigger()
                            default: break
                            }
                        }
                )
                .accessibilityAction { if isEnabled { configuration.trigger() } }
                .accessibilityAction(named: "Press and Hold") { if isEnabled { onHold() } }
        }
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
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 44, height: 36)
                .background(Capsule().fill(.primary.opacity(0.065)))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.055), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(label)
    }
}

private struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.23, dampingFraction: 0.8),
                       value: configuration.isPressed)
    }
}
