import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject var model: RemoteModel
    @State private var showOtherDevices = false

    private var visibleDevices: [AppleTVDevice] {
        model.devices + (showOtherDevices ? model.otherDevices : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose your Apple TV").font(.headline)
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Scan again")
                }
            }

            if visibleDevices.isEmpty {
                Text(model.scanning
                     ? "Looking for Apple TVs on your network…"
                     : "No Apple TVs found. Make sure it's on the same network, and that MenuRemote is allowed under System Settings › Privacy & Security › Local Network.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(visibleDevices) { device in
                            DeviceRow(device: device)
                        }
                    }
                }
                .frame(height: min(CGFloat(visibleDevices.count) * 60, 240))
            }

            if !model.otherDevices.isEmpty {
                Button(showOtherDevices ? "Hide other devices" : "Show other devices (\(model.otherDevices.count))") {
                    showOtherDevices.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                if showOtherDevices {
                    Text("If your TV wasn't listed above, select it here. Some devices may not support remote control.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = model.scanError {
                Text("Scan failed: \(error)")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.hasSavedDevice {
                    Button("Back") { model.closeDevicePicker() }.buttonStyle(.borderless)
                }
                CheckForUpdatesButton().buttonStyle(.borderless)
                Spacer()
                Button("Quit") { model.quit() }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(16)
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var model: RemoteModel
    var device: AppleTVDevice
    @State private var hovering = false

    var body: some View {
        Button { model.choose(device) } label: {
            HStack(spacing: 10) {
                Image(systemName: "appletv.fill").font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.body.weight(.medium))
                    Text("\(device.model) · \(device.address)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(device.paired ? "Connect" : "Pair")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PairingView: View {
    @EnvironmentObject var model: RemoteModel
    var pairing: RemoteModel.Pairing
    @State private var pin = ""

    private var waiting: Bool { pairing.busy && pairing.protocolName == nil }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "appletv.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                Text("Pair with \(pairing.device.name)").font(.headline)
                Text(subtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack {
                PinField(pin: $pin, enabled: !pairing.busy, onComplete: submit)
                    .opacity(waiting ? 0 : 1)
                if pairing.busy {
                    ProgressView().controlSize(.small)
                }
            }

            if let error = pairing.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { model.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if pairing.error != nil && pairing.protocolName == nil {
                    Button("Try Again") { model.retryPairing() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Pair", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(pin.count != 4 || pairing.busy)
                }
            }
            .controlSize(.large)
        }
        .padding(20)
        .onChange(of: pairing.step) { _, _ in pin = "" }
        .onChange(of: pairing.error) { _, error in
            if error != nil { pin = "" }
        }
    }

    private var subtitle: String {
        if pairing.protocolName == nil { return "Contacting your Apple TV…" }
        if pairing.step > 1 { return "Almost done — enter the new code\nshown on your TV." }
        return "Enter the 4-digit code shown on your TV."
    }

    private func submit() {
        guard pin.count == 4, !pairing.busy else { return }
        model.submitPin(pin)
    }
}

/// Four digit boxes backed by an invisible text field that holds focus and input.
private struct PinField: View {
    @Binding var pin: String
    var enabled: Bool
    var onComplete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                digitBox(index)
            }
        }
        .overlay {
            TextField("", text: $pin)
                .textFieldStyle(.plain)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($focused)
                .disabled(!enabled)
                .opacity(0.02)
                .onChange(of: pin) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(4))
                    if digits != new { pin = digits }
                    if digits.count == 4 && new.count == 4 { onComplete() }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        .onChange(of: enabled) { _, isEnabled in
            if isEnabled { focused = true }
        }
    }

    private func digitBox(_ index: Int) -> some View {
        let chars = Array(pin)
        let isActive = focused && enabled && index == min(chars.count, 3)
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.primary.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor : .primary.opacity(0.12),
                                  lineWidth: isActive ? 2 : 1)
            }
            .overlay {
                Text(index < chars.count ? String(chars[index]) : "")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
            }
            .frame(width: 46, height: 54)
            .opacity(enabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}
