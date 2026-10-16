// HotKey.swift
// ピッカーを呼び出すグローバルホットキーの定義・検証・保存・登録

import AppKit
import Carbon.HIToolbox
import Combine

/// キーコードとCarbonの修飾キーの組み合わせ
struct HotKey: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let defaultValue = HotKey(keyCode: UInt32(kVK_ANSI_Period), carbonModifiers: UInt32(cmdKey))

    /// キー入力イベントから作る（ホットキーに使わない修飾キーは無視する）
    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// ⌘・⌥・⌃のいずれかを含むか。Shiftだけや修飾キーなしでは普段の文字入力を奪ってしまう
    var hasRequiredModifier: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// 「⌃⌥⇧⌘.」のような表示用の文字列（修飾キーの並びはmacOSのメニューと同じ順）
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        // 表示名を引けないキーは記録時に拒否しているが、記録後にキーボード配列を変えた場合に備えてキーコードで示す
        return result + (Self.keyName(for: keyCode) ?? "#\(keyCode)")
    }

    /// 表示できる名前があるキーか（ホットキーとして記録してよいか）
    var hasDisplayableKey: Bool {
        Self.keyName(for: keyCode) != nil
    }

    /// 文字を入力しないキーの表示名
    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧", kVK_Help: "Help",
        kVK_JIS_Eisu: "英数", kVK_JIS_Kana: "かな",
    ]

    /// 現在のキーボード配列でキーコードが入力する文字（配列によって表示が変わるため毎回引く）。
    /// 文字を返さないキーや制御文字・機能キー用の私用領域（U+F700台）を返すキーはnil
    private static func keyName(for keyCode: UInt32) -> String? {
        if let name = specialKeyNames[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            fatalError("キーボード配列を取得できません")
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer in
            UCKeyTranslate(
                buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr else {
            fatalError("キーコード\(keyCode)の文字を取得できません（\(status)）")
        }
        let printable = (0..<length).allSatisfy { chars[$0] >= 0x20 && chars[$0] != 0x7F && !(0xF700...0xF8FF).contains(chars[$0]) }
        guard length > 0, printable else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

enum HotKeyValidationError: LocalizedError, Equatable {
    case missingModifier
    case unsupportedKey
    case reservedBySystem
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingModifier: return String(localized: "⌘・⌥・⌃のいずれかを含めてください")
        case .unsupportedKey: return String(localized: "このキーはショートカットに使えません")
        case .reservedBySystem: return String(localized: "macOSのショートカットで使われています")
        case .registrationFailed(let status): return String(localized: "ホットキーを登録できませんでした（\(Int(status))）")
        }
    }
}

enum HotKeyValidator {
    /// 修飾キーと、macOS自体のショートカット（システム設定の「キーボードショートカット」で有効なもの）との重複を確かめる。
    /// 他のアプリが登録したホットキーとの重複は、macOSが情報を提供しないため検出できない
    static func validate(_ hotKey: HotKey) -> HotKeyValidationError? {
        if !hotKey.hasRequiredModifier { return .missingModifier }
        if !hotKey.hasDisplayableKey { return .unsupportedKey }
        if systemHotKeys().contains(hotKey) { return .reservedBySystem }
        return nil
    }

    private static func systemHotKeys() -> [HotKey] {
        var unmanaged: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&unmanaged)
        guard status == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            fatalError("macOSのショートカット一覧を取得できません（\(status)）")
        }
        return array.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int else { return nil }
            // 一覧の修飾キーには、ホットキーの判定に使わないビット（Fnなど）が含まれることがある
            let relevant = UInt32(modifiers) & UInt32(cmdKey | optionKey | controlKey | shiftKey)
            return HotKey(keyCode: UInt32(code), carbonModifiers: relevant)
        }
    }
}

/// 設定したホットキーの保存先。設定画面とAppDelegateが共有する
final class HotKeyStore: ObservableObject {
    static let shared = HotKeyStore(defaults: .standard)

    private static let defaultsKey = "hotKey"
    private let defaults: UserDefaults

    @Published private(set) var hotKey: HotKey
    /// 設定画面でキーを記録している間はtrue（記録中は登録済みのホットキーを外し、押したキーを奪わないようにする）
    @Published var isRecording = false
    /// 直近の登録の失敗（成功したらnil）
    @Published var registrationError: HotKeyValidationError?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                hotKey = try JSONDecoder().decode(HotKey.self, from: data)
            } catch {
                fatalError("保存されたホットキーを読み込めません: \(error)")
            }
        } else {
            hotKey = .defaultValue
        }
    }

    func save(_ hotKey: HotKey) {
        do {
            defaults.set(try JSONEncoder().encode(hotKey), forKey: Self.defaultsKey)
        } catch {
            fatalError("ホットキーを保存できません: \(error)")
        }
        self.hotKey = hotKey
    }
}

/// Carbonのホットキー登録を1つだけ管理する。
/// イベントハンドラにはselfを保持せずに渡し、ハンドラも外さないため、アプリの寿命のあいだ1つだけ作って保持し続けること（AppDelegateが保持する）
final class HotKeyRegistrar {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private let onPressed: () -> Void

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
    }

    /// 登録済みのホットキーを外してから登録する。失敗した場合は何も登録されていない状態になる
    func register(_ hotKey: HotKey) -> HotKeyValidationError? {
        installHandlerIfNeeded()
        unregister()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x454D4F4A), id: 1) // "EMOJ"
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return .registrationFailed(status) }
        hotKeyRef = ref
        return nil
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            let registrar = Unmanaged<HotKeyRegistrar>.fromOpaque(context!).takeUnretainedValue()
            registrar.onPressed()
            return noErr
        }, 1, &eventType, context, nil)
        guard status == noErr else {
            fatalError("ホットキーのイベントハンドラを登録できません（\(status)）")
        }
        handlerInstalled = true
    }
}
