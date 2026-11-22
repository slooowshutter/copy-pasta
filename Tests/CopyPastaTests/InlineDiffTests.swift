import XCTest
@testable import CopyPasta

/// Where a typo fix's changes are in the fixed text (UTF-16, as Accessibility counts).
final class InlineDiffTests: XCTestCase {
    func testReplacedWord() {
        XCTAssertEqual(InlineDiff.changes(before: "une tabel pour", after: "une table pour"),
                       [.init(added: NSRange(location: 4, length: 5), removed: "tabel")])
    }

    func testDeletionMarksTheGap() {
        // "cccc and" went: the gap is where "displays" now starts.
        XCTAssertEqual(InlineDiff.changes(before: "and it cccc and displays a handle", after: "and it displays a handle"),
                       [.init(added: NSRange(location: 7, length: 0), removed: "cccc and")])
    }

    func testAddedWordsAndAccents() {
        // "é" is one UTF-16 unit; the added "a" sits after "réserver ".
        XCTAssertEqual(InlineDiff.changes(before: "réserver table", after: "réserver a table"),
                       [.init(added: NSRange(location: 9, length: 1), removed: "")])
        XCTAssertTrue(InlineDiff.changes(before: "same", after: "same").isEmpty)
    }

    func testLinesSplitAtBreaks() {
        XCTAssertEqual(InlineDiff.lines(of: NSRange(location: 0, length: 9), in: "abc\ndefgh"),
                       [NSRange(location: 0, length: 3), NSRange(location: 4, length: 5)])
    }
}
