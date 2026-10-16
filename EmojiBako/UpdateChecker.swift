// UpdateChecker.swift
// GitHub Releasesで新しいバージョンを確認し、利用者に知らせる（インストールは利用者が手動で行う）

import AppKit
import os

/// 「1.2.3」「v1.2.3」形式のバージョン
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = parts.map { $0! }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// GitHub Releases APIの応答のうち使うフィールド
struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: URL
}

enum UpdateCheckError: Error {
    case unexpectedStatus(Int)
    case invalidVersion(String)
}

final class UpdateChecker {
    static let autoCheckDefaultsKey = "autoCheckUpdates"
    private static let lastNotifiedVersionKey = "lastNotifiedUpdateVersion"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/tmstack-io/EmojiBako/releases/latest")!
    private static let interval: TimeInterval = 24 * 60 * 60

    private let logger = Logger(subsystem: "io.tmstack.EmojiBako", category: "UpdateChecker")
    private let defaults: UserDefaults
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.autoCheckDefaultsKey: true])
    }

    /// 起動時と24時間ごとに確認する。設定がオフのときは通信しない
    func start() {
        checkIfEnabled()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.checkIfEnabled()
        }
    }

    /// 通知すべき新しいバージョンかどうか（同じバージョンは一度だけ知らせる）
    static func shouldNotify(latest: AppVersion, current: AppVersion, lastNotified: AppVersion?) -> Bool {
        guard latest > current else { return false }
        guard let lastNotified else { return true }
        return latest > lastNotified
    }

    private func checkIfEnabled() {
        guard defaults.bool(forKey: Self.autoCheckDefaultsKey) else { return }
        Task { @MainActor in
            do {
                try await check()
            } catch {
                // 定期的に繰り返すバックグラウンドの確認なので、失敗はログに残して次回に任せる（オフライン時など）
                logger.error("更新の確認に失敗しました: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @MainActor
    private func check() async throws {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard status == 200 else { throw UpdateCheckError.unexpectedStatus(status) }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let latest = AppVersion(release.tag_name) else { throw UpdateCheckError.invalidVersion(release.tag_name) }
        let currentString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        guard let current = AppVersion(currentString) else { throw UpdateCheckError.invalidVersion(currentString) }
        let lastNotified = defaults.string(forKey: Self.lastNotifiedVersionKey).flatMap(AppVersion.init)

        guard Self.shouldNotify(latest: latest, current: current, lastNotified: lastNotified) else { return }
        defaults.set(latest.description, forKey: Self.lastNotifiedVersionKey)
        notify(latest: latest, current: current, page: release.html_url)
    }

    @MainActor
    private func notify(latest: AppVersion, current: AppVersion, page: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "EmojiBako \(latest.description)が公開されています")
        alert.informativeText = String(localized: "現在のバージョンは\(current.description)です。ダウンロードページから新しいDMGを入手し、アプリを置き換えてください。")
        alert.addButton(withTitle: String(localized: "ダウンロードページを開く"))
        alert.addButton(withTitle: String(localized: "あとで"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }
}
