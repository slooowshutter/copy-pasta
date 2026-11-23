import AppKit
import Combine
import SwiftUI

/// Dictation's overlay: the Island (DictationIsland.swift), with the API SuperSamuel's
/// DictationController already drives. Top-center of the screen, never takes keyboard
/// focus, and its buttons work on the first click.
@MainActor
final class OverlayWindowController {
    var onStop: (() -> Void)?
    var onAttachScreenshot: (() -> Void)?
    var onClearScreenshot: (() -> Void)?
    var onRetry: (() -> Void)?
    var onDelete: (() -> Void)?

    private let state: AppState
    private let presence = Presence()
    private var panel: IslandPanel?

    final class Presence: ObservableObject {
        @Published var visible = false
        @Published var targetIcon: NSImage?
        /// The camera notch's height on this screen, nil without one (see DictationIslandView).
        @Published var notchHeight: CGFloat?
        /// Space above the Island: below the menu bar on a screen without a notch.
        @Published var topGap: CGFloat = 0
    }

    init(state: AppState) {
        self.state = state
    }

    func show() {
        let panel = ensurePanel()
        if !presence.visible {
            presence.targetIcon = NSWorkspace.shared.frontmostApplication?.icon
        }
        if !panel.isVisible, let screen = NSScreen.main ?? NSScreen.screens.first {
            let notch = screen.safeAreaInsets.top
            presence.notchHeight = notch > 0 ? notch : nil
            // Below the menu bar where there's no notch to hang from.
            presence.topGap = notch > 0 ? 0 : (screen.frame.maxY - screen.visibleFrame.maxY) + 8
            // One fixed size, big enough for every state (the transcript open included):
            // the Island is drawn at the top of it, and the transparent rest lets clicks
            // through. (Sizing the window to the content left it clipped on one screen.)
            let size = NSSize(width: Self.size.width, height: Self.size.height + notch + presence.topGap)
            panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                  width: size.width, height: size.height), display: false)
            panel.orderFrontRegardless()
        }
        withAnimation(.spring(duration: 0.42, bounce: 0.18)) { presence.visible = true }
    }

    func hide() {
        guard presence.visible else { return }
        withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22), completionCriteria: .logicallyComplete) {
            presence.visible = false
        } completion: { [weak self] in
            guard let self, !self.presence.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// Widest state (470 + ears) and tallest (open transcript, notes, recovery buttons), plus shadow room.
    private static let size = NSSize(width: 560, height: 380)

    private func ensurePanel() -> IslandPanel {
        if let panel { return panel }
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        let actions = DictationIslandActions(
            stop: { [weak self] in self?.onStop?() },
            attachScreenshot: { [weak self] in self?.onAttachScreenshot?() },
            clearScreenshot: { [weak self] in self?.onClearScreenshot?() },
            retry: { [weak self] in self?.onRetry?() },
            delete: { [weak self] in self?.onDelete?() })
        let host = FirstClickHostingView(rootView: IslandHost(state: state, presence: presence, actions: actions))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

/// Never key: the words keep going into the app you're dictating into.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons answer the first click, though the window isn't key: a plain hosting view spends
/// it on making the window key (the Island; the drawer's ••• sometimes didn't react).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct IslandHost: View {
    @ObservedObject var state: AppState
    @ObservedObject var presence: OverlayWindowController.Presence
    let actions: DictationIslandActions
    @State private var expanded = false

    var body: some View {
        DictationIslandView(state: islandState, actions: actions, expanded: $expanded, notchHeight: presence.notchHeight)
            .fixedSize()
            // Grows out of the top edge (the notch) and shrinks back into it.
            .scaleEffect(presence.visible ? 1 : 0.5, anchor: .top)
            .opacity(presence.visible ? 1 : 0)
            .padding(.top, presence.topGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: state.phase) { if state.phase != .recording { expanded = false } }
    }

    private var islandState: DictationIslandState {
        var s = DictationIslandState()
        let words = state.transcriptIsProgress ? "" : state.transcriptText
        let progress = state.transcriptIsProgress ? state.transcriptText : nil
        switch state.phase {
        case .idle: s.phase = .ready
        case .recording: s.phase = .recording
        case .transcribing: s.phase = .transcribing
        case .error(let message): s.phase = .failed; s.errorMessage = message.isEmpty ? state.transcriptText : message
        }
        s.elapsed = state.elapsedSeconds
        s.levels = state.waveformSamples
        s.transcript = words
        s.processingMessage = state.processingStatusMessage ?? progress
        s.note = state.screenshotStatusMessage ?? state.captureStatusMessage
            ?? (state.attachedScreenshot.map { "Context attached · \($0.sourceDescription)" })
            ?? (state.liveInstructionsShortened ? "Live instructions limited to 1,024 characters" : nil)
            ?? (state.phase == .recording ? progress : nil)
        s.showsRecoveryActions = state.showsRecoveryActions
        s.screenshot = state.attachedScreenshot?.previewImage
        s.screenshotSource = state.attachedScreenshot?.sourceDescription
        s.isCapturingScreenshot = state.isCapturingScreenshot
        s.targetIcon = presence.targetIcon
        return s
    }
}
