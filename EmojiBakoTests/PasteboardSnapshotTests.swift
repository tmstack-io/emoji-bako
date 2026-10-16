import XCTest
@testable import EmojiBako

final class PasteboardSnapshotTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        // 利用者のクリップボードを汚さないよう、テスト専用の名前付きクリップボードを使う
        pasteboard = NSPasteboard(name: NSPasteboard.Name("EmojiBakoTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testRestoresAllItemsAndTypes() {
        let rtf = Data("{\\rtf1 hello}".utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let first = NSPasteboardItem()
        first.setString("hello", forType: .string)
        first.setData(rtf, forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(png, forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])

        let snapshot = PasteboardSnapshot(of: pasteboard)
        _ = PasteboardSnapshot.writeTransient("😀", to: pasteboard)
        snapshot.restore(to: pasteboard)

        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "hello")
        XCTAssertEqual(items[0].data(forType: .rtf), rtf)
        XCTAssertEqual(items[1].data(forType: .png), png)
    }

    func testRestoresEmptyPasteboard() {
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot(of: pasteboard)
        _ = PasteboardSnapshot.writeTransient("😀", to: pasteboard)
        snapshot.restore(to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testTransientWriteIsMarkedForClipboardManagers() {
        let changeCount = PasteboardSnapshot.writeTransient("😀", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "😀")
        XCTAssertTrue(pasteboard.types?.contains(PasteboardSnapshot.transientType) ?? false)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
    }
}
