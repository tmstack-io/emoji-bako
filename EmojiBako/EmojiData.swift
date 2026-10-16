// EmojiData.swift
// Loads emoji data from bundled JSON file

import Foundation

struct EmojiItem: Codable, Hashable, Identifiable {
    let char: String
    let name: String

    var id: String { char }
}

struct EmojiCategory: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let icon: String
    let emojis: [EmojiItem]
}

struct EmojiDataFile: Codable {
    let version: String
    let categories: [EmojiCategory]
}

class EmojiData: ObservableObject {
    static let shared = EmojiData()

    @Published var usageCounts: [String: Int] = [:]

    private let userDefaultsKey = "emojiUsageCounts"

    let categories: [EmojiCategory]
    /// 検索用：Favoritesカテゴリを除く全絵文字をフラットに保持
    let allEmojis: [EmojiItem]
    /// char(絵文字文字列)→EmojiItem のルックアップ。Favorites復元や検索で使用
    let lookup: [String: EmojiItem]

    init() {
        // JSONファイルから絵文字データを読み込み
        var loadedCategories: [EmojiCategory] = []

        if let url = Bundle.main.url(forResource: "emoji-data", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(EmojiDataFile.self, from: data)
                loadedCategories = decoded.categories
                let total = loadedCategories.reduce(0) { $0 + $1.emojis.count }
                print("Loaded emoji data v\(decoded.version): \(total) emojis")
            } catch {
                print("Failed to load emoji data: \(error)")
            }
        } else {
            print("emoji-data.json not found in bundle")
        }

        // Favoritesカテゴリを先頭に追加（emojisは空：実行時にusageCountsから生成）
        let favorites = EmojiCategory(id: "favorites", name: "Favorites", icon: "star.fill", emojis: [])
        self.categories = [favorites] + loadedCategories

        // 検索用フラットリストとルックアップ辞書（Favoritesは除外）
        let flattened = loadedCategories.flatMap { $0.emojis }
        self.allEmojis = flattened
        self.lookup = Dictionary(uniqueKeysWithValues: flattened.map { ($0.char, $0) })

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
    /// usageCounts に未知の絵文字（旧データなど）があっても name="" でフォールバックする。
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
                lookup[entry.key] ?? EmojiItem(char: entry.key, name: "")
            }
    }
}
