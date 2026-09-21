import AppKit
import Carbon

/// 菜单栏界面：状态图标 + 下拉菜单。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = LockController()
    private var inputSourceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = makeMenu()

        controller.onStateChange = { [weak self] in
            self?.updateIcon()
        }
        observeInputSourceChanges()
        updateIcon()
    }

    /// 输入源集合变化（启用 / 停用 / 安装 / 移除）时清掉图标与名称的缓存，
    /// 否则新增或变更过的输入法会一直用旧的标签 / 父名。
    private func observeInputSourceChanges() {
        let center = DistributedNotificationCenter.default()
        for name in InputSourceManager.inputSourcesChangedNotifications {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                InputSourceManager.invalidateCaches()
            }
            inputSourceObservers.append(observer)
        }
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

        let sources = InputSourceManager.availableSources()
        let names = InputSourceManager.displayNames(for: sources)

        // 状态行
        let statusTitle: String
        if let lockedID = controller.lockedID,
           let source = InputSourceManager.find(byID: lockedID) {
            statusTitle = "已锁定：\(names[lockedID] ?? InputSourceManager.name(of: source) ?? lockedID)"
        } else {
            statusTitle = "未锁定"
        }
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.image = menuBarIcon()
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // 输入法列表（手写这类单列来源单独成组）
        let mainSources = sources.filter { !InputSourceManager.isHandwriting($0) }
        let handwritingSources = sources.filter { InputSourceManager.isHandwriting($0) }

        for source in mainSources {
            addInputSource(source, to: menu, names: names)
        }

        if !handwritingSources.isEmpty {
            menu.addItem(.separator())
            for source in handwritingSources {
                addInputSource(source, to: menu, names: names)
            }
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

    /// 把一个输入源加进菜单（含图标与勾选状态）。
    private func addInputSource(_ source: TISInputSource, to menu: NSMenu, names: [String: String]) {
        guard let id = InputSourceManager.id(of: source) else { return }
        let item = NSMenuItem(
            title: names[id] ?? id,
            action: #selector(selectInputSource(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = id
        // 前置输入法图标，与系统输入法菜单保持一致
        item.image = InputSourceManager.icon(of: source)
        item.state = (id == controller.lockedID) ? .on : .off
        menu.addItem(item)
    }

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
