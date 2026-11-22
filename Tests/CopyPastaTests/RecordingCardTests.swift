import XCTest
@testable import CopyPasta

/// What a Recordings-tab card offers (its button, and ⏎) for each way a recording can fail.
final class RecordingCardTests: XCTestCase {
    private func card(_ status: RecordingCard.Status, audio: Int64 = 1000, text: String? = nil, keyMissing: Bool = false) -> RecordingCard {
        RecordingCard(createdAt: Date(), status: status, duration: 5, text: text, audioBytes: audio, keyMissing: keyMissing)
    }

    func testPrimaryAction() {
        XCTAssertEqual(card(.failed).primary?.action, .retry)
        XCTAssertEqual(card(.failed, keyMissing: true).primary?.action, .addKey)
        XCTAssertEqual(card(.failed, audio: 0, text: "half a sentence").primary?.action, .copyDraft)
        XCTAssertNil(card(.failed, audio: 0).primary)
        XCTAssertEqual(card(.notSent).primary?.action, .send)
        XCTAssertNil(card(.transcribed, text: "done").primary)
        XCTAssertNil(card(.transcribing).primary)
    }
}
