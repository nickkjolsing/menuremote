import AppKit
import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle for the lifetime of the menu bar app. Updates are user initiated.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    var willCheckForUpdates: (() -> Void)?

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        willCheckForUpdates?()
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
