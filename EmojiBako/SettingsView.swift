import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 一般設定
            GroupBox(label: Text("一般").fontWeight(.semibold)) {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }
                    .padding(.vertical, 4)
            }
            
            // キーボード
            GroupBox(label: Text("キーボード").fontWeight(.semibold)) {
                HStack {
                    Text("ショートカット")
                    Spacer()
                    Text("⌘ .")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
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
            }
            
            Spacer()
        }
        .padding(20)
        .frame(width: 350, height: 240)
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
