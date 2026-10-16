// EmojiData.swift
// Loads emoji data from bundled JSON file

import Foundation

struct EmojiItem: Codable, Hashable, Identifiable {
    let char: String
    let englishName: String
    let japaneseName: String
    let japaneseKeywords: [String]
    /// 漢字を含む日本語の名前・キーワードの読み（ひらがな）
    let readings: [String]

    var id: String { char }
}

struct EmojiCategory: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let icon: String
    let emojis: [EmojiItem]
}

struct EmojiDataFile: Codable {
    let emojiVersion: String
    let cldrVersion: String
    let categories: [EmojiCategory]
}

class EmojiData: ObservableObject {
    static let shared = EmojiData()

    @Published var usageCounts: [String: Int] = [:]

    private let userDefaultsKey = "emojiUsageCounts"

    let categories: [EmojiCategory]
    /// char(絵文字文字列)→EmojiItem のルックアップ。Favorites復元や検索で使用
    let lookup: [String: EmojiItem]
    /// 検索用の索引（Favoritesは除外）
    let searchIndex: EmojiSearchIndex

    init() {
        // JSONファイルから絵文字データを読み込む。バンドルに同梱したデータが読めないのはビルドの誤りなので停止する
        guard let url = Bundle.main.url(forResource: "emoji-data", withExtension: "json") else {
            fatalError("emoji-data.jsonがバンドルにありません")
        }
        let loadedCategories: [EmojiCategory]
        do {
            let data = try Data(contentsOf: url)
            loadedCategories = try JSONDecoder().decode(EmojiDataFile.self, from: data).categories
        } catch {
            fatalError("emoji-data.jsonを読み込めません: \(error)")
        }

        // Favoritesカテゴリを先頭に追加（emojisは空：実行時にusageCountsから生成）
        let favorites = EmojiCategory(id: "favorites", name: "Favorites", icon: "star.fill", emojis: [])
        self.categories = [favorites] + loadedCategories

        // ルックアップ辞書と検索用の索引（Favoritesは除外）
        let flattened = loadedCategories.flatMap { $0.emojis }
        self.lookup = Dictionary(uniqueKeysWithValues: flattened.map { ($0.char, $0) })
        self.searchIndex = EmojiSearchIndex(items: flattened)

        loadUsageCounts()
    }

    func loadUsageCounts() {
        if let data = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Int] {
            usageCounts = data
        }
    }

    func saveUsageCounts() {
        UserDefaults.standard.set(usageCounts, forKey: userDefaultsKey)
    }

    func incrementUsage(for emoji: String) {
        usageCounts[emoji, default: 0] += 1
        saveUsageCounts()
    }

    /// お気に入り（使用頻度上位）を EmojiItem として返す。
    /// usageCountsにはピッカーで選んだ絵文字しか記録されないため、データにない絵文字があれば不整合として停止する。
    func getFavorites() -> [EmojiItem] {
        return usageCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key < rhs.key
            }
            .prefix(50)
            .map { entry in
                guard let item = lookup[entry.key] else {
                    fatalError("使用回数に絵文字データにない絵文字があります: \(entry.key)")
                }
                return item
            }
    }
}
