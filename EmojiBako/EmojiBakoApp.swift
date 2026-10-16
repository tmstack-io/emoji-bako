import SwiftUI
import Combine
import ServiceManagement

@main
struct EmojiBakoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// カスタムウィンドウクラス（キーウィンドウになれるborderlessウィンドウ）
class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var floatingWindow: FloatingPanel?
    var settingsWindow: NSWindow?
    var eventMonitor: Any?
    private var hotKeyRegistrar: HotKeyRegistrar!
    private var hotKeySubscription: AnyCancellable?
    var previousApp: NSRunningApplication?
    let accessibilityOnboarding = AccessibilityOnboardingController()
    let updateChecker = UpdateChecker()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dockアイコンを非表示
        NSApp.setActivationPolicy(.accessory)
        
        // メニューバーアイテムを作成
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "EmojiBako")
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        // フローティングウィンドウを作成
        createFloatingWindow()
        
        // グローバルホットキーを登録する。保存されたキーを登録できなければ、設定画面で選び直してもらう
        setupHotKey()
        if HotKeyStore.shared.registrationError != nil {
            openSettings()
        }

        updateChecker.start()

        // 絵文字の入力にはアクセシビリティ権限が必要なため、未許可なら起動時に案内する
        if !AccessibilityPermission.isGranted {
            accessibilityOnboarding.show()
        }
        
        // 外側クリックで閉じる
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let window = self.floatingWindow, window.isVisible else { return }
            
            let screenClickLocation = NSEvent.mouseLocation
            if !window.frame.contains(screenClickLocation) {
                self.hideWindow()
            }
        }
    }
    
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        
        if event.type == .rightMouseUp {
            // 右クリック: メニュー表示
            showMenu()
        } else {
            // 左クリック: ウィンドウトグル
            toggleWindow()
        }
    }
    
    func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        menu.addItem(NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }
    
    // メニューが閉じたらnilに戻す（左クリック動作を維持）
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
    
    @objc func openSettings() {
        // 設定ウィンドウを作成・表示
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            
            let window = NSWindow(contentViewController: hostingController)
            window.title = "EmojiBako 設定"
            window.styleMask = [.titled, .closable]
            window.center()
            
            self.settingsWindow = window
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
    
    func createFloatingWindow() {
        floatingWindow = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = floatingWindow else { return }
        
        let contentView = EmojiPickerView(
            onClose: { [weak self] in
                self?.hideWindowAndPaste()
            },
            onAccessibilityMissing: { [weak self] in
                self?.accessibilityOnboarding.show()
            }
        )
        
        window.contentViewController = NSHostingController(rootView: contentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        
        // 角丸にする
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 12
        window.contentView?.layer?.masksToBounds = true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        hotKeyRegistrar.unregister()
    }
    
    @objc func toggleWindow() {
        guard let window = floatingWindow else { return }
        
        if window.isVisible {
            hideWindow()
        } else {
            showWindowAtMouseLocation()
        }
    }
    
    func showWindowAtMouseLocation() {
        guard let window = floatingWindow else { return }
        
        // 現在アクティブなアプリを記憶
        previousApp = NSWorkspace.shared.frontmostApplication
        
        // マウスカーソルの位置を取得
        let mouseLocation = NSEvent.mouseLocation
        
        // マウスがあるスクリーンを取得
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        
        // ウィンドウサイズ
        let windowSize = window.frame.size
        
        // マウス位置を中心に、画面内に収まるよう調整
        var windowX = mouseLocation.x - windowSize.width / 2
        var windowY = mouseLocation.y - windowSize.height / 2
        
        // 画面からはみ出ないよう調整
        let screenFrame = screen.visibleFrame
        
        windowX = max(screenFrame.minX, min(windowX, screenFrame.maxX - windowSize.width))
        windowY = max(screenFrame.minY, min(windowY, screenFrame.maxY - windowSize.height))
        
        window.setFrameOrigin(NSPoint(x: windowX, y: windowY))
        window.makeKeyAndOrderFront(nil)
    }
    
    func hideWindow() {
        floatingWindow?.orderOut(nil)
    }
    
    func hideWindowAndPaste() {
        floatingWindow?.orderOut(nil)
        
        // 元のアプリにフォーカスを戻す
        if let app = previousApp {
            app.activate()
        }
    }
    
    /// 保存されたホットキーを登録し、設定画面での変更やキーの記録の開始・終了に合わせて登録し直す
    func setupHotKey() {
        hotKeyRegistrar = HotKeyRegistrar { [weak self] in
            self?.toggleWindow()
        }
        let store = HotKeyStore.shared
        hotKeySubscription = store.$hotKey.combineLatest(store.$isRecording)
            .sink { [weak self] hotKey, isRecording in
                guard let self else { return }
                if isRecording {
                    self.hotKeyRegistrar.unregister()
                } else {
                    store.registrationError = self.hotKeyRegistrar.register(hotKey)
                }
            }
    }
}
