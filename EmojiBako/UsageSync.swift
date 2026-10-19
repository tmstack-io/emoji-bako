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
/// - `generation`: リセットの世代番号。複数のMacが書くため、手元の値と比べて大きい方を採る
/// - `mac.<ID>`: そのMacだけが書く欄（generation、name、updatedAt、counts）
/// - `removed.<ID>`: 同期から外したMacの記録。消さない
final class UsageSync: ObservableObject {
    /// 同期中のMacの一覧の1行
    struct Mac: Equatable, Identifiable {
        let id: String
        let name: String
        let updatedAt: Date
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
        /// MacのApple IDが変わった
        case accountChange
    }

    enum SyncError: Error, Equatable {
        /// iCloud上の値の形式が想定と異なる（キー）
        case malformedValue(key: String)
        /// iCloud KVSの容量の上限を超えた
        case quotaExceeded
    }

    // iCloud上のキー
    static let generationKey = "generation"
    static let macKeyPrefix = "mac."
    static let removedKeyPrefix = "removed."

    // 手元（UserDefaults）のキー
    static let countsDefaultsKey = "usage.thisMacCounts"
    static let enabledDefaultsKey = "usage.syncEnabled"
    static let macIDDefaultsKey = "usage.macID"
    static let generationDefaultsKey = "usage.generation"
    static let removedByOtherMacDefaultsKey = "usage.removedByOtherMac"

    /// 表示に使う使用回数（同期がオンなら同期中のMacの合計、オフならこのMacの分）
    @Published private(set) var totals: [String: Int] = [:]
    /// 同期中のMacの一覧（同期がオフなら空）。先頭はこのMac
    @Published private(set) var macs: [Mac] = []
    @Published private(set) var isEnabled: Bool
    /// ほかのMacで、このMacが同期から外された
    @Published private(set) var wasRemovedByOtherMac: Bool
    @Published private(set) var lastError: SyncError?

    /// このMacで数えた使用回数（現在の世代の分）
    private(set) var thisMacCounts: [String: Int]

    private let local: UserDefaults
    private let cloud: UsageCloudStore
    private let computerName: () -> String
    private let now: () -> Date
    private let logger = Logger(subsystem: "io.tmstack.EmojiBako", category: "UsageSync")

    init(local: UserDefaults, cloud: UsageCloudStore, computerName: @escaping () -> String, now: @escaping () -> Date = Date.init) {
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
        if isEnabled {
            applyCloudState(adoptCloudGeneration: false)
        } else {
            recompute()
        }
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
        local.set(UUID().uuidString, forKey: Self.macIDDefaultsKey)
        setEnabled(true)
        setRemovedByOtherMac(false)
        applyCloudState(adoptCloudGeneration: true)
    }

    /// 同期をオフにする。iCloud上のこのMacの欄を消し、このMacの使用回数だけで表示する
    func disable() {
        precondition(isEnabled, "同期はすでにオフです")
        if let macID { cloud.removeObject(forKey: Self.macKey(macID)) }
        leaveSync()
    }

    /// すべてのMacの使用回数を消す（同期がオンのときだけ）
    func resetAllMacs() {
        precondition(isEnabled, "すべてのMacのリセットは同期がオンのときだけ行える")
        let cloudGeneration = readCloudGeneration() ?? 1
        let next = max(localGeneration, cloudGeneration) + 1
        local.set(next, forKey: Self.generationDefaultsKey)
        cloud.set(next, forKey: Self.generationKey)
        thisMacCounts = [:]
        saveThisMacCounts()
        writeThisMacSlotIfNeeded()
        removeStaleSlots()
        recompute()
    }

    /// このMacの使用回数だけを消す。世代番号は変えない
    func resetThisMac() {
        thisMacCounts = [:]
        saveThisMacCounts()
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
        switch reason {
        case .quotaViolation:
            logger.error("iCloud KVSの容量の上限を超えました")
            lastError = .quotaExceeded
        case .serverChange:
            if isEnabled { applyCloudState(adoptCloudGeneration: false) }
        case .initialSync, .accountChange:
            // 初めて読み込んだ世代や、別のApple IDの世代は、リセットではないので使用回数を消さずに採る
            if isEnabled { applyCloudState(adoptCloudGeneration: true) }
        }
    }

    /// コンピュータ名が変わったときに呼ぶ
    func computerNameDidChange() {
        guard isEnabled else { return }
        writeThisMacSlotIfNeeded()
        recompute()
    }

    // MARK: - iCloudとの突き合わせ

    /// iCloudの状態を読み、世代番号・このMacの欄・古い欄を整える。
    /// adoptCloudGeneration が true なら、iCloudの世代が新しくても使用回数を消さずにその世代を採る
    private func applyCloudState(adoptCloudGeneration: Bool) {
        guard let macID else { preconditionFailure("同期がオンなのにこのMacのIDがありません") }
        lastError = nil
        if cloud.object(forKey: Self.removedKey(macID)) != nil {
            // オフラインのあいだに書いた欄が残っていれば消す
            cloud.removeObject(forKey: Self.macKey(macID))
            setRemovedByOtherMac(true)
            leaveSync()
            return
        }

        let cloudGenerationValue = cloud.object(forKey: Self.generationKey)
        let cloudGeneration: Int?
        if let cloudGenerationValue {
            guard let value = cloudGenerationValue as? Int else {
                reportMalformed(key: Self.generationKey, value: cloudGenerationValue)
                recompute()
                return
            }
            cloudGeneration = value
        } else {
            cloudGeneration = nil
        }

        // iCloudに世代番号がなければ、最初の世代（1）とみなす。書き込みは、すべてのMacのリセットで初めて行う
        if adoptCloudGeneration {
            // 同期をオンにしたとき・初めて読み込んだとき・Apple IDが変わったときは、iCloudの世代にそのまま合わせる。
            // 手元に残っている古い世代番号を書くと、ほかのMacの使用回数を消してしまうため、書き戻さない
            local.set(cloudGeneration ?? 1, forKey: Self.generationDefaultsKey)
        } else if let cloudGeneration, cloudGeneration > localGeneration {
            // ほかのMacですべてのMacのリセットが行われた
            thisMacCounts = [:]
            saveThisMacCounts()
            local.set(cloudGeneration, forKey: Self.generationDefaultsKey)
        } else if localGeneration > (cloudGeneration ?? 1) {
            // 後勝ちでiCloudの世代が古い値に戻った。大きい方を正とするため書き戻す
            cloud.set(localGeneration, forKey: Self.generationKey)
        }

        writeThisMacSlotIfNeeded()
        removeStaleSlots()
        recompute()
    }

    /// iCloud上のこのMacの欄が、書くべき内容と異なるときだけ書く（書き込みの応酬を避けるため）
    private func writeThisMacSlotIfNeeded() {
        guard let macID else { preconditionFailure("同期がオンなのにこのMacのIDがありません") }
        let key = Self.macKey(macID)
        let name = computerName()
        if let current = cloud.object(forKey: key) as? [String: Any],
           current["generation"] as? Int == localGeneration,
           current["name"] as? String == name,
           current["counts"] as? [String: Int] == thisMacCounts {
            return
        }
        cloud.set([
            "generation": localGeneration,
            "name": name,
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
            } else if let slot = cloud.object(forKey: key) as? [String: Any], let generation = slot["generation"] as? Int, generation < localGeneration {
                cloud.removeObject(forKey: key)
            }
        }
    }

    /// 表示に使う使用回数と、同期中のMacの一覧を作り直す
    private func recompute() {
        guard isEnabled, let macID else {
            totals = thisMacCounts
            macs = []
            return
        }
        var sum = thisMacCounts
        var others: [Mac] = []
        for key in cloud.allKeys where key.hasPrefix(Self.macKeyPrefix) {
            let id = String(key.dropFirst(Self.macKeyPrefix.count))
            guard id != macID, cloud.object(forKey: Self.removedKey(id)) == nil, let value = cloud.object(forKey: key) else { continue }
            guard let slot = value as? [String: Any],
                  let generation = slot["generation"] as? Int,
                  let name = slot["name"] as? String,
                  let updatedAt = slot["updatedAt"] as? Date,
                  let counts = slot["counts"] as? [String: Int] else {
                // 1台分の欄が壊れていても、ほかのMacの同期は続ける
                reportMalformed(key: key, value: value)
                continue
            }
            guard generation == localGeneration else { continue }
            sum.merge(counts, uniquingKeysWith: +)
            others.append(Mac(id: id, name: name, updatedAt: updatedAt, isThisMac: false))
        }
        let thisSlot = cloud.object(forKey: Self.macKey(macID)) as? [String: Any]
        let thisMac = Mac(id: macID, name: computerName(), updatedAt: thisSlot?["updatedAt"] as? Date ?? now(), isThisMac: true)
        totals = sum
        macs = [thisMac] + others.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: - 手元の状態

    private var macID: String? { local.string(forKey: Self.macIDDefaultsKey) }

    /// 手元に記録した世代番号（記録がなければ最初の世代の1）
    private var localGeneration: Int {
        let stored = local.integer(forKey: Self.generationDefaultsKey)
        return stored == 0 ? 1 : stored
    }

    private func readCloudGeneration() -> Int? {
        cloud.object(forKey: Self.generationKey) as? Int
    }

    private func leaveSync() {
        local.removeObject(forKey: Self.macIDDefaultsKey)
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

    private func reportMalformed(key: String, value: Any) {
        logger.error("iCloud上の値の形式が想定と異なります: \(key, privacy: .public) = \(String(describing: value), privacy: .public)")
        lastError = .malformedValue(key: key)
    }

    private static func macKey(_ id: String) -> String { macKeyPrefix + id }
    private static func removedKey(_ id: String) -> String { removedKeyPrefix + id }
}
