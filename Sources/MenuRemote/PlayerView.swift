import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var model: RemoteModel
    @AppStorage("showRemote") private var showRemote = false
    @State private var scrubFraction: Double?
    @FocusState private var focused: Bool

    private var np: NowPlaying { model.nowPlaying }
    private var connected: Bool { model.isConnected }

    var body: some View {
        VStack(spacing: 14) {
            header
            if let banner = statusBanner {
                banner
            }
            progress
            transport
            volume
            if showRemote {
                Divider().opacity(0.5)
                DPadView()
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down, action: handleKey)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Artwork(image: model.artwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName)
                    .font(.caption).foregroundStyle(.secondary)
                Text(np.isIdle ? "Not Playing" : (np.title ?? ""))
                    .font(.headline).lineLimit(1)
                if let subtitle = np.isIdle ? np.app : np.subtitle {
                    Text(subtitle)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            SettingsMenu()
        }
    }

    private var statusBanner: AnyView? {
        switch model.phase {
        case .connecting(let name):
            return AnyView(Banner(text: "Connecting to \(name)…", spinner: true))
        case .disconnected(let reason):
            return AnyView(Banner(text: reason, spinner: reason.hasPrefix("Reconnecting")) {
                Button("Retry") { model.reconnect() }.buttonStyle(.link).font(.caption)
            })
        case .asleep:
            return AnyView(Banner(text: "\(model.deviceName) is asleep", spinner: false) {
                Button("Wake") { model.togglePower() }.buttonStyle(.link).font(.caption)
            })
        default:
            return nil
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = np.total ?? 0
            let live = np.position(at: context.date) ?? 0
            let position = scrubFraction.map { $0 * total } ?? live
            HStack(spacing: 10) {
                Text(format(position)).frame(width: 44, alignment: .leading)
                ScrubBar(
                    value: total > 0 ? position / total : 0,
                    enabled: connected && total > 0 && np.supports("set_position"),
                    onChanged: { scrubFraction = $0 },
                    onCommit: { fraction in
                        model.seek(to: fraction * total)
                        scrubFraction = nil
                    }
                )
                Text(total > 0 ? "-" + format(max(0, total - position)) : "--:--")
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack {
            IconButton(systemName: "appletvremote.gen4", size: 17, active: showRemote, help: "Remote") {
                showRemote.toggle()
            }
            Spacer()
            IconButton(systemName: "gobackward.10", size: 24, help: "Back 10 seconds") {
                model.skip(-10)
            }
            .disabled(!connected || np.isIdle)
            Spacer()
            IconButton(systemName: np.isPlaying ? "pause.fill" : "play.fill", size: 32, help: "Play/Pause") {
                model.playPause()
            }
            .disabled(!connected)
            .frame(width: 44)
            Spacer()
            IconButton(systemName: "goforward.10", size: 24, help: "Forward 10 seconds") {
                model.skip(10)
            }
            .disabled(!connected || np.isIdle)
            Spacer()
            IconButton(systemName: "power", size: 17, tint: model.powerOn == true ? .green : nil,
                       help: model.powerOn == true ? "Put to sleep" : "Turn on") {
                model.togglePower()
            }
            .disabled(!(connected || model.phase == .asleep))
        }
        .padding(.horizontal, 2)
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            ScrubBar(
                value: (model.volume ?? 0) / 100,
                enabled: connected && model.volumeAvailable,
                onChanged: { model.setVolume($0 * 100, final: false) },
                onCommit: { model.setVolume($0 * 100, final: true) }
            )
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .opacity(model.volumeAvailable ? 1 : 0.5)
        .help(model.volumeAvailable ? "" : "Volume isn't controllable for this Apple TV's audio output")
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard connected else { return .ignored }
        switch press.key {
        case .upArrow: model.press("up")
        case .downArrow: model.press("down")
        case .leftArrow: model.press("left")
        case .rightArrow: model.press("right")
        case .return: model.press("select")
        case .delete: model.press("menu")
        case .space: model.playPause()
        default:
            switch press.characters {
            case "h": model.press("home")
            case "[": model.skip(-10)
            case "]": model.skip(10)
            default: return .ignored
            }
        }
        return .handled
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Components

struct Artwork: View {
    var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "tv").font(.title2).foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(width: 60, height: 60)
    }
}

struct IconButton: View {
    var systemName: String
    var size: CGFloat
    var active = false
    var tint: Color?
    var help: String
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? (active ? Color.accentColor : Color.primary))
                .frame(width: size + 16, height: size + 16)
                .background(Circle().fill(.primary.opacity(hovering && isEnabled ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct Banner<Trailing: View>: View {
    var text: String
    var spinner: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.mini) }
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Banner where Trailing == EmptyView {
    init(text: String, spinner: Bool) {
        self.init(text: text, spinner: spinner) { EmptyView() }
    }
}

/// A thin capsule slider like the iOS Now Playing scrubber.
struct ScrubBar: View {
    var value: Double
    var enabled: Bool
    var onChanged: (Double) -> Void
    var onCommit: (Double) -> Void

    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(dragValue ?? value, 0), 1)
            let expanded = enabled && (hovering || dragValue != nil)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.primary.opacity(expanded ? 0.85 : 0.55))
                    .frame(width: geo.size.width * fraction)
            }
            .frame(height: expanded ? 9 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        let v = min(max(g.location.x / geo.size.width, 0), 1)
                        dragValue = v
                        onChanged(v)
                    }
                    .onEnded { g in
                        guard enabled else { return }
                        onCommit(min(max(g.location.x / geo.size.width, 0), 1))
                        dragValue = nil
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: expanded)
        }
        .frame(height: 16)
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var model: RemoteModel

    var body: some View {
        Menu {
            Button("Reconnect") { model.reconnect() }
            Button("Switch Apple TV…") { model.showDevicePicker() }
            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Divider()
            Button("Quit MenuRemote") { model.quit() }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}
