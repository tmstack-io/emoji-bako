import XCTest
@testable import EmojiBako

final class EmojiPasterTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        // 利用者のクリップボードと設定を汚さないよう、テスト専用のものを使う
        pasteboard = NSPasteboard(name: NSPasteboard.Name("EmojiBakoTests-\(UUID().uuidString)"))
        suiteName = "EmojiBakoTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(0.05, forKey: EmojiPaster.restoreDelayDefaultsKey)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func waitForRestore() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    func testRestoresOriginalAfterPaste() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var pasted: [String?] = []
        let paster = EmojiPaster(pasteboard: pasteboard, defaults: defaults) { [pasteboard] in pasted.append(pasteboard!.string(forType: .string)) }

        paster.paste("😀")
        waitForRestore()

        XCTAssertEqual(pasted, ["😀"])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    /// 書き戻しを待っているあいだに次の絵文字を選んでも、最後に戻るのは最初の元の内容
    func testRapidSecondPasteKeepsOriginal() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var pasted: [String?] = []
        let paster = EmojiPaster(pasteboard: pasteboard, defaults: defaults) { [pasteboard] in pasted.append(pasteboard!.string(forType: .string)) }

        paster.paste("😀")
        paster.paste("👍")
        waitForRestore()

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testKeepsNewCopyMadeWhileWaiting() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let paster = EmojiPaster(pasteboard: pasteboard, defaults: defaults) {}

        paster.paste("😀")
        pasteboard.clearContents()
        pasteboard.setString("copied by user", forType: .string)
        waitForRestore()

        XCTAssertEqual(pasteboard.string(forType: .string), "copied by user")
    }

    /// 待つあいだに利用者がコピーしてから続けて2回選んでも、利用者のコピーが最後に戻る
    func testUserCopyBetweenPastesSurvivesLaterPastes() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let paster = EmojiPaster(pasteboard: pasteboard, defaults: defaults) {}

        paster.paste("😀")  // 書き戻しは約0.15秒後
        pasteboard.clearContents()
        pasteboard.setString("copied by user", forType: .string)
        defaults.set(0.5, forKey: EmojiPaster.restoreDelayDefaultsKey)
        paster.paste("👍")  // 書き戻しは約0.6秒後
        // 1回目の書き戻しが発火したあと、2回目の書き戻しより前に3回目を選ぶ
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        paster.paste("🎉")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        XCTAssertEqual(pasteboard.string(forType: .string), "copied by user")
    }

    func testRestoredContentIsMarkedTransient() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let paster = EmojiPaster(pasteboard: pasteboard, defaults: defaults) {}

        paster.paste("😀")
        waitForRestore()

        XCTAssertTrue(pasteboard.types?.contains(PasteboardSnapshot.transientType) ?? false)
    }

    func testDefaultRestoreDelayIsOneSecond() throws {
        let name = "EmojiBakoTests-\(UUID().uuidString)"
        let fresh = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { fresh.removePersistentDomain(forName: name) }
        _ = EmojiPaster(pasteboard: pasteboard, defaults: fresh) {}
        XCTAssertEqual(fresh.double(forKey: EmojiPaster.restoreDelayDefaultsKey), 1.0)
    }
}
