// EmojiPaster.swift
// 選んだ絵文字を、クリップボードと⌘Vで作業中のアプリに入力する

import AppKit
import Carbon.HIToolbox

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
            snapshot = PasteboardSnapshot(of: pasteboard)
        }
        let emojiChangeCount = PasteboardSnapshot.writeTransient(emoji, to: pasteboard)

        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
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
        let keyCode = keyCodeForV()
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                fatalError("⌘Vのキーイベントを作れません")
            }
            event.flags = .maskCommand
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// ⌘ショートカットに使われる配列で「v」を入力するキーコード。
    /// Dvorakなどでは「v」の位置がQWERTYと異なるため、物理的な位置（kVK_ANSI_V）ではなく配列から引く
    static func keyCodeForV() -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            fatalError("キーボード配列を取得できません")
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        for keyCode in UInt16(0)...127 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = layoutData.withUnsafeBytes { buffer in
                UCKeyTranslate(
                    buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress, keyCode, UInt16(kUCKeyActionDown), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
                )
            }
            if status == noErr, length == 1, chars[0] == UniChar(UInt8(ascii: "v")) {
                return CGKeyCode(keyCode)
            }
        }
        fatalError("キーボード配列に「v」を入力するキーがありません")
    }
}
