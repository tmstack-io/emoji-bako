// UsageBackup.swift
// 使用回数のバックアップ（このMacで数えた使用回数を書き出したファイル）の形式と、読み込むときの確認

import Foundation
import os

/// 使用回数のバックアップ。ファイルはJSONで、次の形をとる。
///
/// ```json
/// {
///   "format": "io.tmstack.EmojiBako.usageBackup",
///   "formatVersion": 1,
///   "exportedAt": "2026-10-20T03:04:05Z",
///   "computerName": "MI-MBN",
///   "counts": { "😀": 3 }
/// }
/// ```
struct UsageBackup: Equatable {
    /// バックアップのファイルであることを示す値
    static let format = "io.tmstack.EmojiBako.usageBackup"
    /// このアプリが書き出し、読み込める形式のバージョン
    static let formatVersion = 1
    /// 読み込める回数の上限。足し合わせても整数があふれないようにする（あふれると、同期中のすべてのMacが合計の計算で止まる）
    static let maxCount = 1_000_000_000

    /// 書き出した日時
    let exportedAt: Date
    /// 書き出したMacのコンピュータ名
    let computerName: String
    /// このMacで数えた使用回数
    let counts: [String: Int]

    /// 読み込めなかった理由
    enum ReadError: Error, Equatable {
        /// 使用回数のバックアップではない
        case notBackup
        /// このアプリが知らない形式のバージョン
        case unsupportedFormatVersion(Int)
        /// 項目が欠けている、回数が整数でないなど
        case malformed
        /// 回数が0以下か、上限を超えている
        case countOutOfRange(emoji: String)

        /// 利用者に見せる説明
        var message: String {
            switch self {
            case .notBackup:
                return String(localized: "EmojiBakoの使用回数のバックアップではありません。")
            case .unsupportedFormatVersion:
                return String(localized: "このバージョンのEmojiBakoでは読み込めない形式です。新しいバージョンのEmojiBakoで書き出したバックアップかもしれません。")
            case .malformed:
                return String(localized: "バックアップの内容が壊れています。")
            case .countOutOfRange(let emoji):
                return String(localized: "バックアップに不正な使用回数があります（\(emoji)）。")
            }
        }
    }

    /// ファイルに書く内容
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(File(format: Self.format, formatVersion: Self.formatVersion, exportedAt: exportedAt, computerName: computerName, counts: counts))
        } catch {
            preconditionFailure("使用回数のバックアップをJSONにできません: \(error)")
        }
    }

    /// ファイルの内容を読み、確認する。確認に通らなければ ReadError を投げる。
    /// 回数は、整数として表せる値（`3`、`3.0`）だけを受け付ける
    static func decode(_ data: Data) throws(ReadError) -> UsageBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 形式の名前、バージョンの順に確かめ、別のファイルや新しい形式を「壊れている」と誤って伝えないようにする
        let header: FormatHeader
        do {
            header = try decoder.decode(FormatHeader.self, from: data)
        } catch {
            logger.notice("使用回数のバックアップではないファイルです: \(String(describing: error), privacy: .public)")
            throw .notBackup
        }
        guard header.format == format else { throw .notBackup }
        let version: Int
        do {
            version = try decoder.decode(VersionHeader.self, from: data).formatVersion
        } catch {
            logger.error("使用回数のバックアップの形式のバージョンを読めません: \(String(describing: error), privacy: .public)")
            throw .malformed
        }
        guard version == formatVersion else { throw .unsupportedFormatVersion(version) }
        let file: File
        do {
            file = try decoder.decode(File.self, from: data)
        } catch {
            logger.error("使用回数のバックアップの内容を読めません: \(String(describing: error), privacy: .public)")
            throw .malformed
        }
        // 絵文字の順に確かめ、同じファイルなら毎回同じ絵文字を伝える
        if let invalid = file.counts.filter({ !(1...maxCount).contains($0.value) }).keys.sorted().first {
            throw .countOutOfRange(emoji: invalid)
        }
        return UsageBackup(exportedAt: file.exportedAt, computerName: file.computerName, counts: file.counts)
    }

    /// 保存画面に最初に入れておくファイル名（`EmojiBako-usage-<コンピュータ名>-<yyyy-MM-dd>.json`）
    var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // ファイル名に使えない「/」と「:」をコンピュータ名から除く
        let name = computerName.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
        return "EmojiBako-usage-\(name)-\(formatter.string(from: exportedAt)).json"
    }

    private static let logger = Logger(subsystem: "io.tmstack.EmojiBako", category: "UsageBackup")

    private struct FormatHeader: Decodable {
        let format: String
    }

    private struct VersionHeader: Decodable {
        let formatVersion: Int
    }

    private struct File: Codable {
        let format: String
        let formatVersion: Int
        let exportedAt: Date
        let computerName: String
        let counts: [String: Int]
    }
}
