// ICloudUsageStore.swift
// 使用回数の同期を、iCloud KVSとmacOSにつなぐ部分（KVS、変更通知、iCloudのサインイン状態、コンピュータ名）

import Foundation
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

/// iCloud KVSの変更通知とiCloudのサインイン状態を、UsageSyncに伝える
final class ICloudUsageSyncConnection {
    private let sync: UsageSync
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "io.tmstack.EmojiBako", category: "UsageSync")

    init(sync: UsageSync) {
        self.sync = sync
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] note in
            self?.handleExternalChange(note)
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateSignInStatus()
        })
        updateSignInStatus()
        // falseはentitlementがないなど、KVSを使えないことを示す
        if !NSUbiquitousKeyValueStore.default.synchronize() {
            logger.error("iCloud KVSを使えません（synchronize()がfalse）")
            sync.cloudStoreDidBecomeUnavailable()
        }
    }

    /// 変更通知のuserInfoから理由を読む。未知の理由ならnil
    static func reason(from userInfo: [AnyHashable: Any]?) -> UsageSync.CloudChangeReason? {
        switch userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
        case NSUbiquitousKeyValueStoreServerChange: return .serverChange
        case NSUbiquitousKeyValueStoreInitialSyncChange: return .initialSync
        case NSUbiquitousKeyValueStoreQuotaViolationChange: return .quotaViolation
        case NSUbiquitousKeyValueStoreAccountChange: return .accountChange
        default: return nil
        }
    }

    private func handleExternalChange(_ note: Notification) {
        guard let reason = Self.reason(from: note.userInfo) else {
            // macOSが将来理由を増やした場合など。通知1件の処理を諦め、次の通知を待つ
            logger.fault("iCloud KVSの変更通知の理由を解釈できません: \(String(describing: note.userInfo), privacy: .public)")
            return
        }
        sync.cloudDidChange(reason: reason)
    }

    private func updateSignInStatus() {
        sync.iCloudSignInDidChange(signedIn: FileManager.default.ubiquityIdentityToken != nil)
    }
}

/// コンピュータ名（システム設定の「一般」→「共有」）の取得と、変更の検出
final class ComputerNameMonitor {
    private let onChange: () -> Void
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    static func current() -> String {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String? else {
            preconditionFailure("コンピュータ名を取得できません")
        }
        return name
    }

    /// 変更の検出を始める。このオブジェクトは検出を続けるあいだ保持しておくこと
    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "io.tmstack.EmojiBako" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<ComputerNameMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
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
