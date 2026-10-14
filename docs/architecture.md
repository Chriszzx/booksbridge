# 架构

## 分层

三层 + 一个宿主，依赖方向单向向上：

```
┌─────────────────────────────────────────────────────────────┐
│ BooksBridgeApp           菜单栏宿主、窗口、WKWebView 前端    │
│  ├ AppDelegate           生命周期、指令分发、状态推送         │
│  ├ ReadingAssistant      预处理与问答编排                    │
│  ├ ConversationStore     书库/对话持久化                     │
│  ├ SettingsStore         设置与 API Key（0600）              │
│  ├ StatusItemController  菜单栏 BR + 下拉菜单                │
│  ├ PageWindowController  标准窗口 / 原生全屏                 │
│  ├ WebBridge             WKWebView 双向 JSON 桥              │
│  └ WebUI/                HTML / CSS / JS                     │
└───────────────────────────┬─────────────────────────────────┘
                            │ 依赖
┌───────────────────────────┴─────────────────────────────────┐
│ BooksBridgeLLM           LLM 侧，不碰 UI                     │
│  ├ ChatClient            OpenAI 兼容客户端（流式 + 非流式）   │
│  ├ SSEDecoder            SSE 增量解析                        │
│  ├ BookPreprocessor      整本书 → 结构化「书籍说明」          │
│  ├ BookKnowledge         说明的数据结构与缓存                │
│  ├ ContextBuilder        按知识范围检索与组装上下文           │
│  └ PromptBuilder         提示词与消息序列                    │
└───────────────────────────┬─────────────────────────────────┘
                            │ 依赖
┌───────────────────────────┴─────────────────────────────────┐
│ BooksBridgeCore          读取苹果图书，与 UI/LLM 无关         │
│  ├ BooksPaths            容器/数据库/EPUB 路径发现            │
│  ├ SQLite                系统 libsqlite3 只读薄封装           │
│  ├ BooksStore            BKLibrary + AEAnnotation + plist    │
│  ├ CFI                   EPUB CFI 解析                       │
│  ├ EpubDocument          OPF 解析 + CFI → 章节正文            │
│  ├ HTMLText              XHTML → 纯文本                      │
│  ├ AccessibilityReader   屏幕可见正文 + 划选 + 屏幕矩形        │
│  ├ FileWatcher           DispatchSource 监听 + 防抖           │
│  ├ Permissions           权限检测与引导                       │
│  ├ ReadingCoordinator    装配各层，对外推送变化                │
│  └ AppPaths              应用自有数据目录                     │
└─────────────────────────────────────────────────────────────┘
```

**Core 与 LLM 都不依赖 App**，可独立复用与测试。Core 甚至可以用在完全不同的界面里。

---

## 读取链路

```
图书 App 翻页
     │ 改写 .sqlite-wal
     ▼
FileWatcher（DispatchSource，150ms 合并）
     │
     ▼
ReadingCoordinator ──────────► ReadingContext
     │                          { 书, 位置(CFI), 屏幕正文, 划选 }
     │ onUpdate（内部串行队列）
     ▼
AppDelegate（hop 回主线程）
     ├─ 更新状态栏 tooltip 与菜单
     └─ WebBridge.push ──► 前端渲染
```

三路数据各司其职：

| 来源 | 提供 | 适合回答 |
|---|---|---|
| `ReadingPosition`（CFI） | 读到哪一章 | 跨会话恢复、定位 |
| `EpubDocument` | **整章**正文 | 「这段前后发生了什么」 |
| `AccessibilityReader` | **当前屏**可见正文 + 划选 | 「这句话什么意思」 |

> ⚠️ CFI 尾部的字符偏移**不能**用来切分正文。它是相对 XPath 指向的那个文本节点，
> 不是相对章节开头。实测见 [findings.md](findings.md)。

---

## 问答链路

```
用户提问
   │ 对话范围已锁定；按 assetID 重新读取 Books 数据库进度
   ▼
ReadingAssistant.ask(question, scope, visibleText, history)
   │
   ├─ ContextBuilder.build(...)          按 scope 定边界 + 关键词检索
   │     ├─ 范围：upToProgress / currentChapter / wholeBook
   │     ├─ 优先带上屏幕可见正文
   │     └─ 再从允许范围内检索相关段落
   │
   ├─ PromptBuilder.build(...)           拼成消息序列
   │     ├─ system：角色 + 范围约束 + 反剧透 + 反幻觉
   │     └─ user：可用材料 + 屏幕正文 + 进度 + 问题
   │
   ▼
ChatClient.stream(...)  ──SSE──►  .content / .reasoning / .finished
   │
   ▼
AppDelegate.handleAssistantEvent
   ├─ 增量推给前端（逐字渲染）
   └─ 结束后落盘到 ConversationStore
```

### 三档知识范围 = 对话固定的剧透边界

```
      已读章节        当前章        后续章节
   ┌──────────┬──────────────┬──────────────┐
   │          │              │              │
   │  读到这为止 ────────────┘              │
   │          │                             │
   │  整章（含未读）─────────────────────────┘   ← 不含后续章节
   │          │              │              │
   │  整本书 ──────────────────────────────┘
   └──────────┴──────────────┴──────────────┘
```

边界落在**章节**而非章内百分比 —— 因为章内位置无法可靠计算（见 findings）。

---

## 书籍预处理

一本 10 万字的书约 15 万 token，每次提问都带上既慢又贵。预处理把它压缩成
几 k token 的「书籍说明」：

```
整本书正文
    │
    ├─ ≤ 6 万字符 ──► 一次调用，直接产出说明书
    │
    └─ > 6 万字符 ──► map-reduce
                         │
                         ├─ 按章节边界切成 ≤2 万字符的块
                         ├─ 每块单独摘要（map）
                         └─ 各块摘要汇总成说明书（reduce）
```

产出结构固定为五节：书籍概览 / 内容脉络 / 核心概念与术语 / 结构形式 / 关键线索。
其中「内容脉络」承担**定位能力** —— 让模型知道某内容大致在书里哪个位置。

**缓存失效**依据完整 UTF-8 正文的 `sha256-v1:` 指纹，读取和写入使用同一函数。
进入书籍只读取本地章节和有效缓存；全书预处理须在整本书范围显式触发。

---

## 前后端契约

### Swift → Web

宿主只有一个推送入口（`WebBridge.push` → `window.booksbridge.onState`），
前端按 payload 里出现哪些字段决定更新什么。

```jsonc
{
  // 一句话状态
  "message": "已进入《…》",
  "facts": { "…": "…" },              // 自检键值对

  // 实时检测（只提示，不代表已进入）
  "detected": {
    "assetID": "…", "title": "…", "author": "…",
    "progress": 0.471, "kind": "EPUB", "cfi": "…", "inLibrary": true
  },
  "detectionState": "ok",   // ok | disconnected | dataUnavailable
                            // | noFullDiskAccess | booksNotRunning
                            // | noBookOpen | transientError | waiting

  // 持久化的书与对话（不含消息正文）
  "library": [{
    "assetID": "…", "title": "…", "author": "…",
    "conversations": [
      { "id": "…", "title": "对话 1", "messageCount": 3, "updatedAt": "…" }
    ]
  }],

  // 当前停留位置；消息正文随它一起来，供前端整段重绘历史
  "active": {
    "assetID": "…", "conversationID": "…",
    "messages": [{ "role": "user", "text": "…", "createdAt": "…" }]
  },

  // 设置与元数据
  "settings": { "provider": "deepseek", "model": "deepseek-flash",
                "defaultScope": "upToProgress", "thinkingLevel": "off",
                "hasAPIKey": true, "isConfigured": true, "…": "…" },
  "providers": [ … ], "knowledgeScopes": [ … ], "thinkingLevels": [ … ],
  "permissionProbe": { "probes": [ … ], "signature": "…" },
  "assistant": { "preparation": "已理解全书 · 39 章 / 128k 字", "ready": true },

  // 问答流式事件
  "chatEvent": { "kind": "delta", "text": "…" },
                // kind: reasoning | delta | finished | error
  "openSettings": true       // 让前端切到设置页
}
```

### Web → Swift

| 指令 | 参数 | 作用 |
|---|---|---|
| `ready` | — | 前端就绪，开通推送 |
| `openBook` | `assetID` | 进入某书 workspace（不存在则加入并建首条对话） |
| `newConversation` | `assetID` | 新建对话并切过去 |
| `selectConversation` | `assetID, conversationID` | 切换对话 |
| `deleteConversation` | `assetID, conversationID` | 删除对话 |
| `removeBook` | `assetID` | 移出书库 |
| `backToLibrary` | — | 取消停留，回到选择态 |
| `ask` | `question, scope` | 提问 |
| `cancelAnswer` | — | 中断回答 |
| `reprocessBook` | — | 强制重做预处理 |
| `connectBooks` | — | 连接苹果图书（含请求辅助功能） |
| `recheckPermissions` | — | 只重新检测，不弹授权框 |
| `openSystemSettings` | `which` | 打开系统设置对应面板 |
| `saveSettings` | 设置字段 | 保存设置 |
| `returnToReader` | — | 返回图书 App |
| `hidePage` | — | 隐藏窗口 |
| `quit` | — | 退出 |
| `renderStats` | DOM 统计 | 前端回报渲染结果（自动化验证用） |

---

## 关键设计决策

### 检测到 ≠ 进入

侧栏顶部「现在在读」只是**实时提示**，只有点击才把书写进 `store.json`。
实现上检测到的书只存在于内存（`latestContext`），`ConversationStore` 完全不知道它。

实测验证：只启动不点击时 `store.json` 哈希不变。

### 启动不主动申请权限

已具备辅助功能与数据读取权限时自动恢复检测；权限不足时显示连接入口，不主动弹授权框。
这是为了解决 TCC 授权弹窗时机不可控的问题（详见 [permissions.md](permissions.md)）。

### 统一的阅读范围

`ScopedReading` 为同一份本地 EPUB 计算三种权限前缀：书首至当前页末尾、书首至当前章末尾、全书。
当前窗口可见文字与原文唯一匹配，确定章内边界；不能可靠定位时停止请求。
CFI 只辅助定位章节，不能把节点偏移当成章节百分比。双页跨章按文本顺序匹配。
`ReadingTools` 仅持有裁剪后的内容，提供有长度限制的 search/read；模型最多补充读取两轮。
正文只保留当前书的内存副本，不创建三份磁盘数据。

实时状态由当前 Books 阅读窗口识别，文件变化、应用激活和一秒轮询触发采集。
唤起应用和打开菜单也主动刷新；检测失效会清空旧状态。聊天仍绑定原书。
对话消息记录读取边界，回退后不再把超过新边界的消息送给模型；旧的未标记消息仅用于展示。

### 离线构建与前端依赖

SQLite 用系统 `libsqlite3`（自带 module map）；网络用 `URLSession`；
界面用系统 WebKit。整个工程 `Package.swift` 没有任何外部依赖，
构建不需要联网拉包。Markdown 使用随源码打包的 Marked 与 DOMPurify，版本和许可证见 WebUI/vendor。

### 前端用 WKWebView 而非纯原生

最值得复用的恰好是**消息区的排版**（流式 Markdown、行内样式、折叠块），
用原生重写性价比极低。侧栏那种规则列表用哪边都行，于是整体走 Web。

### 为什么不用 NSPanel

形态是「接管整屏 + 返回按钮」，此时「不抢焦点」的需求已消失，
而输入框必须能正常成为 key window，所以用普通 `NSWindow`。

### 权限判断必须真读文件

`FileManager.isReadableFile` 对 TCC 拦截会误报 `true`，必须真正 `opendir`/`open`。
且受保护时 `errno` 是 `ENOENT`，与「文件真的不存在」无法从错误码区分 ——
需借助「图书 App 是否安装」这一外部信号（详见 permissions.md）。

---

## 线程约定

| 组件 | 所在线程 | 说明 |
|---|---|---|
| `FileWatcher` | 自有串行队列 | DispatchSource |
| `ReadingCoordinator` | 自有串行队列 | 采集与去重 |
| `AppDelegate` / `WebBridge` | 主线程 | `@MainActor`，AppKit 与 WKWebView 要求 |
| `ReadingAssistant` | 主线程 | `@MainActor`，内部用 Task 并发网络请求 |
| `BookKnowledgeStore` | actor | 文件读写隔离 |
| `ChatClient` | 无状态 | 可任意并发调用 |

跨层回调统一 `Task { @MainActor in … }` hop 回主线程。

## 2026-10-14 问答边界修订

对话首次提问时持久化 scope；后续请求无法切换范围，设置里的默认范围只影响新对话。
每次提问按对话书籍的 assetID 重新读取书目与 CFI，屏幕正文仅来自当前确实打开的同一本书。
受限范围无法定位时停止请求。全书摘要只用于 wholeBook，其他两档检索允许的原文。
旧格式对话的历史保留展示，但锁定范围之前的旧消息不作为 agent 上下文。
upToProgress 包含当前章开头至当前页末尾；第一章同样通过可见文本定位前缀。

## 可选摘要与请求预算

新建或切换对话仅检查本地正文和摘要指纹，不调用 API。用户点击生成并确认服务商、模型与用量后才上传全书生成摘要；可取消和清除。该操作不锁定或扩大对话权限。
缓存保存全书摘要和 SHA-256 指纹，摘要只用于全书权限。摘要失效不自动重做。
请求预算包含提示词、问题、最近历史及检索片段；回答另设输出上限。历史最多八条并按字符预算裁减。
API 测试只发送固定的极短探测文字，不发送书籍或聊天内容。前端展示检测时间、延迟与结果，配置改变后失效。
