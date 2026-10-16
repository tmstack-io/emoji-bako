// SearchField.swift
// IMEで変換中の文字列も含めて入力を通知する検索欄

import SwiftUI
import AppKit

/// SwiftUIのTextFieldは変換を確定するまで値を更新しないため、NSTextFieldを包んで
/// 変換中のひらがなでも絞り込めるようにする
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    /// ウィンドウで入力を受けている欄に、IMEで変換中の文字列があるかどうか
    static func isComposing(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.coordinator = context.coordinator
        // 検索バーが表示されたら入力欄にフォーカスを当てる（ウィンドウへの追加を待つ）
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        // クリアボタンなどで外から値が変わったときだけ反映する（変換中の表示を上書きしないため）
        if context.coordinator.lastReportedText != text {
            context.coordinator.lastReportedText = text
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator {
        private let text: Binding<String>
        /// 最後に入力欄から通知した文字列（変換中の文字列を含む）
        var lastReportedText = ""
        private var observation: NSObjectProtocol?

        init(text: Binding<String>) {
            self.text = text
        }

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }

        /// 入力欄の編集を受け持つフィールドエディタの文字列の変化を監視する。
        /// controlTextDidChangeは変換中の文字列の変化では呼ばれないが、変換中の文字列もtextStorageには入るため、こちらで拾う
        func observe(_ editor: NSTextView) {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: editor.textStorage,
                queue: nil
            ) { [weak self, weak editor] _ in
                guard let self, let editor, editor.string != self.lastReportedText else { return }
                self.lastReportedText = editor.string
                self.text.wrappedValue = editor.string
            }
        }
    }
}

/// フォーカスを得たときに、編集を受け持つフィールドエディタをCoordinatorに渡すNSTextField
final class SearchTextField: NSTextField {
    var coordinator: SearchField.Coordinator?

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let editor = currentEditor() as? NSTextView {
            coordinator?.observe(editor)
        }
        return true
    }
}
