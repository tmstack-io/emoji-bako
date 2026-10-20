// UsageSettingsView.swift
// 設定画面の「使用回数」: 使用回数の同期のオンとオフ、同期中のMacの一覧、リセット、バックアップ

import SwiftUI
import UniformTypeIdentifiers

struct UsageSettingsView: View {
    @ObservedObject var sync: UsageSync

    @State private var confirmingResetAllMacs = false
    @State private var confirmingResetThisMac = false
    @State private var macToRemove: UsageSync.Mac?
    /// 読み込む前の確認画面に出しているバックアップ
    @State private var backupToRestore: UsageBackup?
    /// 書き出し・読み込みに失敗したときに出す説明
    @State private var backupFailure: BackupFailure?

    /// 書き出し・読み込みの失敗
    private struct BackupFailure {
        let title: String
        let message: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("iCloudで使用回数を同期する", isOn: Binding(
                    get: { sync.isEnabled },
                    set: { enabled in
                        // 表示が古いまま押された場合に二重に切り替えない
                        guard enabled != sync.isEnabled else { return }
                        enabled ? sync.enable() : sync.disable()
                    }
                ))
                Text("オンにすると、使用回数とこのMacのコンピュータ名をあなたのiCloudに保存し、同じAppleアカウントのMac同士でよく使う絵文字をそろえます。")
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

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button("使用回数を書き出す…") { exportBackup() }
                    Button("使用回数を読み込む…") { chooseBackupToRestore() }
                }
                .controlSize(.small)
                Text("このMacで数えた使用回数をファイルに書き出し、あとで戻せます。同期中でも、ほかのMacの使用回数は含みません。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        // 確認画面を開いているあいだに、ほかのMacでこのMacが同期から外された場合などは、同期中の操作を取りやめる
        .onChange(of: sync.isEnabled) {
            confirmingResetAllMacs = false
            macToRemove = nil
        }
        .alert("すべてのMacの使用回数をリセットしますか？", isPresented: $confirmingResetAllMacs) {
            Button("リセット", role: .destructive) {
                if sync.isEnabled { sync.resetAllMacs() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("同期しているすべてのMacの使用回数を消します。オフラインのMacでまだ届いていない使用回数も消えます。この操作は取り消せません。")
        }
        .alert("このMacの使用回数をリセットしますか？", isPresented: $confirmingResetThisMac) {
            Button("リセット", role: .destructive) { sync.resetThisMac() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if sync.isEnabled {
                Text("このMacで数えた使用回数だけを消します。ほかのMacの使用回数は残るため、よく使う絵文字が大きくは変わらないことがあります。この操作は取り消せません。")
            } else {
                Text("このMacの使用回数を消します。この操作は取り消せません。")
            }
        }
        .alert(
            "「\(macToRemove?.name ?? "")」を同期から外しますか？",
            isPresented: Binding(get: { macToRemove != nil }, set: { if !$0 { macToRemove = nil } })
        ) {
            Button("同期から外す", role: .destructive) {
                if let macToRemove, sync.isEnabled { sync.removeMac(id: macToRemove.id) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("そのMacの使用回数を合計から除きます。そのMacでは同期がオフになり、そのMacで数えた使用回数はそのMacに残ります。もう一度同期するには、そのMacで同期をオンにしてください。")
        }
        .alert(
            "このMacの使用回数を置き換えますか？",
            isPresented: Binding(get: { backupToRestore != nil }, set: { if !$0 { backupToRestore = nil } }),
            presenting: backupToRestore
        ) { backup in
            Button("置き換える", role: .destructive) { sync.restore(from: backup) }
            Button("キャンセル", role: .cancel) {}
        } message: { backup in
            restoreConfirmationMessage(for: backup)
        }
        .alert(
            backupFailure?.title ?? "",
            isPresented: Binding(get: { backupFailure != nil }, set: { if !$0 { backupFailure = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(backupFailure?.message ?? "")
        }
    }

    /// 読み込む前の確認画面の説明
    private func restoreConfirmationMessage(for backup: UsageBackup) -> Text {
        let summary = Text("「\(backup.computerName)」で\(backup.exportedAt.formatted(date: .long, time: .shortened))に書き出した使用回数（絵文字\(backup.counts.count)種類）で、このMacの使用回数を置き換えます。この操作は取り消せません。")
        // 同期中のほかのMacのバックアップを読み込むと、そのMacの欄と二重に数えることになる
        guard sync.macs.contains(where: { !$0.isThisMac && $0.name == backup.computerName }) else { return summary }
        return summary + Text(verbatim: "\n\n") + Text("「\(backup.computerName)」は同期中のため、そのMacの使用回数が二重に数えられます。二重に数えたくない場合は、先にそのMacを同期から外してください。")
    }

    /// このMacの使用回数を、保存画面で選んだファイルに書き出す
    private func exportBackup() {
        let backup = sync.makeBackup()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = backup.suggestedFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try backup.encoded().write(to: url, options: .atomic)
        } catch {
            backupFailure = BackupFailure(
                title: String(localized: "使用回数を書き出せませんでした"),
                message: error.localizedDescription
            )
        }
    }

    /// 開く画面で選んだバックアップを読み、確認画面を出す
    private func chooseBackupToRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let title = String(localized: "使用回数を読み込めませんでした")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            backupFailure = BackupFailure(title: title, message: error.localizedDescription)
            return
        }
        do {
            backupToRestore = try UsageBackup.decode(data)
        } catch {
            backupFailure = BackupFailure(title: title, message: error.message)
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
        if sync.isEnabled && sync.isQuotaExceeded {
            Text("EmojiBakoがiCloudに保存できる容量の上限を超えたため、同期できません。")
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if sync.isEnabled && !sync.malformedKeys.isEmpty {
            Text("iCloud上のデータの一部（\(sync.malformedKeys.sorted().joined(separator: ", "))）を読み取れませんでした。そのデータは合計に入れていません。")
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
                        if let updatedAt = mac.updatedAt {
                            Text("最終更新: \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
}
