# 开发

## 环境要求

- macOS 14+（开发机为 macOS 27.0.1）
- Xcode 命令行工具（Swift 6.4 / SDK 27.0）
- 无需任何第三方依赖，构建不联网拉包

---

## 构建与运行

```bash
./scripts/setup-signing.sh     # 一次性：创建本地签名证书
./scripts/build-app.sh         # 组装 .app 并签名
./scripts/run-app.sh           # 运行

./scripts/run-app.sh --fullscreen   # 以原生全屏启动
./scripts/run-app.sh --dev          # 前端直接读源码目录，改完不必重编译
```

`--dev` 会把 `BOOKSBRIDGE_WEB_ROOT` 指向 `swift/Sources/BooksBridgeApp/WebUI`，
改 HTML/CSS/JS 只要重开窗口即可看到效果。

### 只想要可执行文件

```bash
cd swift
swift build                    # 全部 target
swift build --product booksbridged
swift test                     # 155 个测试
```

---

## 工程结构

```
swift/
├── Package.swift
├── Sources/
│   ├── CSQLite/                    系统 libsqlite3 的 module map
│   ├── BooksBridgeCore/            读取苹果图书
│   ├── BooksBridgeLLM/             LLM 侧
│   ├── BooksBridgeApp/             宿主 + WebUI/
│   ├── booksbridged/               命令行驱动
│   ├── axtree/ axmenubar/ axact/   界面勘察工具
│   └── returnprobe/                副作用验证
├── Tests/BooksBridgeCoreTests/
└── Resources/Info.plist
```

---

## 测试

155 个用例，按关注点分文件：

| 文件 | 用例 | 覆盖 |
|---|---|---|
| `CFITests` | 21 | CFI 解析（含真实样本与边界） |
| `LLMContextTests` | 38 | 范围边界、检索、分块、知识缓存 |
| `LLMClientTests` | 19 | SSE 解析、请求构造、URL 规范化 |
| `PermissionAndMenuTests` | 18 | 权限判定语义、状态栏菜单结构 |
| `SettingsStoreTests` | 16 | 设置往返、0600 权限、向后兼容 |
| `ConversationStoreTests` | 18 | 持久化、原子写、编号递增、损坏恢复 |
| `ReadingAssistantTests` | 4 | 重启缓存复用、进度刷新、跨书隔离、旧缓存不触发付费调用 |
| `IntegrationTests` | 9 | **跑在真实书库上** |
| `BooksPathsTests` | 7 | 路径发现、作者字段清洗 |
| `FileWatcherTests` | 5 | 触发、合并、文件后创建、停止 |

### 集成测试会跳过

`IntegrationTests` 依赖真实环境（装了图书 App、有书、有权限）。
条件不满足时用 `XCTSkip` 而不是失败，因此别人 clone 下来也能跑通。

### 测试里刻意记录的行为

有些测试**不是断言"正确"而是记录取舍**，避免将来有人误以为是 bug：

- `testContentHashDetectsInteriorChange` —— 完整 SHA-256 指纹覆盖正文内部改动
- `testMissingBooksDataWithoutBooksInstalledIsUnknown` —— 缺数据不等于没权限

---

## 前端开发

前端是纯 HTML/CSS/JS，无框架无构建步骤。

### 布局自检

前端渲染后会测量各区块矩形并两两做重叠判定，结果回报给宿主写进日志：

```
布局=无重叠 ✅
区块尺寸: sidebar=270x632 topbar=789x52 thread=789x488 composer=749x76
```

这是对「不重叠、正确排布」要求的自动化验证。全部用 flex 布局，
**不使用任何 absolute/fixed 定位**。

窗口最小尺寸 720×460，布局在该尺寸下不塌缩。

### 与宿主通信

```js
// Swift → Web：唯一入口
window.booksbridge.onState(payload)

// Web → Swift
window.webkit.messageHandlers.booksbridge.postMessage({ type, payload })
```

契约详见 [architecture.md](architecture.md)。

---

## 调试

### 应用自身的参数

```bash
APP=build/BooksBridge.app/Contents/MacOS/BooksBridgeApp

$APP --diagnostics            # 打印环境信息后退出
$APP --dump-status-menu       # 打印状态栏菜单结构
$APP --show                   # 启动后立即显示窗口
$APP --window-size 720x460    # 强制窗口尺寸（验证最小尺寸布局）
$APP --window-mode fullscreen # 原生全屏
$APP --open-settings          # 直接打开设置页
$APP --open-book <assetID>    # 模拟点击进入某书
$APP --new-conversation <id>  # 模拟新建对话
$APP --back-to-library        # 模拟回到书库
$APP --test-ask "问题"         # 模拟提问
$APP --test-save-settings     # 模拟保存设置
$APP --return-after N         # N 秒后触发返回图书
$APP --quit-after N           # N 秒后退出
```

`--show` 之后的参数可以组合，用于自动化验证完整流程。

> 这些参数主要在**从终端直接运行**时使用（stdout 可见）。
> 但涉及权限的验收必须用 `open` 启动 —— 见 [permissions.md](permissions.md)。

### 命令行驱动 booksbridged

```bash
swift/.build/debug/booksbridged                 # 当前在读的书 + 位置 + 章节正文
swift/.build/debug/booksbridged --list          # 最近在读
swift/.build/debug/booksbridged --permissions   # 权限状态
swift/.build/debug/booksbridged --watch         # 实时跟随翻页
swift/.build/debug/booksbridged --debug-selection  # 监测划选
```

### 界面勘察工具

做 UI 校准时比截图更准，能直接给出每个控件的坐标与尺寸。

```bash
# 读任意运行中 App 的辅助功能树
swift/.build/debug/axtree --find "Books"
swift/.build/debug/axtree <pid> 20 400      # pid 最大深度 最大节点数

# 读菜单栏与弹出菜单
swift/.build/debug/axmenubar <pid>
swift/.build/debug/axmenubar <pid> --open 2  # 打开第 2 个顶层菜单

# 对辅助功能元素执行动作
swift/.build/debug/axact <pid> "账号菜单" list
swift/.build/debug/axact <pid> "账号菜单" showmenu
```

**已知局限**：状态栏项（`NSStatusItem`）不支持 `AXPress`（系统返回 -25204），
无法用这些工具点击验证；WebView 内的辅助功能树是惰性暴露的，不总是可读。
遇到这两种情况改用：

- `--dump-status-menu` 验证菜单**结构**
- 前端 `renderStats` 回报验证界面**渲染**

### 自检报告

每次启动写一份快照，包含权限探测、签名信息、UI 渲染与布局自检：

```bash
cat "$(find /var/folders -name booksbridge-permission-report.txt 2>/dev/null | head -1)"
```

### Python 原型

根目录的 `*.py` 是项目最初的可行性验证脚本，保留作参考：

| 文件 | 用途 |
|---|---|
| `booksbridge.py` | 读取当前书 + CFI + 章节正文（Swift 版的对照实现） |
| `live_probe.py` | 同时监测数据库写入与辅助功能树 |
| `selection_probe.py` | 划选检测探针 |

---

## 代码导航

按「想改什么」找位置：

| 想改 | 去哪 |
|---|---|
| 读取逻辑（数据库、CFI、EPUB） | `BooksBridgeCore/` |
| 提示词、知识范围、检索策略 | `BooksBridgeLLM/PromptBuilder.swift`、`ContextBuilder.swift` |
| 预处理流程与分块 | `BooksBridgeLLM/BookPreprocessor.swift` |
| 界面布局与交互 | `BooksBridgeApp/WebUI/` |
| 宿主行为、指令分发 | `BooksBridgeApp/AppDelegate.swift` |
| 窗口形态 | `BooksBridgeApp/PageWindowController.swift` |
| 状态栏菜单 | `BooksBridgeApp/StatusItemController.swift` |
| 权限检测 | `BooksBridgeCore/Permissions.swift` |
| 设置字段 | `BooksBridgeApp/SettingsStore.swift` |

### 改动前的注意事项

1. **读 [findings.md](findings.md)** —— 里面多条结论与直觉相反，不看容易改错
2. **不要破坏 CFI 与范围边界的关系** —— 三档范围的语义是剧透边界，
   改动必须同步更新 `ContextBuilderTests` 里的边界测试
3. **不要退回 ad-hoc 签名** —— 会让 TCC 授权失效
4. **前端不要用 absolute 定位** —— 会破坏布局自检的前提

---

## 版本控制

```bash
git log --oneline          # 基线提交：7281ba6
```

`.gitignore` 已排除 `build/`、`swift/.build/`、`__pycache__/`。
