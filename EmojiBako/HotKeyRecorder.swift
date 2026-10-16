// HotKeyRecorder.swift
// 設定画面で押したキーの組み合わせをホットキーとして記録する

import SwiftUI
import Carbon.HIToolbox

struct HotKeyRecorder: View {
    @ObservedObject var store: HotKeyStore
    @State private var monitor: Any?
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
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        rejection = nil
        store.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording()
                return nil
            }
            let hotKey = HotKey(event: event)
            if let error = HotKeyValidator.validate(hotKey) {
                rejection = error
                return nil
            }
            store.save(hotKey)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        store.isRecording = false
    }
}
