# Auto Approve

**智能 IDE 权限自动审批代理** — 适用于 VS Code / Antigravity / Cursor

*English version: see README_EN.md*

---

## 概述

Auto Approve Agent 是一款 VS Code 兼容扩展，用于自动处理 IDE 中 AI Agent 运行时产生的所有权限确认弹窗。它采用**五层自动化引擎 + 双层安全过滤**架构，在不干扰用户前台操作的前提下，实现对 `Allow`、`Run`、`Retry` 等 50+ 种按钮变体的毫秒级自动响应。

> 适用场景：当 AI Agent（如 Gemini）在后台持续执行文件操作、命令运行、网络请求等任务时，IDE 会频繁弹出安全确认对话框。本扩展可完全消除人工干预，让 Agent 全自动运行。

---

## 核心架构

### 五层自动化引擎

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Toast Notification Poller (Extension Host)    │
│  每 500ms 调用 notifications.acceptPrimaryAction        │
├─────────────────────────────────────────────────────────┤
│  Layer 2: UIAutomation Silent Invoke                    │
│  InvokePattern / LegacyIAccessiblePattern — 零焦点抢夺  │
├─────────────────────────────────────────────────────────┤
│  Layer 3: user32.dll Keyboard Injection + Idle Guard    │
│  物理 Alt+Enter 注入，受三重智能守卫保护                 │
├─────────────────────────────────────────────────────────┤
│  Layer 4: Warmup Cold-Start Protection                  │
│  首轮扫描仅缓存历史按钮，消除重启抖动                    │
├─────────────────────────────────────────────────────────┤
│  Layer 5: Base64 UTF-16LE Encoding                      │
│  跨语言编码防护，杜绝中文路径乱码                        │
└─────────────────────────────────────────────────────────┘
```

**Layer 1 — Toast 轮询器**：通过 VS Code Extension Host API 直接接受通知弹窗的主操作按钮。Electron Toast 对 Windows UIAutomation 不可见，此层从内部绕过。

**Layer 2 — 静默 UI 自动化**：PowerShell 后台进程扫描 IDE 窗口中的所有按钮控件，优先使用 `InvokePattern` 和 `LegacyIAccessiblePattern` 在**后台完全静默触发**。此层不抢夺焦点。

**Layer 3 — 键盘注入 + 智能空闲守卫**：当 Layer 2 被 Shadow DOM 拦截时，降维至 `user32.dll` 物理注入 `Alt+Enter`。注入前通过 `GetLastInputInfo` API 检测用户真实输入活动：

| 条件 | 行为 |
|---|---|
| 用户在 IDE 中 | ✅ 立即注入 |
| 用户在其他窗口 + 空闲 > 10 秒 | ✅ 判定 AFK，安全注入 |
| 用户在其他窗口 + 按钮等待 > 100 秒 | ✅ 超时强制注入 |
| 用户正在其他窗口打字 | ⏳ 跳过本轮 |

注入后 `StealthAltEnter` 自动恢复用户之前的前台窗口（~250ms）。

**Layer 4 — 冷启动预热**：IDE 重启后首轮扫描仅静默缓存所有已有按钮的 `RuntimeId`，不执行任何点击或滚动，从第二轮开始才处理新按钮。

**Layer 5 — 编码防护**：将 PowerShell 命令编译为 Base64 UTF-16LE 载荷，通过 `-EncodedCommand` 执行，从数学层面杜绝中文路径乱码。

---

### 双层安全过滤系统

取代传统的单一正则匹配，采用 **黑名单优先 + 白名单模糊匹配** 架构：

#### 🚫 黑名单（绝对优先）

包含以下关键词的按钮**永远不会被点击**：

```
deny, reject, cancel, decline, delete, remove, disable, block, stop, abort,
don't, do not, never, revoke, sign out, log out, uninstall, close, exit, quit,
dismiss, discard, revert, rollback, undo, skip, ignore
拒绝, 取消, 删除, 移除, 禁用, 阻止, 停止, 退出, 关闭, 卸载,
不允许, 不同意, 丢弃, 撤销, 回滚, 忽略, 跳过
```

#### ✅ 白名单（分层模糊匹配）

通过黑名单后，匹配以下任意模式的按钮将被自动点击：

| 优先级 | 关键词 | 覆盖示例 |
|---|---|---|
| Tier 1 | `allow`, `accept`, `approve`, `authorize`, `permit`, `grant` | Allow This Conversation, Accept All, Grant Access |
| Tier 2 | `run`, `continue`, `proceed`, `confirm`, `yes`, `ok`, `trust`, `retry`, `always` | Run Command, Continue Anyway, Yes to All |
| Tier 3 | `enable`, `save`, `submit`, `execute`, `apply`, `install`, `update`, `reload`, `restart` | Reload Window, Apply Changes |
| 中文 | `允许`, `确认`, `确定`, `运行`, `继续`, `重试`, `信任`, `接受`, `授权` 等 | 允许本次会话, 总是运行 |

---

## 安装

### 环境要求
- **Windows 10 / 11**（依赖系统自带的 `powershell.exe`）
- VS Code / Antigravity / Cursor 等基于 Electron 的 IDE

### 安装方式

**方式一：从 Marketplace 安装**（推荐）

在 IDE 扩展搜索 `Auto Approve` 直接安装。

**方式二：从 VSIX 安装**

1. 从 GitHub Releases 页面下载最新 `.vsix` 文件
2. IDE → `Ctrl+Shift+X` → 右上角 `...` → "从 VSIX 安装..."
3. **重启 IDE**

### 使用

扩展启动后**零配置自动运行**。如需手动控制：

- `Ctrl+Shift+P` → `Auto Approve: Start`
- `Ctrl+Shift+P` → `Auto Approve: Stop`

> ⚠️ 请勿将 IDE 最小化到任务栏（Chromium 会挂起无障碍树）。正确的挂机方式：让 IDE 窗口平铺在桌面，用浏览器/游戏全屏覆盖即可。

---

## CI/CD 自动发布

本项目通过 GitHub Actions 实现自动发布。创建 GitHub Release（tag 格式 `v*`）即可自动编译、打包并发布到 VS Code Marketplace。

详细配置步骤见 `.github/workflows/publish.yml` 内注释。

---

## 致谢

本项目基于 [fhgffy/antigravity-auto-accept](https://github.com/fhgffy/antigravity-auto-accept) 的优秀工作进行二次开发，感谢原作者的开创性贡献。

---

## 联系

- **QQ**: 1439775520
- **GitHub Issues**: 在 GitHub 仓库提交 Issue

---

## License

MIT
