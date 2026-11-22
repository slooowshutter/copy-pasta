import Foundation
import XCTest
@testable import CopyPasta

/// CopyPasta keeps API keys in private files (never the Keychain), and dictation shares the
/// OpenRouter key with Copy Tricks. SuperSamuel's Keychain-to-file migration tests are gone
/// with the Keychain option; these cover the file storage that replaced it.
@MainActor
final class CredentialStoreTests: XCTestCase {
    func testKeysSurviveRelaunchInPrivateFilesAndClearing() throws {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        settings.openRouterAPIKey = "  router-example \n"
        settings.openAIAPIKey = "openai-example"
        XCTAssertNil(settings.credentialSaveError)

        let reloaded = fixture.makeStore()
        XCTAssertEqual(reloaded.openRouterAPIKey, "router-example")
        XCTAssertEqual(reloaded.openAIAPIKey, "openai-example")
        reloaded.openRouterAPIKey = "updated-example"
        XCTAssertEqual(fixture.makeStore().openRouterAPIKey, "updated-example")
        reloaded.openRouterAPIKey = ""
        XCTAssertEqual(fixture.makeStore().openRouterAPIKey, "")
        XCTAssertFalse(fixture.makeStore().hasOpenRouterAPIKey)

        let manager = FileManager.default
        let permissions = try manager.attributesOfItem(atPath: fixture.keys.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        let files = try manager.contentsOfDirectory(at: fixture.keys, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let attributes = try manager.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testFailedSaveIsReported() throws {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let settings = fixture.makeStore()
        // A file where the credentials directory should be makes saving fail.
        try Data().write(to: fixture.keys)
        settings.openAIAPIKey = "new-example"
        XCTAssertEqual(settings.credentialSaveError?.hasPrefix("Could not save OpenAI API key"), true)
        XCTAssertEqual(settings.openAIAPIKey, "")
    }

    /// Copy Tricks (AppSettings.openRouterKey) and dictation read and write one key.
    func testDictationAndCopyTricksShareTheOpenRouterKey() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let copyTricksKey = fixture.openRouter
        try? copyTricksKey.write("sk-or-shared")
        let settings = fixture.makeStore()
        XCTAssertEqual(settings.openRouterAPIKey, "sk-or-shared")
        settings.openRouterAPIKey = "sk-or-from-dictation"
        XCTAssertEqual(copyTricksKey.read(), "sk-or-from-dictation")
        XCTAssertEqual(settings.openAIAPIKey, "", "the OpenAI key is a separate entry")
    }

    /// SuperSamuel's key comes over the first time it's read, once: a key the user then
    /// clears isn't brought back, and SuperSamuel's own file is left alone.
    func testSuperSamuelKeyIsImportedOnceAndLeftInPlace() throws {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        let superSamuelKeys = fixture.keys.appendingPathComponent("SuperSamuel")
        let old = CredentialStore(service: SuperSamuelImport.bundleID, account: "openai-api-key", localDirectory: superSamuelKeys)
        try old.writeAPIKey("sk-from-supersamuel", useLocalStorage: true)
        let shared = SharedAPIKey(
            store: CredentialStore(service: fixture.suite, account: "openai-api-key", localDirectory: fixture.keys),
            superSamuel: old)
        let settings = SettingsStore(defaults: fixture.defaults, credentials: fixture.openRouter, openAICredentials: shared)

        XCTAssertEqual(settings.openAIAPIKey, "sk-from-supersamuel")
        XCTAssertEqual(settings.realtimeTranscriptionAvailability, .available)
        settings.openAIAPIKey = ""
        XCTAssertEqual(settings.openAIAPIKey, "")
        XCTAssertEqual(old.readAPIKey(useLocalStorage: true), "sk-from-supersamuel")
    }

    func testLegacyDefaultsKeyMovesToTheKeyFile() {
        let fixture = TestSettings()
        defer { fixture.tearDown() }
        fixture.defaults.set("  legacy-example  ", forKey: "dictation.openRouterAPIKey")
        let settings = fixture.makeStore()
        XCTAssertEqual(settings.openRouterAPIKey, "legacy-example")
        XCTAssertNil(fixture.defaults.object(forKey: "dictation.openRouterAPIKey"))
    }

    func testLocalFilesSeparateAccountsAndServices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CredentialStore(service: "one", account: "key", localDirectory: directory)
        let second = CredentialStore(service: "two", account: "key", localDirectory: directory)
        XCTAssertNil(try first.readLocalAPIKey())
        try first.writeAPIKey("first-example", useLocalStorage: true)
        try second.writeAPIKey("second-example", useLocalStorage: true)
        XCTAssertEqual(try first.readLocalAPIKey(), "first-example")
        XCTAssertEqual(try second.readLocalAPIKey(), "second-example")
    }
}
