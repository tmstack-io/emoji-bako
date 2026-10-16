// PasteboardSnapshot.swift
// 絵文字を貼り付ける前のクリップボードを、全項目・全形式のまま退避して書き戻す

import AppKit

struct PasteboardSnapshot {
    /// クリップボード管理アプリに履歴として残さないよう指示する形式（nspasteboard.orgの慣例）
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// 項目ごとの、形式→データ
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(of pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            // 遅延提供（プロミス）の形式は、提供元のアプリがデータを返さないことがあり、その形式は退避できない
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    /// 一時的に置く文字列を、クリップボード管理アプリの履歴に残らない形で書き込む。書き込み後のchangeCountを返す
    static func writeTransient(_ string: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        item.setData(Data(), forType: transientType)
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// 退避した内容を書き戻す。退避時にクリップボードが空だった場合は空に戻す。
    /// 書き戻しを新しいコピーとしてクリップボード管理アプリの履歴に残さないよう、各項目にtransientTypeを付ける
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: type)
            }
            item.setData(Data(), forType: Self.transientType)
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
