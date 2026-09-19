import Carbon
import Foundation

/// 封装 Carbon 文本输入源（TIS）API，负责输入法的枚举、读取与切换。
enum InputSourceManager {
    /// 输入法切换事件的通知名（分布式通知）。
    static let selectionChangedNotification = NSNotification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String
    )

    /// 枚举所有可锁定的输入法（键盘布局 + 输入模式，排除父级模式和表情面板）。
    static func availableSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.filter { source in
            guard let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
                return false
            }
            let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue()
            return type == kTISTypeKeyboardLayout || type == kTISTypeKeyboardInputMode
        }
    }

    /// 输入法的唯一标识。
    static func id(of source: TISInputSource) -> String? {
        stringProperty(kTISPropertyInputSourceID, of: source)
    }

    /// 输入法的本地化显示名。
    static func name(of source: TISInputSource) -> String? {
        stringProperty(kTISPropertyLocalizedName, of: source)
    }

    /// 当前激活的输入法标识。
    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return id(of: source)
    }

    /// 按标识查找输入法。
    static func find(byID target: String) -> TISInputSource? {
        availableSources().first { id(of: $0) == target }
    }

    /// 切换到指定输入法。
    static func select(_ source: TISInputSource) {
        TISSelectInputSource(source)
    }

    // MARK: - 私有

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
