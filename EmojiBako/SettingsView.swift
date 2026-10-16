import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin: Bool = false
    @AppStorage(UpdateChecker.autoCheckDefaultsKey) private var autoCheckUpdates = true
    @AppStorage(EmojiPaster.restoreDelayDefaultsKey) private var clipboardRestoreDelay = 1.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 一般設定
            GroupBox(label: Text("一般").fontWeight(.semibold)) {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(enabled: newValue)
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
            
            // 情報
            GroupBox(label: Text("情報").fontWeight(.semibold)) {
                HStack {
                    Text("バージョン")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                Link("ウェブサイト", destination: URL(string: "https://tmstack-io.github.io/EmojiBako/")!)
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
            launchAtLogin = getLaunchAtLoginStatus()
        }
    }
    
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
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

    private func getLaunchAtLoginStatus() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }
}

#Preview {
    SettingsView()
}
