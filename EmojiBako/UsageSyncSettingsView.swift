// UsageSyncSettingsView.swift
// 設定画面の「同期」: 使用回数の同期のオンとオフ、同期中のMacの一覧、リセット

import SwiftUI

struct UsageSyncSettingsView: View {
    @ObservedObject var sync: UsageSync

    @State private var confirmingResetAllMacs = false
    @State private var confirmingResetThisMac = false
    @State private var macToRemove: UsageSync.Mac?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("iCloudで使用回数を同期する", isOn: Binding(
                    get: { sync.isEnabled },
                    set: { $0 ? sync.enable() : sync.disable() }
                ))
                Text("オンにすると、使用回数とこのMacのコンピュータ名をあなたのiCloudに保存し、同じApple IDのMac同士でよく使う絵文字をそろえます。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusMessages

            if sync.isEnabled {
                macList
            }

            VStack(alignment: .leading, spacing: 4) {
                if sync.isEnabled {
                    Button("すべてのMacの使用回数をリセット…") { confirmingResetAllMacs = true }
                }
                Button("このMacの使用回数をリセット…") { confirmingResetThisMac = true }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .alert("すべてのMacの使用回数をリセットしますか？", isPresented: $confirmingResetAllMacs) {
            Button("リセット", role: .destructive) { sync.resetAllMacs() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("同期しているすべてのMacの使用回数を消します。オフラインのMacでまだ届いていない使用回数も消えます。この操作は取り消せません。")
        }
        .alert("このMacの使用回数をリセットしますか？", isPresented: $confirmingResetThisMac) {
            Button("リセット", role: .destructive) { sync.resetThisMac() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if sync.isEnabled {
                Text("このMacで数えた使用回数だけを消します。ほかのMacの使用回数は残るため、よく使う絵文字が大きくは変わらないことがあります。")
            } else {
                Text("このMacの使用回数を消します。この操作は取り消せません。")
            }
        }
        .alert(
            "「\(macToRemove?.name ?? "")」を同期から外しますか？",
            isPresented: Binding(get: { macToRemove != nil }, set: { if !$0 { macToRemove = nil } })
        ) {
            Button("同期から外す", role: .destructive) {
                if let macToRemove { sync.removeMac(id: macToRemove.id) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("そのMacの使用回数を合計から除きます。そのMacでは同期がオフになり、そのMacで数えた使用回数はそのMacに残ります。もう一度同期するには、そのMacで同期をオンにしてください。")
        }
    }

    /// iCloudの状態と、同期から外されたことの表示
    @ViewBuilder
    private var statusMessages: some View {
        if sync.wasRemovedByOtherMac {
            HStack(alignment: .firstTextBaseline) {
                Text("ほかのMacで、このMacが同期から外されました。")
                Button("表示を消す") { sync.dismissRemovedNotice() }
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundColor(.orange)
        }
        if sync.isEnabled && !sync.isICloudSignedIn {
            Text("iCloudにサインインしていないため、このMacにだけ記録しています。")
                .font(.caption)
                .foregroundColor(.orange)
        }
        if sync.isEnabled && !sync.isCloudStoreAvailable {
            Text("iCloudを使えないため、このMacにだけ記録しています。")
                .font(.caption)
                .foregroundColor(.red)
        }
        if sync.isEnabled, let error = sync.lastError {
            Text(Self.message(for: error))
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 同期中のMacの一覧
    private var macList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("同期中のMac")
                .font(.subheadline)
            ForEach(sync.macs) { mac in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(mac.name)
                            if mac.isThisMac {
                                Text("このMac")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text("最後に記録: \(mac.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !mac.isThisMac {
                        Button("同期から外す…") { macToRemove = mac }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
    }

    private static func message(for error: UsageSync.SyncError) -> String {
        switch error {
        case .quotaExceeded:
            return String(localized: "iCloudの保存容量の上限を超えたため、同期できません。")
        case .malformedValue(let key):
            return String(localized: "iCloud上のデータの一部（\(key)）を読み取れませんでした。そのデータは合計に入れていません。")
        }
    }
}
