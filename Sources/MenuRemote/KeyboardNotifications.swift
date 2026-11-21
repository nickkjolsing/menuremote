import Foundation
import UserNotifications

/// One quiet prompt for each TV keyboard session. Never activates the app itself.
@MainActor
final class KeyboardNotifications: NSObject, UNUserNotificationCenterDelegate {
    var shouldPresent: () -> Bool = { false }
    var onOpen: () -> Void = {}

    private let center = UNUserNotificationCenter.current()
    private var identifier: String?
    private var deliveryTask: Task<Void, Never>?
    private static let prefix = "menuremote.keyboard."

    override init() {
        super.init()
        center.delegate = self
        // A previous process may have exited while the TV keyboard was open.
        Task { [weak self] in
            guard let self else { return }
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier)
                .filter { $0.hasPrefix(Self.prefix) && $0 != self.identifier })
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier)
                .filter { $0.hasPrefix(Self.prefix) && $0 != self.identifier })
        }
    }

    func show(for deviceName: String) {
        clear()
        let id = Self.prefix + UUID().uuidString
        identifier = id
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            let settings = await center.notificationSettings()
            do {
                let allowed: Bool
                if settings.authorizationStatus == .notDetermined {
                    // Ask in context, when a TV field first needs input.
                    guard !Task.isCancelled, identifier == id, shouldPresent() else { return }
                    allowed = try await center.requestAuthorization(options: [.alert])
                } else {
                    allowed = settings.authorizationStatus == .authorized
                        || settings.authorizationStatus == .provisional
                }
                guard allowed, !Task.isCancelled, identifier == id, shouldPresent() else { return }
                let content = UNMutableNotificationContent()
                content.title = "Apple TV Keyboard"
                content.body = "Click to type on \(deviceName)"
                // No sound, badge, or field contents.
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                // Authorization or delivery can finish after the user leaves the field.
                if Task.isCancelled || identifier != id || !shouldPresent() {
                    remove(id)
                }
            } catch {
                // The in-panel composer works even if notifications aren't available.
                NSLog("Could not show the Apple TV keyboard notification.")
            }
        }
    }

    func clear() {
        deliveryTask?.cancel()
        deliveryTask = nil
        if let identifier { remove(identifier) }
        identifier = nil
    }

    private func remove(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor [weak self] in
            let present = self.map {
                $0.identifier == notification.request.identifier && $0.shouldPresent()
            } ?? false
            completionHandler(present ? [.banner] : [])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               response.notification.request.identifier.hasPrefix(Self.prefix) {
                self?.onOpen()
            }
            completionHandler()
        }
    }
}
