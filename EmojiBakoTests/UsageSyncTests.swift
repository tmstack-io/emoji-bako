import XCTest
@testable import EmojiBako

/// iCloudのサーバーの偽物。各MacのFakeCloudReplicaがpush・pullで値をやり取りする（同じキーは後勝ち）
private final class FakeCloudServer {
    var values: [String: Any] = [:]
}

/// 1台のMacから見たiCloud KVSの偽物。書き込みは手元にすぐ反映し、pushするまでサーバーには届かない
private final class FakeCloudReplica: UsageCloudStore {
    let server: FakeCloudServer
    private(set) var values: [String: Any] = [:]
    private var pending: [(key: String, value: Any?)] = []
    private(set) var writeCount = 0

    init(server: FakeCloudServer) { self.server = server }

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) {
        values[key] = value
        pending.append((key, value))
        writeCount += 1
    }
    func removeObject(forKey key: String) {
        values[key] = nil
        pending.append((key, nil))
        writeCount += 1
    }
    var allKeys: [String] { Array(values.keys) }

    func push() {
        for (key, value) in pending { server.values[key] = value }
        pending = []
    }

    /// サーバーの値を取り込み、変わったキーがあればtrueを返す
    func pull() -> Bool {
        precondition(pending.isEmpty, "pullの前にpushする")
        let changed = !NSDictionary(dictionary: values).isEqual(to: server.values)
        values = server.values
        return changed
    }
}

/// すべてのMacで共有する時計。読むたびに1秒進む（操作の前後関係を日時で比べられるように）
private final class TestClock {
    private(set) var current = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date {
        current += 1
        return current
    }
}

/// 1台のMac（手元の保存先、iCloudの偽物、UsageSync）
@MainActor
private final class FakeMac {
    let defaults: UserDefaults
    let suiteName: String
    let cloud: FakeCloudReplica
    let clock: TestClock
    var name: String
    var hardwareID: String
    var iCloudIdentity: Data? = Data("account-1".utf8)
    private(set) var sync: UsageSync!

    init(name: String, server: FakeCloudServer, clock: TestClock, prepareDefaults: (UserDefaults) -> Void = { _ in }) {
        self.name = name
        self.clock = clock
        hardwareID = "hardware-\(name)"
        suiteName = "EmojiBakoTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        cloud = FakeCloudReplica(server: server)
        prepareDefaults(defaults)
        launch()
    }

    /// アプリを起動し直す（手元の保存先とiCloudの手元の写しはそのまま）
    func launch() {
        sync = UsageSync(local: defaults, cloud: cloud, computerName: name, hardwareID: hardwareID, now: clock.now)
        sync.start(iCloudIdentity: iCloudIdentity)
    }

    func rename(_ newName: String) {
        name = newName
        sync.computerNameDidChange(to: newName)
    }

    func use(_ emoji: String, times: Int = 1) {
        for _ in 0..<times { sync.increment(emoji) }
    }
}

@MainActor
final class UsageSyncTests: XCTestCase {
    private var server: FakeCloudServer!
    private var clock: TestClock!
    private var macs: [FakeMac] = []

    override func setUp() {
        server = FakeCloudServer()
        clock = TestClock()
        macs = []
    }

    override func tearDown() {
        for mac in macs { mac.defaults.removePersistentDomain(forName: mac.suiteName) }
    }

    private func makeMac(_ name: String, prepareDefaults: (UserDefaults) -> Void = { _ in }) -> FakeMac {
        let mac = FakeMac(name: name, server: server, clock: clock, prepareDefaults: prepareDefaults)
        macs.append(mac)
        return mac
    }

    /// 指定したMac（省略時は全台）をiCloudとつなぎ、変更がなくなるまでやり取りする
    private func syncAll(_ online: [FakeMac]? = nil, reason: UsageSync.CloudChangeReason = .serverChange) {
        let targets = online ?? macs
        for _ in 0..<10 {
            for mac in targets { mac.cloud.push() }
            var anyChanged = false
            for mac in targets where mac.cloud.pull() {
                anyChanged = true
                mac.sync.cloudDidChange(reason: reason)
            }
            if !anyChanged { return }
        }
        XCTFail("同期が収束しません（書き込みの応酬）")
    }

    // MARK: - 同期のオフ

    func testCountsLocallyWhenSyncIsOff() {
        let a = makeMac("MacA")
        a.use("😀", times: 2)

        XCTAssertEqual(a.sync.totals, ["😀": 2])
        XCTAssertEqual(a.sync.macs, [])
        XCTAssertEqual(a.cloud.writeCount, 0, "同期がオフのときはiCloudに書かない")
    }

    func testCountsSurviveRelaunch() {
        let a = makeMac("MacA")
        a.use("😀")
        a.launch()

        XCTAssertEqual(a.sync.totals, ["😀": 1])
    }

    // MARK: - 合計（Q2・Q3）

    func testTotalsAreSumOfAllMacs() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        a.use("😀", times: 3)
        b.use("😀", times: 2)
        b.use("🎉")
        syncAll()

        XCTAssertEqual(a.sync.totals, ["😀": 5, "🎉": 1])
        XCTAssertEqual(b.sync.totals, ["😀": 5, "🎉": 1])
    }

    func testCountsMadeOfflineOnBothMacsAreNotLost() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        syncAll()
        // 2台ともオフラインで同じ絵文字を使い、あとでつながる
        a.use("😀", times: 3)
        b.use("😀", times: 2)
        syncAll()

        XCTAssertEqual(a.sync.totals["😀"], 5)
        XCTAssertEqual(b.sync.totals["😀"], 5)
    }

    func testSettledStateDoesNotKeepWriting() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        a.use("😀"); b.use("🎉")
        syncAll()
        let writes = (a.cloud.writeCount, b.cloud.writeCount)

        a.sync.cloudDidChange(reason: .serverChange)
        b.sync.cloudDidChange(reason: .serverChange)

        XCTAssertEqual(a.cloud.writeCount, writes.0)
        XCTAssertEqual(b.cloud.writeCount, writes.1)
    }

    // MARK: - すべてのMacのリセット（Q10・Q14）

    func testResetAllMacsClearsEveryMac() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        a.use("😀"); b.use("🎉", times: 2)
        syncAll()

        a.sync.resetAllMacs()
        syncAll()

        XCTAssertEqual(a.sync.totals, [:])
        XCTAssertEqual(b.sync.totals, [:])
        XCTAssertEqual(b.sync.thisMacCounts, [:])
        b.use("🎉")
        syncAll()
        XCTAssertEqual(a.sync.totals, ["🎉": 1], "リセット後に数えた分は合計に入る")
    }

    func testCountsMadeOfflineBeforeLearningOfResetAreDiscarded() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        syncAll()
        // MacBがオフラインのあいだに、MacAでリセットし、MacBで5回使う
        a.sync.resetAllMacs()
        syncAll([a])
        b.use("😀", times: 5)
        syncAll()

        XCTAssertEqual(a.sync.totals, [:])
        XCTAssertEqual(b.sync.totals, [:])
    }

    func testGenerationRolledBackByLastWriterWinsIsRestored() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        a.sync.resetAllMacs()
        syncAll()
        // 後勝ちで古い世代がiCloudに書かれた状態
        server.values[UsageSync.generationKey] = UsageSync.encode(.first)
        syncAll()

        XCTAssertEqual((server.values[UsageSync.generationKey]).flatMap(UsageSync.decodeGeneration)?.number, 2)
    }

    // MARK: - このMacのリセット（Q16・Q26）

    func testResetThisMacKeepsOtherMacsAndGeneration() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        a.use("😀"); b.use("🎉")
        syncAll()

        a.sync.resetThisMac()
        syncAll()

        XCTAssertEqual(a.sync.totals, ["🎉": 1])
        XCTAssertEqual(b.sync.totals, ["🎉": 1])
        XCTAssertNil(server.values[UsageSync.generationKey], "世代番号は変えない")
    }

    func testResetThisMacWhileOffDoesNotAffectOtherMacsLater() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        b.sync.enable()
        b.use("🎉")
        syncAll()
        a.use("😀")

        a.sync.resetThisMac()
        a.sync.enable()
        syncAll()

        XCTAssertEqual(a.sync.totals, ["🎉": 1])
        XCTAssertEqual(b.sync.totals, ["🎉": 1])
    }

    // MARK: - オンとオフ（Q12・Q15・Q19）

    func testEnablingKeepsLocalCountsAndJoinsCurrentGeneration() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable()
        a.sync.resetAllMacs()
        a.sync.resetAllMacs()
        a.use("🎉")
        syncAll()
        b.use("😀", times: 10)

        b.sync.enable()
        syncAll()

        XCTAssertEqual(b.sync.totals, ["😀": 10, "🎉": 1])
        XCTAssertEqual(a.sync.totals, ["😀": 10, "🎉": 1])
    }

    func testEnablingWithStaleLocalGenerationDoesNotResetOtherMacs() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        // MacBは以前、別の場所で世代3まで進めた記録を持っている
        b.defaults.set(3, forKey: UsageSync.generationNumberDefaultsKey)
        b.defaults.set(Date(timeIntervalSince1970: 1_700_000_000), forKey: UsageSync.generationResetAtDefaultsKey)
        a.sync.enable()
        a.use("😀")
        syncAll()

        b.sync.enable()
        syncAll()

        XCTAssertEqual(a.sync.totals, ["😀": 1])
        XCTAssertEqual(b.sync.totals, ["😀": 1])
    }

    func testDisablingShowsOnlyThisMacAndLeavesOtherMacsList() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        a.use("😀"); b.use("🎉")
        syncAll()

        a.sync.disable()
        syncAll()

        XCTAssertEqual(a.sync.totals, ["😀": 1])
        XCTAssertEqual(a.sync.macs, [])
        XCTAssertEqual(b.sync.totals, ["🎉": 1])
        XCTAssertEqual(b.sync.macs.map(\.name), ["MacB"])
    }

    func testInitialSyncWithNewerGenerationKeepsLocalCounts() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable()
        a.sync.resetAllMacs()
        a.use("🎉")
        syncAll([a])
        // MacBはiCloudのデータを読み込む前に同期をオンにした
        b.use("😀", times: 4)
        b.sync.enable()

        syncAll(reason: .initialSync)

        XCTAssertEqual(b.sync.totals, ["😀": 4, "🎉": 1])
    }

    func testAccountChangeAddsThisMacToNewAccount() {
        let a = makeMac("MacA")
        a.sync.enable()
        a.use("😀", times: 2)
        syncAll()
        // 別のApple IDに切り替わり、iCloudのデータが新しいアカウントのものに置き換わった
        server.values = ["mac.other": ["generation": 1, "name": "OtherMac", "updatedAt": Date(), "counts": ["🍣": 3]] as [String: Any]]

        syncAll(reason: .accountChange)

        XCTAssertEqual(a.sync.totals, ["😀": 2, "🍣": 3])
        XCTAssertNotNil(server.values.keys.first { $0.hasPrefix(UsageSync.macKeyPrefix) && $0 != "mac.other" }, "このMacの欄を新しいアカウントに書く")
    }

    // MARK: - 同期中のMacの一覧（Q27・Q28）

    func testMacListShowsNamesAndUpdatedAt() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        b.use("🎉")
        let bWroteAt = clock.current
        syncAll()

        XCTAssertEqual(a.sync.macs.map(\.name), ["MacA", "MacB"])
        XCTAssertEqual(a.sync.macs.map(\.isThisMac), [true, false])
        XCTAssertEqual(a.sync.macs[1].updatedAt, bWroteAt)
    }

    func testComputerNameChangeIsReflectedOnOtherMacs() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        syncAll()

        b.rename("MacB Pro")
        syncAll()

        XCTAssertEqual(a.sync.macs.map(\.name), ["MacA", "MacB Pro"])
    }

    // MARK: - 同期から外す（Q29・Q30・Q31）

    func testRemovedMacLeavesTotalsAndTurnsSyncOffKeepingItsCounts() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        a.use("😀"); b.use("🎉", times: 2)
        syncAll()
        let bID = a.sync.macs.first { !$0.isThisMac }!.id

        a.sync.removeMac(id: bID)
        XCTAssertEqual(a.sync.totals, ["😀": 1], "外したMacの使用回数はすぐに合計から除く")
        syncAll()

        XCTAssertFalse(b.sync.isEnabled)
        XCTAssertTrue(b.sync.wasRemovedByOtherMac)
        XCTAssertEqual(b.sync.totals, ["🎉": 2])
        XCTAssertEqual(a.sync.macs.map(\.name), ["MacA"])
    }

    func testRemovedMacRejoinsAsNewMacWhenEnabledAgain() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        b.use("🎉", times: 2)
        syncAll()
        let oldID = a.sync.macs.first { !$0.isThisMac }!.id
        a.sync.removeMac(id: oldID)
        syncAll()

        b.sync.enable()
        syncAll()

        XCTAssertTrue(b.sync.isEnabled)
        XCTAssertFalse(b.sync.wasRemovedByOtherMac)
        XCTAssertEqual(a.sync.totals, ["🎉": 2])
        XCTAssertNotEqual(a.sync.macs.first { !$0.isThisMac }?.id, oldID)
    }

    func testRemovalRecordSurvivesResetForMacThatWasOffline() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        syncAll()
        let bID = a.sync.macs.first { !$0.isThisMac }!.id
        // MacBがオフラインのあいだに外され、そのあとリセットされた
        a.sync.removeMac(id: bID)
        a.sync.resetAllMacs()
        syncAll([a])
        b.use("🎉")

        syncAll()

        XCTAssertFalse(b.sync.isEnabled)
        XCTAssertTrue(b.sync.wasRemovedByOtherMac)
        XCTAssertEqual(a.sync.macs.map(\.name), ["MacA"])
        XCTAssertNil(server.values[UsageSync.macKeyPrefix + bID], "オフラインのあいだに書いた欄も消す")
    }

    // MARK: - v1.0.0からの移行（Q13）

    func testMigratesV1_0_0CountsOnce() {
        let a = makeMac("MacA") { $0.set(["😀": 7], forKey: "emojiUsageCounts") }

        XCTAssertEqual(a.sync.totals, ["😀": 7])
        XCTAssertNil(a.defaults.object(forKey: "emojiUsageCounts"))
        a.launch()
        XCTAssertEqual(a.sync.totals, ["😀": 7])
    }

    func testMigrationAddsCountsMadeAfterDowngradingToV1_0_0() {
        let a = makeMac("MacA") {
            $0.set(["😀": 7], forKey: UsageSync.countsDefaultsKey)
            $0.set(["😀": 1, "🎉": 2], forKey: "emojiUsageCounts")
        }

        XCTAssertEqual(a.sync.totals, ["😀": 8, "🎉": 2])
    }

    // MARK: - 壊れたデータ（Q18）

    func testMalformedSlotIsReportedAndExcluded() {
        let a = makeMac("MacA")
        a.sync.enable()
        a.use("😀")
        syncAll()
        server.values["mac.broken"] = "not a dictionary"

        syncAll()

        XCTAssertEqual(a.sync.totals, ["😀": 1])
        XCTAssertEqual(a.sync.malformedKeys, ["mac.broken"])
    }

    func testQuotaViolationIsReported() {
        let a = makeMac("MacA")
        a.sync.enable()

        a.sync.cloudDidChange(reason: .quotaViolation)
        a.sync.cloudDidChange(reason: .serverChange)

        XCTAssertTrue(a.sync.isQuotaExceeded, "ほかの変更が届いても、容量超過の表示は残す")
        a.sync.resetThisMac()
        XCTAssertFalse(a.sync.isQuotaExceeded, "使用回数を減らす操作をしたら消す")
    }

    // MARK: - レビューで見つかった筋書き

    /// 移行アシスタントなどで、同期中のMacの保存データが別のMacに写った
    func testCopiedDefaultsWithSyncOnJoinAsNewMacWithoutDoubleCounting() {
        let a = makeMac("MacA")
        a.sync.enable()
        a.use("😀", times: 3)
        syncAll()
        let c = makeMac("MacC") { defaults in
            for (key, value) in a.defaults.dictionaryRepresentation() where key.hasPrefix("usage.") {
                defaults.set(value, forKey: key)
            }
        }
        c.use("🎉")
        syncAll()

        XCTAssertNotEqual(c.defaults.string(forKey: UsageSync.macIDDefaultsKey), a.defaults.string(forKey: UsageSync.macIDDefaultsKey))
        XCTAssertEqual(c.sync.thisMacCounts, ["🎉": 1], "写す前のMacの使用回数はiCloudにあるので捨てる")
        XCTAssertEqual(a.sync.totals, ["😀": 3, "🎉": 1])
        XCTAssertEqual(c.sync.totals, ["😀": 3, "🎉": 1])
    }

    func testCopiedDefaultsWithSyncOffKeepCounts() {
        let a = makeMac("MacA")
        a.use("😀", times: 3)
        let c = makeMac("MacC") { defaults in
            for (key, value) in a.defaults.dictionaryRepresentation() where key.hasPrefix("usage.") {
                defaults.set(value, forKey: key)
            }
        }
        c.launch()

        XCTAssertEqual(c.sync.totals, ["😀": 3])
    }

    /// iCloudのデータが届く前に同期をオンにし、そのあと加わる前のリセットの世代が届いた
    func testResetMadeBeforeJoiningDoesNotClearCountsWhenItArrivesLate() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable()
        a.sync.resetAllMacs()
        a.sync.resetAllMacs()
        a.use("🎉")
        syncAll([a])
        b.use("😀", times: 5)

        b.sync.enable()
        syncAll(reason: .serverChange)

        XCTAssertEqual(b.sync.thisMacCounts, ["😀": 5])
        XCTAssertEqual(a.sync.totals, ["😀": 5, "🎉": 1])
    }

    /// 同期がオンのまま終了しているあいだに、ほかのMacでリセットされた
    func testResetLearnedAtLaunchClearsCounts() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        b.use("😀", times: 2)
        syncAll()
        a.sync.resetAllMacs()
        syncAll([a])
        _ = b.cloud.pull()

        b.launch()

        XCTAssertEqual(b.sync.thisMacCounts, [:])
        XCTAssertEqual(b.sync.totals, [:])
    }

    /// アプリを終了しているあいだにAppleアカウントが変わった
    func testAccountChangedWhileNotRunningDoesNotWriteOldGeneration() {
        let a = makeMac("MacA")
        a.sync.enable()
        a.sync.resetAllMacs()
        a.sync.resetAllMacs()
        a.use("😀")
        syncAll()
        // 新しいアカウントには、世代のないほかのMacの欄がある
        server.values = ["mac.other": ["generation": 1, "name": "OtherMac", "updatedAt": Date(), "counts": ["🍣": 3]] as [String: Any]]
        _ = a.cloud.pull()
        a.iCloudIdentity = Data("account-2".utf8)

        a.launch()
        syncAll()

        XCTAssertNil(server.values[UsageSync.generationKey], "古いアカウントの世代を書かない")
        XCTAssertEqual(a.sync.totals, ["😀": 1, "🍣": 3])
    }

    func testMalformedGenerationIsReportedAndNotOverwritten() {
        let a = makeMac("MacA")
        a.sync.enable()
        a.use("😀")
        syncAll()
        server.values[UsageSync.generationKey] = 5

        syncAll()

        XCTAssertEqual(a.sync.malformedKeys, [UsageSync.generationKey])
        XCTAssertEqual(server.values[UsageSync.generationKey] as? Int, 5)
        XCTAssertEqual(a.sync.totals, ["😀": 1])
        a.sync.resetAllMacs()
        syncAll()
        XCTAssertEqual((server.values[UsageSync.generationKey]).flatMap(UsageSync.decodeGeneration)?.number, 2, "すべてのMacのリセットで正しい形式に書き直す")
    }

    func testRemovedNoticeSurvivesRelaunchUntilDismissed() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        syncAll()
        a.sync.removeMac(id: a.sync.macs.first { !$0.isThisMac }!.id)
        syncAll()

        b.launch()
        XCTAssertTrue(b.sync.wasRemovedByOtherMac)
        b.sync.dismissRemovedNotice()
        b.launch()
        XCTAssertFalse(b.sync.wasRemovedByOtherMac)
    }

    func testMalformedV1_0_0DataIsRemoved() {
        let a = makeMac("MacA") { $0.set("broken", forKey: "emojiUsageCounts") }

        XCTAssertEqual(a.sync.totals, [:])
        XCTAssertNil(a.defaults.object(forKey: "emojiUsageCounts"))
    }

    func testSettledStateDoesNotWriteOnInitialSyncOrRepeatedAccountChange() {
        let a = makeMac("MacA"), b = makeMac("MacB")
        a.sync.enable(); b.sync.enable()
        a.use("😀"); b.use("🎉")
        syncAll()
        a.sync.cloudDidChange(reason: .accountChange)
        syncAll()
        let writes = (a.cloud.writeCount, b.cloud.writeCount)

        a.sync.cloudDidChange(reason: .initialSync)
        a.sync.cloudDidChange(reason: .accountChange)
        b.sync.cloudDidChange(reason: .initialSync)

        XCTAssertEqual(a.cloud.writeCount, writes.0)
        XCTAssertEqual(b.cloud.writeCount, writes.1)
    }
}
