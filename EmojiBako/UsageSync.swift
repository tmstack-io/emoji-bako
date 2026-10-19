// UsageSync.swift
// 使用回数の保存と、iCloud KVSによる使用回数の同期（ADR 0003）

import Foundation
import os

/// 使用回数の同期で使う、キーと値の保存先（iCloud KVS）。テストでは偽物に差し替える
protocol UsageCloudStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any, forKey key: String)
    func removeObject(forKey key: String)
    var allKeys: [String] { get }
}

/// 使用回数を記録し、同期がオンなら同期中のMacの使用回数と合わせる。
///
/// iCloud上のデータ:
/// - `generation`: リセットの世代（number: 世代番号、resetAt: リセットした日時）。複数のMacが書くため、番号の大きい方を採る
/// - `mac.<ID>`: そのMacだけが書く欄（generation、name、updatedAt、counts）
/// - `removed.<ID>`: 同期から外したMacの記録。消さない
@MainActor
final class UsageSync: ObservableObject {
    /// 同期中のMacの一覧の1行
    struct Mac: Equatable, Identifiable {
        let id: String
        let name: String
        /// そのMacが最後に欄を書いた日時（このMacの欄がまだiCloudにないときはnil）
        let updatedAt: Date?
        let isThisMac: Bool
    }

    /// iCloud KVSの変更通知の理由
    enum CloudChangeReason {
        /// ほかのMacの変更が届いた
        case serverChange
        /// このMacで初めてiCloudのデータを読み込んだ
        case initialSync
        /// 容量の上限を超えた
        case quotaViolation
        /// MacのAppleアカウントが変わった
        case accountChange
    }

    /// リセットの世代
    struct Generation: Equatable {
        let number: Int
        /// リセットした日時（最初の世代はdistantPast）
        let resetAt: Date

        static let first = Generation(number: 1, resetAt: .distantPast)
    }

    // iCloud上のキー
    static let generationKey = "generation"
    static let macKeyPrefix = "mac."
    static let removedKeyPrefix = "removed."

    // 手元（UserDefaults）のキー
    static let countsDefaultsKey = "usage.thisMacCounts"
    static let enabledDefaultsKey = "usage.syncEnabled"
    static let macIDDefaultsKey = "usage.macID"
    static let hardwareIDDefaultsKey = "usage.hardwareID"
    static let joinedAtDefaultsKey = "usage.joinedAt"
    static let generationNumberDefaultsKey = "usage.generationNumber"
    static let generationResetAtDefaultsKey = "usage.generationResetAt"
    static let iCloudIdentityDefaultsKey = "usage.iCloudIdentity"
    static let removedByOtherMacDefaultsKey = "usage.removedByOtherMac"

    /// 表示に使う使用回数（同期がオンなら同期中のMacの合計、オフならこのMacの分）
    @Published private(set) var totals: [String: Int] = [:]
    /// 同期中のMacの一覧（同期がオフなら空）。先頭はこのMac
    @Published private(set) var macs: [Mac] = []
    @Published private(set) var isEnabled: Bool
    /// ほかのMacで、このMacが同期から外された
    @Published private(set) var wasRemovedByOtherMac: Bool
    /// 形式が想定と異なるため読めなかった、iCloud上のキー
    @Published private(set) var malformedKeys: Set<String> = []
    /// iCloud KVSの容量の上限を超えた（使用回数を減らす操作をするまで表示する）
    @Published private(set) var isQuotaExceeded = false
    /// iCloudにサインインしている（していなければ、使用回数はこのMacの中にだけ記録される）
    @Published private(set) var isICloudSignedIn = true
    /// iCloud KVSを使える（entitlementがないなどで使えなければfalse）
    @Published private(set) var isCloudStoreAvailable = true

    /// このMacで数えた使用回数（現在の世代の分）
    private(set) var thisMacCounts: [String: Int]

    private let local: UserDefaults
    private let cloud: UsageCloudStore
    private var computerName: String
    private let now: () -> Date
    /// 一度ログに記録した、形式の不正なキー（同じキーで何度も記録しないため）
    private var loggedMalformedKeys: Set<String> = []
    private let logger = Logger(subsystem: "io.tmstack.EmojiBako", category: "UsageSync")

    /// 手元の保存データを読み込む。iCloudとの突き合わせは start で行う
    /// - Parameter hardwareID: このMacのハードウェアの識別子。移行アシスタントなどで別のMacから写ってきた保存データを見分けるのに使う
    init(local: UserDefaults, cloud: UsageCloudStore, computerName: String, hardwareID: String, now: @escaping () -> Date = Date.init) {
        self.local = local
        self.cloud = cloud
        self.computerName = computerName
        self.now = now
        Self.migrateUsageCountsFromV1_0_0(in: local, logger: logger)
        if let stored = local.object(forKey: Self.countsDefaultsKey), !(stored is [String: Int]) {
            logger.error("使用回数の保存データの形式が不正なため、使用回数なしで始めます: \(String(describing: stored), privacy: .public)")
        }
        thisMacCounts = local.object(forKey: Self.countsDefaultsKey) as? [String: Int] ?? [:]
        isEnabled = local.bool(forKey: Self.enabledDefaultsKey)
        wasRemovedByOtherMac = local.bool(forKey: Self.removedByOtherMacDefaultsKey)
        handleCopiedFromAnotherMac(hardwareID: hardwareID)
    }

    // MARK: - v1.0.0からの移行

    /// v1.0.0の保存データ（キー`emojiUsageCounts`、[絵文字: 回数]）を、このMacの使用回数へ一度だけ移し、古いデータを消す
    private static func migrateUsageCountsFromV1_0_0(in local: UserDefaults, logger: Logger) {
        let v1Key = "emojiUsageCounts"
        guard let v1Counts = local.object(forKey: v1Key) else { return }
        guard let counts = v1Counts as? [String: Int] else {
            logger.error("v1.0.0の使用回数の保存データの形式が不正なため、移さずに消します: \(String(describing: v1Counts), privacy: .public)")
            local.removeObject(forKey: v1Key)
            return
        }
        // 1.1.0以降で移行したあとにv1.0.0へ戻して使った場合は両方ある。v1.0.0は移行で消えた状態から数え直しているので、足し合わせる
        let existing = local.object(forKey: countsDefaultsKey)
        if let existing, !(existing is [String: Int]) {
            logger.error("使用回数の保存データの形式が不正なため、v1.0.0の使用回数で置き換えます: \(String(describing: existing), privacy: .public)")
        }
        let current = existing as? [String: Int] ?? [:]
        local.set(current.merging(counts, uniquingKeysWith: +), forKey: countsDefaultsKey)
        local.removeObject(forKey: v1Key)
    }

    // MARK: - 別のMacから写ってきた保存データ

    /// 保存データが別のMacから写ってきたもの（移行アシスタントなど）なら、このMacを新しいMacとして扱う。
    /// 写す前のMacで同期がオンだった場合、その使用回数は写す前のMacの欄としてiCloudにあるので、二重に数えないよう捨てる
    private func handleCopiedFromAnotherMac(hardwareID: String) {
        let storedHardwareID = local.string(forKey: Self.hardwareIDDefaultsKey)
        local.set(hardwareID, forKey: Self.hardwareIDDefaultsKey)
        guard let storedHardwareID, storedHardwareID != hardwareID, isEnabled else { return }
        logger.notice("別のMacから写ってきた保存データのため、新しいMacとして同期に加わります")
        thisMacCounts = [:]
        saveThisMacCounts()
        joinSync()
    }

    // MARK: - 起動

    /// 起動時に、iCloudとの突き合わせを始める
    /// - Parameter iCloudIdentity: 今のAppleアカウントを表すデータ（サインインしていなければnil）
    func start(iCloudIdentity: Data?) {
        let accountChanged = recordICloudIdentity(iCloudIdentity)
        guard isEnabled else {
            recompute()
            return
        }
        if accountChanged {
            // アプリを終了しているあいだにAppleアカウントが変わった
            joinCurrentGeneration()
        }
        applyCloudState()
    }

    /// 最後にサインインしていたAppleアカウントを記録し、記録と違うアカウントになったかどうかを返す。
    /// サインアウト中（nil）は記録を上書きしない（サインアウトを挟んで別のアカウントになった場合も見分けるため）
    private func recordICloudIdentity(_ identity: Data?) -> Bool {
        guard let identity else { return false }
        let stored = local.data(forKey: Self.iCloudIdentityDefaultsKey)
        local.set(identity, forKey: Self.iCloudIdentityDefaultsKey)
        return stored != nil && stored != identity
    }

    // MARK: - 操作

    /// 絵文字を1回使ったことを記録する
    func increment(_ emoji: String) {
        thisMacCounts[emoji, default: 0] += 1
        saveThisMacCounts()
        if isEnabled { writeThisMacSlotIfNeeded() }
        recompute()
    }

    /// 同期をオンにする。このMacの使用回数は消さず、iCloudの現在の世代に加える
    func enable() {
        precondition(!isEnabled, "同期はすでにオンです")
        setRemovedByOtherMac(false)
        joinSync()
        applyCloudState()
    }

    /// 同期をオフにする。iCloud上のこのMacの欄を消し、このMacの使用回数だけで表示する
    func disable() {
        precondition(isEnabled, "同期はすでにオフです")
        cloud.removeObject(forKey: Self.macKey(requireMacID()))
        isQuotaExceeded = false
        leaveSync()
    }

    /// すべてのMacの使用回数を消す（同期がオンのときだけ）
    func resetAllMacs() {
        precondition(isEnabled, "すべてのMacのリセットは同期がオンのときだけ行える")
        let cloudNumber = readCloudGeneration()?.number ?? Generation.first.number
        let next = Generation(number: max(localGeneration.number, cloudNumber) + 1, resetAt: now())
        saveLocalGeneration(next)
        cloud.set(Self.encode(next), forKey: Self.generationKey)
        thisMacCounts = [:]
        saveThisMacCounts()
        isQuotaExceeded = false
        writeThisMacSlotIfNeeded()
        removeStaleSlots()
        recompute()
    }

    /// このMacの使用回数だけを消す。世代は変えない
    func resetThisMac() {
        thisMacCounts = [:]
        saveThisMacCounts()
        isQuotaExceeded = false
        if isEnabled { writeThisMacSlotIfNeeded() }
        recompute()
    }

    /// ほかのMacを同期から外す
    func removeMac(id: String) {
        precondition(isEnabled, "同期から外す操作は同期がオンのときだけ行える")
        precondition(id != macID, "このMacは同期をオフにして外す")
        cloud.set(true, forKey: Self.removedKey(id))
        cloud.removeObject(forKey: Self.macKey(id))
        recompute()
    }

    /// 「ほかのMacで同期から外された」の表示を消す
    func dismissRemovedNotice() {
        setRemovedByOtherMac(false)
    }

    /// iCloud KVSの変更通知を受け取ったときに呼ぶ
    func cloudDidChange(reason: CloudChangeReason) {
        guard isEnabled else { return }
        switch reason {
        case .quotaViolation:
            logger.error("iCloud KVSの容量の上限を超えました")
            isQuotaExceeded = true
        case .serverChange, .initialSync:
            applyCloudState()
        case .accountChange:
            // 新しいアカウントの世代は、このMacにとってのリセットではない
            joinCurrentGeneration()
            applyCloudState()
        }
    }

    /// iCloudのサインイン状態が分かったとき・変わったときに呼ぶ
    func iCloudSignInDidChange(signedIn: Bool, identity: Data?) {
        isICloudSignedIn = signedIn
        // KVSのAccountChangeの通知が届く前にアプリが終了しても、次の起動で古い世代を書かないよう、ここでも合わせる
        if recordICloudIdentity(identity), isEnabled {
            joinCurrentGeneration()
            applyCloudState()
        }
    }

    /// iCloud KVSを使えるかどうか（synchronize()の結果）が分かったときに呼ぶ
    func cloudStoreAvailabilityDidChange(available: Bool) {
        isCloudStoreAvailable = available
    }

    /// コンピュータ名が変わったときに呼ぶ
    func computerNameDidChange(to name: String) {
        computerName = name
        guard isEnabled else { return }
        writeThisMacSlotIfNeeded()
        recompute()
    }

    // MARK: - iCloudとの突き合わせ

    /// 新しいIDで同期に加わる（同期をオンにしたとき、別のMacから写ってきたとき）
    private func joinSync() {
        local.set(UUID().uuidString, forKey: Self.macIDDefaultsKey)
        setEnabled(true)
        joinCurrentGeneration()
    }

    /// iCloudの今の世代に、使用回数を消さずに合わせる。
    /// 手元に残っている古い世代を書き戻すと、ほかのMacの使用回数を消してしまうため、手元の方をiCloudに合わせる。
    /// iCloudのデータがまだ届いていない場合に備え、加わった日時を記録する（これより前のリセットでは使用回数を消さない）
    private func joinCurrentGeneration() {
        saveLocalGeneration(readCloudGeneration() ?? .first)
        local.set(now(), forKey: Self.joinedAtDefaultsKey)
    }

    /// iCloudの状態を読み、世代・このMacの欄・古い欄を整える
    private func applyCloudState() {
        let macID = requireMacID()
        if cloud.object(forKey: Self.removedKey(macID)) != nil {
            // オフラインのあいだに書いた欄が残っていれば消す
            cloud.removeObject(forKey: Self.macKey(macID))
            setRemovedByOtherMac(true)
            leaveSync()
            return
        }

        let cloudGeneration: Generation?
        if let value = cloud.object(forKey: Self.generationKey) {
            guard let generation = Self.decodeGeneration(value) else {
                // 世代が読めないまま書くと、ほかのMacの使用回数を誤って消しかねないため、iCloudには書かない
                recompute()
                return
            }
            cloudGeneration = generation
        } else {
            cloudGeneration = nil
        }

        let current = localGeneration
        // iCloudに世代がなければ、最初の世代とみなす。世代を書くのは、すべてのMacのリセットのときと、下の書き戻しのときだけ
        let cloudOrFirst = cloudGeneration ?? .first
        if cloudOrFirst.number > current.number {
            if cloudOrFirst.resetAt > joinedAt {
                // このMacが同期に加わったあとで、ほかのMacがすべてのMacのリセットをした
                thisMacCounts = [:]
                saveThisMacCounts()
            }
            // 加わる前のリセット（iCloudのデータが届く前に同期をオンにした場合など）では、使用回数を消さずに合わせる
            saveLocalGeneration(cloudOrFirst)
        } else if current.number > cloudOrFirst.number {
            // 後勝ちでiCloudの世代が古い値に戻った。大きい方を正とするため書き戻す
            cloud.set(Self.encode(current), forKey: Self.generationKey)
        }

        writeThisMacSlotIfNeeded()
        removeStaleSlots()
        recompute()
    }

    /// iCloud上のこのMacの欄が、書くべき内容と異なるときだけ書く（書き込みの応酬を避けるため）
    private func writeThisMacSlotIfNeeded() {
        let key = Self.macKey(requireMacID())
        let generation = localGeneration.number
        if let current = cloud.object(forKey: key) as? [String: Any],
           current["generation"] as? Int == generation,
           current["name"] as? String == computerName,
           current["counts"] as? [String: Int] == thisMacCounts {
            return
        }
        cloud.set([
            "generation": generation,
            "name": computerName,
            "updatedAt": now(),
            "counts": thisMacCounts,
        ] as [String: Any], forKey: key)
    }

    /// 前の世代の欄と、外されたMacの欄を消す
    private func removeStaleSlots() {
        for key in cloud.allKeys where key.hasPrefix(Self.macKeyPrefix) {
            let id = String(key.dropFirst(Self.macKeyPrefix.count))
            guard id != macID else { continue }
            if cloud.object(forKey: Self.removedKey(id)) != nil {
                cloud.removeObject(forKey: key)
            } else if let slot = cloud.object(forKey: key) as? [String: Any], let generation = slot["generation"] as? Int, generation < localGeneration.number {
                cloud.removeObject(forKey: key)
            }
        }
    }

    /// 表示に使う使用回数、同期中のMacの一覧、読めなかったキーを作り直す
    private func recompute() {
        guard isEnabled, let macID else {
            update(totals: thisMacCounts, macs: [], malformedKeys: [])
            return
        }
        let generation = localGeneration.number
        var sum = thisMacCounts
        var others: [Mac] = []
        var malformed: Set<String> = []
        if let value = cloud.object(forKey: Self.generationKey), Self.decodeGeneration(value) == nil {
            malformed.insert(Self.generationKey)
            logMalformedOnce(key: Self.generationKey, value: value)
        }
        for key in cloud.allKeys where key.hasPrefix(Self.macKeyPrefix) {
            let id = String(key.dropFirst(Self.macKeyPrefix.count))
            guard id != macID, cloud.object(forKey: Self.removedKey(id)) == nil, let value = cloud.object(forKey: key) else { continue }
            guard let slot = value as? [String: Any],
                  let slotGeneration = slot["generation"] as? Int,
                  let name = slot["name"] as? String,
                  let updatedAt = slot["updatedAt"] as? Date,
                  let counts = slot["counts"] as? [String: Int] else {
                // 1台分の欄が壊れていても、ほかのMacの同期は続ける
                malformed.insert(key)
                logMalformedOnce(key: key, value: value)
                continue
            }
            guard slotGeneration == generation else { continue }
            sum.merge(counts, uniquingKeysWith: +)
            others.append(Mac(id: id, name: name, updatedAt: updatedAt, isThisMac: false))
        }
        let thisSlot = cloud.object(forKey: Self.macKey(macID)) as? [String: Any]
        let thisMac = Mac(id: macID, name: computerName, updatedAt: thisSlot?["updatedAt"] as? Date, isThisMac: true)
        update(totals: sum, macs: [thisMac] + others.sorted { ($0.name, $0.id) < ($1.name, $1.id) }, malformedKeys: malformed)
    }

    /// 値が変わったときだけ更新する（同じ値で表示を作り直さないため）
    private func update(totals: [String: Int], macs: [Mac], malformedKeys: Set<String>) {
        if self.totals != totals { self.totals = totals }
        if self.macs != macs { self.macs = macs }
        if self.malformedKeys != malformedKeys { self.malformedKeys = malformedKeys }
    }

    // MARK: - 手元の状態

    private var macID: String? { local.string(forKey: Self.macIDDefaultsKey) }

    private func requireMacID() -> String {
        guard let macID else { preconditionFailure("同期がオンなのにこのMacのIDがありません") }
        return macID
    }

    /// 手元に記録した世代（記録がなければ最初の世代）
    private var localGeneration: Generation {
        guard let number = local.object(forKey: Self.generationNumberDefaultsKey) as? Int,
              let resetAt = local.object(forKey: Self.generationResetAtDefaultsKey) as? Date else {
            return .first
        }
        return Generation(number: number, resetAt: resetAt)
    }

    private func saveLocalGeneration(_ generation: Generation) {
        local.set(generation.number, forKey: Self.generationNumberDefaultsKey)
        local.set(generation.resetAt, forKey: Self.generationResetAtDefaultsKey)
    }

    /// このMacが今のIDで同期に加わった日時
    private var joinedAt: Date {
        guard let date = local.object(forKey: Self.joinedAtDefaultsKey) as? Date else {
            preconditionFailure("同期がオンなのに、同期に加わった日時がありません")
        }
        return date
    }

    /// iCloudの世代。形式が不正ならログに記録してnil（呼び出し側は、不正なら書かない方に倒す）
    private func readCloudGeneration() -> Generation? {
        guard let value = cloud.object(forKey: Self.generationKey) else { return nil }
        guard let generation = Self.decodeGeneration(value) else {
            logMalformedOnce(key: Self.generationKey, value: value)
            return nil
        }
        return generation
    }

    private func leaveSync() {
        local.removeObject(forKey: Self.macIDDefaultsKey)
        local.removeObject(forKey: Self.joinedAtDefaultsKey)
        setEnabled(false)
        recompute()
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        local.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    private func setRemovedByOtherMac(_ removed: Bool) {
        wasRemovedByOtherMac = removed
        local.set(removed, forKey: Self.removedByOtherMacDefaultsKey)
    }

    private func saveThisMacCounts() {
        local.set(thisMacCounts, forKey: Self.countsDefaultsKey)
    }

    private func logMalformedOnce(key: String, value: Any) {
        guard loggedMalformedKeys.insert(key).inserted else { return }
        logger.error("iCloud上の値の形式が想定と異なります: \(key, privacy: .public) = \(String(describing: value), privacy: .public)")
    }

    // MARK: - iCloud上の形式

    static func encode(_ generation: Generation) -> [String: Any] {
        ["number": generation.number, "resetAt": generation.resetAt]
    }

    static func decodeGeneration(_ value: Any) -> Generation? {
        guard let dictionary = value as? [String: Any],
              let number = dictionary["number"] as? Int,
              let resetAt = dictionary["resetAt"] as? Date else { return nil }
        return Generation(number: number, resetAt: resetAt)
    }

    private static func macKey(_ id: String) -> String { macKeyPrefix + id }
    private static func removedKey(_ id: String) -> String { removedKeyPrefix + id }
}
