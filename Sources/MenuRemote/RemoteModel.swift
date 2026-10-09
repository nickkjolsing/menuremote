import AppKit
import ServiceManagement
import SwiftUI

struct AppleTVDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let model: String
    let paired: Bool

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        name = dict["name"] as? String ?? "Apple TV"
        address = dict["address"] as? String ?? ""
        model = dict["model"] as? String ?? ""
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

    var isPlaying: Bool { state == "playing" }
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
    @Published var pairing: Pairing?
    @Published var deviceName = "Apple TV"
    @Published var nowPlaying = NowPlaying()
    @Published var artwork: NSImage?
    @Published var volume: Double?
    @Published var volumeAvailable = false
    @Published var powerOn: Bool?
    @Published var lastError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    @AppStorage("deviceID") private var savedDeviceID: String?

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
    var hasSavedDevice: Bool { savedDeviceID != nil }

    init() {
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        bridge.onExit = { [weak self] status in self?.bridgeExited(status) }
        Task { await start() }
    }

    // MARK: - Bridge lifecycle

    func start() async {
        if !PythonEnvironment.isReady {
            phase = .settingUp("Installing pyatv (first launch only)…")
            do {
                try await PythonEnvironment.install()
            } catch {
                phase = .setupFailed(error.localizedDescription)
                return
            }
        }
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

    private func handle(_ e: [String: Any]) {
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
        case "devices":
            scanning = false
            devices = (e["devices"] as? [[String: Any]] ?? []).compactMap(AppleTVDevice.init)
        case "connecting":
            if !isConnected { phase = .connecting(deviceName) }
        case "connected":
            restartAttempts = 0
            if let device = (e["device"] as? [String: Any]).flatMap(AppleTVDevice.init) {
                deviceName = device.name
                savedDeviceID = device.id
            }
            pairing = nil
            bridgeConnected = true
            phase = .connected
        case "needs_pairing":
            if let device = (e["device"] as? [String: Any]).flatMap(AppleTVDevice.init) {
                deviceName = device.name
                pair(device)
            }
        case "asleep":
            bridgeConnected = false
            phase = .asleep
            powerOn = false
        case "disconnected":
            bridgeConnected = false
            if (e["reason"] as? String) != "user" {
                phase = .disconnected("Connection lost")
            }
        case "reconnecting":
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
            volumeAvailable = e["available"] as? Bool ?? false
            volume = (e["level"] as? NSNumber)?.doubleValue
        case "power":
            if e["known"] as? Bool ?? true { powerOn = e["on"] as? Bool }
        case "error":
            let message = e["message"] as? String ?? "Unknown error"
            if pairing != nil, ["pair_begin", "pair_pin"].contains(e["command"] as? String) {
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

    func showDevicePicker() {
        phase = .choosingDevice
        scan()
    }

    func scan() {
        scanning = true
        bridge.send(["cmd": "scan"])
    }

    func closeDevicePicker() {
        if bridgeConnected {
            phase = .connected
        } else {
            reconnect()
        }
    }

    func choose(_ device: AppleTVDevice) {
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
        guard let id = savedDeviceID else { return showDevicePicker() }
        phase = .connecting(deviceName)
        bridge.send(["cmd": "connect", "id": id])
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

    func setVolume(_ level: Double, final: Bool) {
        volume = level
        // Throttle while dragging; always send the final value.
        guard final || Date().timeIntervalSince(lastVolumeSend) > 0.15 else { return }
        lastVolumeSend = Date()
        bridge.send(["cmd": "volume", "level": level])
    }

    func press(_ key: String) {
        bridge.send(["cmd": "key", "key": key])
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
