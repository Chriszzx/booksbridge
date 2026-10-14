# BooksBridge 工程骨架

macOS 上「读取苹果图书正在读什么 → 交给 LLM 问答」的读取侧实现。

本目录是**工程骨架**：不包含 UI、不包含 LLM 调用，只负责把「用户此刻在读什么」
这件事做成一条可靠、可测试、权限可控的数据管道。

Python 原型在上一级目录（`../booksbridge.py`），用于最初的技术验证；
本目录是生产化的 Swift 实现。

---

## 为什么是这套架构

前置调研（实测 macOS 27 / 图书 9.0）确定了三件事，直接决定了架构：

1. **图书 App 没有第三方扩展点。** 它的 appex 全是系统扩展（通知、Spotlight、
   QuickLook、分享、存储管理），App Intents 里也没有「获取当前书 / 当前页」这类动作。
   所以不存在「写个插件挂进去」这条路，只能从外部旁路读取。

2. **但图书 App 自己把状态写得非常规整。** 当前书、阅读进度、精确位置
   （标准 EPUB CFI）都在可读的 SQLite / plist 里，而且 EPUB 被解包成目录、正文是明文。

3. **位置是翻页即写的。** 实测每次翻页 `AEAnnotation-wal` 与 `BKLibrary-wal`
   同时被改写，延迟为 0 秒。这意味着不需要轮询，文件监听就够。

---

## 数据链路

```
图书 App 翻页
     │  改写 .sqlite-wal
     ▼
FileWatcher ──────────────► ReadingCoordinator ──────► ReadingContext
（DispatchSource，150ms 合并）      │                    （单一事实来源）
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
  BooksStore                  EpubDocument               AccessibilityReader
  ├ 当前书 (plist)            ├ OPF manifest/spine       └ 屏幕可见正文 + 划选
  ├ 书目元数据 (BKLibrary)    ├ CFI → 章节
  └ 阅读位置 (AEAnnotation)   └ 章节纯文本
```

三路数据各司其职：

| 来源 | 提供 | 适合回答 |
|---|---|---|
| `ReadingPosition` (CFI) | 「读到哪一章的哪个位置」 | 跨会话恢复、进度跟踪 |
| `EpubDocument` | **整章**正文 | 「这一段前后发生了什么」 |
| `AccessibilityReader` | **当前屏**可见正文 + 划选 | 「这句话什么意思」 |

> ⚠️ **关键设计决策**：CFI 尾部的字符偏移**不能**用来切分正文。
> 它是相对图书 App 自己排版文档的位置，与剥离 HTML 后的纯文本字符数不同源
> （同一位置一处是 `:124`、一处是 `:1`）。所以「当前这一页」一律走辅助功能 API，
> CFI 只负责定位到章节。

---

## 权限

两项权限都是**必需**的，且都必须在代码里可检测、可解释、可引导：

| 权限 | 用途 | 检测方式 |
|---|---|---|
| 完全磁盘访问权限 | 读取 `~/Library/Containers/com.apple.iBooksX` | 真正 `open()` 并处理 `EPERM`——`FileManager.isReadableFile` 对 TCC 拦截会误报 `true` |
| 辅助功能权限 | 读取窗口内正文与划选 | `AXIsProcessTrusted()` |

**产品层面的硬约束**：读其它 App 的沙盒容器需要完全磁盘访问权限，
因此 **Mac App Store 上架基本无望**，只能走开发者 ID 签名直接分发。

---

## 目录结构

```
swift/
├── Package.swift
├── Sources/
│   ├── CSQLite/                    系统 libsqlite3 的 module map（无第三方依赖）
│   ├── BooksBridgeCore/
│   │   ├── BooksPaths.swift        容器 / 数据库 / EPUB 的路径发现
│   │   ├── SQLite.swift            只读薄封装
│   │   ├── Models.swift            Book / ReadingPosition / ReadingContext
│   │   ├── BooksStore.swift        BKLibrary + AEAnnotation + plist 读取
│   │   ├── CFI.swift               EPUB CFI 解析
│   │   ├── EpubDocument.swift      OPF 解析 + CFI → 章节正文
│   │   ├── HTMLText.swift          XHTML → 纯文本
│   │   ├── FileWatcher.swift       DispatchSource 监听 + 合并
│   │   ├── Permissions.swift       权限检测与引导
│   │   ├── AccessibilityReader.swift 读取屏幕可见正文
│   │   └── ReadingCoordinator.swift 装配各层，对外推送变化
│   └── booksbridged/
│       └── main.swift              CLI 驱动
└── Tests/BooksBridgeCoreTests/     31 个测试，全绿
```

---

## 使用

```bash
swift build
swift test

./.build/debug/booksbridged                # 当前状态：权限 / 书 / 位置 / 章节 / 屏幕正文
./.build/debug/booksbridged --permissions  # 只查权限
./.build/debug/booksbridged --list         # 最近在读
./.build/debug/booksbridged --watch        # 实时跟随翻页，Ctrl-C 退出
```

---

## 实测可靠性

| 项目 | 结果 |
|---|---|
| CFI → 章节定位（全库 235 本） | **99.6%**（唯一失败是书籍文件本身不完整） |
| CFI 数字路径 vs id 断言一致率 | **100%**（4 本真实书籍逐一核对） |
| 屏幕正文 vs CFI 章节正文一致率 | **97%**（唯一未命中项是窗口标题） |
| 翻页 → 位置更新延迟 | **0 秒**（11/11 次） |

---

## 已处理的边界情况

- **偏好设置 plist 解析失败**：文件里存在越界日期字段会让 `PropertyListSerialization`
  整体抛错，因此做了三级降级：plist 解析 → `plutil` 单键提取 → 二进制裸扫描。
- **CFI 的 id 断言归一化**：CFI 会把 `.` `-` 写成 `_`，需要模糊匹配。
- **书籍文件不完整**：manifest 声明了章节但磁盘上没有，按"章节缺失"降级而不是崩溃。
- **从未标注过**：`AEAnnotation` 数据库尚不存在时，改为监听父目录等它出现。
- **SQLite checkpoint**：可能替换而非改写文件（inode 变化），因此同时监听
  数据库本体与其 `-wal`，并在 `delete`/`rename` 后自动重挂。
- **回调风暴**：WebKit 重绘会造成 AX 文本抖动，用变化签名 + 150ms 合并窗口抑制。

---

## 尚未实现（下一步）

- [ ] LLM 接入与流式问答
- [ ] UI（菜单栏 / 悬浮窗）
- [ ] RAG：章节切分、向量化、按当前位置检索
- [ ] PDF 路线（`ZCONTENTTYPE = 3`，位置是页码而非 CFI）
- [ ] 权限引导 UI（当前 CLI 只打印提示）
- [ ] 代码签名与公证
