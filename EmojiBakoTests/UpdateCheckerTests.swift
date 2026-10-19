import XCTest
@testable import EmojiBako

final class UpdateCheckerTests: XCTestCase {

    private func v(_ s: String) -> AppVersion { AppVersion(s)! }

    func testParsesTagWithAndWithoutPrefix() {
        XCTAssertEqual(AppVersion("v1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(AppVersion("10.0.1")?.components, [10, 0, 1])
    }

    func testRejectsMalformedVersions() {
        for s in ["1.2", "1.2.3.4", "v1.x.3", "", "1..3", "1.2.3-beta"] {
            XCTAssertNil(AppVersion(s), s)
        }
    }

    func testComparesNumericallyNotLexically() {
        XCTAssertLessThan(v("1.9.0"), v("1.10.0"))
        XCTAssertLessThan(v("1.0.9"), v("1.1.0"))
        XCTAssertEqual(v("v2.0.0"), v("2.0.0"))
    }

    func testNotifiesOnlyNewerVersionOnce() {
        XCTAssertTrue(UpdateChecker.shouldNotify(latest: v("1.1.0"), current: v("1.0.0"), lastNotified: nil))
        XCTAssertFalse(UpdateChecker.shouldNotify(latest: v("1.0.0"), current: v("1.0.0"), lastNotified: nil))
        XCTAssertFalse(UpdateChecker.shouldNotify(latest: v("1.1.0"), current: v("1.0.0"), lastNotified: v("1.1.0")))
        XCTAssertTrue(UpdateChecker.shouldNotify(latest: v("1.2.0"), current: v("1.0.0"), lastNotified: v("1.1.0")))
    }

    func testDecodesGitHubReleaseResponse() throws {
        let json = #"{"tag_name": "v1.2.0", "html_url": "https://github.com/tmstack-io/emoji-bako/releases/tag/v1.2.0", "name": "1.2.0", "draft": false}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.tag_name, "v1.2.0")
        XCTAssertEqual(release.html_url.absoluteString, "https://github.com/tmstack-io/emoji-bako/releases/tag/v1.2.0")
    }

    func testAutoCheckDefaultsToOn() throws {
        let suiteName = "EmojiBakoTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = UpdateChecker(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: UpdateChecker.autoCheckDefaultsKey))
    }
}
