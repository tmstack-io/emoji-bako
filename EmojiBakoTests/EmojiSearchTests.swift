import XCTest
@testable import EmojiBako

@MainActor
final class EmojiSearchTests: XCTestCase {

    private func item(_ char: String, en: String = "", ja: String = "", keywords: [String] = [], readings: [String] = []) -> EmojiItem {
        EmojiItem(char: char, englishName: en, japaneseName: ja, japaneseKeywords: keywords, readings: readings)
    }

    // MARK: - 正規化

    func testNormalizeFoldsWidthCaseAndKana() {
        XCTAssertEqual(EmojiSearch.normalize("ﾈｺ"), "ねこ")
        XCTAssertEqual(EmojiSearch.normalize("ネコ"), "ねこ")
        XCTAssertEqual(EmojiSearch.normalize("ＣＡＴ"), "cat")
        XCTAssertEqual(EmojiSearch.normalize("Cat Face"), "cat face")
    }

    func testNormalizeKeepsProlongedSoundMark() {
        XCTAssertEqual(EmojiSearch.normalize("タワー"), "たわー")
        XCTAssertEqual(EmojiSearch.normalize("ﾋﾞｰﾙ"), "びーる")
    }

    // MARK: - 一致と並び順

    func testEmptyQueryReturnsAllInDataOrder() {
        let items = [item("A"), item("B"), item("C")]
        let result = EmojiSearch.search("  ", in: EmojiSearchIndex(items: items), usageCounts: [:])
        XCTAssertEqual(result.map(\.char), ["A", "B", "C"])
    }

    func testRanksExactNameThenPrefixThenSubstring() {
        // データ上はあえて逆順に並べ、並び順が一致の強さで決まることを確かめる
        let items = [
            item("substring", ja: "子猫", keywords: ["こねこ"]),
            item("prefix", ja: "猫じゃらし", keywords: ["ねこじゃらし"]),
            item("exact", ja: "ネコ"),
        ]
        let result = EmojiSearch.search("ねこ", in: EmojiSearchIndex(items: items), usageCounts: [:])
        XCTAssertEqual(result.map(\.char), ["exact", "prefix", "substring"])
    }

    func testEnglishWordPrefixRanksAboveSubstring() {
        let items = [
            item("substring", en: "bobcat"),
            item("prefix", en: "cat face"),
        ]
        let result = EmojiSearch.search("cat", in: EmojiSearchIndex(items: items), usageCounts: [:])
        XCTAssertEqual(result.map(\.char), ["prefix", "substring"])
    }

    func testSameRankOrderedByUsageThenDataOrder() {
        let items = [
            item("first", keywords: ["ねこA"]),
            item("second", keywords: ["ねこB"]),
            item("third", keywords: ["ねこC"]),
        ]
        let result = EmojiSearch.search("ねこ", in: EmojiSearchIndex(items: items), usageCounts: ["third": 5])
        XCTAssertEqual(result.map(\.char), ["third", "first", "second"])
    }

    func testAllTokensMustMatch() {
        let items = [
            item("both", keywords: ["ねこ", "かお"]),
            item("catOnly", keywords: ["ねこ"]),
            item("faceOnly", keywords: ["かお"]),
        ]
        let result = EmojiSearch.search("ねこ　かお", in: EmojiSearchIndex(items: items), usageCounts: [:])
        XCTAssertEqual(result.map(\.char), ["both"])
    }

    func testReadingsAreSearchable() {
        let items = [item("smile", ja: "にっこり笑う", keywords: ["笑顔"], readings: ["にっこりわらう", "えがお"])]
        let result = EmojiSearch.search("えが", in: EmojiSearchIndex(items: items), usageCounts: [:])
        XCTAssertEqual(result.map(\.char), ["smile"])
    }

    // MARK: - 同梱の絵文字データ

    func testBundledDataFindsCatInEveryScript() {
        let index = EmojiData.shared.searchIndex
        for query in ["ねこ", "ネコ", "ﾈｺ", "猫", "cat"] {
            let result = EmojiSearch.search(query, in: index, usageCounts: [:]).map(\.char)
            XCTAssertTrue(result.contains("🐈"), "「\(query)」で🐈が見つからない")
        }
    }

    func testBundledDataFindsByReading() {
        let result = EmojiSearch.search("えがお", in: EmojiData.shared.searchIndex, usageCounts: [:]).map(\.char)
        XCTAssertTrue(result.contains("😀"))
    }
}
