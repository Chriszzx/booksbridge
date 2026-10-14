# 实测发现

这份文档记录**在本机（macOS 27.0.1 / 图书 9.0）实测得到的、关于苹果图书的事实**。
其中多条与直觉相反，且都是踩过坑才确认的。改动相关代码前请先读这里。

所有结论都标注了验证方式与样本量，便于判断可信度。

---

## 1. 苹果图书没有第三方插件机制

**结论：不存在任何官方或可行的第三方扩展点。**

三重证据：

| 检查 | 结果 |
|---|---|
| `Books.app/Contents/PlugIns` 下的 appex | 6 个全是系统扩展：通知内容 / Spotlight 索引 / QuickLook 缩略图 / 分享 / 存储管理 / AMS 营销。没有可注册的第三方类型 |
| AppleScript 字典 | **没有 `.sdef`**。`tell application "Books" to get name` 能返回，但 `properties` 直接报 -1728 |
| App Intents（`Resources/Metadata.appintents`） | 有 `OpenBookIntent`、`BookReaderNavigatePageInBookIntent`、`SearchBooksIntent` 等，但**没有任何「输出当前书 / 当前页 / 选中文本」的动作** |

`AEBookPlugins.framework` 名字有迷惑性，实为**苹果自用的内容插件框架**（EPUB/PDF 渲染插件），
不是扩展点。EPUB 正文由 WebKit 渲染（`BookEPUBWebProcessPlugin` + `BECFIUtilitiesJS`
注入 JS 到正文文档）。

**因此只能从外部旁路读取，不存在「写个插件挂进去」这条路。**

---

## 2. 数据链路（可用，但不是公开接口）

```
~/Library/Containers/com.apple.iBooksX/Data/
├── Library/Preferences/com.apple.iBooksX.plist     → kLastCurrentBookKey = 当前书 assetID
├── Documents/BKLibrary/BKLibrary-*.sqlite          → ZBKLIBRARYASSET（书名/作者/进度/路径）
└── Documents/AEAnnotation/AEAnnotation_*.sqlite    → ZAEANNOTATION（阅读位置 CFI）
```

EPUB 本体在 `~/Library/Mobile Documents/iCloud~com~apple~iBooks/Documents/`，
且**被解包成普通目录**（不是 zip），正文 `*.xhtml` 是明文。

### 阅读位置的关键性质

`ZANNOTATIONTYPE = 3` 是图书 App 自动写入的阅读位置标记。实测两条重要性质：

- **每本书只有 1 条记录，原地更新**（不是追加历史）
- 位置是标准 EPUB CFI，形如 `epubcfi(/6/30[id54]!/4/2/124/1,:1)`

这让「读取当前读到哪」变得非常简单：取那一条即可。

---

## 3. ⚠️ CFI 偏移不是章节内位置

**这是最容易做错的一点。**

CFI 尾部的 `:N` 看起来像「章节内字符偏移」，让人自然想到用它换算阅读百分比。
**实测证明不可行。**

在 53 条真实位置记录上统计 `偏移 / 章节长度`：

| 样本 | 偏移 | XHTML 字符数 | 比值 |
|---|---|---|---|
| 金瓶梅 | 1321 | 7689 | 0.172 |
| 金色梦乡 | 158 | 5597 | 0.028 |
| 张爱玲大全集 | 239 | 39442 | 0.006 |
| 脑髓地狱 | 147 | 51386 | 0.003 |

```
比 XHTML  : 均值 0.0059  标准差 0.0237   ← 标准差是均值的 4 倍
比纯文本  : 均值 0.0113  标准差 0.0329
```

标准差远大于均值，说明它**不是**一个稳定的比例量。

**原因**：该偏移是相对 XPath 指向的**那个文本节点**的，不是相对章节开头。
`/4/2/370/1` 指向第 370 个子节点，偏移是那个节点内部的。

**结论**：只能可靠地定位到**章节**。任何「读到本章百分之几」的推算都不可靠。
本项目的三档知识范围因此把边界定在章节上。

---

## 4. 翻页是「即写」，延迟 0 秒

实测监测 11 次翻页，`AEAnnotation-wal` 与 `BKLibrary-wal` 每次都被改写，
位置记录时间戳与当前秒**完全一致**。

**因此不需要轮询** —— 用 `DispatchSource` 监听 `.sqlite-wal` 的写入事件即可。

监听时要注意：SQLite 在 checkpoint 时可能**替换**而非改写文件（inode 变化），
所以需同时监听数据库本体与 `-wal`，并在 `delete`/`rename` 后自动重挂。

---

## 5. 辅助功能 API 能读到正文，不需要 OCR

macOS 27 上，图书 App 的 WebKit 正文在辅助功能树里是大量 `AXStaticText` 节点，
**内容是干净的正文**（不是渲染后的图片）。实测抓取到 32 段可见文字。

社区里有些老帖说「只能拿到窗口标题」，在本版本已不成立。

### 划选也能拿到，且带屏幕矩形

实测触发划选后：

| 内容 | 屏幕矩形 |
|---|---|
| 完整段落（101 字） | `(486, 319, 414, 70)` |
| 另一段（16 字） | `(969, 319, 224, 21)` |

**但注意**：`AXSelectedText` 返回的很可能是**整个段落**，而非用户划的那几个字
（三次采样里两次返回完整段落）。字符级范围 `AXSelectedTextRange` 是否可用**尚未验证**。

**因此**：可以可靠地做「就某一段提问」，但做「划词就地问」需要先验证字符级范围。

---

## 6. ⚠️ 权限判断：errno 相同，必须靠外部信号区分

`FileManager.isReadableFile` 对 TCC 拦截会**误报 `true`**，必须真正 `opendir`/`open`。

但更隐蔽的问题是：**受 TCC 保护时返回的 `errno` 是 `ENOENT`**，
与「路径真的不存在」完全无法从错误码区分。

早期实现据此报「图书数据尚未创建」，把**没权限**误报成**还没在图书 App 里打开过书**，
让排查方向完全跑偏。

**解决办法**：用「图书 App 是否安装」作为外部信号。
`/System/Applications/Books.app` 不受 TCC 保护，可安全探测：

| 情况 | 判定 |
|---|---|
| 装了图书 App，容器读不到 | **未授权** |
| 没装图书 App，容器读不到 | 数据本来就不存在 → 无法判定 |

这个信号做成可注入参数，使测试不依赖「本机是否装了图书 App」。

---

## 7. ⚠️ 终端启动 ≠ 应用启动（TCC 主体不同）

**这是最容易得出错误结论的地方。**

| 启动方式 | TCC 主体 | 实测结果 |
|---|---|---|
| 终端直接跑可执行文件 | **继承终端**的权限 | 完全磁盘访问 ✅ / 辅助功能 ✅ |
| `open` / Finder 启动 | **App 自己**（独立主体） | ❌ 容器路径都看不到 |

同一份二进制、同一时刻，两种方式结论完全相反。

**因此：验收权限必须用 `open` 或 `run-app.sh`。从终端跑的结果不能证明应用有权限。**

开发者自身若已给终端授予完全磁盘访问，会长期看不到这个差异。

---

## 8. 返回图书 App 无副作用

实测 `NSRunningApplication.activate()` 把图书 App 唤到前台：

```
切换前位置: epubcfi(/6/38[id58]!/4/2/370/1,:1)
切换后位置: epubcfi(/6/38[id58]!/4/2/370/1,:1)   ← 完全一致
当前书    : 未变
```

**结论**：返回只需 `activate`，不需要 `ibooks://` 那种「重新打开书」的重动作。
后者反而有丢失位置的风险。

`ibooks:` 由图书 App 注册（`claimed schemes: ibooks:, itms-books:, itms-bookss:`），
作为备用存在但不必要。

---

## 9. 数据文件的解析陷阱

| 陷阱 | 现象 | 应对 |
|---|---|---|
| 偏好设置 plist 有越界日期字段 | `PropertyListSerialization` 整体抛错，拿不到任何键 | 三级降级：plist → `plutil` 单键提取 → 二进制裸扫描 |
| 作者字段带 Unicode 私有区字符 | 实测值 `\u{E83A}UnknownAuthor`，与字符串比较不相等 | 按 Unicode 类别剥掉控制/格式/私有区字符 |
| CFI 的 id 断言归一化 | `.` `-` 会被写成 `_` | 匹配时归一化 |
| 书籍文件不完整 | manifest 声明了章节但磁盘上没有 | 按「章节缺失」降级，不崩溃 |
| 从未标注过 | `AEAnnotation` 数据库不存在 | 监听父目录等它出现 |

**全库可靠性实测**（235 本有位置记录的电子书）：

```
CFI → 章节定位成功 : 234 / 235 = 99.6%
唯一失败          : 书籍正文文件本身不在磁盘（非解析器问题）
```

---

## 10. 交叉验证：两条独立路线一致

用两条完全独立的路径取同一段正文：

- **数据库路线**：CFI → 章节文件 → 纯文本
- **辅助功能路线**：屏幕可见文本

比对结果：**命中 30 / 未命中 1 → 一致率 97%**
（唯一未命中项是窗口标题，不算正文）

两条路互相印证，说明实现可靠。

---

## 11. DeepSeek API 的当前形态

来自官方文档（api-docs.deepseek.com）核对：

- 模型标识当前是 **`deepseek-flash`** / **`deepseek-v4-pro`**
  （不是老文档里的 `deepseek-chat` / `deepseek-reasoner`）
- 思考模式用 **`thinking` 对象**控制，不靠选模型名：
  `{"type":"enabled","reasoning_effort":"low|high|max"}`，`none` 关闭
- 流式最后一条 chunk 的 `choices` 数组含一个**无新内容**的元素，
  携带 `finish_reason` 与 `usage`；需同时处理，否则会丢用量或截断
- `usage.prompt_tokens_details.cached_tokens` 反映上下文缓存命中，
  反复带同一本书时这个值很高，直接影响计费

---

## 12. 自签名证书的可行性与坑

| 坑 | 现象 | 应对 |
|---|---|---|
| OpenSSL 3 默认加密的 p12 | `security import` 报 `MAC verification failed during PKCS12 import` | 打包时加 `-legacy` |
| 未设信任的证书 | 身份显示 `CSSMERR_TP_NOT_TRUSTED` | `security add-trusted-cert -d -r trustRoot`（用户级，不需要 sudo） |
| 私钥访问授权 | 签名时弹钥匙串授权框 | 导入时加 `-T /usr/bin/codesign` |

**稳定性实测**（改源码触发真实重编译）：

| | CDHash | 指定要求（TCC 认这个） |
|---|---|---|
| 改动前 | `80679468…` | `identifier "com.chris.booksbridge" and certificate leaf = H"da184be1…"` |
| 改动后 | `b7eabc79…` | **完全相同** |

二进制变了但指定要求不变 → 重新编译不再丢失授权。

**但注意**：TCC 授权不会自动从旧身份迁移到新身份。
更换证书后必须重新授权（用 `tccutil reset All com.chris.booksbridge` 清掉旧记录再授）。
