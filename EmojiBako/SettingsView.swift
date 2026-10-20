import SwiftUI
import ServiceManagement

struct SettingsView: View {
    /// SMAppServiceの実際の状態（トグルはこれを表示し、操作のたびに読み直す）
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    /// 直近の「ログイン時に起動」の操作の失敗
    @State private var launchAtLoginError: String?
    @AppStorage(UpdateChecker.autoCheckDefaultsKey) private var autoCheckUpdates = true
    @AppStorage(EmojiPaster.restoreDelayDefaultsKey) private var clipboardRestoreDelay = 1.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 一般設定
            GroupBox(label: Text("一般").fontWeight(.semibold)) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("ログイン時に起動", isOn: Binding(
                        get: { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval },
                        set: { setLaunchAtLogin(enabled: $0) }
                    ))
                    if launchAtLoginStatus == .requiresApproval {
                        HStack {
                            Text("システム設定の「ログイン項目」で許可が必要です。")
                            Button("ログイン項目を開く") { SMAppService.openSystemSettingsLoginItems() }
                        }
                        .font(.caption)
                    }
                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
                Toggle("アップデートを自動で確認する", isOn: $autoCheckUpdates)
                    .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Picker("クリップボードを元に戻すまでの時間", selection: $clipboardRestoreDelay) {
                        ForEach(EmojiPaster.restoreDelayChoices, id: \.self) { seconds in
                            Text("\(seconds.formatted())秒").tag(seconds)
                        }
                    }
                    Text("絵文字ではなく元の内容が貼り付けられる場合は、長くしてください。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            // キーボード
            GroupBox(label: Text("キーボード").fontWeight(.semibold)) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ショートカット")
                    Spacer()
                    HotKeyRecorder(store: HotKeyStore.shared)
                }
                .padding(.vertical, 4)
            }
            
            // 使用回数
            GroupBox(label: Text("使用回数").fontWeight(.semibold)) {
                UsageSettingsView(sync: EmojiData.shared.usageSync)
            }

            // 情報
            GroupBox(label: Text("情報").fontWeight(.semibold)) {
                HStack {
                    Text("バージョン")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                Link("ウェブサイト", destination: URL(string: "https://tmstack-io.github.io/emoji-bako/")!)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("EmojiBakoはMITライセンスで公開しています。絵文字の名前とキーワードには、Unicode, Inc.のデータ（Unicode License v3）を使用しています。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("MITライセンス") { openBundledLicense("LICENSE", extension: nil) }
                        Button("Unicodeライセンス") { openBundledLicense("LICENSE-UNICODE", extension: "txt") }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
            
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            launchAtLoginStatus = SMAppService.mainApp.status
        }
        // システム設定のログイン項目で許可して戻ってきたときに、表示を実際の状態に合わせる
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLoginStatus = SMAppService.mainApp.status
        }
    }
    
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = String(localized: "ログイン時の起動を変更できませんでした: \(error.localizedDescription)")
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }
    
    /// アプリに同梱したライセンス本文を既定のテキストエディタで開く。同梱はproject.ymlで保証しているので、なければビルドの誤りとして停止する
    private func openBundledLicense(_ name: String, extension ext: String?) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            fatalError("\(name)がバンドルにありません")
        }
        NSWorkspace.shared.open(url)
    }

    /// Info.plistのCFBundleShortVersionString。project.ymlで必ず設定されるため、欠けていればビルド設定の誤りとして停止する
    private var appVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            fatalError("CFBundleShortVersionStringがInfo.plistにありません")
        }
        return version
    }

}

#Preview {
    SettingsView()
}
