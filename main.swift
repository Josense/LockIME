import AppKit
import Carbon

// MARK: - 输入法工具

enum InputSourceUtil {
    /// 枚举所有可锁定的输入法（键盘布局 + 输入模式，排除父级模式和表情面板）
    static func availableSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.filter { src in
            guard let typePtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return false }
            let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue()
            return type == kTISTypeKeyboardLayout || type == kTISTypeKeyboardInputMode
        }
    }

    static func id(_ src: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func name(_ src: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func currentID() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return id(src)
    }

    static func find(byID target: String) -> TISInputSource? {
        return availableSources().first { id($0) == target }
    }

    static func select(_ src: TISInputSource) {
        TISSelectInputSource(src)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var lockedID: String?
    private var isRestoring = false

    private let defaultsKey = "lockedInputSourceID"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 恢复上次锁定状态
        lockedID = UserDefaults.standard.string(forKey: defaultsKey)

        // 创建菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "LockIME")
        }
        statusItem.menu = makeMenu()

        // 监听输入法切换事件
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged(_:)),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )

        updateIcon()
    }

    // MARK: 菜单

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // 状态行
        let statusTitle: String
        if let lockedID = lockedID, let src = InputSourceUtil.find(byID: lockedID) {
            statusTitle = "🔒 已锁定：\(InputSourceUtil.name(src) ?? lockedID)"
        } else {
            statusTitle = "🔓 未锁定"
        }
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // 输入法列表
        for src in InputSourceUtil.availableSources() {
            guard let sid = InputSourceUtil.id(src) else { continue }
            let item = NSMenuItem(
                title: InputSourceUtil.name(src) ?? sid,
                action: #selector(selectInputSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = sid
            item.state = (sid == lockedID) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 解锁
        let unlock = NSMenuItem(title: "解锁", action: #selector(unlock), keyEquivalent: "")
        unlock.target = self
        unlock.isEnabled = (lockedID != nil)
        menu.addItem(unlock)

        menu.addItem(.separator())

        // 退出
        let quit = NSMenuItem(title: "退出 LockIME", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: 动作

    @objc private func selectInputSource(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        // 点击已锁定的输入法 = 解锁
        if lockedID == sid {
            unlock()
            return
        }
        lockedID = sid
        UserDefaults.standard.set(sid, forKey: defaultsKey)
        // 立即切到该输入法
        if let src = InputSourceUtil.find(byID: sid) {
            isRestoring = true
            InputSourceUtil.select(src)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isRestoring = false }
        }
        updateIcon()
    }

    @objc private func unlock() {
        lockedID = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        updateIcon()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 核心：监听并切回

    @objc private func inputSourceChanged(_ note: Notification) {
        guard let lockedID = lockedID, !isRestoring else { return }
        let current = InputSourceUtil.currentID()
        if current != lockedID {
            restore(lockedID)
        }
    }

    private func restore(_ targetID: String) {
        guard let src = InputSourceUtil.find(byID: targetID) else {
            // 目标输入法已被卸载，自动解锁
            lockedID = nil
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            updateIcon()
            return
        }
        isRestoring = true
        InputSourceUtil.select(src)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.isRestoring = false }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = (lockedID != nil) ? "lock.fill" : "keyboard"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LockIME")
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不显示 Dock 图标
app.run()
