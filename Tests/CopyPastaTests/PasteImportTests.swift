import Compression
import XCTest
@testable import CopyPasta

/// Reading Paste's stored values: 0x01, then a property list, plain or LZFSE-compressed.
final class PasteImportTests: XCTestCase {
    private let items: [[String: Any]] = [["types": ["public.utf8-plain-text"],
                                           "dataByType": ["public.utf8-plain-text": Data("Bonjour".utf8)]]]

    func testPlainAndCompressedValues() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
        XCTAssertEqual(PasteImport.pasteboardItems(Data([1]) + plist)?.first?["public.utf8-plain-text"], Data("Bonjour".utf8))

        var packed = Data(count: plist.count + 1024)
        let n = packed.withUnsafeMutableBytes { dst in
            plist.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, plist.count + 1024,
                                          src.bindMemory(to: UInt8.self).baseAddress!, plist.count, nil, COMPRESSION_LZFSE)
            }
        }
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(PasteImport.pasteboardItems(Data([1]) + packed.prefix(n))?.first?["public.utf8-plain-text"], Data("Bonjour".utf8))
        XCTAssertNil(PasteImport.pasteboardItems(Data([1, 9, 9, 9])))
    }
}
