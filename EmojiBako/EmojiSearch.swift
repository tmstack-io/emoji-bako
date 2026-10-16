// EmojiSearch.swift
// 日本語キーワード・読み・英語名による絵文字検索

import Foundation

/// 検索用に正規化した文字列を絵文字ごとに保持する索引。起動時に一度だけ作る
struct EmojiSearchIndex {
    struct Entry {
        let item: EmojiItem
        /// 絵文字データ上の並び順（同順位のときの並べ替えに使う）
        let order: Int
        /// 完全一致の判定に使う名前（日本語名・英語名）
        let names: [String]
        /// 前方一致の判定に使う語（日本語キーワード・読み・英語名とその各単語）
        let words: [String]
    }

    let entries: [Entry]

    init(items: [EmojiItem]) {
        entries = items.enumerated().map { order, item in
            let englishName = EmojiSearch.normalize(item.englishName)
            let englishWords = englishName.split(separator: " ").map(String.init)
            return Entry(
                item: item,
                order: order,
                names: [EmojiSearch.normalize(item.japaneseName), englishName],
                words: ([item.japaneseName] + item.japaneseKeywords + item.readings).map(EmojiSearch.normalize) + [englishName] + englishWords
            )
        }
    }
}

enum EmojiSearch {
    /// 一致の強さ。値が小さいほど上位に並べる
    enum Rank: Int, Comparable {
        /// 入力全体が名前（日本語名・英語名）と一致する
        case exactName = 0
        /// 入力のすべての語が、いずれかの語の先頭と一致する
        case prefix = 1
        /// 入力のすべての語が、いずれかの語に含まれる
        case substring = 2

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 全角と半角（NFKC）、英字の大文字と小文字、カタカナとひらがなの違いをなくす。
    /// 長音記号「ー」はそのまま残す
    static func normalize(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in s.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            // ァ（U+30A1）〜ヶ（U+30F6）は、0x60を引くと対応するひらがなになる
            if ("\u{30A1}"..."\u{30F6}").contains(scalar), let hiragana = Unicode.Scalar(scalar.value - 0x60) {
                scalars.append(hiragana)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// 空白で区切った入力のすべての語に一致する絵文字を、一致の強さ→使用回数→データの並び順で返す。
    /// 入力が空なら全件をデータの並び順で返す
    static func search(_ query: String, in index: EmojiSearchIndex, usageCounts: [String: Int]) -> [EmojiItem] {
        let normalizedQuery = normalize(query).trimmingCharacters(in: .whitespaces)
        guard !normalizedQuery.isEmpty else { return index.entries.map(\.item) }
        let tokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)

        let matches: [(entry: EmojiSearchIndex.Entry, rank: Rank)] = index.entries.compactMap { entry in
            guard let rank = rank(of: entry, query: normalizedQuery, tokens: tokens) else { return nil }
            return (entry, rank)
        }
        return matches
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                let lhsCount = usageCounts[lhs.entry.item.char, default: 0]
                let rhsCount = usageCounts[rhs.entry.item.char, default: 0]
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs.entry.order < rhs.entry.order
            }
            .map(\.entry.item)
    }

    private static func rank(of entry: EmojiSearchIndex.Entry, query: String, tokens: [String]) -> Rank? {
        if entry.names.contains(query) { return .exactName }
        if tokens.allSatisfy({ token in entry.words.contains { $0.hasPrefix(token) } }) { return .prefix }
        let targets = entry.names + entry.words
        if tokens.allSatisfy({ token in targets.contains { $0.contains(token) } }) { return .substring }
        return nil
    }
}
