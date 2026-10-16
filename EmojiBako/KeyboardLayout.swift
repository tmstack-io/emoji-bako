// KeyboardLayout.swift
// ⌘ショートカットに使われるキーボード配列での、文字とキーコードの対応

import Carbon.HIToolbox

enum KeyboardLayout {
    /// ⌘ショートカットに使われる配列（ASCIIを入力できる配列）で、指定した英小文字を入力するキーコード。
    /// Dvorakなどでは位置がQWERTYと異なり、ロシア語配列や「かな入力」では文字そのものが英字にならないため、キーコードも文字も直接は使えない。
    /// 「Dvorak - QWERTY ⌘」のように⌘を押すとQWERTYになる配列では、実際の⌘ショートカットと位置がずれる
    static func shortcutKeyCode(for character: Character) -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            fatalError("キーボード配列を取得できません")
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        let target = Array(String(character).utf16)
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
            if status == noErr, Array(chars.prefix(length)) == target {
                return CGKeyCode(keyCode)
            }
        }
        fatalError("キーボード配列に「\(character)」を入力するキーがありません")
    }
}
