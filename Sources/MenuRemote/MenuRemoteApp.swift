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
