import Carbon
import Foundation

final class LockController {
    var onStateChange: (() -> Void)?
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

    func lock(to id: String) {
        lockedID = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
        switchTo(id)
        onStateChange?()
    }

    func unlock() {
        lockedID = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        onStateChange?()
    }

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
            // 目标输入法已被卸载
            unlock()
            return
        }
        // 切回去之后，系统还会再回发一次切换通知，先忽略掉以免自触发循环
        isRestoring = true
        InputSourceManager.select(source)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isRestoring = false
        }
    }
}
