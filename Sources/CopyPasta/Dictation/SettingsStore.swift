import Foundation

struct TranscriptCleanupConfiguration: Codable, Equatable, Sendable {
    var model: String
    var instructions: String
}

enum TranscriptionDelay: String, CaseIterable, Codable {
    case minimal, low, medium, high, xhigh

    var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-high"
        }
    }
}

enum PersonalDictionary {
    static func normalizedEntries(_ entries: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for (index, entry) in entries.enumerated() {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            let unsupported = CharacterSet(charactersIn: "<>")
                .union(.newlines).union(.controlCharacters)
            guard trimmed.rangeOfCharacter(from: unsupported) == nil
            else {
                throw ValidationError.invalidCharacters(line: index + 1)
            }
            guard !trimmed.isEmpty else { continue }
            let identity = trimmed.precomposedStringWithCanonicalMapping.lowercased()
            if seen.insert(identity).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    enum ValidationError: LocalizedError {
        case invalidCharacters(line: Int)

        var errorDescription: String? {
            switch self {
            case .invalidCharacters(let line):
                return "Line \(line) contains an unsupported character. Use one word or phrase per line, without <, >, tabs, or control characters."
            }
        }
    }
}

enum RealtimeTranscriptionAvailability: Equatable {
    case disabled
    case missingOpenAIAPIKey
    case available
}

/// Dictation's settings. They live in CopyPasta's defaults under "dictation."-prefixed
/// keys, so they can't collide with CopyPasta's own (SuperSamuelImport copies SuperSamuel's
/// settings into these keys once). The OpenRouter key is the one Copy Tricks uses too.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    enum Keys {
        static let prefix = "dictation."
        static let autoPaste = prefix + "autoPaste"
        static let restoreClipboard = prefix + "restoreClipboard"
        static let realtimeTranscriptionEnabled = prefix + "realtimeTranscriptionEnabled"
        static let transcriptionDelay = prefix + "realtimeTranscriptionDelay"
        static let personalDictionary = prefix + "personalDictionary"
        static let legacyOpenRouterAPIKey = prefix + "openRouterAPIKey"
        static let transcriptionModel = prefix + "openRouterTranscriptionModel"
        static let transcriptionContext = prefix + "openRouterTranscriptionContext"
        static let legacyCleanupPrompt = prefix + "openRouterCleanupPrompt"
        static let cleanupEnabled = prefix + "transcriptCleanupEnabled"
        static let cleanupModel = prefix + "transcriptCleanupModel"
        static let cleanupInstructions = prefix + "transcriptCleanupInstructions"
        static let minimalCleanupPromptInstalled = prefix + "minimalCleanupPromptInstalled"
        static let gemmaCleanupDefaultInstalled = prefix + "gemmaCleanupDefaultInstalled"
        static let nitroCleanupDefaultInstalled = prefix + "nitroCleanupDefaultInstalled"
    }

    private let defaults: UserDefaults
    private let openRouterCredentials: SharedAPIKey
    private let openAICredentials: SharedAPIKey
    private(set) var credentialSaveError: String?

    init(
        defaults: UserDefaults = .standard,
        credentials: SharedAPIKey = .openRouter,
        openAICredentials: SharedAPIKey = .openAI
    ) {
        self.defaults = defaults
        self.openRouterCredentials = credentials
        self.openAICredentials = openAICredentials
        replaceLegacyPrompts()
        migrateCleanupModel()
        registerDefaults()
        migrateLegacyAPIKey()
    }

    var autoPaste: Bool {
        get { defaults.bool(forKey: Keys.autoPaste) }
        set { defaults.set(newValue, forKey: Keys.autoPaste) }
    }

    var restoreClipboard: Bool {
        get { defaults.bool(forKey: Keys.restoreClipboard) }
        set { defaults.set(newValue, forKey: Keys.restoreClipboard) }
    }

    var openRouterAPIKey: String {
        get { openRouterCredentials.read() ?? "" }
        set {
            do {
                try openRouterCredentials.write(newValue)
                credentialSaveError = nil
            } catch {
                credentialSaveError = "Could not save OpenRouter API key: \(error.localizedDescription)"
            }
        }
    }

    var openAIAPIKey: String {
        get { openAICredentials.read() ?? "" }
        set {
            do {
                try openAICredentials.write(newValue)
                credentialSaveError = nil
            } catch {
                credentialSaveError = "Could not save OpenAI API key: \(error.localizedDescription)"
            }
        }
    }

    var realtimeTranscriptionEnabled: Bool {
        get { defaults.bool(forKey: Keys.realtimeTranscriptionEnabled) }
        set { defaults.set(newValue, forKey: Keys.realtimeTranscriptionEnabled) }
    }

    var transcriptionDelay: TranscriptionDelay {
        get {
            TranscriptionDelay(rawValue: defaults.string(forKey: Keys.transcriptionDelay) ?? "")
                ?? .xhigh
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.transcriptionDelay) }
    }

    var personalDictionary: [String] {
        defaults.stringArray(forKey: Keys.personalDictionary) ?? []
    }

    func setPersonalDictionary(_ entries: [String]) throws {
        let normalized = try PersonalDictionary.normalizedEntries(entries)
        defaults.set(normalized, forKey: Keys.personalDictionary)
    }

    var transcriptionModel: String {
        get {
            let value = defaults.string(forKey: Keys.transcriptionModel)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? OpenRouterService.transcriptionModel : value
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(
                value.isEmpty ? OpenRouterService.transcriptionModel : value,
                forKey: Keys.transcriptionModel
            )
        }
    }

    var hasOpenRouterAPIKey: Bool {
        !openRouterAPIKey.isEmpty
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Keys.cleanupEnabled) }
        set { defaults.set(newValue, forKey: Keys.cleanupEnabled) }
    }

    var cleanupModel: String {
        get {
            let value = defaults.string(forKey: Keys.cleanupModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? OpenRouterService.defaultCleanupModel : value
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.cleanupModel) }
    }

    var cleanupInstructions: String {
        get {
            let instructions = defaults.string(forKey: Keys.cleanupInstructions) ?? ""
            return instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? OpenRouterService.defaultCleanupInstruction : instructions
        }
        set { defaults.set(newValue, forKey: Keys.cleanupInstructions) }
    }

    /// SuperSamuel's transcripts came over without their audio (over the import's size limit).
    var superSamuelAudioLeftBehind: Bool {
        defaults.bool(forKey: SuperSamuelImport.audioLeftBehindKey)
    }

    var cleanupConfiguration: TranscriptCleanupConfiguration? {
        cleanupEnabled ? TranscriptCleanupConfiguration(model: cleanupModel, instructions: cleanupInstructions) : nil
    }

    var hasOpenAIAPIKey: Bool {
        !openAIAPIKey.isEmpty
    }

    var canUseRealtimeGPTTranscribe: Bool {
        realtimeTranscriptionAvailability == .available
    }

    var realtimeTranscriptionAvailability: RealtimeTranscriptionAvailability {
        guard realtimeTranscriptionEnabled else {
            return .disabled
        }

        guard hasOpenAIAPIKey else {
            return .missingOpenAIAPIKey
        }

        return .available
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.autoPaste: true,
            Keys.restoreClipboard: true,
            Keys.realtimeTranscriptionEnabled: true,
            Keys.transcriptionDelay: TranscriptionDelay.xhigh.rawValue,
            Keys.personalDictionary: [String](),
            Keys.transcriptionModel: OpenRouterService.transcriptionModel
        ])
    }

    private func replaceLegacyPrompts() {
        guard !defaults.bool(forKey: Keys.minimalCleanupPromptInstalled) else { return }
        defaults.removeObject(forKey: Keys.transcriptionContext)
        defaults.removeObject(forKey: Keys.legacyCleanupPrompt)
        defaults.removeObject(forKey: Keys.cleanupInstructions)
        defaults.set(true, forKey: Keys.minimalCleanupPromptInstalled)
    }

    private func migrateCleanupModel() {
        if !defaults.bool(forKey: Keys.gemmaCleanupDefaultInstalled) {
            let model = defaults.string(forKey: Keys.cleanupModel)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if model == "google/gemini-3.8-flash" {
                defaults.set(OpenRouterService.defaultCleanupModel, forKey: Keys.cleanupModel)
            }
            defaults.set(true, forKey: Keys.gemmaCleanupDefaultInstalled)
        }
        // The previous default (saved as-is by the migration above, so it isn't necessarily a
        // choice) now fails: it was pinned to Cerebras, which stopped serving it. Any other
        // saved model is the user's choice and stays.
        guard !defaults.bool(forKey: Keys.nitroCleanupDefaultInstalled) else { return }
        let model = defaults.string(forKey: Keys.cleanupModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if model == OpenRouterService.previousDefaultCleanupModel {
            defaults.set(OpenRouterService.defaultCleanupModel, forKey: Keys.cleanupModel)
        }
        defaults.set(true, forKey: Keys.nitroCleanupDefaultInstalled)
    }

    private func migrateLegacyAPIKey() {
        let legacyKey = defaults.string(forKey: Keys.legacyOpenRouterAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacyKey.isEmpty else { return }

        do {
            if openRouterCredentials.read() == nil {
                try openRouterCredentials.write(legacyKey)
            }
            defaults.removeObject(forKey: Keys.legacyOpenRouterAPIKey)
        } catch {
            print("Could not migrate OpenRouter API key: \(error.localizedDescription)")
        }
    }
}
