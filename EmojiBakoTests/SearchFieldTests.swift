import XCTest
import SwiftUI
@testable import EmojiBako

final class SearchFieldTests: XCTestCase {

    /// IMEが変換中の文字列を置いたときと同じ状態を、フィールドエディタのsetMarkedTextで再現する
    @MainActor
    func testReportsMarkedTextWhileComposing() throws {
        var reported = ""
        let binding = Binding(get: { reported }, set: { reported = $0 })
        let coordinator = SearchField(text: binding, placeholder: "").makeCoordinator()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        let field = SearchTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.coordinator = coordinator
        window.contentView!.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        XCTAssertFalse(SearchField.isComposing(in: window))
        editor.setMarkedText("ねこ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(reported, "ねこ")
        XCTAssertTrue(SearchField.isComposing(in: window))

        // 確定後の通常の入力も通知される
        editor.unmarkText()
        XCTAssertFalse(SearchField.isComposing(in: window))
        editor.insertText("と", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(reported, "ねこと")
    }
}
