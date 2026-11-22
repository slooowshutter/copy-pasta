import AppKit
import Sparkle

/// Self-updates, through Sparkle. Once a day CopyPasta reads the appcast (Info.plist `SUFeedURL`,
/// a file attached to the latest GitHub release) and offers a newer version if there is one;
/// "Check for Updates…" checks right away. Sparkle installs an update only if it's signed with
/// the private key matching Info.plist's `SUPublicEDKey`, and newer means a higher
/// `CFBundleVersion` (the commit count, see build.sh).
///
/// Builds without a real `SUPublicEDKey` (the placeholder in the repo's Info.plist, `swift run`)
/// leave the updater off and "Check for Updates…" disabled: README › Releasing sets the key up.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    /// Called when `pendingVersion` changes, to retitle the menu item.
    var onChange: (@MainActor () -> Void)?

    /// A newer version a background check found that the user hasn't looked at yet. CopyPasta
    /// has no window of its own to put Sparkle's alert in front of, so rather than popping it
    /// over whatever app the user is in, the menu bar menu offers it ("Update to 1.2.0…").
    private(set) var pendingVersion: String?

    private var controller: SPUStandardUpdaterController?

    var isEnabled: Bool { controller != nil }
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// "Check for Updates…", or "Update to 1.2.0…" once a background check found that version.
    var menuTitle: String {
        pendingVersion.map { "Update to \($0)…" } ?? "Check for Updates…"
    }

    func start() {
        guard controller == nil, Self.isConfigured(.main) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                      userDriverDelegate: self)
        do {
            // Not `controller.startUpdater()`: that shows an alert when it fails.
            try controller.updater.start()
            self.controller = controller
        } catch {
            NSLog("CopyPasta: the updater didn't start: \(error.localizedDescription)")
        }
    }

    /// Checks now and shows the result, or brings forward the update a background check found.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true) // a menu bar app: the window would open behind
        guard let controller else { return explainUpdatesOff() }
        controller.checkForUpdates(nil)
    }

    /// The status menu disables "Check for Updates…" in builds that can't update, but the
    /// panel's ••• menu calls it regardless: say why nothing happens.
    private func explainUpdatesOff() {
        let alert = NSAlert()
        alert.messageText = "This copy of CopyPasta doesn't update itself"
        alert.informativeText = "It was built without the key that verifies updates. The latest version is on GitHub."
        alert.addButton(withTitle: "Open GitHub Releases")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/slooowshutter/copy-pasta/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A feed URL and a well-formed EdDSA public key (base64 of 32 bytes). Without them Sparkle
    /// can't verify updates, and starting it would only fail.
    nonisolated static func isConfigured(_ bundle: Bundle) -> Bool {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32
        else { return false }
        return true
    }

    private func setPending(_ version: String?) {
        guard pendingVersion != version else { return }
        pendingVersion = version
        onChange?()
    }
}

/// Gentle reminders (sparkle-project.org/documentation/gentle-reminders): Sparkle shows a
/// background check's update itself only when it can put it in focus, e.g. right after launch.
/// Otherwise, and in case that alert ends up behind other windows, the menu offers it.
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { setPending(version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { setPending(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { setPending(nil) }
    }
}
