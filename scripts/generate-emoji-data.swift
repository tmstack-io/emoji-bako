#!/usr/bin/env swift
// Unicodeのemoji-test.txtとCLDRの日本語アノテーションから`EmojiBako/emoji-data.json`を生成する。
//
// 使い方（リポジトリのルートで実行）:
//     swift scripts/generate-emoji-data.swift
//
// 絵文字のバージョンを上げるときは`EMOJI_VERSION`と、そのバージョンの日本語データを全件含む`CLDR_VERSION`を更新する。
// 読みの誤りは`data/reading-overrides.json`（キーワード→読み）で上書きする。
// 途中で1件でも不整合があれば、JSONを書き出さずにエラーで終了する。

import Foundation

let EMOJI_VERSION = "15.1"
let CLDR_VERSION = "45"

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputURL = repoRoot.appendingPathComponent("EmojiBako/emoji-data.json")
let overridesURL = repoRoot.appendingPathComponent("data/reading-overrides.json")

struct GenerationError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - 出力形式（`EmojiBako/EmojiData.swift`と同じ構造）

struct EmojiItem: Encodable {
    let char: String
    let englishName: String
    let japaneseName: String
    let japaneseKeywords: [String]
    let readings: [String]
}

struct EmojiCategory: Encodable {
    let id: String
    let name: String
    let icon: String
    var emojis: [EmojiItem]
}

struct EmojiDataFile: Encodable {
    let emojiVersion: String
    let cldrVersion: String
    let categories: [EmojiCategory]
}

// MARK: - 取得

func download(_ urlString: String) throws -> String {
    print("Downloading \(urlString)")
    let data = try Data(contentsOf: URL(string: urlString)!)
    guard let text = String(data: data, encoding: .utf8) else {
        throw GenerationError(description: "UTF-8として読めません: \(urlString)")
    }
    return text
}

// MARK: - CLDRの日本語アノテーション

struct JapaneseAnnotation {
    var name: String?
    var keywords: [String]?
}

/// `annotations/ja.xml`と`annotationsDerived/ja.xml`を読み、cp（絵文字）ごとの名前（type="tts"）とキーワードを返す
func parseAnnotations(_ xmlTexts: [String]) throws -> [String: JapaneseAnnotation] {
    var result: [String: JapaneseAnnotation] = [:]
    for xml in xmlTexts {
        let doc = try XMLDocument(xmlString: xml)
        for node in try doc.nodes(forXPath: "//annotations/annotation") {
            guard let element = node as? XMLElement,
                  let cp = element.attribute(forName: "cp")?.stringValue,
                  let text = element.stringValue else {
                throw GenerationError(description: "annotation要素の形式が不正です: \(node)")
            }
            if text.contains("↑↑↑") {
                throw GenerationError(description: "継承マーカーを含むアノテーションがあります: \(cp)")
            }
            if element.attribute(forName: "type")?.stringValue == "tts" {
                result[cp, default: JapaneseAnnotation()].name = text
            } else {
                result[cp, default: JapaneseAnnotation()].keywords = text
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
    }
    return result
}

// MARK: - 読み

/// 漢字（CJK統合漢字と「々」）を含むかどうか
func containsKanji(_ s: String) -> Bool {
    s.unicodeScalars.contains { ("\u{4E00}"..."\u{9FFF}").contains($0) || ("\u{3400}"..."\u{4DBF}").contains($0) || $0 == "々" }
}

/// ひらがな・カタカナ・長音記号だけでできているかどうか
func isKanaOnly(_ s: String) -> Bool {
    s.unicodeScalars.allSatisfy { ("\u{3041}"..."\u{3096}").contains($0) || ("\u{30A1}"..."\u{30FA}").contains($0) || $0 == "ー" }
}

/// 漢字を含む文字列の読みをひらがなで返す。
/// 漢字を含むトークンはCFStringTokenizerのローマ字読みをひらがなに変換する。
/// かなだけのトークンは長音記号を保つためローマ字を経由せず直接ひらがなにし、それ以外（記号・英数字）はそのまま残す。
func generateReading(_ text: String) throws -> String {
    let cf = text as CFString
    let tokenizer = CFStringTokenizerCreate(
        nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)),
        kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale
    )
    let ns = text as NSString
    var reading = ""
    var cursor = 0
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
        let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        // トークンの間にある空白や記号はそのまま残す
        reading += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
        let token = ns.substring(with: NSRange(location: range.location, length: range.length))
        if containsKanji(token) {
            guard let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String else {
                throw GenerationError(description: "読みを取得できません: \(token)（\(text)）")
            }
            guard let hiragana = latin.applyingTransform(.latinToHiragana, reverse: false) else {
                throw GenerationError(description: "ひらがなに変換できません: \(latin)（\(text)）")
            }
            reading += hiragana
        } else if isKanaOnly(token) {
            guard let hiragana = token.applyingTransform(.hiraganaToKatakana, reverse: true) else {
                throw GenerationError(description: "ひらがなに変換できません: \(token)（\(text)）")
            }
            reading += hiragana
        } else {
            reading += token
        }
        cursor = range.location + range.length
    }
    reading += ns.substring(from: cursor)
    if containsKanji(reading) {
        throw GenerationError(description: "読みに漢字が残っています: \(reading)（\(text)）")
    }
    return reading
}

// MARK: - emoji-test.txt

/// emoji-test.txtのグループ名 → (カテゴリID, 表示名, カテゴリアイコン)。nilのグループは収録しない
let groupMapping: [String: (id: String, name: String, icon: String)?] = [
    "Smileys & Emotion": ("smileys", "Smileys", "face.smiling"),
    "People & Body": ("people", "People", "person"),
    "Animals & Nature": ("animals", "Animals & Nature", "hare"),
    "Food & Drink": ("food", "Food & Drink", "fork.knife"),
    "Travel & Places": ("travel", "Travel", "car"),
    "Activities": ("activities", "Activities", "sportscourt"),
    "Objects": ("objects", "Objects", "desktopcomputer"),
    "Symbols": ("symbols", "Symbols", "heart"),
    "Flags": ("flags", "Flags", "flag"),
    "Component": nil,
]

let skinToneModifiers: Set<String> = ["1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"]

// 行の例: `1F600 ; fully-qualified     # 😀 E1.0 grinning face`
let emojiLineRegex = try NSRegularExpression(pattern: #"^([0-9A-F ]+?)\s*; fully-qualified\s*# (\S+) E\d+\.\d+ (.+)$"#)

/// キーワード→読みの修正表
func loadOverrides() throws -> [String: String] {
    let data = try Data(contentsOf: overridesURL)
    return try JSONDecoder().decode([String: String].self, from: data)
}

func buildCategories(emojiTest: String, annotations: [String: JapaneseAnnotation], overrides: [String: String]) throws -> [EmojiCategory] {
    var categories: [EmojiCategory] = []
    var currentCategoryIndex: Int?
    var usedOverrides = Set<String>()

    func reading(for keyword: String) throws -> String {
        if let overridden = overrides[keyword] {
            usedOverrides.insert(keyword)
            return overridden
        }
        return try generateReading(keyword)
    }

    for line in emojiTest.components(separatedBy: "\n") {
        if line.hasPrefix("# group:") {
            let group = line.dropFirst("# group:".count).trimmingCharacters(in: .whitespaces)
            guard let mapping = groupMapping[group] else {
                throw GenerationError(description: "未知のグループです: \(group)")
            }
            if let mapping {
                categories.append(EmojiCategory(id: mapping.id, name: mapping.name, icon: mapping.icon, emojis: []))
                currentCategoryIndex = categories.count - 1
            } else {
                currentCategoryIndex = nil
            }
            continue
        }
        guard line.contains("; fully-qualified"), let categoryIndex = currentCategoryIndex else { continue }

        let ns = line as NSString
        guard let match = emojiLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            throw GenerationError(description: "解析できない行です: \(line)")
        }
        let codepoints = ns.substring(with: match.range(at: 1)).split(separator: " ").map(String.init)
        if codepoints.contains(where: skinToneModifiers.contains) { continue }
        let char = ns.substring(with: match.range(at: 2))
        let englishName = ns.substring(with: match.range(at: 3))

        // CLDRのcpは異体字セレクタ（U+FE0F）を省いた形で書かれていることがある
        let annotation = annotations[char] ?? annotations[String(String.UnicodeScalarView(char.unicodeScalars.filter { $0 != "\u{FE0F}" }))]
        guard let japaneseName = annotation?.name, let japaneseKeywords = annotation?.keywords else {
            throw GenerationError(description: "日本語の名前またはキーワードがありません: \(char) \(englishName)")
        }

        var readings: [String] = []
        for keyword in [japaneseName] + japaneseKeywords where containsKanji(keyword) {
            let r = try reading(for: keyword)
            if !readings.contains(r) { readings.append(r) }
        }

        categories[categoryIndex].emojis.append(EmojiItem(
            char: char,
            englishName: englishName,
            japaneseName: japaneseName,
            japaneseKeywords: japaneseKeywords,
            readings: readings
        ))
    }

    // どの絵文字にも使われない修正は、キーワードの綴り違いか古い修正の取り残しなので止める
    let unusedOverrides = Set(overrides.keys).subtracting(usedOverrides)
    if !unusedOverrides.isEmpty {
        throw GenerationError(description: "使われていない読みの修正があります: \(unusedOverrides.sorted())")
    }
    return categories
}

// MARK: - main

do {
    let emojiTest = try download("https://unicode.org/Public/emoji/\(EMOJI_VERSION)/emoji-test.txt")
    let annotationXMLs = try ["annotations", "annotationsDerived"].map {
        try download("https://raw.githubusercontent.com/unicode-org/cldr/release-\(CLDR_VERSION)/common/\($0)/ja.xml")
    }
    let annotations = try parseAnnotations(annotationXMLs)
    let overrides = try loadOverrides()

    print("Building emoji data...")
    let categories = try buildCategories(emojiTest: emojiTest, annotations: annotations, overrides: overrides)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let output = EmojiDataFile(emojiVersion: EMOJI_VERSION, cldrVersion: CLDR_VERSION, categories: categories)
    try encoder.encode(output).write(to: outputURL)

    let all = categories.flatMap(\.emojis)
    print("\n✅ Generated \(outputURL.path)")
    print("   Unicode Emoji \(EMOJI_VERSION) / CLDR \(CLDR_VERSION)")
    print("   Total emojis: \(all.count)")
    print("   With readings: \(all.filter { !$0.readings.isEmpty }.count)")
    print("   Reading overrides: \(overrides.count)")
    for category in categories {
        print("   - \(category.name): \(category.emojis.count)")
    }
} catch {
    FileHandle.standardError.write("❌ \(error)\n".data(using: .utf8)!)
    exit(1)
}
