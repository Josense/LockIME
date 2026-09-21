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
swiftc -O -o LockIME main.swift AppDelegate.swift LockController.swift InputSourceManager.swift
```

## 发布（打包 + 签名 + 公证）

```bash
./release.sh                 # 完整流程：编译 → 签名 → 公证 → 生成并公证 dmg
./release.sh --no-notarize   # 只打包签名，不联网公证（本地验证流程用）
./release.sh --build-only    # 只编译 + 组装 + 签名
./release.sh --skip-build    # 复用 build/LockIME.app，从公证开始（改完脚本重跑很快）
```

产物：`build/LockIME.app`（已 staple）和 `LockIME-<版本>.dmg`（已签名 + 已 staple）。

### 为什么 app 和 dmg 各公证、各 staple 一次

app 与 dmg 是两个独立对象，各自签名，票据不通用。Gatekeeper 有两个检查点：挂载 dmg 时校验 dmg，首次启动 app 时校验 app。只 staple 外层 dmg 的话，用户拖进 `/Applications` 后启动走的还是 app 自己的票据 —— 缺票据时会退化成联网校验，离线/被防火墙拦截时可能启动失败。

因此顺序不能颠倒：

```
签名 app → 公证 app → staple app → 用「已 staple 的 app」做 dmg → 签名 dmg → 公证 dmg → staple dmg
```

> staple 会写入 app bundle，所以必须在制作 dmg **之前** 完成，否则 dmg 的内容摘要变化会导致签名失效。

### 首次使用前准备公证凭据（一次性）

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "<你的 Apple ID>" --team-id "<TEAMID>" --password "<App 专用密码>"
```

脚本默认读取钥匙串 profile `AC_PASSWORD`，可用环境变量覆盖：

```bash
VERSION=1.0.1 SIGN_ID="Developer ID Application: ..." KEYCHAIN_PROFILE=AC_PASSWORD ./release.sh
```

> `Info.plist` 位于仓库根目录，是唯一的权威来源；版本号从它读取。改版本时改这里即可。

## 项目结构

| 文件 | 职责 |
|------|------|
| `main.swift` | 程序入口 |
| `InputSourceManager.swift` | TIS API 封装（枚举 / 读取 / 切换输入法） |
| `LockController.swift` | 锁定状态、持久化、监听并切回（核心业务） |
| `AppDelegate.swift` | 菜单栏界面（状态图标 + 下拉菜单） |

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
