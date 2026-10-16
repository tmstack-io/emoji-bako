import SwiftUI
import Carbon.HIToolbox

struct EmojiPickerView: View {
    @StateObject private var emojiData = EmojiData.shared
    @State private var selectedCategoryIndex = 0
    @State private var selectedEmojiIndex = 0
    @State private var currentEmojis: [EmojiItem] = []

    // 検索モード関連
    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""

    // キーボードイベントモニター（多重登録防止のため保持→onDisappearで解除）
    @State private var keyMonitor: Any?

    var onClose: (() -> Void)? = nil
    /// アクセシビリティ権限がないまま絵文字が選ばれたときに呼ぶ（ピッカーは閉じたあと）
    var onAccessibilityMissing: (() -> Void)? = nil

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 4), count: 8)

    /// 上部バー（カテゴリタブ／検索バー）の固定高さ。
    /// CategoryTab(32) + 上下余白(8×2) = 48 を想定。検索モード切替時にレイアウトを不動に保つ。
    private let topBarHeight: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            // 上部: 検索モード時は検索バー、通常時はカテゴリタブ
            if isSearching {
                searchBar
            } else {
                categoryTabs
            }

            Divider()

            // 絵文字グリッド
            ScrollViewReader { proxy in
                ScrollView {
                    if currentEmojis.isEmpty && isSearching && !searchQuery.isEmpty {
                        // 検索結果ゼロ
                        Text("該当する絵文字がありません")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                            .padding(.vertical, 40)
                            .frame(maxWidth: .infinity)
                    } else {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(Array(currentEmojis.enumerated()), id: \.offset) { index, item in
                                EmojiButton(
                                    item: item,
                                    isSelected: selectedEmojiIndex == index,
                                    action: {
                                        selectEmoji(item)
                                    }
                                )
                                .id(index)
                            }
                        }
                        .padding(8)
                    }
                }
                .onChange(of: selectedEmojiIndex) { _, newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 320, height: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            updateCurrentEmojis()
            setupKeyboardHandler()
        }
        .onDisappear {
            teardownKeyboardHandler()
        }
        .onChange(of: emojiData.usageCounts) {
            guard !isSearching, selectedCategoryIndex < emojiData.categories.count else { return }
            if emojiData.categories[selectedCategoryIndex].id == "favorites" {
                updateCurrentEmojis()
            }
        }
        .onChange(of: searchQuery) {
            if isSearching {
                updateCurrentEmojis()
            }
        }
        .onChange(of: isSearching) {
            updateCurrentEmojis()
        }
    }

    // MARK: - サブビュー

    private var categoryTabs: some View {
        // Tab/Shift+Tab でカテゴリを切り替えた際、画面外にあるタブもスクロールで追従させる
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(emojiData.categories.enumerated()), id: \.element.id) { index, category in
                        CategoryTab(
                            category: category,
                            isSelected: selectedCategoryIndex == index,
                            action: {
                                selectedCategoryIndex = index
                                selectedEmojiIndex = 0
                                updateCurrentEmojis()
                            }
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: topBarHeight)
            .background(Color(NSColor.controlBackgroundColor))
            .onAppear {
                // 表示直後、現在選択中のカテゴリがウィンドウ外に隠れていないようにする
                proxy.scrollTo(selectedCategoryIndex, anchor: .center)
            }
            .onChange(of: selectedCategoryIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
            // Enterでの確定はキーボードハンドラが受け持つ
            SearchField(text: $searchQuery, placeholder: String(localized: "絵文字を検索"))
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("クリア")
            }
            Button(action: { exitSearch() }) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("検索を終了 (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: topBarHeight)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - データ更新

    private func updateCurrentEmojis() {
        if isSearching {
            currentEmojis = filteredEmojis(query: searchQuery)
        } else {
            guard selectedCategoryIndex < emojiData.categories.count else {
                currentEmojis = []
                return
            }
            let category = emojiData.categories[selectedCategoryIndex]
            if category.id == "favorites" {
                currentEmojis = emojiData.getFavorites()
            } else {
                currentEmojis = category.emojis
            }
        }
        selectedEmojiIndex = min(selectedEmojiIndex, max(0, currentEmojis.count - 1))
    }

    private func filteredEmojis(query: String) -> [EmojiItem] {
        EmojiSearch.search(query, in: emojiData.searchIndex, usageCounts: emojiData.usageCounts)
    }

    // MARK: - 選択・貼り付け

    private func selectEmoji(_ item: EmojiItem) {
        // 権限がないと⌘Vを送れず何も起きないため、クリップボードには触らずに案内を出す
        guard AccessibilityPermission.isGranted else {
            onClose?()
            onAccessibilityMissing?()
            return
        }
        let emoji = item.char
        emojiData.incrementUsage(for: emoji)

        // 元のクリップボードを全形式のまま退避し、絵文字を一時的に置く
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(of: pasteboard)
        let emojiChangeCount = PasteboardSnapshot.writeTransient(emoji, to: pasteboard)

        // ウィンドウを閉じる（元アプリにフォーカスが戻る）
        onClose?()

        // 少し待ってからCmd+Vを送信
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)

            // V key = 0x09
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }

            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }

            // 元のクリップボードを復元する。待つあいだに利用者が別の内容をコピーしていたら、そちらを残す
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if pasteboard.changeCount == emojiChangeCount {
                    snapshot.restore(to: pasteboard)
                }
            }
        }
    }

    // MARK: - 検索モード制御

    private func enterSearch() {
        isSearching = true
        selectedEmojiIndex = 0
    }

    private func exitSearch() {
        isSearching = false
        searchQuery = ""
        selectedEmojiIndex = 0
    }

    // MARK: - キーボードハンドリング

    private func setupKeyboardHandler() {
        // NSWindowの開閉ではonAppearは呼ばれないが、ビューが作り直されたときに多重登録しないよう、既存があればまず解除する。
        teardownKeyboardHandler()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return self.handleKeyEvent(event)
        }
    }

    private func teardownKeyboardHandler() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let columnsCount = 8

        // ローカルモニタはアプリのすべてのウィンドウのキー入力を受け取るため、ピッカー以外（設定画面など）の入力には触らない
        guard event.window is FloatingPanel else {
            return event
        }

        // IMEで変換中のキー入力（候補の選択・確定・取り消し）はすべてIMEに渡す
        if SearchField.isComposing(in: event.window) {
            return event
        }

        // Cmd+F は検索モードのトグル（通常モード/検索モードどちらでも消費）
        if event.modifierFlags.contains(.command) && event.keyCode == UInt16(kVK_ANSI_F) {
            if isSearching {
                exitSearch()
            } else {
                enterSearch()
            }
            return nil
        }

        switch event.keyCode {
        case 123: // Left arrow
            if selectedEmojiIndex > 0 {
                selectedEmojiIndex -= 1
            }
            return nil
        case 124: // Right arrow
            if selectedEmojiIndex < currentEmojis.count - 1 {
                selectedEmojiIndex += 1
            }
            return nil
        case 125: // Down arrow
            let newIndex = selectedEmojiIndex + columnsCount
            if newIndex < currentEmojis.count {
                selectedEmojiIndex = newIndex
            }
            return nil
        case 126: // Up arrow
            let newIndex = selectedEmojiIndex - columnsCount
            if newIndex >= 0 {
                selectedEmojiIndex = newIndex
            }
            return nil
        case 36: // Enter
            if !currentEmojis.isEmpty && selectedEmojiIndex < currentEmojis.count {
                selectEmoji(currentEmojis[selectedEmojiIndex])
            }
            return nil
        case 53: // Escape
            if isSearching {
                exitSearch()
            } else {
                onClose?()
            }
            return nil
        case 48: // Tab
            // 検索モード中はカテゴリ切替を無効化（検索結果を維持）
            if isSearching { return nil }
            if event.modifierFlags.contains(.shift) {
                selectedCategoryIndex = (selectedCategoryIndex - 1 + emojiData.categories.count) % emojiData.categories.count
            } else {
                selectedCategoryIndex = (selectedCategoryIndex + 1) % emojiData.categories.count
            }
            selectedEmojiIndex = 0
            updateCurrentEmojis()
            return nil
        default:
            // 文字キー等は下流（検索モード時は TextField）に渡す
            return event
        }
    }
}

struct CategoryTab: View {
    let category: EmojiCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: category.icon)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(isSelected ? Color.accentColor : Color.clear)
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        // カテゴリ名は絵文字データのIDに対応する英語の表示名で、String Catalogで翻訳する
        .help(LocalizedStringKey(category.name))
    }
}

struct EmojiButton: View {
    let item: EmojiItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(item.char)
                .font(.system(size: 24))
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .help(item.localizedName)
    }
}

#Preview {
    EmojiPickerView()
}
