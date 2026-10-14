## 权限修复（2026-10-14）

### 本机已确认的授权迁移问题

2026-10-14 的 tccd 日志明确显示 Accessibility、SystemPolicyAllFiles、
SystemPolicyAppDataDetailed 的 `Failed to match existing code requirement`：
旧授权绑定 `cdhash 337f74225d2db146cbeac9468d0e990a6d5c9890`，当前应用绑定固定证书。
有效签名并不会自动迁移旧的 TCC 授权。已针对 `com.chris.booksbridge` 执行一次
`/usr/bin/tccutil reset All com.chris.booksbridge`，之后需用户给当前应用重新授权。
这不是每次构建或启动应执行的操作，也不应重置其他应用的授权。

历史直接执行测试的 TCC responsible 为 `com.deepseek.dsh`，其成功结果不能证明
BooksBridge 自身有权限。验收必须独立启动，并核对 tccd 的 subject、实际数据库读取、
辅助功能状态；再退出重开验证持久性。单元测试成功及集成测试跳过不代表授权通过。


启动先显示界面，不读取 Apple Books 的受保护目录，也不主动弹辅助功能授权框。
每次启动后，在「设置 → 权限」点击「连接 Apple Books」开始本次连接。
已有书库和对话离线可用。授权后返回应用会重新检测；也可点击「重新检测」重建监听。
若系统要求重启，请退出 BooksBridge 后重新打开并点击连接。
「图书数据访问」显示实际数据库读取结果，不等同于系统的完全磁盘访问开关。
数据不存在、读取失败和权限拒绝分别显示。

请使用 `scripts/run-app.sh` 或 Finder 打开 `build/BooksBridge.app`。
构建必须使用有效的固定签名身份，失败会保留原应用，不再自动退回 ad-hoc。
默认身份为 `BooksBridge Dev`，可通过 `BOOKSBRIDGE_SIGNING_IDENTITY` 指定。
验收需通过 Finder 启动，在系统设置中亲自授予权限；命令行测试不能代替 TCC 验收。

# BooksBridge

macOS 上「读取苹果图书正在读什么 → 交给 LLM 问答」的应用。这是 **UI 骨架**：
不接 LLM，但读取侧、前后端桥、持久化、界面结构都已完整可用。

---

## 现在能做什么

- 菜单栏常驻 `BR` 图标。**左键先下拉状态菜单**，不直接跳窗口
- 菜单**上半是状态**（当前在读什么、进度、权限与配置是否就绪），**下半是操作**
  （打开界面 / 设置 / 返回图书 App / 退出）
- **自动检测**你正在图书 App 里读的书（书名、进度、精确位置），实时跟随翻页
- 检测到只是**提示**：点它才把书加入书库并进入它的对话页
- 侧栏按 `书名 → 对话`（1:N）组织，可新建对话
- **左下角「设置」**：模型与 API 配置、权限检测，类似 DSH 的两栏设置页
- 标准窗口（可拖可缩可最小化），也支持原生全屏
- 页面在前台时**在 Dock 里显示**（图标为程序化绘制的 `BR`），收起后应用仍常驻菜单栏
- 右上角 `← 返回图书` 回到图书 App，**不影响你的阅读位置**
- 会话、书库与设置持久化到磁盘，重启后恢复

## 现在不能做什么

- LLM 调用（设置能保存，但**不会发起任何请求**；composer 结构完整但禁用）
- RAG / 向量检索
- PDF 的阅读位置（EPUB 已支持）
- 划选浮层

---

## 快速开始

```bash
# 0. 一次性：创建本地签名证书（避免重新编译就丢系统权限授权）
./scripts/setup-signing.sh

# 1. 构建（会组装成 .app 并使用上一步的证书签名）
./scripts/build-app.sh

# 2. 运行
./scripts/run-app.sh

# 以原生全屏启动
./scripts/run-app.sh --fullscreen

# 开发前端时不重编译：改完 HTML/CSS/JS 只要重开窗口
./scripts/run-app.sh --dev
```

首次运行需要两项系统权限：

| 权限 | 用途 | 不给会怎样 |
|---|---|---|
| 完全磁盘访问权限 | 读取图书 App 的书库与阅读位置 | 检测不到任何书 |
| 辅助功能权限 | 读取屏幕可见正文与划选文本 | 仍可用，只是拿不到屏幕正文（骨架期未用到） |

**授权位置**：系统设置 → 隐私与安全性 → 完全磁盘访问权限 / 辅助功能。
应用在「设置 → 权限」页里有直达按钮，页面上还会显示**实际读取探测**结果。

### ⚠️ 两个容易踩的坑

**1. 从终端直接运行会"看起来有权限"**

macOS 的 TCC 授权按**进程主体**判定。从终端直接跑可执行文件时，
进程会继承终端已获得的权限；用 `open` 或 Finder 启动才是独立主体，
需要自己持有授权。实测对比：

| 启动方式 | TCC 主体 | 完全磁盘访问 | 辅助功能 |
|---|---|---|---|
| 终端直接跑 | 继承终端 | ✅ | ✅ |
| `open` / Finder | App 自己 | ❌（errno 1） | ❌ |

所以**验证权限必须用 `open` 启动**，不能靠终端跑的结果下结论。

**2. 需要一次性配置签名证书（重要）**

默认的 ad-hoc 临时签名下，TCC 把授权与内容哈希绑定，**每次重新编译都会丢失授权**。
解决方法是做一次本地自签名证书，之后 TCC 认的是证书身份，重新编译不再影响授权：

```bash
./scripts/setup-signing.sh    # 只需运行一次，不需要管理员密码
./scripts/build-app.sh         # 之后正常构建，签名会自动使用该证书
```

实测签名稳定性（改源码触发真实重编译）：

| | CDHash | 指定要求（TCC 认这个） |
|---|---|---|
| 改动前 | `80679468…` | `identifier "com.chris.booksbridge" and certificate leaf = H"da184be1…"` |
| 改动后 | `b7eabc79…` | **完全相同** |

二进制变了但指定要求不变 → 授权不会掉。

脚本做了三件事：
1. `openssl` 生成带 `codeSigning` 扩展的自签名证书（有效期 10 年）
2. 用 `-legacy` 打包 p12 后导入登录钥匙串（不加 `-legacy` 会因
   OpenSSL 3 的默认加密算法 macOS 不认而报 `MAC verification failed`）
3. `security add-trusted-cert -d -r trustRoot` 设为**用户级信任**——不需要 sudo；
   不设信任时身份会显示 `CSSMERR_TP_NOT_TRUSTED`，TCC 可能不认

`build-app.sh` 会自动检测该证书并使用；没有证书时退回 ad-hoc 并给出提示。

> 证书是自签名的，**不能用于分发**（别人机器上不信任）。仅用于本机开发。
> 若更换 Bundle ID，授权需要重做一次——TCC 同时认证书身份与 bundle id。

### 签名排查

```bash
# 当前用的是哪个身份
security find-identity -v -p codesigning | grep BooksBridge

# 这个应用的签名与"指定要求"（TCC 就是按它记授权的）
codesign -dvvv build/BooksBridge.app 2>&1 | grep -E "Authority|Identifier"
codesign -d --requirements - build/BooksBridge.app

# 重新创建证书（会改变身份，TCC 授权需重做一次）
security delete-identity -c "BooksBridge Dev"
./scripts/setup-signing.sh
```

### 自检报告

应用每次启动会写一份快照到
`$TMPDIR/booksbridge-permission-report.txt`（通常是
`/var/folders/.../T/booksbridge-permission-report.txt`），内容包括：
权限开关状态、**实际读取探测结果（含 errno）**、签名信息、UI 渲染与布局自检。
遇到问题时把这个文件发出来即可。

### 数据存放

| 文件 | 权限 | 内容 |
|---|---|---|
| `~/Library/Application Support/BooksBridge/store.json` | 0644 | 书库与对话 |
| `~/Library/Application Support/BooksBridge/settings.json` | **0600** | 服务商、模型、读取范围 |
| `~/Library/Application Support/BooksBridge/secret.json` | **0600** | API Key（单独存放，不混在配置里） |

> API Key 以明文落盘（靠 0600 限制为仅当前用户可读），**没有用 Keychain**。
> 取舍原因：Keychain 对未签名的本地应用每次读写都可能弹授权框，对自用工具摩擦过大。
> 若要分发，应改为 Keychain 或每次让用户输入。

---

## 架构

```
         图书 App 翻页
              │ 改写 .sqlite-wal
              ▼
      FileWatcher（DispatchSource，150ms 合并）
              │
              ▼
   ReadingCoordinator ────────► ReadingContext
   （BooksBridgeCore）          （书 + 位置 + 屏幕正文 + 划选）
              │
              │ onUpdate（后台队列）
              ▼
   ┌──────────────────────────────────────┐
   │ BooksBridgeApp（主线程）              │
   │  AppDelegate                          │
   │   ├ ConversationStore  书库/对话持久化 │
   │   ├ SettingsStore      模型/API 配置   │
   │   ├ StatusItemController  BR + 下拉菜单│
   │   ├ PageWindowController  窗口/全屏    │
   │   └ WebBridge ──push/invoke──► WKWebView
   │                                  （WebUI/）
   └──────────────────────────────────────┘
```

### 目录

```
swift/
├── Sources/
│   ├── BooksBridgeCore/        读取苹果图书的数据层（与 UI 无关，可单独复用）
│   │   ├── BooksPaths           容器/数据库/EPUB 路径发现
│   │   ├── SQLite               系统 libsqlite3 的只读薄封装
│   │   ├── BooksStore           BKLibrary + AEAnnotation + 当前书 plist
│   │   ├── CFI                  EPUB CFI 解析（按 271 条真实记录校正）
│   │   ├── EpubDocument         OPF 解析 + CFI → 章节正文
│   │   ├── HTMLText             XHTML → 纯文本
│   │   ├── AccessibilityReader  屏幕可见正文 + 划选 + 屏幕矩形
│   │   ├── FileWatcher          DispatchSource 监听 + 防抖
│   │   ├── Permissions          两项权限的检测与引导
│   │   └── ReadingCoordinator   装配各层，对外推送
│   ├── BooksBridgeApp/         菜单栏 App 宿主
│   │   ├── AppDelegate          生命周期 + 进入流程 + 状态推送
│   │   ├── ConversationStore    书库/对话持久化（原子写）
│   │   ├── SettingsStore        设置与 API Key（0600 权限）
│   │   ├── AppIconFactory       程序化生成 BR 图标
│   │   ├── ApplicationMenu      应用菜单栏（Dock 应用必需）
│   │   ├── StatusItemController 菜单栏 BR
│   │   ├── PageWindowController 原生全屏 / 无边框两条路径
│   │   ├── WebBridge            WKWebView + JSON 双向桥
│   │   └── WebUI/               HTML / CSS / JS 前端
│   ├── booksbridged/           命令行驱动（调试用）
│   ├── axtree/                 设计工具：读任意 App 的辅助功能树
│   ├── axmenubar/              设计工具：读菜单栏与弹出菜单
│   ├── axact/                  设计工具：对辅助功能元素执行动作
│   └── returnprobe/            设计工具：验证切回图书 App 是否影响阅读位置
└── Tests/                      57 个测试
```

---

## 关键设计决策

### 检测到 ≠ 进入

侧栏顶部的「现在在读」只是**实时提示**，只有点击才把书写进 `store.json`。
实现上，`ReadingCoordinator` 检测到的书只存在于内存（`latestContext`），
`ConversationStore` 完全不知道它的存在。

实测验证：只启动不点击时，`store.json` 的哈希不变。

### CFI 定位章节，辅助功能 API 提供"这一页"

CFI 尾部的字符偏移是相对图书 App 自己排版文档的位置，与剥离 HTML 后的
纯文本字符数**不同源**（同一位置一处是 `:124`、一处是 `:1`），不能直接切片。

因此分工是：

| 来源 | 提供 |
|---|---|
| CFI | 读到哪一章（跨会话稳定，可持久化） |
| 章节正文 | 整章文本（回答"这段前后发生了什么"） |
| 辅助功能 | 此刻屏幕上那几段 + 划选（回答"这句话什么意思"） |

### 返回图书是纯前台切换

实测（`Sources/returnprobe`）：`NSRunningApplication.activate()` 之后，
图书 App 的当前书与阅读位置**都不变**。所以返回按钮不需要任何状态恢复逻辑，
也不会把你翻到的那页弄丢。

### 为什么是标准窗口而不是无边框

早期版本用过 `.borderless` 铺满屏幕，问题很明显：没有标题栏，用户既不能拖也不能缩，
且窗口被压小时内容会互相挤压。现在默认是标准窗口（`styleMask` 含 `.titled`/`.resizable`），
内容最小尺寸 720×460，`visibleFrame` 居中摆放，不与菜单栏/Dock 重叠。

### 前端布局的硬约束

手写 flex 布局最容易出的问题是某个子项撑破容器后压到相邻区块上。
因此前端内置了**布局自检**：渲染后测量 `sidebar / topbar / thread / composer`
的矩形，两两做重叠判定，并把结果回报给宿主写进日志。
全部使用 flex 流式布局，**没有任何 absolute/fixed 定位**。

实测（窗口 720×460）：

```
sidebar=270x432  topbar=450x52  thread=450x288  composer=410x76   无重叠
（52 + 288 + 76 = 416，加边距正好填满窗口高度）
```

### 为什么不用 NSPanel

形态是"接管整屏 + 返回按钮"，此时"不抢焦点"这个需求已经消失，
而输入框必须能正常成为 key window。所以用普通 `NSWindow`。

---

## 前后端契约

### Swift → Web

```jsonc
{
  "message": "已进入《…》",          // 一句话状态
  "facts":  { "…": "…" },            // 自检键值对
  "detected": {                       // 实时检测，只是提示
    "assetID": "…", "title": "…", "author": "…",
    "progress": 0.471, "kind": "EPUB", "cfi": "…", "inLibrary": true
  },
  "detectionState": "ok",             // ok / noFullDiskAccess / booksNotRunning / noBookOpen / waiting
  "library": [                        // 持久化的书与对话
    { "assetID": "…", "title": "…", "author": "…",
      "conversations": [ { "id": "…", "title": "对话 1", "messageCount": 0, "updatedAt": "…" } ] }
  ],
  "active": { "assetID": "…", "conversationID": "…" },
  "permissions": { "fullDiskAccess": true, "accessibility": true }
}
```

### Web → Swift

| 指令 | 参数 | 作用 |
|---|---|---|
| `openBook` | `assetID` | 进入某书 workspace（不存在则加入并建首条对话） |
| `newConversation` | `assetID` | 新建对话并切过去 |
| `selectConversation` | `assetID, conversationID` | 切换对话 |
| `deleteConversation` | `assetID, conversationID` | 删除对话 |
| `removeBook` | `assetID` | 移出书库 |
| `backToLibrary` | — | 取消停留，回到选择态 |
| `returnToReader` | — | 返回图书 App |
| `hidePage` | — | 隐藏页面 |
| `showPermissions` | — | 弹权限自检 |
| `quit` | — | 退出 |
| `renderStats` | DOM 统计 | 前端回报渲染结果（用于自动化验证） |

---

## 调试

```bash
# 打包与运行环境自检
build/BooksBridge.app/Contents/MacOS/BooksBridgeApp --diagnostics

# 实时跟随翻页（命令行，不需要 UI）
swift/.build/debug/booksbridged --watch

# 看任意 App 的界面结构（做 UI 校准很有用）
swift/.build/debug/axtree --find "Books"

# 单元测试
cd swift && swift test
```

应用自身支持这些测试参数：

| 参数 | 作用 |
|---|---|
| `--show` | 启动后立即显示页面 |
| `--quit-after N` | N 秒后退出 |
| `--window-mode native\|frameless` | 指定窗口模式 |
| `--open-book <assetID>` | 模拟点击进入某书 |
| `--new-conversation <assetID>` | 模拟新建对话 |
| `--back-to-library` | 模拟回到书库 |
| `--return-after N` | N 秒后触发返回图书 |
| `--open-settings` | 启动后直接打开设置页 |
| `--window-size WxH` | 强制窗口内容尺寸（用于验证最小尺寸下的布局） |
| `--test-save-settings` | 模拟前端提交一份设置 |
| `--dump-status-menu` | 打印状态栏菜单结构（状态栏项无法用辅助功能 API 点击，只能这样验证） |
| `--diagnostics` | 打印环境信息后退出 |

---

## 实测数据

| 项目 | 结果 |
|---|---|
| CFI → 章节定位（全库 235 本） | 99.6% |
| CFI 数字路径 vs id 断言一致率 | 100% |
| 屏幕正文 vs CFI 章节正文一致率 | 97% |
| 翻页 → 位置更新延迟 | 0 秒（11/11 次） |
| 测试 | 57 个，全绿 |

---

## 已知限制

- 读图书 App 容器需要**完全磁盘访问权限**，因此 **Mac App Store 上架基本无望**，
  只能走开发者 ID 签名直接分发。本项目用的是本机自签名证书，
  **只能自用**，别人机器上不信任，也无法公证
- 图书 App 里未下载完的书，章节文件可能不在本地，此时只能定位到章名、取不到正文
- PDF 的位置是页码而非 CFI，走另一条路线，当前未实现
- `NSStatusItem` 在原生全屏空间下可能不可见，因此 `Esc` 与右上角返回按钮是主要出口
