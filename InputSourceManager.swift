import AppKit
import Carbon
import Foundation

/// 封装 Carbon 文本输入源（TIS）API，负责输入法的枚举、读取与切换。
enum InputSourceManager {
    /// 输入源集合发生变化时系统发出的通知名，用于清缓存。
    /// 其中两个是 Carbon SPI（未公开在公共头文件中），需动态解析，取不到则忽略。
    static var inputSourcesChangedNotifications: [NSNotification.Name] {
        let keys: [CFString?] = [
            kTISNotifyEnabledKeyboardInputSourcesChanged,
            PrivateTISKeys.enabledNonKeyboardInputSourcesChanged,
            PrivateTISKeys.installedInputSourcesChanged,
        ]
        return keys.compactMap { $0 }.map { NSNotification.Name($0 as String) }
    }

    /// 输入法切换事件的通知名（分布式通知）。
    static let selectionChangedNotification = NSNotification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String
    )

    /// 枚举用户实际启用的输入法（键盘布局 + 输入模式 + 手写）。
    ///
    /// 不能用 `TISCreateInputSourceList(nil, false)`：它一开始返回不完整的列表，
    /// 随后异步补齐成「全部已安装里 IsEnabled 的」，会让菜单先正确、后变多。
    /// 这里改成取全部已安装源，再自己按「真正启用」过滤。
    ///
    /// 另外用户删除某个输入法后，TIS 可能仍把它的输入模式标为 enabled，
    /// 所以输入模式还要求它所属的**父输入法**也是启用的。
    static func availableSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.filter { source in
            guard isEnabled(source) else { return false }
            if isKeyboardLayout(source) || isHandwriting(source) { return true }
            if isKeyboardInputMode(source) { return isParentEnabled(source) }
            return false
        }
    }

    /// 是否已启用。
    private static func isEnabled(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else {
            return false
        }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    /// 输入模式所属的父输入法是否启用。沿 ID 向上找到最近的父输入法类型，返回其启用状态。
    private static func isParentEnabled(_ source: TISInputSource) -> Bool {
        guard let id = id(of: source) else { return false }
        var components = id.split(separator: ".").map(String.init)
        while components.count > 1 {
            components.removeLast()
            let ancestorID = components.joined(separator: ".")
            if let ancestor = allSourcesByID[ancestorID],
               hasType(ancestor, kTISTypeKeyboardInputMethodModeEnabled) {
                return isEnabled(ancestor)
            }
        }
        return false
    }

    /// 输入法的唯一标识。
    static func id(of source: TISInputSource) -> String? {
        stringProperty(kTISPropertyInputSourceID, of: source)
    }

    /// 输入法的本地化显示名。
    ///
    /// 手写输入源单独处理：它的 `LocalizedName` 是「手写输入」（bundle 名），
    /// 而系统用的是 `HandwritingLocalizedNames` 里按输入语言选出的名字（简体手写）。
    static func name(of source: TISInputSource) -> String? {
        if let handwritingName = handwritingName(of: source) {
            return handwritingName
        }
        return stringProperty(kTISPropertyLocalizedName, of: source)
    }

    /// 计算一批输入源的显示名。
    ///
    /// 默认用本地化名称；当多个已启用输入源同名时，用**父输入法名**区分
    /// （例如日文「かな入力」和「ローマ字入力」的子模式都叫 Hiragana，
    /// 这时系统/我们都会退回到父输入法名）。
    static func displayNames(for sources: [TISInputSource]) -> [String: String] {
        let names = sources.map { name(of: $0) ?? id(of: $0) ?? "?" }
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)

        var result: [String: String] = [:]
        for source in sources {
            guard let id = id(of: source) else { continue }
            let base = name(of: source) ?? id
            if counts[base, default: 0] > 1, let parent = parentName(of: source) {
                result[id] = parent
            } else {
                result[id] = base
            }
        }
        return result
    }

    /// 逐级回退到父输入法名（`a.b.c` → `a.b` → `a`）。
    private static func parentName(of source: TISInputSource) -> String? {
        guard let id = id(of: source) else { return nil }
        var components = id.split(separator: ".").map(String.init)
        while components.count > 1 {
            components.removeLast()
            let candidate = components.joined(separator: ".")
            if let parent = allSourcesByID[candidate], let parentName = name(of: parent) {
                return parentName
            }
        }
        return nil
    }

    /// 所有已安装输入源（含未启用的父输入法），按 ID 索引，用于查父名。
    private static var allSourcesByIDCache: [String: TISInputSource]?
    private static var allSourcesByID: [String: TISInputSource] {
        if let cache = allSourcesByIDCache { return cache }
        let built = buildAllSourcesByID()
        allSourcesByIDCache = built
        return built
    }

    private static func buildAllSourcesByID() -> [String: TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return [:]
        }
        var map: [String: TISInputSource] = [:]
        for source in list {
            if let id = id(of: source) { map[id] = source }
        }
        return map
    }

    /// 所有菜单图标统一的槽位尺寸（系统输入法的文字块就是这么大）。
    /// 三方输入法的图标也放进同样大小的槽位里居中，保证所有菜单项文字对齐。
    static let iconSlot = NSSize(width: 22, height: 16)

    /// 输入法图标（菜单项名称左侧的小图标）。
    ///
    /// 系统自带输入法统一用**文字标签块**：取 `kTISPropertyInputSourceIconLabels.Primary`
    /// （如「拼音」「US」「RO」「A」），现画一个 22×16 的圆角矩形并把文字镂空出来；
    /// 没有文字标签的（手写）就用它的显示名当文字。
    ///
    /// 用户自己安装的三方输入法（如微信输入法）保留它自带的图标，
    /// 但同样放进 22×16 的槽位里居中，避免宽度不一导致菜单项错位。
    static func icon(of source: TISInputSource) -> NSImage? {
        if isFromSystem(source), let label = iconLabel(of: source) ?? name(of: source), !label.isEmpty {
            return labelChip(label)
        }
        guard let raw = rawIcon(of: source) else { return nil }
        return slotIcon(raw)
    }

    /// 是否为系统自带输入法。
    static func isFromSystem(_ source: TISInputSource) -> Bool {
        guard let key = PrivateTISKeys.inputSourceIsFromSystem,
              let ptr = TISGetInputSourceProperty(source, key) else {
            // 兜底：按 bundle ID 前缀判断
            return id(of: source)?.hasPrefix("com.apple.") ?? false
        }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    /// 是否为手写输入源。
    static func isHandwriting(_ source: TISInputSource) -> Bool {
        handwritingID != nil && id(of: source) == handwritingID
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

    // MARK: - 图标

    /// 输入源的图标短标签。
    private static func iconLabel(of source: TISInputSource) -> String? {
        if let id = id(of: source) {
            if let label = systemIconLabels[id] { return label }
            if let label = plistIconLabels[id] { return label }
        }
        // 兜底：键盘布局没有标签时用名称首字符（ABC → A）
        if isKeyboardLayout(source), let first = name(of: source)?.first {
            return String(first)
        }
        return nil
    }

    /// 用系统输入法菜单同款的方式画图标：22×16 圆角矩形 + 镂空标签。
    /// 标签过宽时按「能放几个字放几个」截断（如「拼音」→「拼」，而「US」保留两位）。
    private static func labelChip(_ label: String) -> NSImage {
        let size = iconSlot
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let text = fittedLabel(label, font: font, maxWidth: 18)

        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3.5, yRadius: 3.5).fill()

        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.black]
        )
        let textSize = attributed.size()
        let origin = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        )
        if let context = NSGraphicsContext.current?.cgContext {
            context.setBlendMode(.destinationOut)
            attributed.draw(at: origin)
            context.setBlendMode(.normal)
        }

        image.unlockFocus()
        return image
    }

    /// 贪心取最长的、宽度不超过 `maxWidth` 的前缀（按字符 / grapheme cluster 截断）。
    private static func fittedLabel(_ label: String, font: NSFont, maxWidth: CGFloat) -> String {
        var result = ""
        for character in label {
            let candidate = result + String(character)
            let width = (candidate as NSString).size(withAttributes: [.font: font]).width
            if width > maxWidth { break }
            result = candidate
        }
        return result.isEmpty ? String(label.prefix(1)) : result
    }

    /// 手写输入源按其输入语言从 `HandwritingLocalizedNames` 取名字（如 zh-Hans → 简体手写）。
    private static func handwritingName(of source: TISInputSource) -> String? {
        guard handwritingID != nil, id(of: source) == handwritingID else { return nil }
        guard let key = PrivateTISKeys.handwritingLocalizedNames,
              let ptr = TISGetInputSourceProperty(source, key),
              let names = Unmanaged<NSDictionary>.fromOpaque(ptr).takeUnretainedValue() as? [String: String]
        else { return nil }
        if let languageKey = PrivateTISKeys.intendedLanguage,
           let languagePtr = TISGetInputSourceProperty(source, languageKey) {
            let language = Unmanaged<CFString>.fromOpaque(languagePtr).takeUnretainedValue() as String
            if let name = names[language] { return name }
        }
        return names.values.first
    }

    /// 把三方输入法的图标放进统一槽位：等比缩放到不超出槽位，然后居中。
    private static func slotIcon(_ icon: NSImage) -> NSImage {
        let slot = iconSlot
        let natural = icon.size
        let scale = min(1, min(slot.width / natural.width, slot.height / natural.height))
        let size = NSSize(width: natural.width * scale, height: natural.height * scale)
        let rect = NSRect(
            x: (slot.width - size.width) / 2,
            y: (slot.height - size.height) / 2,
            width: size.width,
            height: size.height
        )

        let image = NSImage(size: slot)
        image.lockFocus()
        icon.draw(in: rect)
        image.unlockFocus()
        return image
    }

    /// 输入法自带图标（没有声明短标签时的回退）：优先图标文件 URL，其次 IconRef。
    private static func rawIcon(of source: TISInputSource) -> NSImage? {
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) {
            let url = Unmanaged<CFURL>.fromOpaque(ptr).takeUnretainedValue() as URL
            if let image = NSImage(contentsOf: url) { return image }
        }
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyIconRef) {
            let image = NSImage(iconRef: IconRef(ptr))
            if image.isValid { return image }
        }
        return nil
    }

    // MARK: - 私有

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func hasType(_ source: TISInputSource, _ expected: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return false
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() == expected
    }

    private static func isKeyboardLayout(_ source: TISInputSource) -> Bool {
        hasType(source, kTISTypeKeyboardLayout)
    }

    private static func isKeyboardInputMode(_ source: TISInputSource) -> Bool {
        hasType(source, kTISTypeKeyboardInputMode)
    }

    /// 手写输入源的 ID（`com.apple.inputmethod.ChineseHandwriting`）。
    static let handwritingID: String? = PrivateTISKeys.lookupString("kTISAppleChineseHandwritingInputSourceID")

    /// 输入源集合发生变化（启用 / 停用 / 安装 / 移除）时清空派生缓存，
    /// 否则新增或变更过的输入法会用到旧的标签 / 父名。
    static func invalidateCaches() {
        systemIconLabelsCache = nil
        plistIconLabelsCache = nil
        allSourcesByIDCache = nil
    }

    /// 系统声明的图标短标签：`输入源 ID -> Primary 标签`。
    /// `kTISPropertyInputSourceIconLabels` 是已导出的 Carbon SPI，直接给出菜单实际使用的标签
    /// （键盘布局也在其中，如 U.S. → US、Romanian → RO）。
    private static var systemIconLabelsCache: [String: String]?
    private static var systemIconLabels: [String: String] {
        if let cache = systemIconLabelsCache { return cache }
        let built = buildSystemIconLabels()
        systemIconLabelsCache = built
        return built
    }

    private static func buildSystemIconLabels() -> [String: String] {
        var result: [String: String] = [:]
        guard let key = PrivateTISKeys.inputSourceIconLabels else { return result }
        let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        for source in list {
            guard let id = id(of: source),
                  let ptr = TISGetInputSourceProperty(source, key),
                  let labels = Unmanaged<NSDictionary>.fromOpaque(ptr).takeUnretainedValue() as? [String: Any],
                  let primary = labels["Primary"] as? String
            else { continue }
            result[id] = primary
        }
        return result
    }

    /// 兜底：从各输入法的 Info.plist 里读 `TISIconLabels.Primary`（老系统上没有上面的 SPI 时）。
    private static var plistIconLabelsCache: [String: String]?
    private static var plistIconLabels: [String: String] {
        if let cache = plistIconLabelsCache { return cache }
        let built = buildPlistIconLabels()
        plistIconLabelsCache = built
        return built
    }

    private static func buildPlistIconLabels() -> [String: String] {
        var labels: [String: String] = [:]
        let fileManager = FileManager.default
        let roots = [
            "/System/Library/Input Methods",
            "/Library/Input Methods",
            "/System/Library/Keyboard Layouts",
            "/Library/Keyboard Layouts",
        ]

        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let contents = "\(root)/\(entry)/Contents"
                var plists = ["\(contents)/Info.plist"]
                if let plugins = try? fileManager.contentsOfDirectory(atPath: "\(contents)/PlugIns") {
                    plists += plugins.map { "\(contents)/PlugIns/\($0)/Contents/Info.plist" }
                }

                for path in plists {
                    guard let data = fileManager.contents(atPath: path),
                          let plist = try? PropertyListSerialization.propertyList(
                              from: data, options: [], format: nil
                          ) as? [String: Any],
                          let component = plist["ComponentInputModeDict"] as? [String: Any],
                          let modes = component["tsInputModeListKey"] as? [String: Any]
                    else { continue }

                    for value in modes.values {
                        guard let info = value as? [String: Any],
                              let iconLabels = info["TISIconLabels"] as? [String: Any],
                              let primary = iconLabels["Primary"] as? String,
                              let sourceID = info["TISInputSourceID"] as? String
                        else { continue }
                        labels[sourceID] = primary
                    }
                }
            }
        }
        return labels
    }
}

/// 系统输入法菜单使用的若干 Carbon SPI（未公开在公共头文件中），通过 dlsym 动态解析。
enum PrivateTISKeys {
    static let inputSourceIconLabels = lookup("kTISPropertyInputSourceIconLabels")
    static let inputSourceIsFromSystem = lookup("kTISPropertyInputSourceIsFromSystem")
    static let handwritingLocalizedNames = lookup("kTISPropertyHandwritingLocalizedNames")
    static let intendedLanguage = lookup("kTISPropertyIntendedLanguage")
    static let enabledNonKeyboardInputSourcesChanged = lookup("kTISNotifyEnabledNonKeyboardInputSourcesChanged")
    static let installedInputSourcesChanged = lookup("kTISNotifyInstalledInputSourcesChanged")

    static func lookup(_ name: String) -> CFString? {
        guard let handle = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY),
              let symbol = dlsym(handle, name) else { return nil }
        return symbol.assumingMemoryBound(to: CFString.self).pointee
    }

    /// 解析导出为 `CFStringRef` 的常量并转成 Swift String。
    static func lookupString(_ name: String) -> String? {
        lookup(name) as String?
    }
}
