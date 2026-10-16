// AccessibilityPermission.swift
// 絵文字の入力（⌘Vの送信）に必要なアクセシビリティ権限の確認と案内

import SwiftUI
import ApplicationServices

enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// EmojiBakoをアクセシビリティの一覧に登録してmacOSの確認ダイアログを出し、システム設定の該当画面を開く。
    /// ダイアログは一度拒否すると出なくなるため、設定画面も必ず開く
    static func requestAndOpenSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// アクセシビリティ権限の案内ウィンドウ。許可されたら自動で閉じる
final class AccessibilityOnboardingController {
    private var window: NSWindow?
    private var timer: Timer?
    private var closeObserver: NSObjectProtocol?

    func show() {
        if window == nil {
            let view = AccessibilityOnboardingView(
                onOpenSettings: { AccessibilityPermission.requestAndOpenSettings() },
                onLater: { [weak self] in self?.close() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "EmojiBako"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            // 閉じるボタンで閉じたときも確認のタイマーを止める
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.stopTimer()
            }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if AccessibilityPermission.isGranted {
                self?.close()
            }
        }
    }

    private func close() {
        stopTimer()
        window?.close()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct AccessibilityOnboardingView: View {
    let onOpenSettings: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("アクセシビリティの許可が必要です")
                .font(.headline)
            Text("EmojiBakoは、選んだ絵文字を作業中のアプリに入力するために、⌘Vのキー操作を送ります。システム設定の「プライバシーとセキュリティ」→「アクセシビリティ」で、EmojiBakoを許可してください。")
                .fixedSize(horizontal: false, vertical: true)
            Text("許可すると、この画面は自動で閉じます。")
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("あとで", action: onLater)
                Button("システム設定を開く", action: onOpenSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
