<div align="center">

<img src="Resources/menubar.png" width="96" height="96" alt="LockIME icon">

# LockIME

锁定 macOS 输入法，防止系统或应用意外切换。

菜单栏常驻工具：选定目标输入法后，无论切换到哪个应用、按下什么快捷键，输入法都会被自动切回锁定目标。

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#系统要求)
[![Version](https://img.shields.io/badge/version-1.0.0-green.svg)](Info.plist)
[![Language](https://img.shields.io/badge/language-Swift-orange.svg)](#方式三从源码编译)
[![Homebrew](https://img.shields.io/badge/Homebrew-cask-FBB040.svg)](#方式二homebrew)

</div>

---

## 简介

LockIME 是一款轻量的 macOS 菜单栏应用，通过 Carbon Text Input Source（TIS）API 监听并接管输入法切换事件，把当前输入法固定在你指定的目标上。

本项目是闭源付费软件 InputLock 的开源替代品，功能对齐其“全局锁定”能力。

## 特性

- **锁定任意输入法**：中文、英文、日文等均可作为锁定目标，可随时更换。
- **自动切回**：检测到输入法被切换时立即切回锁定目标，无需手动干预。
- **状态持久化**：记住上次的锁定目标，重启应用后自动恢复。
- **实时状态提示**：菜单栏图标以透明度区分锁定状态（未锁定半透明 / 已锁定实心），下拉菜单显示当前锁定项。
- **一键解锁**：点击已锁定的输入法或选择“解锁”即可恢复系统默认行为。
- **无 Dock 图标**：以菜单栏常驻方式运行，不占用 Dock 与窗口空间。
- **轻量**：常驻内存约 10 MB，CPU 占用接近 0。
- **原生实现**：纯 Swift + AppKit，无第三方依赖。

## 系统要求

- macOS 13.0（Ventura）或更高版本
- 下载预编译版本需要 Apple Silicon 或 Intel 处理器（依据发布包而定）
- 从源码编译需要 Xcode Command Line Tools

## 安装

推荐按以下顺序选择安装方式：优先下载 DMG，其次使用 Homebrew，最后从源码编译。

### 方式一：下载 DMG（推荐）

1. 从 [Releases](../../releases) 页面下载最新的 `LockIME-<版本>.dmg`。
2. 打开磁盘映像，将 `LockIME.app` 拖入 `/Applications`。
3. 首次启动时，如系统提示来源未知，请在「系统设置 → 隐私与安全性」中允许打开。

### 方式二：Homebrew

通过 Homebrew Cask 安装：

```bash
brew tap Josense/lockime
brew install --cask lockime
```

也可以用一条命令完成 tap 与安装：

```bash
brew install --cask Josense/lockime/lockime
```

常用管理命令：

```bash
brew upgrade --cask lockime   # 更新到最新版本
brew uninstall --cask lockime # 卸载
```

> 该 Cask 由本项目的 tap 仓库维护；若后续被收录进官方仓库，则可直接执行 `brew install --cask lockime`。

### 方式三：从源码编译

克隆仓库并编译可执行文件：

```bash
git clone https://github.com/Josense/LockIME.git
cd LockIME
swiftc -O -o LockIME \
  main.swift AppDelegate.swift LockController.swift InputSourceManager.swift
```

编译完成后，将可执行文件与 `Info.plist`、`Resources/` 一起放入标准的 `.app` 包结构即可运行：

```
LockIME.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/LockIME
    └── Resources/
        ├── AppIcon.icns
        ├── menubar.png
        └── menubar@2x.png
```

## 使用

1. 启动 LockIME，菜单栏出现应用图标。
2. 点击菜单栏图标，在下拉列表中选择要锁定的输入法（点击即锁定并立即切换过去）。
3. 再次点击已锁定的输入法，或选择“解锁”，即可解除锁定。
4. 选择“退出 LockIME”结束运行。

## 工作原理

LockIME 基于 macOS 的 Carbon 文本输入源 API：

- `TISCreateInputSourceList`：枚举系统中已安装的输入法。
- `kTISNotifySelectedKeyboardInputSourceChanged`：通过分布式通知监听输入法切换事件。
- `TISSelectInputSource`：在检测到切换后，把输入法切回锁定目标。

当锁定的输入法被卸载时，应用会自动解除锁定。

## 开机自启

如需开机自动运行，请在「系统设置 → 通用 → 登录项」中添加 `LockIME.app`。

## 项目结构

| 文件 | 职责 |
|------|------|
| `main.swift` | 程序入口 |
| `InputSourceManager.swift` | TIS API 封装（枚举 / 读取 / 切换输入法） |
| `LockController.swift` | 锁定状态、持久化、监听并切回（核心业务） |
| `AppDelegate.swift` | 菜单栏界面（状态图标 + 下拉菜单） |
| `Info.plist` | 应用元信息，版本号的唯一来源 |
| `Resources/` | 应用图标与菜单栏图标资源 |

## 已知限制

- 仅支持“全局锁定”，不支持按应用自动切换输入法（与 InputLock 行为一致）。
- 锁定的输入法被卸载后会自动解锁。
- 未实现全局快捷键，所有操作通过菜单栏完成。

## 贡献

欢迎提交 Issue 与 Pull Request。提交代码前请确保：

- 代码可编译通过，且不引入第三方依赖。
- 遵循现有代码风格与文件职责划分。
- 一次提交只做一件事，提交信息清晰描述改动内容。

## 许可

本项目基于 [MIT License](LICENSE) 开源。
