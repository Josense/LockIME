import AppKit

/// 菜单栏界面：状态图标 + 下拉菜单。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = LockController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = makeMenu()

        controller.onStateChange = { [weak self] in
            self?.updateIcon()
        }
        updateIcon()
    }

    // MARK: - 菜单

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
        if let lockedID = controller.lockedID,
           let source = InputSourceManager.find(byID: lockedID) {
            statusTitle = "已锁定：\(InputSourceManager.name(of: source) ?? lockedID)"
        } else {
            statusTitle = "未锁定"
        }
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.image = menuBarIcon()
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // 输入法列表
        for source in InputSourceManager.availableSources() {
            guard let id = InputSourceManager.id(of: source) else { continue }
            let item = NSMenuItem(
                title: InputSourceManager.name(of: source) ?? id,
                action: #selector(selectInputSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = id
            item.state = (id == controller.lockedID) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 解锁
        let unlock = NSMenuItem(title: "解锁", action: #selector(unlock), keyEquivalent: "")
        unlock.target = self
        unlock.isEnabled = controller.isLocked
        menu.addItem(unlock)

        menu.addItem(.separator())

        // 退出
        let quit = NSMenuItem(title: "退出 LockIME", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - 动作

    @objc private func selectInputSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // 点击已锁定的输入法 = 解锁
        if controller.lockedID == id {
            controller.unlock()
        } else {
            controller.lock(to: id)
        }
    }

    @objc private func unlock() {
        controller.unlock()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 图标

    /// 加载菜单栏图标（模板图标，随系统明暗模式自动着色）。
    /// 原图为 72×72 高分辨率，这里把逻辑尺寸设为 18pt，让 Retina 屏以 2x 像素密度渲染，保证清晰。
    private func menuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menubar", withExtension: "png") else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = menuBarIcon()
        // 未锁定时半透明，锁定时实心，便于一眼区分状态
        button.alphaValue = controller.isLocked ? 1.0 : 0.5
    }
}
