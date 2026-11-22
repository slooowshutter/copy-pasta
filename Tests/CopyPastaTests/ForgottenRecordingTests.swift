import XCTest
@testable import CopyPasta

/// The failsafe that stops a recording nobody stopped (one ran for 9.5 hours, Nov 2026).
@MainActor
final class ForgottenRecordingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testKeepsRecordingWhileSpeechContinues() {
        XCTAssertNil(DictationController.forgottenRecordingReason(
            startedAt: start, lastSpeechAt: start.addingTimeInterval(500), now: start.addingTimeInterval(560)))
    }

    func testStopsAfterTwoMinutesWithoutSpeech() {
        XCTAssertNil(DictationController.forgottenRecordingReason(
            startedAt: start, lastSpeechAt: nil, now: start.addingTimeInterval(119)))
        XCTAssertNotNil(DictationController.forgottenRecordingReason(
            startedAt: start, lastSpeechAt: nil, now: start.addingTimeInterval(120)))
        XCTAssertNotNil(DictationController.forgottenRecordingReason(
            startedAt: start, lastSpeechAt: start.addingTimeInterval(60), now: start.addingTimeInterval(181)))
    }

    func testStopsAtThirtyMinutesEvenWhileTalking() {
        XCTAssertNotNil(DictationController.forgottenRecordingReason(
            startedAt: start, lastSpeechAt: start.addingTimeInterval(1799), now: start.addingTimeInterval(1800)))
    }
}
