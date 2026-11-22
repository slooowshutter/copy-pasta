import Foundation
import XCTest
@testable import CopyPasta

/// A throwaway defaults suite and key folder, so tests never touch CopyPasta's real settings,
/// its key files, or SuperSamuel's keys.
@MainActor
final class TestSettings {
    let suite = "CopyPastaTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let keys = FileManager.default.temporaryDirectory.appendingPathComponent("CopyPastaTests-\(UUID().uuidString)")

    init() { defaults = UserDefaults(suiteName: suite)! }

    var openRouter: SharedAPIKey {
        SharedAPIKey(store: CredentialStore(service: suite, account: "openrouter-api-key", localDirectory: keys))
    }
    var openAI: SharedAPIKey {
        SharedAPIKey(store: CredentialStore(service: suite, account: "openai-api-key", localDirectory: keys))
    }

    func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, credentials: openRouter, openAICredentials: openAI)
    }

    func tearDown() {
        SuperSamuelImport.removeDefaultsSuite(suite) // also deletes the empty plist it leaves
        try? FileManager.default.removeItem(at: keys)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testCleanupIsOptionalAndPersistsFullInstructions() throws {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        XCTAssertNil(settings.cleanupConfiguration)
        XCTAssertEqual(settings.cleanupModel, "google/gemma-4-31b-it:nitro")
        XCTAssertEqual(settings.cleanupInstructions, OpenRouterService.defaultCleanupInstruction)
        settings.cleanupEnabled = true
        settings.cleanupInstructions = String(repeating: "Keep names. ", count: 200)
        settings.cleanupModel = "  google/gemini-3.8-flash  "
        let reloaded = fixture.makeStore()
        XCTAssertEqual(reloaded.cleanupConfiguration, settings.cleanupConfiguration)
        XCTAssertEqual(reloaded.cleanupModel, "google/gemini-3.8-flash")
        reloaded.cleanupEnabled = false
        XCTAssertNil(reloaded.cleanupConfiguration)
        XCTAssertEqual(reloaded.cleanupInstructions, settings.cleanupInstructions)
    }

    func testTranscriptionModelCanBeChangedAndPersists() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        XCTAssertEqual(settings.transcriptionModel, "openai/gpt-transcribe")
        settings.transcriptionModel = "custom/transcription-model"
        let reloaded = fixture.makeStore()
        XCTAssertEqual(reloaded.transcriptionModel, "custom/transcription-model")
    }

    func testOldPromptsAreReplacedOnceAndSubsequentEditsSurviveRelaunch() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let defaults = fixture.defaults
        for key in ["openRouterCleanupPrompt", "openRouterTranscriptionContext", "transcriptCleanupInstructions"] {
            defaults.set("Old instructions that must no longer apply.", forKey: "dictation." + key)
        }
        defaults.set(true, forKey: "dictation.transcriptCleanupEnabled")
        defaults.set("custom/cleanup-model", forKey: "dictation.transcriptCleanupModel")
        defaults.set(["SuperSamuel"], forKey: "dictation.personalDictionary")

        let settings = fixture.makeStore()
        XCTAssertEqual(settings.cleanupInstructions, OpenRouterService.defaultCleanupInstruction)
        XCTAssertNil(defaults.object(forKey: "dictation.openRouterCleanupPrompt"))
        XCTAssertNil(defaults.object(forKey: "dictation.openRouterTranscriptionContext"))
        XCTAssertNil(defaults.object(forKey: "dictation.transcriptCleanupInstructions"))
        XCTAssertTrue(settings.cleanupEnabled)
        XCTAssertEqual(settings.cleanupModel, "custom/cleanup-model")
        XCTAssertEqual(settings.personalDictionary, ["SuperSamuel"])

        settings.cleanupInstructions = "My new editing instructions."
        let reloaded = fixture.makeStore()
        XCTAssertEqual(reloaded.cleanupConfiguration?.instructions, "My new editing instructions.")
    }

    func testBlankCleanupInstructionsUseTheSameDefault() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        settings.cleanupEnabled = true
        settings.cleanupInstructions = "  \n "
        let reloaded = fixture.makeStore()
        XCTAssertEqual(reloaded.cleanupConfiguration?.instructions, OpenRouterService.defaultCleanupInstruction)
    }

    func testGeminiCleanupMigratesOnceWithoutReplacingCustomInstructions() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let defaults = fixture.defaults
        defaults.set(true, forKey: "dictation.minimalCleanupPromptInstalled")
        defaults.set(true, forKey: "dictation.transcriptCleanupEnabled")
        defaults.set("  google/gemini-3.8-flash  ", forKey: "dictation.transcriptCleanupModel")
        defaults.set("Keep my custom editing rules.", forKey: "dictation.transcriptCleanupInstructions")

        let settings = fixture.makeStore()
        XCTAssertTrue(settings.cleanupEnabled)
        XCTAssertEqual(settings.cleanupModel, "google/gemma-4-31b-it:nitro")
        XCTAssertEqual(settings.cleanupInstructions, "Keep my custom editing rules.")

        settings.cleanupModel = "google/gemini-3.8-flash"
        let reloaded = fixture.makeStore()
        XCTAssertEqual(reloaded.cleanupModel, "google/gemini-3.8-flash")
        XCTAssertEqual(reloaded.cleanupInstructions, "Keep my custom editing rules.")
    }

    /// The old default (Gemma pinned to Cerebras) now fails, so a saved copy of it moves to
    /// the new default once. Any other saved model is the user's choice and stays.
    func testPreviousGemmaDefaultMovesToNitroOnceAndOtherChoicesStay() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let defaults = fixture.defaults
        defaults.set(true, forKey: "dictation.gemmaCleanupDefaultInstalled")
        defaults.set("google/gemma-4-31b-it", forKey: "dictation.transcriptCleanupModel")
        XCTAssertEqual(fixture.makeStore().cleanupModel, "google/gemma-4-31b-it:nitro")

        // Chosen again after the move: kept.
        let settings = fixture.makeStore()
        settings.cleanupModel = "google/gemma-4-31b-it"
        XCTAssertEqual(fixture.makeStore().cleanupModel, "google/gemma-4-31b-it")

        let other = TestSettings()
        defer { other.tearDown() }
        other.defaults.set(true, forKey: "dictation.gemmaCleanupDefaultInstalled")
        other.defaults.set("openai/gpt-oss-120b:nitro", forKey: "dictation.transcriptCleanupModel")
        XCTAssertEqual(other.makeStore().cleanupModel, "openai/gpt-oss-120b:nitro")
    }

    func testRealtimeOpenAIKeyUsesSeparateEntry() throws {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        settings.openRouterAPIKey = "sk-or-test"

        XCTAssertEqual(settings.openRouterAPIKey, "sk-or-test")
        XCTAssertEqual(
            settings.realtimeTranscriptionAvailability,
            .missingOpenAIAPIKey
        )
        XCTAssertFalse(settings.canUseRealtimeGPTTranscribe)

        settings.openAIAPIKey = "sk-openai-test"

        XCTAssertEqual(settings.openAIAPIKey, "sk-openai-test")
        XCTAssertEqual(settings.openRouterAPIKey, "sk-or-test")
        XCTAssertTrue(settings.realtimeTranscriptionEnabled)
        XCTAssertEqual(settings.realtimeTranscriptionAvailability, .available)
        XCTAssertTrue(settings.canUseRealtimeGPTTranscribe)

        settings.transcriptionModel = "mistralai/voxtral-mini-transcribe"
        XCTAssertEqual(
            settings.realtimeTranscriptionAvailability,
            .available
        )
        XCTAssertTrue(settings.canUseRealtimeGPTTranscribe)
    }

    func testDelayDefaultsAndEveryPresetPersists() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        XCTAssertEqual(settings.transcriptionDelay, .xhigh)
        for delay in TranscriptionDelay.allCases {
            settings.transcriptionDelay = delay
            let reloaded = fixture.makeStore()
            XCTAssertEqual(reloaded.transcriptionDelay, delay)
        }
        fixture.defaults.set("unsupported", forKey: "dictation.realtimeTranscriptionDelay")
        XCTAssertEqual(settings.transcriptionDelay, .xhigh)
    }

    func testDictionaryNormalizesAndRejectsInvalidEditsWithoutLosingSavedTerms() throws {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        try settings.setPersonalDictionary(["  SuperSamuel  ", "", "supersamuel", "Café", "Cafe\u{301}", "GPT Live Transcribe"])
        XCTAssertEqual(settings.personalDictionary, ["SuperSamuel", "Café", "GPT Live Transcribe"])
        for invalid in ["<tag>", "a>b", "a\nb", "a\rb", "a\tb", "a\u{0}b", "a\u{2028}b"] {
            XCTAssertThrowsError(try settings.setPersonalDictionary(["New term", invalid]))
            XCTAssertEqual(settings.personalDictionary, ["SuperSamuel", "Café", "GPT Live Transcribe"])
        }
        let reloaded = fixture.makeStore()
        XCTAssertEqual(reloaded.personalDictionary, settings.personalDictionary)
    }

    /// Dictation's settings use their own "dictation." keys, never CopyPasta's.
    func testSettingsStayUnderTheDictationPrefix() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        settings.autoPaste = false
        settings.restoreClipboard = false
        settings.cleanupEnabled = true
        settings.transcriptionDelay = .low
        let keys = fixture.defaults.persistentDomain(forName: fixture.suite)?.keys.map { $0 } ?? []
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            XCTAssertTrue(key.hasPrefix("dictation."), "\(key) is outside the dictation prefix")
        }
    }
}
