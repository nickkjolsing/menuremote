import AppKit
import ServiceManagement
import SwiftUI

struct AppleTVDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let model: String
    let software: String?
    let softwareBuild: String?
    let paired: Bool

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        name = dict["name"] as? String ?? "Apple TV"
        address = dict["address"] as? String ?? ""
        model = dict["model"] as? String ?? ""
        software = dict["software"] as? String
        softwareBuild = dict["build"] as? String
        paired = dict["paired"] as? Bool ?? false
    }
}

struct NowPlaying: Equatable {
    var state: String = "idle"
    var title: String?
    var subtitle: String?
    var app: String?
    var position: Double?
    var total: Double?
    /// When `position` was sampled; used to extrapolate while playing.
    var sampledAt = Date()
    var features: [String: Bool] = [:]

    // pyatv reports nonstandard playback rates (e.g. 1.25x) as seeking.
    var isPlaying: Bool { state == "playing" || state == "seeking" }
    var isIdle: Bool { state == "idle" || state == "stopped" || title == nil }

    func supports(_ feature: String) -> Bool { features[feature] ?? false }

    func position(at date: Date) -> Double? {
        guard let position else { return nil }
        let elapsed = isPlaying ? date.timeIntervalSince(sampledAt) : 0
        return min(position + elapsed, total ?? .greatestFiniteMagnitude)
    }

    init() {}

    init(_ e: [String: Any]) {
        state = e["state"] as? String ?? "idle"
        title = (e["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        app = e["app"] as? String
        position = (e["position"] as? NSNumber)?.doubleValue
        total = (e["total"] as? NSNumber)?.doubleValue
        if let ts = (e["timestamp"] as? NSNumber)?.doubleValue {
            sampledAt = Date(timeIntervalSince1970: ts)
        }
        features = e["features"] as? [String: Bool] ?? [:]

        var parts: [String] = []
        if let series = e["series"] as? String, !series.isEmpty {
            var episode = series
            if let s = e["season"] as? Int, let ep = e["episode"] as? Int { episode += " · S\(s) E\(ep)" }
            parts.append(episode)
        } else {
            if let artist = e["artist"] as? String, !artist.isEmpty { parts.append(artist) }
            if let album = e["album"] as? String, !album.isEmpty { parts.append(album) }
        }
        subtitle = parts.isEmpty ? app : parts.joined(separator: " — ")
    }
}

@MainActor
final class RemoteModel: ObservableObject {
    enum VolumeControlMode: Equatable {
        case slider, buttons, unavailable
    }

    enum Phase: Equatable {
        case settingUp(String)
        case setupFailed(String)
        case choosingDevice
        case connecting(String)
        case connected
        case asleep
        case disconnected(String)
    }

    struct Pairing: Equatable {
        var device: AppleTVDevice
        var protocolName: String?
        var step = 1
        var busy = true
        var error: String?
    }

    @Published var phase: Phase = .settingUp("Starting…")
    @Published var devices: [AppleTVDevice] = []
    @Published var scanning = false
    @Published var scanError: String?
    @Published var pairing: Pairing?
    @Published var deviceName = "Apple TV"
    @Published var nowPlaying = NowPlaying()
    @Published var artwork: NSImage?
    @Published var volume: Double?
    @Published var volumeAvailable = false
    @Published var volumeUpAvailable = false
    @Published var volumeDownAvailable = false
    @Published var powerOn: Bool?
    @Published var lastError: String?
    @Published var keyboardAvailable = false
    @Published var keyboardFocused = false
    @Published private(set) var textFocusRequest = UUID()
    @Published var textDraft = ""
    @Published var textSending = false
    @Published var textError: String?
    @Published var textSent = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    @AppStorage("deviceID") private var savedDeviceID: String?
    private let preferences: UserDefaults
    private(set) var textRequestID: String?
    private var textTimeoutTask: Task<Void, Never>?
    private var textConfirmationTask: Task<Void, Never>?

    private let bridge = BridgeProcess()
    private var restartAttempts = 0
    private var errorClearTask: Task<Void, Never>?
    private var lastVolumeSend = Date.distantPast
    /// Optimistic state shown after a local play/pause/skip/seek. Updates from the
    /// Apple TV that contradict it are ignored until it confirms or this expires,
    /// so stale updates already in flight don't make the UI flicker back.
    private var expected: (state: String, position: Double?, until: Date)?
    /// Whether the bridge holds a live connection, even while another screen is shown.
    private var bridgeConnected = false

    var isConnected: Bool { phase == .connected }
    var volumeControlMode: VolumeControlMode {
        if volumeAvailable, let volume, volume.isFinite, (0...100).contains(volume) { return .slider }
        return volumeUpAvailable || volumeDownAvailable ? .buttons : .unavailable
    }
    var hasSavedDevice: Bool { savedDeviceID != nil }
    var needsTextEntry: Bool { isConnected && keyboardAvailable && keyboardFocused }
    var canSendText: Bool {
        needsTextEntry && !textSending
            && !textDraft.isEmpty && textDraft.unicodeScalars.count <= 4096
    }

    // Artwork rendering uses sample data without starting setup or network discovery.
    init(startAutomatically: Bool = true, defaults: UserDefaults? = nil) {
        preferences = defaults ?? .standard
        _savedDeviceID = AppStorage("deviceID", store: defaults)
        if let id = savedDeviceID,
           let names = preferences.dictionary(forKey: "deviceNames") as? [String: String] {
            deviceName = names[id] ?? "Apple TV"
        }
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        bridge.onExit = { [weak self] status in self?.bridgeExited(status) }
        if startAutomatically {
            Task { await start() }
        }
    }

    // MARK: - Bridge lifecycle

    func start() async {
        do {
            phase = .settingUp("Starting…")
            try bridge.start()
        } catch {
            phase = .setupFailed(error.localizedDescription)
        }
    }

    func retrySetup() {
        Task { await start() }
    }

    private func bridgeExited(_ status: Int32) {
        bridgeConnected = false
        resetVolume()
        resetKeyboard()
        restartAttempts += 1
        guard restartAttempts <= 3 else {
            phase = .setupFailed("The pyatv helper keeps crashing (exit \(status)). See ~/Library/Logs/MenuRemote.log.")
            return
        }
        phase = .disconnected("Helper restarted")
        Task {
            try? await Task.sleep(for: .seconds(2))
            await start()
        }
    }

    // MARK: - Events

    func handle(_ e: [String: Any]) {
        // Background retries for the previous TV must not dismiss the picker
        // or replace a pairing the user has started for another device.
        let choosingDevice = phase == .choosingDevice || pairing != nil
        switch e["event"] as? String {
        case "ready":
            if let id = savedDeviceID {
                phase = .connecting(deviceName)
                bridge.send(["cmd": "connect", "id": id])
            } else {
                showDevicePicker()
            }
        case "scanning":
            scanning = true
            scanError = nil
        case "devices":
            scanning = false
            scanError = nil
            devices = (e["devices"] as? [[String: Any]] ?? []).compactMap(AppleTVDevice.init)
        case "connecting":
            if !choosingDevice && !isConnected { phase = .connecting(deviceName) }
        case "connected":
            restartAttempts = 0
            bridgeConnected = true
            guard !choosingDevice else { break }
            resetVolume()
            if let device = (e["device"] as? [String: Any]).flatMap(AppleTVDevice.init) {
                deviceName = device.name
                savedDeviceID = device.id
                remember(device)
            }
            pairing = nil
            phase = .connected
        case "needs_pairing":
            guard !choosingDevice else { break }
            if let device = (e["device"] as? [String: Any]).flatMap(AppleTVDevice.init) {
                deviceName = device.name
                pair(device)
            }
        case "asleep":
            bridgeConnected = false
            resetVolume()
            resetKeyboard()
            if !choosingDevice,
               let device = (e["device"] as? [String: Any]).flatMap(AppleTVDevice.init) {
                deviceName = device.name
                remember(device)
            }
            if !choosingDevice { phase = .asleep }
            powerOn = false
        case "disconnected":
            bridgeConnected = false
            resetVolume()
            resetKeyboard()
            if !choosingDevice && (e["reason"] as? String) != "user" {
                phase = .disconnected("Connection lost")
            }
        case "reconnecting":
            resetVolume()
            guard !choosingDevice else { break }
            if case .asleep = phase { break }
            let seconds = e["seconds"] as? Int ?? 0
            phase = .disconnected("Reconnecting in \(seconds)s…")
        case "pairing":
            handlePairing(e)
        case "now_playing":
            applyNowPlaying(NowPlaying(e))
        case "artwork":
            if let b64 = e["data"] as? String, let data = Data(base64Encoded: b64) {
                artwork = NSImage(data: data)
            } else {
                artwork = nil
            }
        case "volume":
            guard bridgeConnected && !choosingDevice,
                  e["device_id"] as? String == savedDeviceID else { break }
            let level = (e["level"] as? NSNumber)?.doubleValue
            volume = level.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
            volumeAvailable = (e["available"] as? Bool ?? false) && volume != nil
            volumeUpAvailable = e["up_available"] as? Bool ?? false
            volumeDownAvailable = e["down_available"] as? Bool ?? false
        case "power":
            if e["known"] as? Bool ?? true { powerOn = e["on"] as? Bool }
        case "keyboard":
            guard isConnected && !choosingDevice else { break }
            keyboardAvailable = e["available"] as? Bool ?? false
            keyboardFocused = e["focused"] as? Bool ?? false
        case "text_sent":
            guard let request = e["request"] as? String, request == textRequestID else { break }
            finishTextRequest()
            textDraft = ""
            showTextConfirmation()
            textError = nil
        case "error":
            let message = e["message"] as? String ?? "Unknown error"
            if e["command"] as? String == "text" {
                guard let request = e["request"] as? String, request == textRequestID else { break }
                finishTextRequest()
                textError = message
            } else if e["command"] as? String == "scan" {
                scanning = false
                scanError = message
            } else if pairing != nil, ["pair_begin", "pair_pin"].contains(e["command"] as? String) {
                pairing?.busy = false
                pairing?.error = message
            } else if case .connecting = phase, e["command"] as? String == "connect" {
                phase = .disconnected(message)
            } else {
                showError(message)
            }
        default:
            break
        }
    }

    private func handlePairing(_ e: [String: Any]) {
        switch e["state"] as? String {
        case "need_pin":
            pairing?.protocolName = e["protocol"] as? String
            pairing?.step = e["step"] as? Int ?? 1
            pairing?.busy = false
            pairing?.error = nil
        case "done":
            pairing = nil
            phase = .connecting(deviceName)
        case "failed":
            pairing?.busy = false
            pairing?.error = e["message"] as? String ?? "Pairing failed"
        default:
            break
        }
    }

    private func showError(_ message: String) {
        lastError = message
        errorClearTask?.cancel()
        errorClearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { lastError = nil }
        }
    }

    // MARK: - Devices & pairing

    private func remember(_ device: AppleTVDevice) {
        var names = preferences.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        names[device.id] = device.name
        preferences.set(names, forKey: "deviceNames")
    }

    func showDevicePicker() {
        resetVolume()
        resetKeyboard(clearDraft: true)
        phase = .choosingDevice
        scan()
    }

    func scan() {
        scanning = true
        scanError = nil
        bridge.send(["cmd": "scan"])
    }

    func closeDevicePicker() {
        if bridgeConnected {
            if let id = savedDeviceID,
               let names = preferences.dictionary(forKey: "deviceNames") as? [String: String] {
                deviceName = names[id] ?? deviceName
            }
            phase = .connected
            bridge.send(["cmd": "refresh"])
        } else {
            reconnect()
        }
    }

    func choose(_ device: AppleTVDevice) {
        resetVolume()
        resetKeyboard(clearDraft: true)
        deviceName = device.name
        if device.paired {
            savedDeviceID = device.id
            phase = .connecting(device.name)
            bridge.send(["cmd": "connect", "id": device.id])
        } else {
            pair(device)
        }
    }

    func pair(_ device: AppleTVDevice) {
        resetVolume()
        pairing = Pairing(device: device)
        bridge.send(["cmd": "pair_begin", "id": device.id])
    }

    func submitPin(_ pin: String) {
        pairing?.busy = true
        pairing?.error = nil
        bridge.send(["cmd": "pair_pin", "pin": pin])
    }

    func retryPairing() {
        guard let device = pairing?.device else { return }
        pair(device)
    }

    func cancelPairing() {
        bridge.send(["cmd": "pair_cancel"])
        pairing = nil
        if !bridgeConnected { showDevicePicker() }
    }

    func reconnect() {
        resetVolume()
        guard let id = savedDeviceID else { return showDevicePicker() }
        resetKeyboard()
        phase = .connecting(deviceName)
        bridge.send(["cmd": "connect", "id": id])
    }

    // MARK: - Text entry

    func focusTextEntry() {
        guard needsTextEntry else { return }
        textFocusRequest = UUID()
    }

    func sendText() {
        guard canSendText, let id = savedDeviceID else { return }
        let request = UUID().uuidString
        textRequestID = request
        textSending = true
        textError = nil
        clearTextConfirmation()
        bridge.send(["cmd": "text", "text": textDraft, "request": request, "device_id": id])
        textTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.textRequestID == request else { return }
            self.finishTextRequest()
            self.textError = "Couldn't confirm text was sent. Check the TV before trying again."
        }
    }

    private func finishTextRequest() {
        textTimeoutTask?.cancel()
        textTimeoutTask = nil
        textRequestID = nil
        textSending = false
    }

    private func showTextConfirmation() {
        clearTextConfirmation()
        textSent = true
        textConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.textSent = false
            self?.textConfirmationTask = nil
        }
    }

    private func clearTextConfirmation() {
        textConfirmationTask?.cancel()
        textConfirmationTask = nil
        textSent = false
    }

    private func resetKeyboard(clearDraft: Bool = false) {
        if textSending { textError = "Connection changed. Check the TV before sending again." }
        finishTextRequest()
        keyboardAvailable = false
        keyboardFocused = false
        clearTextConfirmation()
        if clearDraft {
            textDraft = ""
            textError = nil
        }
    }

    // MARK: - Playback

    private func applyNowPlaying(_ update: NowPlaying) {
        guard let expected, Date() < expected.until else {
            self.expected = nil
            nowPlaying = update
            return
        }
        let stateMatches = update.state == expected.state
        let positionMatches = expected.position.map { target in
            update.position.map { abs($0 - target) < 3 } ?? true
        } ?? true
        if stateMatches && positionMatches {
            self.expected = nil
            nowPlaying = update
        } else {
            // Take the new metadata but keep the optimistic playback state.
            var merged = update
            merged.state = nowPlaying.state
            merged.position = nowPlaying.position
            merged.sampledAt = nowPlaying.sampledAt
            nowPlaying = merged
        }
    }

    private func setOptimistic(state: String? = nil, position: Double?) {
        let now = Date()
        if let position {
            nowPlaying.position = max(0, min(position, nowPlaying.total ?? .greatestFiniteMagnitude))
        } else {
            nowPlaying.position = nowPlaying.position(at: now)
        }
        nowPlaying.sampledAt = now
        if let state { nowPlaying.state = state }
        expected = (nowPlaying.state, position == nil ? nil : nowPlaying.position, now.addingTimeInterval(2))
    }

    func playPause() {
        setOptimistic(state: nowPlaying.isPlaying ? "paused" : "playing", position: nil)
        bridge.send(["cmd": "play_pause"])
    }

    func skip(_ seconds: Double) {
        if let pos = nowPlaying.position(at: Date()) {
            setOptimistic(position: pos + seconds)
        }
        bridge.send(["cmd": "skip", "seconds": seconds])
    }

    func seek(to position: Double) {
        setOptimistic(position: position)
        bridge.send(["cmd": "seek", "position": Int(position)])
    }

    private func resetVolume() {
        volume = nil
        volumeAvailable = false
        volumeUpAvailable = false
        volumeDownAvailable = false
        lastVolumeSend = .distantPast
    }

    func setVolume(_ level: Double, final: Bool) {
        guard isConnected, volumeControlMode == .slider, level.isFinite,
              (0...100).contains(level), let id = savedDeviceID else { return }
        volume = level
        // Throttle while dragging; always send the final value.
        guard final || Date().timeIntervalSince(lastVolumeSend) > 0.15 else { return }
        lastVolumeSend = Date()
        bridge.send(["cmd": "volume", "level": level, "device_id": id])
    }

    func changeVolume(up: Bool) {
        guard isConnected, let id = savedDeviceID,
              up ? volumeUpAvailable : volumeDownAvailable else { return }
        bridge.send(["cmd": "volume_step", "direction": up ? "up" : "down", "device_id": id])
    }

    func press(_ key: String, hold: Bool = false) {
        bridge.send(["cmd": "key", "key": key, "hold": hold])
    }

    func togglePower() {
        let turnOn = !(powerOn ?? false) || phase == .asleep
        powerOn = turnOn
        bridge.send(["cmd": "power", "on": turnOn])
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showError("Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit() {
        bridge.stop()
        NSApp.terminate(nil)
    }
}
