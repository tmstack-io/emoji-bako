#!/usr/bin/env swift
// data/readings.jsonの読みを`claude -p`でチェックし、修正候補をdata/reading-overrides.jsonに書き込む。
//
// 使い方（リポジトリのルートで、generate-emoji-data.swiftの実行後に）:
//     swift scripts/check-readings.swift            # 修正表にまだないキーワードをすべてチェックする
//     swift scripts/check-readings.swift --limit 100 # 先頭の100語だけチェックする（お試し用）
//
// 書き込まれた修正候補は`git diff data/reading-overrides.json`で確認し、不要なものを消してから
// generate-emoji-data.swiftを再実行する。修正表にあるキーワードは確認済みとみなし、チェックしない。
// claudeコマンドの失敗や応答の形式違いが1回でもあれば、修正表を書き換えずに終了する。

import Foundation

let batchSize = 100

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let readingsURL = repoRoot.appendingPathComponent("data/readings.json")
let overridesURL = repoRoot.appendingPathComponent("data/reading-overrides.json")

struct CheckError: Error, CustomStringConvertible {
    let description: String
}

struct ReadingEntry: Codable {
    let keyword: String
    let reading: String
}

struct Correction: Codable {
    let keyword: String
    let current: String
    let suggested: String
    let reason: String
}

struct StructuredOutput: Codable {
    let corrections: [Correction]
}

/// `claude -p --output-format json`の出力のうち、判定に使うフィールド
struct ClaudeResult: Codable {
    let is_error: Bool
    let subtype: String
    let structured_output: StructuredOutput?
}

let jsonSchema = """
{"type":"object","properties":{"corrections":{"type":"array","items":{"type":"object","properties":{"keyword":{"type":"string"},"current":{"type":"string"},"suggested":{"type":"string"},"reason":{"type":"string"}},"required":["keyword","current","suggested","reason"]}}},"required":["corrections"]}
"""

let prompt = """
標準入力のJSON配列は、絵文字ピッカーの日本語キーワード（keyword）と、機械的に生成したその読み（reading、ひらがな）の組です。
利用者は読みをひらがなで入力して絵文字を検索します。次のどちらかに当てはまる読みだけを修正候補として返してください。
- 読みが誤っている（例: 顔→がん）
- 正しいが、検索するときに多くの人が入力する読みではない（例: 一般には別の読みで呼ばれる語）
修正後の読み（suggested）はひらがなで書き、keywordに含まれる英数字・記号・空白はそのまま残してください。
current には入力の reading をそのまま入れ、reason には修正の理由を日本語で短く書いてください。
問題のない読みは返さないでください。修正候補がなければ corrections を空配列にしてください。
"""

func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

/// 漢字（CJK統合漢字と「々」）を含むかどうか
func containsKanji(_ s: String) -> Bool {
    s.unicodeScalars.contains { ("\u{4E00}"..."\u{9FFF}").contains($0) || ("\u{3400}"..."\u{4DBF}").contains($0) || $0 == "々" }
}

/// 1バッチ分を`claude -p`に渡し、形式を検証した修正候補を返す
func checkBatch(_ batch: [ReadingEntry], workDir: URL) throws -> [Correction] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // ツール・MCP・設定ファイルを使わせず、入力したテキストだけで判断させる
    process.arguments = [
        "claude", "-p",
        "--output-format", "json",
        "--json-schema", jsonSchema,
        "--tools", "",
        "--strict-mcp-config",
        "--setting-sources", "",
        "--no-session-persistence",
        prompt,
    ]
    // リポジトリのCLAUDE.mdなどを読ませないため、空の作業ディレクトリで実行する
    process.currentDirectoryURL = workDir
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    stdin.fileHandleForWriting.write(try JSONEncoder().encode(batch))
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CheckError(description: "claudeが終了コード\(process.terminationStatus)で失敗しました: \(errorOutput)")
    }

    let result = try JSONDecoder().decode(ClaudeResult.self, from: output)
    guard !result.is_error, result.subtype == "success", let structured = result.structured_output else {
        throw CheckError(description: "claudeの応答が成功を示していません: \(String(decoding: output, as: UTF8.self))")
    }

    let currentByKeyword = Dictionary(uniqueKeysWithValues: batch.map { ($0.keyword, $0.reading) })
    for correction in structured.corrections {
        guard let current = currentByKeyword[correction.keyword] else {
            throw CheckError(description: "入力にないキーワードが返されました: \(correction.keyword)")
        }
        guard correction.current == current else {
            throw CheckError(description: "currentが入力の読みと一致しません: \(correction.keyword) \(correction.current) ≠ \(current)")
        }
        guard !correction.suggested.isEmpty, correction.suggested != current, !containsKanji(correction.suggested) else {
            throw CheckError(description: "修正案が不正です: \(correction.keyword) → \(correction.suggested)")
        }
    }
    return structured.corrections
}

do {
    var limit: Int?
    let args = CommandLine.arguments.dropFirst()
    if args.first == "--limit" {
        guard args.count == 2, let n = Int(args.last!), n > 0 else {
            throw CheckError(description: "使い方: swift scripts/check-readings.swift [--limit N]")
        }
        limit = n
    } else if !args.isEmpty {
        throw CheckError(description: "使い方: swift scripts/check-readings.swift [--limit N]")
    }

    let readings = try loadJSON([String: String].self, from: readingsURL)
    var overrides = try loadJSON([String: String].self, from: overridesURL)

    var targets = readings.keys.sorted()
        .filter { overrides[$0] == nil }
        .map { ReadingEntry(keyword: $0, reading: readings[$0]!) }
    if let limit { targets = Array(targets.prefix(limit)) }
    let batches = stride(from: 0, to: targets.count, by: batchSize).map { Array(targets[$0..<min($0 + batchSize, targets.count)]) }
    print("チェック対象: \(targets.count)語（\(batches.count)回に分けて実行）")

    let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("emojibako-check-readings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    var corrections: [Correction] = []
    for (index, batch) in batches.enumerated() {
        print("[\(index + 1)/\(batches.count)] \(batch.first!.keyword) 〜 \(batch.last!.keyword)")
        corrections += try checkBatch(batch, workDir: workDir)
    }

    for correction in corrections {
        overrides[correction.keyword] = correction.suggested
        print("  \(correction.keyword): \(correction.current) → \(correction.suggested)（\(correction.reason)）")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(overrides).write(to: overridesURL)
    print("\n✅ 修正候補\(corrections.count)件をdata/reading-overrides.jsonに書き込みました。git diffで確認してください。")
} catch {
    FileHandle.standardError.write("❌ \(error)\n".data(using: .utf8)!)
    exit(1)
}
