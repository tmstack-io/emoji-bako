// HotKeyRecorder.swift
// 設定画面で押したキーの組み合わせをホットキーとして記録する

import SwiftUI
import Carbon.HIToolbox

struct HotKeyRecorder: View {
    @ObservedObject var store: HotKeyStore
    @State private var session: RecordingSession?
    /// 記録しようとしたキーが使えなかった理由
    @State private var rejection: HotKeyValidationError?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: { store.isRecording ? stopRecording() : startRecording() }) {
                Group {
                    if store.isRecording {
                        Text("キーを押してください（Escで中止）")
                    } else {
                        Text(verbatim: store.hotKey.displayString)
                    }
                }
                .frame(minWidth: 60)
            }
            if let error = rejection ?? store.registrationError {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private func startRecording() {
        // 記録ボタンを押したウィンドウ（設定画面）
        guard let window = NSApp.keyWindow else {
            fatalError("記録ボタンを押したウィンドウがキーウィンドウになっていません")
        }
        rejection = nil
        store.isRecording = true
        session = RecordingSession(
            window: window,
            onKeyDown: { event in
                if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    stopRecording()
                    return
                }
                let hotKey = HotKey(event: event)
                if let error = HotKeyValidator.validate(hotKey) {
                    rejection = error
                    return
                }
                store.save(hotKey)
                stopRecording()
            },
            // NSWindowを閉じてもSwiftUIのonDisappearは呼ばれないため、ウィンドウの通知で記録を止める
            onEnd: { stopRecording() }
        )
    }

    private func stopRecording() {
        session?.invalidate()
        session = nil
        store.isRecording = false
    }
}

/// 記録中だけ有効なキー入力の監視。記録を始めたウィンドウ宛ての入力だけを奪い、
/// そのウィンドウが閉じるかキーウィンドウでなくなったら記録を終える
private final class RecordingSession {
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow, onKeyDown: @escaping (NSEvent) -> Void, onEnd: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            onKeyDown(event)
            return nil
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in onEnd() })
        }
    }

    func invalidate() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
