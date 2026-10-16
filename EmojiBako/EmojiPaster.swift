// EmojiPaster.swift
// 選んだ絵文字を、クリップボードと⌘Vで作業中のアプリに入力する

import AppKit

final class EmojiPaster {
    static let shared = EmojiPaster()

    static let restoreDelayDefaultsKey = "clipboardRestoreDelay"
    /// 設定画面で選べる、⌘Vを送ってから元のクリップボードを書き戻すまでの秒数
    static let restoreDelayChoices: [Double] = [0.5, 1, 2, 3]

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let sendPasteKeystroke: () -> Void
    /// 書き戻しを待っている元のクリップボードと、絵文字を置いた時点のchangeCount
    private var pending: (snapshot: PasteboardSnapshot, emojiChangeCount: Int, restore: DispatchWorkItem)?

    init(pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard, sendPasteKeystroke: @escaping () -> Void = EmojiPaster.sendCommandV) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.sendPasteKeystroke = sendPasteKeystroke
        defaults.register(defaults: [Self.restoreDelayDefaultsKey: 1.0])
    }

    /// 絵文字をクリップボードに置いて⌘Vを送り、設定した時間のあとに元のクリップボードを書き戻す。
    /// 呼び出し側はピッカーを閉じ、元のアプリにフォーカスを戻しておく
    func paste(_ emoji: String) {
        let snapshot: PasteboardSnapshot
        if let pending, pasteboard.changeCount == pending.emojiChangeCount {
            // 前の絵文字の書き戻しを待っているあいだに選ばれた。いまのクリップボードは前の絵文字なので退避せず、元の内容を引き継ぐ
            pending.restore.cancel()
            snapshot = pending.snapshot
        } else {
            // 待っている書き戻しがあっても、利用者が別の内容をコピーしたあとなので、その書き戻しは不要
            pending?.restore.cancel()
            snapshot = PasteboardSnapshot(of: pasteboard)
        }
        let emojiChangeCount = PasteboardSnapshot.writeTransient(emoji, to: pasteboard)

        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 後から選ばれた絵文字の待ち状態は消さない
            if self.pending?.emojiChangeCount == emojiChangeCount {
                self.pending = nil
            }
            // 待つあいだに利用者が別の内容をコピーしていたら、そちらを残す
            if self.pasteboard.changeCount == emojiChangeCount {
                snapshot.restore(to: self.pasteboard)
            }
        }
        pending = (snapshot, emojiChangeCount, restore)

        let delay = defaults.double(forKey: Self.restoreDelayDefaultsKey)
        // フォーカスが元のアプリに戻るのを待ってから⌘Vを送る
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.sendPasteKeystroke()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: restore)
        }
    }

    static func sendCommandV() {
        let keyCode = KeyboardLayout.shortcutKeyCode(for: "v")
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                fatalError("⌘Vのキーイベントを作れません")
            }
            event.flags = .maskCommand
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
