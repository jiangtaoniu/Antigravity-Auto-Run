# Antigravity Auto Run — 项目开发指南

> 此文件为 AI 辅助开发上下文文件。让 Gemini/Antigravity Agent 理解项目架构、编码规范和关键设计决策，以提高辅助开发效率。

---

## 项目概述

**Antigravity Auto Run** 是一个 VS Code / Antigravity / Cursor 扩展，用于自动处理 IDE 中 AI Agent 运行时产生的所有权限确认弹窗（Allow, Run, Retry 等）。

**核心目标**：让 AI Agent 全自动运行，无需人工干预。

**仓库**：https://github.com/jiangtaoniu/Antigravity-Auto-Run

---

## 文件结构

```
├── src/
│   ├── extension.ts          # VS Code 扩展入口（TypeScript）
│   └── autoClicker.ps1       # 核心自动化脚本（PowerShell + 嵌入式 C#）
├── out/
│   └── extension.js          # 编译输出（由 tsc 生成，不要手动编辑）
├── .github/
│   └── workflows/
│       └── publish.yml       # CI/CD：GitHub Release → 自动发布到 Marketplace
├── package.json              # 扩展清单（名称、版本、命令定义）
├── tsconfig.json             # TypeScript 编译配置
├── .vscodeignore             # 打包排除规则
├── .gitignore                # Git 忽略规则
├── README.md                 # 中文文档
├── README_EN.md              # 英文文档
└── LICENSE                   # MIT 许可证
```

---

## 架构设计

### Layer 1 — Toast 轮询器（extension.ts）

```
每 500ms 执行 → vscode.commands.executeCommand('notifications.acceptPrimaryAction')
```

- 运行在 VS Code Extension Host 内部
- 处理 Electron Toast 通知（UIAutomation 不可见）
- 完全静默，无副作用

### Layer 2 — 静默 UI 自动化（autoClicker.ps1）

```
UIAutomation API → InvokePattern → LegacyIAccessiblePattern
```

- PowerShell 后台进程，由 extension.ts 以 Base64 编码启动
- 扫描 IDE 窗口中 `ControlType.Button` 控件
- 优先使用完全静默的 API 触发，不抢焦点

### Layer 3 — 键盘注入 + 智能守卫（autoClicker.ps1）

```
user32.dll → keybd_event(Alt+Enter) → StealthAltEnter(自动恢复焦点)
```

- 当 Layer 2 被 Shadow DOM 拦截时使用
- 三重智能守卫：IDE 前台 → 直接注入 | 空闲 >10s → AFK 注入 | 等待 >100s → 超时注入
- `GetLastInputInfo` 检测真实键盘/鼠标活动
- 注入后自动恢复用户之前的前台窗口

### Layer 4 — 冷启动预热（autoClicker.ps1）

```
首轮扫描 → 缓存历史按钮 → 保留最后 3 个按钮不缓存（活跃提示）
```

- 防止 IDE 重启后扫描历史按钮导致画面跳动
- 最后 3 个按钮不缓存，确保当前活跃提示可被处理

### Layer 5 — 编码防护（extension.ts）

```
命令 → Buffer.from(cmd, 'utf16le').toString('base64') → -EncodedCommand
```

- 防止中文路径在 Node.js → PowerShell 传递时乱码

---

## 双层安全过滤（Blacklist + Whitelist）

### 修改规则

**黑名单**（`$BLOCK_KEYWORDS`）：使用 **精确子串匹配**（`[regex]::Escape()`），包含即拦截。
- 修改位置：`autoClicker.ps1` 第 162-173 行
- 添加新危险词：直接追加字符串到数组

**白名单**（`$ALLOW_PATTERNS`）：使用 **正则模糊匹配**（`-imatch`），分两层级。
- 修改位置：`autoClicker.ps1` 第 180-207 行
- Tier 1（高优先）：allow, accept, approve, authorize, permit, grant
- Tier 2（中优先）：run, continue, proceed, confirm, yes, ok, trust, retry, always
- 添加新按钮词：追加正则模式，注意使用 `^` 锚定和 `\b` 边界防止误匹配

### ⚠️ 关键原则

1. **黑名单绝对优先**于白名单
2. **不要添加** `expand`、`collapse`、`enable`、`install`、`reload`、`restart` 等非权限按钮
3. 新增模式需考虑子串误匹配风险（例如 `"run"` 需用 `"^run\b"` 锚定）

---

## 开发命令

```bash
# 安装依赖
npm install

# 编译 TypeScript
npm run compile

# 监听模式编译
npm run watch

# 打包 .vsix（本地测试用）
npx -y @vscode/vsce package --allow-missing-repository --allow-star-activation

# 安装到 IDE 测试
# IDE → Ctrl+Shift+X → ... → "从 VSIX 安装..."

# 查看插件日志
# IDE → Ctrl+Shift+U → 下拉选择 "Antigravity Auto Run"

# 提交并推送
git add -A
git commit -m "feat/fix: 描述"
git push
```

---

## 发布流程

1. 更新 `package.json` 中 `version` 字段
2. 推送到 GitHub main 分支
3. 创建 GitHub Release（tag 格式 `v2.0.1`）
4. GitHub Actions 自动编译、打包、发布到 VS Code Marketplace

**前提**：`package.json` 中 `publisher` 设为有效的 Marketplace Publisher ID，GitHub Secrets 中配置 `VSCE_PAT`。

---

## 关键设计决策记录

| 决策 | 原因 |
|---|---|
| 静默 API 优先于键盘注入 | 避免抢夺用户前台焦点 |
| 黑名单先于白名单检查 | 防止误点危险按钮（delete, cancel 等） |
| Warmup 保留最后 3 个按钮 | 防止当前活跃提示被预热缓存吞掉 |
| `GetLastInputInfo` 检测空闲 | 比检查前台窗口更精确 |
| Base64 编码启动 PowerShell | 防止中文路径乱码 |
| RuntimeId HashSet 缓存 | 防止重复点击同一按钮 |
| 100 秒超时强制注入 | 防止用户 AFK 时插件永远不注入 |

---

## 调试技巧

1. **启用按钮扫描日志**：取消 `autoClicker.ps1` 中 `Write-Host "SCANNING BTN: '$cleanName'"` 的注释（约第 273 行）
2. **查看匹配结果**：Output 面板会显示 `>>> TARGET MATCHED: 'Run' <<<`
3. **检查进程名**：日志首行显示 `Resolved IDE Process Name: Antigravity`
4. **PowerShell 独立调试**：可单独运行 `autoClicker.ps1` 并传入 IDE PID 进行测试

---

## 已知限制

1. **仅支持 Windows**：依赖 `user32.dll` 和 `UIAutomationClient`
2. **不支持最小化 IDE**：Chromium 最小化时会挂起无障碍树
3. **Environment.TickCount 溢出**：系统运行超过 ~49.7 天后 `GetIdleTimeMs()` 可能短暂异常
4. **publisher 占位符**：当前 `package.json` 中 `publisher: "tempPublisher"` 需替换为真实值才能发布到 Marketplace
