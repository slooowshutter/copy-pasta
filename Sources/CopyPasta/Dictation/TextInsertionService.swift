import AppKit
import Foundation

@MainActor
final class TextInsertionService {
    private let clipboard: ClipboardService

    init(clipboard: ClipboardService) {
        self.clipboard = clipboard
    }

    func deliver(
        text: String,
        targetApplication: NSRunningApplication?,
        autoPaste: Bool,
        restoreClipboard: Bool
    ) {
        let snapshot = (autoPaste && restoreClipboard) ? clipboard.snapshot() : nil

        clipboard.setString(text)
        let deliveryChangeCount = clipboard.changeCount

        guard autoPaste else { return }

        targetApplication?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            Paster.pasteIntoFrontApp {
                guard let snapshot else { return }
                // Once the app has had time to read the transcript: counted from the ⌘V,
                // which can wait for keys to be let go, not from the start.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self?.clipboard.restore(snapshot, ifUnchangedSince: deliveryChangeCount)
                }
            }
        }
    }
}
