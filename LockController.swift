import Carbon
import Foundation

/// 负责锁定状态的管理：持久化、监听输入法变化并强制切回。
final class LockController {
    /// 锁定状态变化时回调（用于刷新菜单栏图标等 UI）。
    var onStateChange: (() -> Void)?

    /// 当前锁定的输入法标识；nil 表示未锁定。
    private(set) var lockedID: String?

    private let defaultsKey = "lockedInputSourceID"
    private var isRestoring = false
    private var observer: NSObjectProtocol?

    init() {
        lockedID = UserDefaults.standard.string(forKey: defaultsKey)
        startObserving()
    }

    deinit {
        if let observer = observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    var isLocked: Bool { lockedID != nil }

    /// 锁定到指定输入法。
    func lock(to id: String) {
        lockedID = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
        switchTo(id)
        onStateChange?()
    }

    /// 解除锁定。
    func unlock() {
        lockedID = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        onStateChange?()
    }

    // MARK: - 私有

    private func startObserving() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: InputSourceManager.selectionChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSelectionChanged()
        }
    }

    private func handleSelectionChanged() {
        guard let lockedID = lockedID, !isRestoring else { return }
        guard InputSourceManager.currentID() != lockedID else { return }
        switchTo(lockedID)
    }

    private func switchTo(_ id: String) {
        guard let source = InputSourceManager.find(byID: id) else {
            // 目标输入法已被卸载，自动解锁。
            unlock()
            return
        }
        isRestoring = true
        InputSourceManager.select(source)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isRestoring = false
        }
    }
}
