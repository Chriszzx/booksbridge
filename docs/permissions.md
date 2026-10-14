# 权限与签名

这个应用需要两项系统权限，而 macOS 的 TCC（Transparency, Consent, and Control）
有两处极易踩的坑。这份文档把机制、现象、排查方法讲清楚。

---

## 需要什么权限

| 权限 | 用途 | 不给会怎样 |
|---|---|---|
| 完全磁盘访问 | 读取图书 App 的书库与阅读位置 | 检测不到任何书 |
| 辅助功能 | 读取屏幕可见正文与划选文字 | 基本功能仍可用，但拿不到屏幕正文 |

图书 App 没有插件机制（见 [findings.md](findings.md)），
只能从外部旁路读取它的数据文件，因此必须授权。

---

## ⚠️ 坑一：从终端启动 ≠ 应用启动

**这是最容易得出错误结论的地方。**

TCC 按**进程主体**判定权限。从终端直接跑可执行文件时，进程会**继承终端**已获得的权限；
用 `open` 或 Finder 启动才是独立主体，需要自己持有授权。

实测对比（同一份二进制、同一时刻）：

| 启动方式 | TCC 主体 | 完全磁盘访问 | 辅助功能 |
|---|---|---|---|
| 终端直接跑 | 继承终端 | ✅ 已授权 | ✅ 已授权 |
| `open` / Finder | App 自己 | ❌ `errno 1` | ❌ |

**结论：验收权限必须用 `./scripts/run-app.sh` 或 Finder。
从终端跑的结果不能证明应用有权限。**

开发者自身若给过终端完全磁盘访问，会长期看不到这个差异。
本机历史记录中，直接执行测试的 TCC responsible 是 `com.deepseek.dsh`，
其成功结果**不能**证明 BooksBridge 自身有权限。

---

## ⚠️ 坑二：更换签名身份后授权不会自动迁移

TCC 把授权记录与代码签名绑定。本机 tccd 日志曾明确显示
Accessibility / SystemPolicyAllFiles / SystemPolicyAppDataDetailed 三类
`Failed to match existing code requirement`：

```
旧授权绑定 cdhash 337f74225d2db146cbeac9468d0e990a6d5c9890
当前应用绑定固定证书
```

**有效签名并不会自动迁移旧的 TCC 授权。** 更换证书后必须重新授权：

```bash
# 清掉旧记录（只针对本应用，绝不要对其他应用执行）
/usr/bin/tccutil reset All com.chris.booksbridge
```

这不是每次构建或启动都该做的事。

---

## 连接流程

因为 TCC 弹窗时机不可控，应用**启动时不主动读取受保护目录，也不弹授权框**：

```
启动
 └─ 只显示界面；dataAccess = .unknown("尚未连接 Apple Books")
    （已有书库与对话可离线浏览）

用户点「设置 → 权限 → 连接 Apple Books」
 └─ reconnectBooks(requestAccessibility: true)
      ├─ 停止并重建 ReadingCoordinator（connectionGeneration 递增，丢弃旧回调）
      ├─ 探测 dataAccess = Permissions().fullDiskAccessStatus()
      ├─ 刷新 permissionProbe
      ├─ 若辅助功能未授予 → 弹一次系统引导框
      └─ 数据可读才启动监听
```

- 「连接 Apple Books」会**同时**请求辅助功能权限
- 「重新检测」只重新探测，**不弹授权框**
- 从系统设置返回应用会自动重新检测
- 若系统要求重启，退出 BooksBridge 后重新打开再点连接

界面上「图书数据访问」显示的是**实际数据库读取结果**，
不等同于系统设置里的「完全磁盘访问」开关。三种情况分别显示：

| 显示 | 含义 |
|---|---|
| 已授权 | 真正读到了数据库 |
| 未授权 | 被 TCC 拦截 |
| 无法判定 | 数据本来就不存在 |

---

## 为什么不能用 `isReadableFile`，以及 `errno` 的陷阱

**第一层**：`FileManager.isReadableFile` 对 TCC 拦截会**误报 `true`**，
所以必须真正 `opendir` / `open`。

**第二层**（更隐蔽）：受 TCC 保护时返回的 `errno` 是 **`ENOENT`**，
与「路径真的不存在」**无法从错误码区分**。

早期实现据此报「图书数据尚未创建」，把**没权限**误报成**还没在图书 App 里打开过书**，
让排查方向完全跑偏。

**解决办法**：用一个不受 TCC 保护的外部信号做交叉判断 ——
**图书 App 是否安装**（`/System/Applications/Books.app`）：

| 情况 | 判定 |
|---|---|
| 装了图书 App，容器读不到 | **未授权** |
| 没装图书 App，容器读不到 | 数据本来就不存在 → 无法判定 |

该信号在 `Permissions.init` 里可注入，使测试不依赖「本机是否装了图书 App」。

---

## 签名

### 为什么需要固定签名

默认的 ad-hoc 临时签名下，CDHash 随内容变化，
**每次重新编译都会让已授的权限失效**。

用一张固定的自签名证书后，TCC 认的是证书身份，重新编译不再影响授权：

```
指定要求 = identifier "com.chris.booksbridge"
        and certificate leaf = H"da184be1…"
```

实测（改源码触发真实重编译）：CDHash 从 `80679468…` 变为 `b7eabc79…`，
而**指定要求完全不变**。

### 一次性配置

```bash
./scripts/setup-signing.sh
```

脚本做三件事：

1. `openssl` 生成带 `codeSigning` 扩展的自签名证书（有效期 10 年）
2. 用 **`-legacy`** 打包 p12 后导入登录钥匙串
   （不加 `-legacy` 会因 OpenSSL 3 的默认加密算法 macOS 不认而报
   `MAC verification failed during PKCS12 import`）
3. `security add-trusted-cert -d -r trustRoot` 设为**用户级信任**
   （不需要 sudo；不设信任时身份显示 `CSSMERR_TP_NOT_TRUSTED`，TCC 可能不认）

导入时加 `-T /usr/bin/codesign` 授权 codesign 使用私钥，避免签名时弹框。

### 构建时的行为

`build-app.sh` **不再静默退回 ad-hoc**：

- 找不到签名身份 → 报错退出，**保留现有应用**
- 签名后先 `codesign --verify --deep --strict`
- 只有验证通过才原子替换旧应用（旧应用临时改名为 `previous.app`）

这是刻意的：静默换签名会让 TCC 授权失效而用户毫无察觉。
可用 `BOOKSBRIDGE_SIGNING_IDENTITY` 指定其他身份。

> 自签名证书**仅本机有效**，别人机器上不信任，不能用于分发。

---

## 自检报告

每次启动会写一份快照到：

```
$TMPDIR/booksbridge-permission-report.txt
# 通常是 /var/folders/.../T/booksbridge-permission-report.txt
```

内容包含权限状态、**实际读取探测结果（含 errno）**、签名信息、
UI 渲染与布局自检。遇到问题把这个文件发出来即可。

查看方式：

```bash
cat "$(find /var/folders -name booksbridge-permission-report.txt 2>/dev/null | head -1)"
```

---

## 排查清单

按顺序检查，每一步都能独立证伪：

```bash
# 1. 当前用的是哪个签名身份
security find-identity -v -p codesigning | grep BooksBridge

# 2. 这个应用的签名与"指定要求"（TCC 就是按它记授权的）
codesign -dvvv build/BooksBridge.app 2>&1 | grep -E "Authority|Identifier"
codesign -d --requirements - build/BooksBridge.app

# 3. 应用自己怎么说（必须用 open 启动才有意义）
open build/BooksBridge.app
cat "$(find /var/folders -name booksbridge-permission-report.txt 2>/dev/null | head -1)"

# 4. 数据层是否真的读得到（这条只反映运行它的那个进程）
swift/.build/debug/booksbridged --permissions
```

| 现象 | 可能原因 |
|---|---|
| 报告里「完全磁盘访问：未授权」 | 需要授予，或换签名后未重新授权 |
| 报告里探测为空、容器不可见 | 同上 |
| 终端跑正常、`open` 跑不正常 | 正常现象，见「坑一」 |
| 授权了但仍报未授权 | 按「坑二」重置后重新授权 |
| 辅助功能始终拿不到 | 检查 `Info.plist` 是否有 `NSAccessibilityUsageDescription`（缺它系统不弹引导框） |

---

## 若必须重新创建证书

```bash
security delete-identity -c "BooksBridge Dev"
./scripts/setup-signing.sh
/usr/bin/tccutil reset All com.chris.booksbridge   # 清旧授权记录
./scripts/build-app.sh
# 然后重新授予两项权限
```

更换 Bundle ID 同样需要重新授权 —— TCC 同时认证书身份与 bundle id。
