// ICloudUsageStore.swift
// 使用回数の同期を、iCloud KVSとmacOSにつなぐ部分（KVS、変更通知、Appleアカウント、コンピュータ名、ハードウェアの識別子）

import Foundation
import Combine
import IOKit
import SystemConfiguration
import os

/// NSUbiquitousKeyValueStoreを、使用回数の同期の保存先として使う
final class ICloudKeyValueStore: UsageCloudStore {
    private let store = NSUbiquitousKeyValueStore.default

    func object(forKey key: String) -> Any? { store.object(forKey: key) }
    func set(_ value: Any, forKey key: String) { store.set(value, forKey: key) }
    func removeObject(forKey key: String) { store.removeObject(forKey: key) }
    var allKeys: [String] { Array(store.dictionaryRepresentation.keys) }
}

/// 同期がオンのあいだだけ、iCloud KVSの変更通知とAppleアカウントの状態をUsageSyncに伝える。
/// 同期がオフのあいだはiCloud KVSに触れない（通信しない）
@MainActor
final class ICloudUsageSyncConnection {
    private let sync: UsageSync
    private var observers: [NSObjectProtocol] = []
    private var enabledSubscription: AnyCancellable?
    private let logger = Logger(subsystem: "io.tmstack.EmojiBako", category: "UsageSync")

    init(sync: UsageSync) {
        self.sync = sync
    }

    func start() {
        sync.start(iCloudIdentity: Self.currentIdentity())
        enabledSubscription = sync.$isEnabled.removeDuplicates().sink { [weak self] enabled in
            if enabled { self?.connect() } else { self?.disconnect() }
        }
    }

    /// 変更通知のuserInfoから理由を読む。未知の理由ならnil
    nonisolated static func reason(from userInfo: [AnyHashable: Any]?) -> UsageSync.CloudChangeReason? {
        switch userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
        case NSUbiquitousKeyValueStoreServerChange: return .serverChange
        case NSUbiquitousKeyValueStoreInitialSyncChange: return .initialSync
        case NSUbiquitousKeyValueStoreQuotaViolationChange: return .quotaViolation
        case NSUbiquitousKeyValueStoreAccountChange: return .accountChange
        default: return nil
        }
    }

    /// 今のAppleアカウントを表すデータ（サインインしていなければnil）
    static func currentIdentity() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
        } catch {
            preconditionFailure("Appleアカウントの識別子を保存できる形にできません: \(error)")
        }
    }

    private func connect() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] note in
            let reason = Self.reason(from: note.userInfo)
            let userInfo = String(describing: note.userInfo)
            MainActor.assumeIsolated { self?.handleExternalChange(reason: reason, userInfo: userInfo) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccountState() }
        })
        refreshAccountState()
    }

    private func disconnect() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func handleExternalChange(reason: UsageSync.CloudChangeReason?, userInfo: String) {
        guard let reason else {
            // macOSが将来理由を増やした場合など。通知1件の処理を諦め、次の通知を待つ
            logger.fault("iCloud KVSの変更通知の理由を解釈できません: \(userInfo, privacy: .public)")
            return
        }
        sync.cloudDidChange(reason: reason)
    }

    /// サインイン状態と、iCloud KVSを使えるかどうかを読み直す
    private func refreshAccountState() {
        let identity = Self.currentIdentity()
        sync.iCloudSignInDidChange(signedIn: identity != nil, identity: identity)
        // falseはentitlementがないなど、KVSを使えないことを示す
        let available = NSUbiquitousKeyValueStore.default.synchronize()
        if !available { logger.error("iCloud KVSを使えません（synchronize()がfalse）") }
        sync.cloudStoreAvailabilityDidChange(available: available)
    }
}

/// コンピュータ名（システム設定の「一般」→「共有」）の取得と、変更の検出
@MainActor
final class ComputerNameMonitor {
    private let onChange: (String) -> Void
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
    }

    static func current() -> String {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String? else {
            preconditionFailure("コンピュータ名を取得できません")
        }
        return name
    }

    /// 変更の検出を始める。このオブジェクトはアプリの終了まで保持すること（コールバックは保持していない参照を使う）
    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "io.tmstack.EmojiBako" as CFString, { _, _, info in
            guard let info else { return }
            // メインのRunLoopに登録しているので、メインスレッドで呼ばれる
            MainActor.assumeIsolated {
                Unmanaged<ComputerNameMonitor>.fromOpaque(info).takeUnretainedValue().onChange(ComputerNameMonitor.current())
            }
        }, &context) else {
            preconditionFailure("コンピュータ名の変更を検出できません: \(String(cString: SCErrorString(SCError())))")
        }
        let key = SCDynamicStoreKeyCreateComputerName(nil)
        guard SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
            preconditionFailure("コンピュータ名の変更を検出できません: \(String(cString: SCErrorString(SCError())))")
        }
        // メニューの表示中なども通知を受けるため、commonModesに登録する
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        self.source = source
    }
}

/// このMacのハードウェアの識別子（IOPlatformUUID）。移行アシスタントなどで写ってきた保存データを見分けるのに使う
enum MacHardware {
    static func platformUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { preconditionFailure("IOPlatformExpertDeviceが見つかりません") }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            preconditionFailure("IOPlatformUUIDを取得できません")
        }
        return uuid
    }
}
