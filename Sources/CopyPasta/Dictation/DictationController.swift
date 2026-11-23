import AppKit
import Foundation

private struct DeliveryOptions {
    let targetApplication: NSRunningApplication?
    let autoPaste: Bool
    let restoreClipboard: Bool
    /// Retried from its card in the panel: the card shows the progress and the transcript (⏎
    /// pastes it from there), so no Island, and nothing pasted or put on the clipboard.
    var inPanel = false
}

/// Dictation (SuperSamuel's engine): its shortcut (⌥⇧⌘Space by default, registered by
/// AppDelegate) calls `toggleRecording()` to start and stop a recording, which is
/// transcribed (OpenAI Realtime live, or OpenRouter from the saved audio), optionally cleaned
/// up, and pasted into the app you were in. AppDelegate calls `start()` / `shutdown()` and
/// puts `menuItems` in CopyPasta's menu bar menu.
@MainActor
final class DictationController {
    private let appState = AppState()
    private let settings: SettingsStore
    private let permissions = PermissionsService()
    private let audioCapture: AudioCaptureService
    private let realtimeAudioCapture = RealtimeAudioCaptureService()
    private let clipboard = ClipboardService()
    private let openRouterService = OpenRouterService()
    private let screenshotCapture = ScreenshotCaptureService()
    private let recordingStore: RecordingStore
    private let microphonePermission: (() async throws -> Void)?
    private let historyStore: TranscriptHistoryStore
    private lazy var textInsertion = TextInsertionService(clipboard: clipboard)
    private lazy var recordingProcessor = RecordingProcessor(
        recordingStore: recordingStore,
        historyStore: historyStore,
        openRouterService: openRouterService
    )

    private var overlayController: OverlayWindowController?
    private var menuBarController: MenuBarController?

    /// The menu bar icon follows the dictation phase (set before `start()`).
    var onPhaseChange: ((DictationPhase) -> Void)?

    /// Dictation's section of CopyPasta's menu bar menu (empty before `start()`).
    var menuItems: [NSMenuItem] { menuBarController?.items ?? [] }

    /// Call from the host menu's `menuWillOpen`: refreshes recordings, history and checkmarks.
    func menuWillOpen(_ menu: NSMenu) { menuBarController?.menuWillOpen(menu) }

    private var elapsedTimer: Timer?
    private var startedAt: Date?
    private var isStartingRecording = false
    private var hasDetectedMicrophoneSignal = false
    /// Last moment the level looked like speech; see stopForgottenRecordingIfNeeded.
    private var lastSpeechAt: Date?
    private var isShowingMicrophoneWarning = false
    private var lastTranscript = ""
    private var targetApplication: NSRunningApplication?
    private var activeRecordingID: UUID?
    private var activeInputDevice: AudioInputDeviceInfo?
    private var realtimeSession: RealtimeTranscriptionService?
    private var realtimeStartTask: Task<Void, Never>?
    private var liveContextAttachmentID: UUID?
    private var recordingConfiguration: RecordingConfiguration?
    private var liveCaptureContinuous = true
    private var savedCaptureContinuous = true
    private var liveAudioDuration: TimeInterval = 0
    private var nextMicrophoneRecoveryAt = Date.distantPast
    private var persistentMenuRefreshTask: Task<Void, Never>?

    private struct RecordingConfiguration {
        let model: String
        let context: String
        let vocabulary: [String]
        let delay: TranscriptionDelay
        let cleanup: TranscriptCleanupConfiguration?
    }

    private var processingTask: Task<Void, Never>?
    private var processingSessionID: UUID?
    private var activeOperationID: UUID?
    private var errorResetTask: Task<Void, Never>?
    private var recoverySessionID: UUID?

    init(
        settings: SettingsStore? = nil,
        recordingStore: RecordingStore? = nil,
        historyStore: TranscriptHistoryStore? = nil,
        audioCapture: AudioCaptureService? = nil,
        microphonePermission: (() async throws -> Void)? = nil
    ) {
        self.settings = settings ?? SettingsStore.shared
        self.recordingStore = recordingStore ?? RecordingStore()
        self.historyStore = historyStore ?? TranscriptHistoryStore()
        self.audioCapture = audioCapture ?? AudioCaptureService()
        self.microphonePermission = microphonePermission
    }

    func start() {
        configureOverlay()
        configureMenuBar()
        try? recordingStore.recoverInterruptedSessions()

        // No "Unsent recording found" alert at launch (SuperSamuel's): unsent and failed
        // recordings wait in the panel's Recordings tab.
        refreshPersistentMenus()
    }

    func shutdown() {
        errorResetTask?.cancel()
        processingTask?.cancel()
        cancelActiveRealtimeTranscription()

        if let processingSessionID {
            try? recordingStore.markReady(
                processingSessionID,
                message: "Processing stopped because CopyPasta quit."
            )
        }

        preserveActiveRecording(
            message: "Recording saved because CopyPasta quit."
        )
        clearAttachedScreenshot()
    }

    private func configureOverlay() {
        let overlayController = OverlayWindowController(state: appState)
        overlayController.onStop = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleOverlayPrimaryAction()
            }
        }
        overlayController.onAttachScreenshot = { [weak self] in
            Task { @MainActor [weak self] in
                self?.captureScreenshot()
            }
        }
        overlayController.onClearScreenshot = { [weak self] in
            Task { @MainActor [weak self] in
                self?.clearAttachedScreenshot()
            }
        }
        overlayController.onRetry = { [weak self] in
            Task { @MainActor [weak self] in
                self?.retryRecoverableRecording()
            }
        }
        overlayController.onDelete = { [weak self] in
            Task { @MainActor [weak self] in
                self?.deleteRecoverableRecording()
            }
        }
        self.overlayController = overlayController
    }

    private func handleOverlayPrimaryAction() {
        if appState.phase == .idle {
            resetToIdle()
            return
        }
        if case .error = appState.phase {
            resetToIdle()
            return
        }

        toggleRecording()
    }

    private func configureMenuBar() {
        let menuBarController = MenuBarController(settings: settings)
        menuBarController.onToggleRecording = { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleRecording()
            }
        }
        menuBarController.onCopyLastTranscript = { [weak self] in
            Task { @MainActor [weak self] in
                self?.copyLastTranscript()
            }
        }
        menuBarController.onOpenAccessibilitySettings = { [weak self] in
            Task { @MainActor [weak self] in
                self?.openAccessibilitySettings()
            }
        }
        menuBarController.onMenuWillOpen = { [weak self] in
            self?.refreshPersistentMenus()
        }
        menuBarController.onSendPendingRecording = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.sendPendingRecording(id)
            }
        }
        menuBarController.onDeletePendingRecording = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.deletePendingRecording(id)
            }
        }
        menuBarController.onRevealPendingRecording = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.revealPendingRecording(id)
            }
        }
        menuBarController.onCopyHistoryTranscript = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.copyHistoryTranscript(id)
            }
        }
        menuBarController.onRevealHistoryTranscript = { [weak self] id in
            Task { @MainActor [weak self] in
                self?.revealHistoryTranscript(id)
            }
        }
        menuBarController.onClearTranscriptHistory = { [weak self] in
            Task { @MainActor [weak self] in
                self?.confirmAndClearTranscriptHistory()
            }
        }
        menuBarController.onPhaseChange = { [weak self] phase in
            self?.onPhaseChange?(phase)
        }
        self.menuBarController = menuBarController
    }

    /// The shortcut, the menu bar item, and the panel's ••• › Start Dictation.
    func toggleRecording() {
        switch appState.phase {
        case .idle, .error:
            Task { await startRecording() }
        case .recording:
            stopAndProcessRecording()
        case .transcribing:
            cancelProcessing()
        }
    }

    func startRecording() async {
        guard
            !isStartingRecording,
            activeRecordingID == nil,
            processingTask == nil
        else {
            return
        }

        isStartingRecording = true
        errorResetTask?.cancel()
        errorResetTask = nil
        defer { isStartingRecording = false }

        do {
            guard settings.hasOpenRouterAPIKey else {
                throw OpenRouterServiceError.missingAPIKey
            }

            targetApplication = NSWorkspace.shared.frontmostApplication
            if let microphonePermission {
                try await microphonePermission()
            } else {
                try await permissions.ensureMicrophonePermission()
            }
            guard !Task.isCancelled, activeRecordingID == nil, processingTask == nil else { return }

            clearAttachedScreenshot()

            let configuration = RecordingConfiguration(
                model: settings.transcriptionModel,
                context: "",
                vocabulary: settings.personalDictionary,
                delay: settings.transcriptionDelay,
                cleanup: settings.cleanupConfiguration
            )
            recordingConfiguration = configuration
            liveCaptureContinuous = true
            savedCaptureContinuous = true
            liveAudioDuration = 0
            let session = try recordingStore.createSession(
                transcriptionModel: configuration.model,
                transcriptionContext: configuration.context,
                vocabulary: configuration.vocabulary,
                liveTranscriptionModel: settings.canUseRealtimeGPTTranscribe
                    ? RealtimeTranscriptionService.transcriptionModel : nil,
                liveTranscriptionDelay: settings.canUseRealtimeGPTTranscribe
                    ? configuration.delay.rawValue : nil,
                cleanup: configuration.cleanup
            )
            let chunkURL = try recordingStore.beginChunk(in: session.id)

            do {
                let inputDevice = try audioCapture.start(at: chunkURL)
                try recordingStore.setInputDevice(
                    inputDevice,
                    for: session.id
                )
                activeInputDevice = inputDevice
            } catch {
                _ = audioCapture.stopIfNeeded()
                try? recordingStore.finishCurrentChunk(in: session.id, duration: audioCapture.recordedDuration)
                try? recordingStore.markFailed(session.id, message: error.localizedDescription)
                refreshPersistentMenus()
                throw error
            }

            recoverySessionID = nil
            activeRecordingID = session.id
            startedAt = Date()
            lastSpeechAt = nil
            hasDetectedMicrophoneSignal = false
            isShowingMicrophoneWarning = false
            nextMicrophoneRecoveryAt = .distantPast
            startElapsedTimer()
            appState.resetForRecording(
                deviceName: activeInputDevice?.name ??
                    "System Default Microphone"
            )
            overlayController?.show()
            menuBarController?.updateStatusTitle(for: .recording)
            startRealtimeTranscriptionIfAvailable(sessionID: session.id)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func stopAndProcessRecording() {
        guard let sessionID = activeRecordingID else {
            return
        }

        if case .interrupted(let message) = audioCapture.checkHealth() {
            savedCaptureContinuous = false
            appState.captureStatusMessage = message
        }
        if let attachment = appState.attachedScreenshot,
           liveContextAttachmentID != attachment.id {
            liveCaptureContinuous = false
        }
        let realtimeSession = detachActiveRealtimeSession()
        let pasteTarget = currentPasteTarget()
        do {
            try finishCurrentChunk(sessionID: sessionID)
            try recordingStore.prepareForProcessing(
                sessionID: sessionID,
                transcriptionModel: recordingConfiguration?.model ?? settings.transcriptionModel,
                transcriptionContext: recordingConfiguration?.context ?? "",
                vocabulary: recordingConfiguration?.vocabulary ?? settings.personalDictionary,
                cleanup: recordingConfiguration == nil ? settings.cleanupConfiguration : recordingConfiguration?.cleanup,
                screenshotSourceURL: appState.attachedScreenshot?.fileURL
            )
        } catch {
            realtimeSession?.cancel()
            if case AudioCaptureError.emptyRecording = error,
               savedCaptureContinuous,
               let startedAt, Date().timeIntervalSince(startedAt) < 0.15 {
                try? recordingStore.markReady(sessionID, message: "Recording was too short. The saved audio was kept.")
                activeRecordingID = nil
                resetToIdle()
                refreshPersistentMenus()
                return
            }
            try? recordingStore.markFailed(
                sessionID,
                message: error.localizedDescription
            )
            activeRecordingID = nil
            stopElapsedTimer()
            clearAttachedScreenshot()
            refreshPersistentMenus()
            recoverySessionID = sessionID
            showError(
                error.localizedDescription,
                recoverable: true
            )
            return
        }

        activeRecordingID = nil
        stopElapsedTimer()
        clearAttachedScreenshot()
        refreshPersistentMenus()

        processSavedRecording(
            sessionID,
            realtimeSession: realtimeSession,
            delivery: DeliveryOptions(
                targetApplication: pasteTarget,
                autoPaste: settings.autoPaste,
                restoreClipboard: settings.restoreClipboard
            )
        )
    }

    private func finishCurrentChunk(sessionID: UUID) throws {
        var stopError: Error?
        if audioCapture.hasActiveRecording {
            do { _ = try audioCapture.stop() } catch { stopError = error }
            try recordingStore.finishCurrentChunk(
                in: sessionID,
                duration: audioCapture.recordedDuration
            )
        }
        // Allow AAC priming and one capture buffer of scheduling skew. Larger gaps
        // include a slow sidecar startup or missed PCM, even if the engine recovered.
        if audioCapture.recordedDuration - liveAudioDuration > 0.15 {
            liveCaptureContinuous = false
        }
        try recordingStore.setCaptureContinuity(
            live: liveCaptureContinuous,
            saved: savedCaptureContinuous,
            for: sessionID
        )
        if let stopError { throw stopError }
    }

    private func startRealtimeTranscriptionIfAvailable(sessionID: UUID) {
        switch settings.realtimeTranscriptionAvailability {
        case .available:
            break
        case .missingOpenAIAPIKey:
            appState.setProgressMessage(
                "Live transcription needs a separate OpenAI API key in Settings. Recording locally..."
            )
            return
        case .disabled:
            return
        }

        let service = RealtimeTranscriptionService { [weak self] transcript in
            guard let self else {
                return
            }
            guard self.activeRecordingID == sessionID ||
                    self.processingSessionID == sessionID
            else {
                return
            }
            self.appState.setTranscriptPreview(fullText: transcript)
        }
        realtimeSession = service
        appState.setProgressMessage("Listening for live transcription...")

        realtimeAudioCapture.onDiscontinuity = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.activeRecordingID == sessionID else { return }
                self.liveCaptureContinuous = false
                self.appState.captureStatusMessage = "Live audio interrupted. The saved recording will be transcribed. \(message)"
            }
        }
        do {
            try realtimeAudioCapture.start { [weak self] data in
                guard let self, self.activeRecordingID == sessionID else { return }
                self.liveAudioDuration += Double(data.count) / (24_000 * 2)
                self.realtimeSession?.appendAudio(data)
            }
        } catch {
            realtimeSession = nil
            liveCaptureContinuous = false
            service.cancel()
            appState.captureStatusMessage = "Live audio unavailable. The saved recording will be used. \(error.localizedDescription)"
            appState.setProgressMessage("Recording locally...")
            plog(
                "Realtime audio sidecar unavailable; recording locally: " +
                    error.localizedDescription
            )
            return
        }

        let apiKey = settings.openAIAPIKey
        let context = recordingConfiguration?.context ?? ""
        let delay = recordingConfiguration?.delay ?? settings.transcriptionDelay
        let keywords = recordingConfiguration?.vocabulary ?? settings.personalDictionary
        appState.liveInstructionsShortened = !RealtimeTranscriptionService.contextIsValid(context)
        realtimeStartTask = Task { @MainActor [weak self, weak service] in
            guard let service else {
                return
            }
            do {
                try await service.start(
                    apiKey: apiKey,
                    transcriptionContext: context,
                    delay: delay,
                    keywords: keywords
                )
            } catch {
                service.cancel()
                guard let self, self.realtimeSession === service else {
                    return
                }
                self.realtimeAudioCapture.stop()
                self.realtimeSession = nil
                self.realtimeStartTask = nil
                if self.activeRecordingID == sessionID {
                    self.liveCaptureContinuous = false
                    self.appState.captureStatusMessage = "Live transcription unavailable. The saved recording will be used. \(error.localizedDescription)"
                    self.appState.setProgressMessage("Recording locally...")
                }
                plog(
                    "Realtime connection unavailable; recording locally: " +
                        error.localizedDescription
                )
            }
        }
    }

    private func detachActiveRealtimeSession() -> RealtimeTranscriptionService? {
        realtimeAudioCapture.stop()
        liveCaptureContinuous = liveCaptureContinuous && !realtimeAudioCapture.hasDiscontinuity
        let service = realtimeSession
        realtimeSession = nil
        realtimeStartTask = nil
        return service
    }

    private func cancelActiveRealtimeTranscription() {
        realtimeAudioCapture.stop()
        realtimeStartTask?.cancel()
        realtimeStartTask = nil
        realtimeSession?.cancel()
        realtimeSession = nil
    }

    private func preserveActiveRecording(message: String) {
        plog("dictation: preserving recording (\(activeRecordingID?.uuidString ?? "none active")): \(message)")
        guard let sessionID = activeRecordingID else {
            stopElapsedTimer()
            return
        }

        cancelActiveRealtimeTranscription()

        if audioCapture.hasActiveRecording {
            do {
                try finishCurrentChunk(sessionID: sessionID)
            } catch {
                plog("Could not finalize saved recording: \(error.localizedDescription)")
            }
        }

        do {
            try recordingStore.prepareForProcessing(
                sessionID: sessionID,
                transcriptionModel: recordingConfiguration?.model ?? settings.transcriptionModel,
                transcriptionContext: recordingConfiguration?.context ?? "",
                vocabulary: recordingConfiguration?.vocabulary ?? settings.personalDictionary,
                cleanup: recordingConfiguration == nil ? settings.cleanupConfiguration : recordingConfiguration?.cleanup,
                screenshotSourceURL: appState.attachedScreenshot?.fileURL
            )
            try recordingStore.markFailed(sessionID, message: message)
        } catch {
            plog("Could not update saved recording metadata: \(error.localizedDescription)")
        }

        activeRecordingID = nil
        stopElapsedTimer()
        refreshPersistentMenus()
    }

    private func processSavedRecording(
        _ sessionID: UUID,
        realtimeSession: RealtimeTranscriptionService? = nil,
        delivery: DeliveryOptions
    ) {
        guard processingTask == nil, activeRecordingID == nil else {
            return
        }

        do {
            guard settings.hasOpenRouterAPIKey else {
                throw OpenRouterServiceError.missingAPIKey
            }
            try recordingStore.markProcessing(sessionID)
        } catch {
            try? recordingStore.markFailed(
                sessionID,
                message: error.localizedDescription
            )
            refreshPersistentMenus()
            if delivery.inPanel { resetToIdle() } else { showError(error.localizedDescription) }
            return
        }

        let operationID = UUID()
        activeOperationID = operationID
        processingSessionID = sessionID
        appState.setPhase(.transcribing)
        appState.setProgressMessage("Preparing saved recording...")
        if !delivery.inPanel { overlayController?.show() }
        menuBarController?.updateStatusTitle(for: .transcribing)
        refreshPersistentMenus()

        processingTask = Task { [weak self] in
            await self?.process(
                sessionID: sessionID,
                realtimeSession: realtimeSession,
                delivery: delivery,
                operationID: operationID
            )
        }
    }

    private func process(
        sessionID: UUID,
        realtimeSession: RealtimeTranscriptionService?,
        delivery: DeliveryOptions,
        operationID: UUID
    ) async {
        do {
            var realtimeTranscript: String?
            let savedSession = try recordingStore.load(sessionID)
            if let realtimeSession,
               !savedSession.canUseLiveTranscript || savedSession.savedCaptureContinuous == false {
                try? recordingStore.saveLivePartialTranscript(realtimeSession.currentTranscript, sessionID: sessionID)
                realtimeSession.cancel()
                appState.setProgressMessage(savedSession.livePreviewRequiresFinalization == true
                    ? "Applying your full instructions to the saved recording..."
                    : "Transcribing the saved recording...")
            } else if let realtimeSession {
                appState.setProgressMessage("Finishing live transcript...")
                do {
                    let finishedTranscript = try await realtimeSession.finish()
                    let session = try recordingStore.load(sessionID)
                    if session.canUseLiveTranscript {
                        realtimeTranscript = finishedTranscript
                    }
                } catch is CancellationError {
                    realtimeSession.cancel()
                    throw CancellationError()
                } catch {
                    try? recordingStore.saveLivePartialTranscript(realtimeSession.currentTranscript, sessionID: sessionID)
                    realtimeSession.cancel()
                    plog(
                        "Realtime transcription unavailable; using saved recording: " +
                            error.localizedDescription
                    )
                    appState.setProgressMessage(
                        "Realtime unavailable. Transcribing saved recording..."
                    )
                }
            }

            let result = try await recordingProcessor.process(
                sessionID: sessionID,
                apiKey: settings.openRouterAPIKey,
                preferredTranscript: realtimeTranscript
            ) { [weak self] progress in
                guard self?.isCurrentOperation(operationID) == true else { return }
                self?.showProcessingProgress(progress)
            }

            try Task.checkCancellation()
            guard isCurrentOperation(operationID) else {
                return
            }

            completeOperation(
                transcript: result.transcript,
                captureWarning: result.captureWarning,
                delivery: delivery
            )
        } catch {
            guard isCurrentOperation(operationID) else {
                return
            }

            let message: String
            if case OpenRouterServiceError.noSpeechDetected = error {
                try? recordingStore.markReady(
                    sessionID,
                    message: "No speech detected. The saved audio remains available."
                )
                resetToIdle()
                appState.setProgressMessage("No speech detected. Ready to record.")
            } else if isCancellation(error) {
                message = "Processing cancelled. The recording was kept."
                try? recordingStore.markReady(sessionID, message: message)
                resetToIdle()
            } else {
                message = error.localizedDescription
                try? recordingStore.markFailed(sessionID, message: message)
                if delivery.inPanel {
                    resetToIdle() // the card says what went wrong
                } else {
                    recoverySessionID = sessionID
                    showError(message, recoverable: true)
                }
            }

            activeOperationID = nil
            processingTask = nil
            processingSessionID = nil
            refreshPersistentMenus()
        }
    }

    private func showProcessingProgress(
        _ progress: RecordingProcessingProgress
    ) {
        appState.setPhase(.transcribing)
        appState.processingStatusMessage = progress.stage == .cleaningUp ? "Cleaning up transcript..." : "Transcribing"
        appState.setProgressMessage(
            progress.stage == .cleaningUp ? "Cleaning up transcript..."
                : "Transcribing part \(progress.currentPart) of \(progress.totalParts)..."
        )
        if !progress.transcriptPreview.isEmpty {
            appState.setTranscriptPreview(fullText: progress.transcriptPreview)
        }
        menuBarController?.updateStatusTitle(for: .transcribing)
    }

    private func completeOperation(
        transcript: String,
        captureWarning: String?,
        delivery: DeliveryOptions
    ) {
        activeOperationID = nil
        processingTask = nil
        processingSessionID = nil
        targetApplication = nil
        lastTranscript = transcript
        appState.setTranscriptPreview(fullText: transcript)
        appState.captureStatusMessage = captureWarning
        appState.showsRecoveryActions = false

        if !delivery.inPanel {
            let canAutoPaste = delivery.autoPaste &&
                permissions.hasAccessibilityPermission(prompt: false)
            textInsertion.deliver(
                text: transcript,
                targetApplication: delivery.targetApplication,
                autoPaste: canAutoPaste,
                restoreClipboard: delivery.restoreClipboard
            )
        }

        appState.setPhase(.idle)
        appState.setElapsed(seconds: 0)
        if captureWarning != nil, !delivery.inPanel {
            overlayController?.show()
        } else {
            overlayController?.hide()
        }
        menuBarController?.updateStatusTitle(for: .idle)
        refreshPersistentMenus()
    }

    private func cancelProcessing() {
        let sessionID = processingSessionID
        activeOperationID = nil
        processingTask?.cancel()
        processingTask = nil
        processingSessionID = nil

        if let sessionID {
            try? recordingStore.markReady(
                sessionID,
                message: "Processing cancelled. The recording was kept."
            )
        }

        refreshPersistentMenus()
        resetToIdle()
    }

    private func retryRecoverableRecording() {
        guard let recoverySessionID else {
            return
        }

        self.recoverySessionID = nil
        appState.showsRecoveryActions = false
        resetToIdle()
        sendPendingRecording(recoverySessionID)
    }

    private func deleteRecoverableRecording() {
        guard let recoverySessionID else {
            return
        }
        deletePendingRecording(recoverySessionID)
    }

    /// False when it can't start now (dictating or transcribing something else).
    @discardableResult
    private func sendPendingRecording(
        _ sessionID: UUID,
        targetApplication: NSRunningApplication? = nil,
        inPanel: Bool = false
    ) -> Bool {
        guard !isStartingRecording, appState.phase == .idle || isErrorPhase else {
            return false
        }

        errorResetTask?.cancel()
        resetToIdle()
        do {
            let saved = try recordingStore.load(sessionID)
            let resumesCleanup = saved.cleanup != nil && recordingStore.draftTranscript(sessionID: sessionID) != nil
            try recordingStore.prepareForProcessing(
                sessionID: sessionID,
                transcriptionModel: resumesCleanup ? saved.resolvedTranscriptionModel : settings.transcriptionModel,
                transcriptionContext: resumesCleanup ? (saved.resolvedTranscriptionContext ?? "") : "",
                vocabulary: resumesCleanup ? (saved.vocabulary ?? []) : settings.personalDictionary,
                forceRetranscription: !resumesCleanup,
                cleanup: settings.cleanupConfiguration,
                screenshotSourceURL: nil
            )
        } catch {
            if inPanel {
                try? recordingStore.markFailed(sessionID, message: error.localizedDescription)
            } else {
                showError(error.localizedDescription)
            }
            return true
        }
        processSavedRecording(
            sessionID,
            delivery: DeliveryOptions(
                targetApplication: targetApplication ?? currentPasteTarget(),
                autoPaste: settings.autoPaste,
                restoreClipboard: settings.restoreClipboard,
                inPanel: inPanel
            )
        )
        return true
    }

    private func deletePendingRecording(_ sessionID: UUID) {
        guard processingSessionID != sessionID, activeRecordingID != sessionID else {
            return
        }

        do {
            try recordingStore.trashSession(sessionID)
            refreshPersistentMenus()
            if recoverySessionID == sessionID, activeRecordingID == nil {
                resetToIdle()
            }
        } catch {
            if activeRecordingID != nil {
                appState.captureStatusMessage = "Could not move the older recording to Trash: \(error.localizedDescription)"
            } else {
                showError(error.localizedDescription)
            }
        }
    }

    private func revealPendingRecording(_ sessionID: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([
            recordingStore.directoryURL(for: sessionID)
        ])
    }

    private func copyHistoryTranscript(_ id: UUID) {
        do {
            guard let item = try historyStore.item(id: id) else {
                return
            }
            clipboard.setString(item.text)
            lastTranscript = item.text
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func revealHistoryTranscript(_ id: UUID) {
        guard let url = historyStore.artifactURL(for: id) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func confirmAndClearTranscriptHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear transcript history?"
        alert.informativeText =
            "This permanently deletes every archived recording, transcript, " +
            "and metadata file. Pending unsent recordings are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await historyStore.clear()
                lastTranscript = ""
                refreshPersistentMenus()
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func refreshPersistentMenus() {
        // Coalesce menu openings; the history store caches decoded entries and scans off-main.
        persistentMenuRefreshTask?.cancel()
        persistentMenuRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let history = try await historyStore.recent()
                try Task.checkCancellation()
                let pending = try recordingStore.summaries()
                let hiddenIDs = Set(
                    [activeRecordingID, processingSessionID].compactMap { $0 }
                )
                menuBarController?.updatePendingRecordings(
                    pending.filter { !hiddenIDs.contains($0.id) }
                )
                menuBarController?.updateTranscriptHistory(history)
                if lastTranscript.isEmpty, let mostRecent = history.first {
                    lastTranscript = mostRecent.text
                }
            } catch is CancellationError {
                return
            } catch {
                plog("Could not refresh saved data: \(error.localizedDescription)")
            }
        }
    }

    private var isErrorPhase: Bool {
        if case .error = appState.phase {
            return true
        }
        return false
    }

    private func resetToIdle() {
        activeOperationID = nil
        processingTask = nil
        processingSessionID = nil
        stopElapsedTimer()
        targetApplication = nil
        activeInputDevice = nil
        appState.recordingDeviceName = nil
        appState.captureStatusMessage = nil
        appState.liveInstructionsShortened = false
        recordingConfiguration = nil
        clearAttachedScreenshot()
        overlayController?.hide()
        appState.setPhase(.idle)
        appState.showsRecoveryActions = false
        recoverySessionID = nil
        appState.setElapsed(seconds: 0)
        menuBarController?.updateStatusTitle(for: .idle)
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        return (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    let startedAt = self.startedAt,
                    self.appState.phase == .recording
                else {
                    return
                }

                self.appState.setElapsed(
                    seconds: Date().timeIntervalSince(startedAt)
                )
                self.monitorCaptureHealth()
                let level = self.audioCapture.currentLevel()
                self.appState.pushLevel(level)
                self.updateMicrophoneSignalStatus(
                    level: level,
                    elapsed: self.appState.elapsedSeconds
                )
                self.stopForgottenRecordingIfNeeded(level: level)
            }
        }
    }

    private func monitorCaptureHealth() {
        guard let sessionID = activeRecordingID else { return }
        realtimeAudioCapture.checkHealth()
        if let message = realtimeSession?.failureMessage {
            liveCaptureContinuous = false
            appState.captureStatusMessage = "Live transcription stopped. The saved recording will be used. \(message)"
        }

        guard Date() >= nextMicrophoneRecoveryAt else { return }
        let interruption: String
        if !audioCapture.hasActiveRecording {
            interruption = "The microphone is unavailable. Retrying capture..."
        } else if case .interrupted(let message) = audioCapture.checkHealth() {
            interruption = message
        } else {
            return
        }

        savedCaptureContinuous = false
        liveCaptureContinuous = false
        appState.captureStatusMessage = "\(interruption) Some audio may be missing; recorded parts will be kept."
        try? recordingStore.setCaptureContinuity(live: false, saved: false, for: sessionID)
        nextMicrophoneRecoveryAt = Date().addingTimeInterval(2)
        if audioCapture.hasActiveRecording {
            _ = audioCapture.stopIfNeeded()
            try? recordingStore.finishCurrentChunk(in: sessionID, duration: audioCapture.recordedDuration)
        }
        do {
            let url = try recordingStore.beginChunk(in: sessionID)
            let device = try audioCapture.start(at: url)
            try recordingStore.setInputDevice(device, for: sessionID)
            activeInputDevice = device
            appState.recordingDeviceName = device.name
        } catch {
            appState.captureStatusMessage = "Microphone capture interrupted. Recorded parts are safe. Retrying: \(error.localizedDescription)"
        }
    }

    private func updateMicrophoneSignalStatus(
        level: Float,
        elapsed: TimeInterval
    ) {
        if level >= 0.025 {
            hasDetectedMicrophoneSignal = true
            if isShowingMicrophoneWarning {
                isShowingMicrophoneWarning = false
                if liveCaptureContinuous && savedCaptureContinuous {
                    appState.captureStatusMessage = nil
                }
            }
            return
        }

        guard
            elapsed >= 5,
            !hasDetectedMicrophoneSignal,
            !isShowingMicrophoneWarning
        else {
            return
        }

        isShowingMicrophoneWarning = true
        guard appState.captureStatusMessage == nil else { return }
        appState.captureStatusMessage =
            "No recorded signal from \(activeInputDevice?.name ?? "the selected microphone") — check your input device."
    }

    // A recording nobody stopped kept the microphone on for 9.5 hours (Nov 2026: the
    // overlay was hidden behind the notch, and SuperSamuel had taken ⌥Space). Failsafe:
    // after 2 minutes without speech, or 30 minutes in all, stop and keep the audio
    // without sending it anywhere; the Island offers Send (Retry) or Trash.
    static let silenceLimit: TimeInterval = 120
    static let lengthLimit: TimeInterval = 30 * 60
    /// About -32 dB average: speech near the Mac's microphone is well above it, a quiet room below.
    static let speechLevel: Float = 0.22

    private func stopForgottenRecordingIfNeeded(level: Float, now: Date = Date()) {
        guard appState.phase == .recording, let startedAt else { return }
        if level >= Self.speechLevel { lastSpeechAt = now }
        guard let reason = Self.forgottenRecordingReason(startedAt: startedAt, lastSpeechAt: lastSpeechAt, now: now)
        else { return }
        let sessionID = activeRecordingID
        preserveActiveRecording(message: reason)
        recoverySessionID = sessionID
        lastSpeechAt = nil
        showError(reason, recoverable: sessionID != nil)
    }

    /// Why a recording should stop by itself now, or nil while it's fine.
    static func forgottenRecordingReason(startedAt: Date, lastSpeechAt: Date?, now: Date) -> String? {
        let silent = now.timeIntervalSince(max(lastSpeechAt ?? startedAt, startedAt))
        if silent >= silenceLimit {
            return "Stopped after 2 minutes without speech. The recording is saved and wasn't sent: send it, or trash it."
        }
        if now.timeIntervalSince(startedAt) >= lengthLimit {
            return "Stopped at 30 minutes. The recording is saved and wasn't sent: send it, or trash it."
        }
        return nil
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
        hasDetectedMicrophoneSignal = false
        isShowingMicrophoneWarning = false
        activeInputDevice = nil
    }

    private func currentPasteTarget() -> NSRunningApplication? {
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != currentProcessIdentifier
        {
            return frontmostApplication
        }

        if let targetApplication,
           targetApplication.processIdentifier != currentProcessIdentifier
        {
            return targetApplication
        }

        return nil
    }

    private func copyLastTranscript() {
        let transcript = lastTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !transcript.isEmpty else {
            return
        }
        clipboard.setString(transcript)
    }

    private func openAccessibilitySettings() {
        _ = permissions.hasAccessibilityPermission(prompt: true)
        permissions.openAccessibilitySettings()
    }

    private func captureScreenshot() {
        guard appState.phase == .recording, !appState.isCapturingScreenshot else {
            return
        }

        appState.isCapturingScreenshot = true
        appState.screenshotStatusMessage = nil
        defer { appState.isCapturingScreenshot = false }

        do {
            try permissions.ensureScreenRecordingPermission(prompt: true)
        } catch {
            appState.screenshotStatusMessage =
                "\(error.localizedDescription) Enable it in System Settings, then retake."
            return
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let candidates = [NSWorkspace.shared.frontmostApplication, targetApplication]
            .compactMap { $0 }
            .filter { $0.processIdentifier != currentProcessIdentifier }
            .reduce(into: [NSRunningApplication]()) { applications, application in
                if !applications.contains(where: {
                    $0.processIdentifier == application.processIdentifier
                }) {
                    applications.append(application)
                }
            }

        var lastError: Error?
        for application in candidates {
            do {
                let attachment = try screenshotCapture.captureWindow(for: application)
                let previousAttachment = appState.attachedScreenshot
                appState.attachedScreenshot = attachment
                screenshotCapture.remove(previousAttachment)
                updateRealtimeContext(for: attachment)
                return
            } catch {
                lastError = error
            }
        }

        appState.screenshotStatusMessage =
            lastError?.localizedDescription ?? "Could not attach a screenshot."
    }

    private func updateRealtimeContext(for attachment: AttachedScreenshot) {
        let attachmentID = attachment.id
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let visibleText = await ScreenshotContextExtractor.extractText(
                from: attachment.fileURL
            )
            guard
                self.activeRecordingID != nil,
                self.appState.attachedScreenshot?.id == attachmentID
            else {
                return
            }

            var contextParts = [self.recordingConfiguration?.context ?? ""]
            if let visibleText {
                contextParts.append(
                    "Screenshot text:\n\(visibleText)"
                )
            }
            self.realtimeSession?.updateTranscriptionContext(
                contextParts.joined(separator: "\n\n")
            )
            self.appState.liveInstructionsShortened = self.realtimeSession?.usesShortenedInstructions ?? false
            self.liveContextAttachmentID = attachmentID
        }
    }

    private func clearAttachedScreenshot() {
        liveContextAttachmentID = nil
        screenshotCapture.remove(appState.attachedScreenshot)
        appState.attachedScreenshot = nil
        appState.screenshotStatusMessage = nil
        appState.isCapturingScreenshot = false
        if activeRecordingID != nil {
            realtimeSession?.updateTranscriptionContext(
                recordingConfiguration?.context ?? ""
            )
        }
    }

    private func showError(
        _ message: String,
        recoverable: Bool = false
    ) {
        stopElapsedTimer()
        targetApplication = nil
        clearAttachedScreenshot()
        appState.setPhase(.error(message))
        if recoverable {
            appState.captureStatusMessage = message
            if let id = recoverySessionID,
               let partial = recordingStore.draftTranscript(sessionID: id)
                    ?? recordingStore.livePartialTranscript(sessionID: id) {
                appState.setTranscriptPreview(fullText: partial)
            }
        } else {
            appState.setProgressMessage(message)
        }
        appState.showsRecoveryActions = recoverable
        menuBarController?.updateStatusTitle(for: .error(message))
        overlayController?.show()

        errorResetTask?.cancel()
        guard !recoverable else {
            return
        }

        errorResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            self?.resetToIdle()
        }
    }
}

// MARK: - The panel's Recordings tab

extension DictationController {
    /// The finished recordings, newest first, from Transcript History.
    /// ponytail: the latest 150 transcripts; page it if anyone wants to scroll further back.
    func archivedRecordingCards() async -> [RecordingCard] {
        let history = (try? await historyStore.recent(limit: 150)) ?? []
        return history.map { item -> RecordingCard in
            let meta = historyDetails(item.id)
            return RecordingCard(
                id: item.id, createdAt: item.createdAt, status: .transcribed, duration: meta.duration,
                text: item.text, audioBytes: meta.bytes, screenSource: meta.screen ? "Screen" : nil, archived: true
            )
        }
    }

    /// The recordings still in Recordings: live, transcribing, not sent, failed. A few
    /// small files, so quick: the panel shows these at once, before the history.
    func pendingRecordingCards() -> [RecordingCard] {
        let sessions = (try? recordingStore.pendingSessions()) ?? []
        return sessions.map { session -> RecordingCard in
            let summary = recordingStore.summary(for: session)
            let status: RecordingCard.Status
            switch session.status {
            case .recording where session.id == activeRecordingID: status = .recording
            case .processing where session.id == processingSessionID: status = .transcribing
            case .ready: status = .notSent
            default: status = .failed   // incl. recording/processing left over from a crash
            }
            return RecordingCard(
                id: session.id, createdAt: session.createdAt, status: status,
                duration: status == .recording ? Date().timeIntervalSince(session.createdAt) : summary.estimatedDuration,
                text: recordingStore.finalTranscript(sessionID: session.id)
                    ?? recordingStore.draftTranscript(sessionID: session.id)
                    ?? recordingStore.livePartialTranscript(sessionID: session.id),
                message: status == .transcribing ? appState.processingStatusMessage
                    : session.lastError ?? (status == .notSent ? "Saved, not sent yet." : nil),
                audioBytes: summary.sizeBytes,
                screenSource: session.screenshotFilename == nil ? nil : "Screen",
                inputDevice: session.inputDevice?.name,
                keyMissing: status == .failed && !settings.hasOpenRouterAPIKey,
                levels: status == .recording ? Array(appState.waveformSamples.suffix(34)) : []
            )
        }
    }

    /// A finished recording's length, size and screen context, read once: an archive never
    /// changes, and re-reading 150 files on every panel opening would hitch its slide.
    private static var historyDetailsCache: [UUID: (duration: TimeInterval, bytes: Int64, screen: Bool)] = [:]

    private func historyDetails(_ id: UUID) -> (duration: TimeInterval, bytes: Int64, screen: Bool) {
        if let cached = Self.historyDetailsCache[id] { return cached }
        let meta = try? historyStore.metadata(id: id)
        let audio = meta?.audio ?? []
        let details = (duration: audio.reduce(0) { $0 + ($1.durationSeconds ?? 0) },
                       bytes: audio.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) },
                       screen: meta?.workflow.usedScreenshotContext == true)
        Self.historyDetailsCache[id] = details
        return details
    }

    /// What the Island shows, for the Recordings tab's live card.
    var liveState: AppState { appState }

    /// A card's Retry / Send Anyway: transcribes it again right in the card, panel open.
    /// False when it can't start now (dictating or transcribing something else).
    func retryInPanel(_ id: UUID) -> Bool { sendPendingRecording(id, inPanel: true) }

    func trashRecording(_ card: RecordingCard) {
        if card.archived {
            guard let url = historyStore.artifactURL(for: card.id) else { return }
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { showError(error.localizedDescription) }
        } else {
            deletePendingRecording(card.id)
        }
    }

    /// The recording's audio, in order; empty when none is on disk (SuperSamuel's history
    /// can come over without its audio, see SuperSamuelImport.audioLimit).
    func audioFiles(for card: RecordingCard) -> [URL] {
        let urls: [URL]
        if card.archived {
            guard let folder = historyStore.artifactURL(for: card.id),
                  let meta = try? historyStore.metadata(id: card.id) else { return [] }
            urls = meta.audio.map { folder.appendingPathComponent($0.filename) }
        } else {
            guard let session = try? recordingStore.load(card.id) else { return [] }
            let folder = recordingStore.directoryURL(for: card.id)
            urls = session.chunks.map { folder.appendingPathComponent($0.filename) }
        }
        return urls.filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
    }

    func revealRecording(_ card: RecordingCard) {
        card.archived ? revealHistoryTranscript(card.id) : revealPendingRecording(card.id)
    }
}
