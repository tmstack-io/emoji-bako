import XCTest
@testable import EmojiBako

final class UsageBackupTests: XCTestCase {
    /// ISO 8601は秒までしか残らないので、秒ちょうどの日時を使う
    private let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// 形式の名前とバージョンを正しく入れた、バックアップのJSON
    private func json(format: String = UsageBackup.format, formatVersion: Int = UsageBackup.formatVersion, counts: String) -> Data {
        Data("""
        {"format": "\(format)", "formatVersion": \(formatVersion), "exportedAt": "2027-01-15T08:00:00Z", "computerName": "MacA", "counts": \(counts)}
        """.utf8)
    }

    private func assertReadError(_ data: Data, _ expected: UsageBackup.ReadError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try UsageBackup.decode(data), file: file, line: line) { error in
            XCTAssertEqual(error as? UsageBackup.ReadError, expected, file: file, line: line)
        }
    }

    func testRoundTrip() throws {
        let backup = UsageBackup(exportedAt: exportedAt, computerName: "MI-MBN", counts: ["😀": 3, "👨‍👩‍👧": 1])

        XCTAssertEqual(try UsageBackup.decode(backup.encoded()), backup)
    }

    func testEncodedFileNamesFormatAndVersion() throws {
        let data = UsageBackup(exportedAt: exportedAt, computerName: "MacA", counts: ["😀": 1]).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["format"] as? String, "io.tmstack.EmojiBako.usageBackup")
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertEqual(object["exportedAt"] as? String, "2027-01-15T08:00:00Z")
    }

    func testEmptyCountsCanBeRead() throws {
        XCTAssertEqual(try UsageBackup.decode(json(counts: "{}")).counts, [:])
    }

    func testRejectsFilesThatAreNotBackups() {
        assertReadError(Data("not json".utf8), .notBackup)
        assertReadError(Data(#"{"counts": {"😀": 1}}"#.utf8), .notBackup)
        assertReadError(json(format: "something.else", counts: #"{"😀": 1}"#), .notBackup)
    }

    func testRejectsUnknownFormatVersion() {
        assertReadError(json(formatVersion: 2, counts: #"{"😀": 1}"#), .unsupportedFormatVersion(2))
    }

    func testMissingOrMalformedFieldsOfBackupAreReportedAsMalformed() {
        let format = UsageBackup.format
        assertReadError(Data(#"{"format": "\#(format)", "exportedAt": "2027-01-15T08:00:00Z", "computerName": "MacA", "counts": {}}"#.utf8), .malformed)
        assertReadError(Data(#"{"format": "\#(format)", "formatVersion": "1", "exportedAt": "2027-01-15T08:00:00Z", "computerName": "MacA", "counts": {}}"#.utf8), .malformed)
        assertReadError(Data(#"{"format": "\#(format)", "formatVersion": 1, "exportedAt": "2027-01-15T08:00:00Z", "counts": {}}"#.utf8), .malformed)
        assertReadError(Data(#"{"format": "\#(format)", "formatVersion": 1, "exportedAt": "yesterday", "computerName": "MacA", "counts": {}}"#.utf8), .malformed)
        assertReadError(Data(#"{"format": "\#(format)", "formatVersion": 1, "exportedAt": "2027-01-15T08:00:00Z", "computerName": "MacA"}"#.utf8), .malformed)
    }

    func testRejectsMalformedCounts() {
        assertReadError(json(counts: #"{"😀": 1.5}"#), .malformed)
        assertReadError(json(counts: #"{"😀": "3"}"#), .malformed)
        assertReadError(json(counts: #"{"😀": true}"#), .malformed)
        assertReadError(json(counts: "[1]"), .malformed)
    }

    func testAcceptsWholeNumbersWrittenAsDecimals() throws {
        XCTAssertEqual(try UsageBackup.decode(json(counts: #"{"😀": 3.0}"#)).counts, ["😀": 3])
    }

    func testRejectsCountsOutOfRange() {
        assertReadError(json(counts: #"{"😀": 1, "🎉": 0}"#), .countOutOfRange(emoji: "🎉"))
        assertReadError(json(counts: #"{"😀": -1}"#), .countOutOfRange(emoji: "😀"))
        assertReadError(json(counts: #"{"😀": 1000000001}"#), .countOutOfRange(emoji: "😀"))
        assertReadError(json(counts: #"{"😀": 9223372036854775807}"#), .countOutOfRange(emoji: "😀"))
    }

    func testAcceptsMaximumCount() throws {
        XCTAssertEqual(try UsageBackup.decode(json(counts: #"{"😀": 1000000000}"#)).counts, ["😀": UsageBackup.maxCount])
    }

    func testSuggestedFileNameUsesComputerNameAndLocalDate() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9)))
        let backup = UsageBackup(exportedAt: date, computerName: "Tom's Mac/Studio:2", counts: [:])

        XCTAssertEqual(backup.suggestedFileName, "EmojiBako-usage-Tom's Mac-Studio-2-2026-10-20.json")
    }
}
