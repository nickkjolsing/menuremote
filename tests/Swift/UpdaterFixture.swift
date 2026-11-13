import AppKit
import Sparkle

// Runs only inside disposable test bundles with a separate bundle identifier.
// Auto-accepting the fixture's updates exercises Sparkle's real installer.
@MainActor
final class UpdaterFixture: NSObject, NSApplicationDelegate, SPUUserDriver {
    private var updater: SPUUpdater!
    private var productionUpdater: AppUpdater?

    private func errorCodes(_ error: NSError) -> [Int] {
        var codes = [error.code]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            codes += errorCodes(underlying)
        }
        return codes
    }

    private func finish(_ result: String, error: Error? = nil) {
        let path = Bundle.main.object(forInfoDictionaryKey: "TestResultPath") as! String
        let payload: [String: Any] = [
            "result": result,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String,
            "error": error.map { String(reflecting: $0) } ?? "",
            "code": error.map { ($0 as NSError).code } ?? 0,
            "codes": error.map { errorCodes($0 as NSError) } ?? [],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try! data.write(to: URL(fileURLWithPath: path), options: .atomic)
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "TestScenario") as? String == "manual-idle" {
            productionUpdater = AppUpdater()
            productionUpdater!.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                precondition(productionUpdater!.canCheckForUpdates)
                finish("ready")
            }
            return
        }
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2.0.0",
           Bundle.main.object(forInfoDictionaryKey: "TestScenario") as? String == "install" {
            finish("relaunched")
            return
        }
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            // Starting a manual-only updater must not enable background checks.
            precondition(!updater.automaticallyChecksForUpdates)
            precondition(!updater.automaticallyDownloadsUpdates)
            updater.checkForUpdates()
        } catch {
            finish("startup-error", error: error)
        }
    }

    func show(_ request: SPUUpdatePermissionRequest,
                                     reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        finish("unexpected-permission-request")
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        finish("up-to-date", error: error)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        finish("error", error: error)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        if !relaunched { finish("installed-without-relaunch") }
    }
    func dismissUpdateInstallation() {}
}

@main
enum UpdaterFixtureMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = UpdaterFixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
