# LockIME

锁定 macOS 输入法，防止系统或应用意外切换。菜单栏常驻，选择要锁定的输入法后，无论切到什么应用、按了什么快捷键，输入法都会被自动切回锁定目标。

这是闭源付费软件 InputLock 的开源替代品，功能对齐其"全局锁定"能力。

## 功能

- 🔒 锁定任意输入法（中文 / 英文均可），随时切换锁定目标
- 🚫 解锁即恢复系统默认行为
- 💾 记住上次锁定状态，重启后自动恢复
- ⚡ 菜单栏图标实时反映锁定状态（🔓 未锁定 / 🔒 已锁定）
- 🪶 轻量：常驻内存约 10MB，CPU 占用接近 0

## 安装

### 方式一：直接使用编译好的 App

把 `LockIME.app` 拖进 `/Applications` 即可。

### 方式二：从源码编译

```bash
swiftc -O -o LockIME main.swift
```

## 使用

1. 点击菜单栏图标
2. 在下拉列表里选择要锁定的输入法（点一下即锁定并立即切换过去）
3. 再次点击已锁定的输入法，或点"解锁"，即可解除锁定

## 原理

- `TISCreateInputSourceList` 枚举已安装的输入法
- `kTISNotifySelectedKeyboardInputSourceChanged` 分布式通知监听输入法切换
- `TISSelectInputSource` 把输入法切回锁定目标

## 开机自启（可选）

系统设置 → 通用 → 登录项 → 添加 `LockIME.app`。

## 已知限制

- 仅做"全局锁定"，不支持按应用自动切换输入法（与 InputLock 一致）
- 若锁定的输入法被卸载，会自动解锁

## 许可

MIT License
