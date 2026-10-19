// EmojiData.swift
// Loads emoji data from bundled JSON file

import Foundation
import Combine
import os

struct EmojiItem: Codable, Hashable, Identifiable {
    let char: String
    let englishName: String
    let japaneseName: String
    let japaneseKeywords: [String]
    /// 漢字を含む日本語の名前・キーワードの読み（ひらがな）
    let readings: [String]

    var id: String { char }

    /// アプリの表示言語に合わせた名前（日本語で表示しているときは日本語名、それ以外は英語名）
    var localizedName: String {
        Bundle.main.preferredLocalizations.first == "ja" ? japaneseName : englishName
    }
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

@MainActor
class EmojiData: ObservableObject {
    static let shared = EmojiData()

    /// よく使う絵文字のカテゴリのID
    static let frequentlyUsedCategoryID = "frequentlyUsed"

    /// 表示に使う使用回数（同期がオンなら同期中のMacの合計）
    @Published private(set) var usageCounts: [String: Int] = [:]

    let usageSync: UsageSync
    private let cloudConnection: ICloudUsageSyncConnection
    private let computerNameMonitor: ComputerNameMonitor
    private var totalsSubscription: AnyCancellable?
    /// 最後にログに記録した、絵文字データにない絵文字
    private var loggedUnknownEmojis: Set<String> = []

    let categories: [EmojiCategory]
    /// char(絵文字文字列)→EmojiItem のルックアップ。よく使う絵文字や検索で使用
    let lookup: [String: EmojiItem]
    /// 検索用の索引（よく使う絵文字のカテゴリは除外）
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

        // よく使う絵文字のカテゴリを先頭に追加（emojisは空：実行時にusageCountsから生成）
        let frequentlyUsed = EmojiCategory(id: Self.frequentlyUsedCategoryID, name: "Frequently Used", icon: "star.fill", emojis: [])
        self.categories = [frequentlyUsed] + loadedCategories

        // ルックアップ辞書と検索用の索引（よく使う絵文字のカテゴリは除外）
        let flattened = loadedCategories.flatMap { $0.emojis }
        self.lookup = Dictionary(uniqueKeysWithValues: flattened.map { ($0.char, $0) })
        self.searchIndex = EmojiSearchIndex(items: flattened)

        let usageSync = UsageSync(local: .standard, cloud: ICloudKeyValueStore(), computerName: ComputerNameMonitor.current(), hardwareID: MacHardware.platformUUID())
        self.usageSync = usageSync
        self.cloudConnection = ICloudUsageSyncConnection(sync: usageSync)
        self.computerNameMonitor = ComputerNameMonitor { usageSync.computerNameDidChange(to: $0) }

        totalsSubscription = usageSync.$totals.sink { [weak self] totals in
            self?.usageCounts = totals
            self?.logUnknownEmojis(in: totals)
        }
        cloudConnection.start()
        computerNameMonitor.start()
    }

    private let logger = Logger(subsystem: "io.tmstack.EmojiBako", category: "EmojiData")

    /// 新しい版で使った絵文字を古い版で読んだ場合などに起きる。保存データは残し、表示からは外す
    private func logUnknownEmojis(in counts: [String: Int]) {
        let unknown = Set(counts.keys.filter { lookup[$0] == nil })
        guard !unknown.isEmpty, unknown != loggedUnknownEmojis else { return }
        loggedUnknownEmojis = unknown
        logger.notice("絵文字データにない絵文字の使用回数があるため、よく使う絵文字には表示しません: \(unknown.sorted(), privacy: .public)")
    }

    func incrementUsage(for emoji: String) {
        usageSync.increment(emoji)
    }

    /// よく使う絵文字（使用回数の多い順に最大50件）を返す。
    /// 絵文字データにない絵文字（新しい版で使ったものなど）は、ログに残したうえで除外する。
    func frequentlyUsedEmojis() -> [EmojiItem] {
        return usageCounts
            .filter { lookup[$0.key] != nil }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key < rhs.key
            }
            .prefix(50)
            .map { lookup[$0.key]! }
    }
}
