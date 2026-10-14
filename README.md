# BooksBridge

macOS 上的辅助阅读工具：在你读苹果图书（Apple Books）时，把「你正在读什么」交给 LLM，
让你就当前内容提问。书仍然在图书 App 里读，BooksBridge 负责**理解你在读的这本书**，
并让你按选定的**剧透边界**提问。

---

## 现在能做什么

**读取侧**

- 菜单栏常驻 `BR` 图标。左键下拉状态菜单，**上半是状态、下半是操作**
- 自动检测正在图书 App 里读的书：书名、作者、进度、精确位置
- 翻页实时跟随（实测延迟 0 秒）
- 抓取当前屏幕可见的正文与划选文字
- 检测到只是**提示**，点击才进入那本书的 workspace
- 启动时**不触碰受保护目录**，需在「设置 → 权限」点「连接 Apple Books」才开始读取
  （原因见 [docs/permissions.md](docs/permissions.md)）

**问答侧**（需自行配置 API Key）

- 打开一本书时后台把**整本书预处理**成结构化「书籍说明」，带缓存复用
- 三档知识范围，本质是**剧透边界**：
  - `读到这为止` — 只用已读章节，不剧透
  - `整章（含未读）` — 含当前章未读部分，不含后续章节
  - `整本书` — 全书内容
- 流式回答，思考过程（thinking）可折叠查看
- 多轮对话，历史落盘
- 会话、书库、设置持久化，重启恢复

**界面**

- 标准窗口（可拖可缩可最小化），也支持原生全屏
- 左下角设置页：通用 / 模型与 API / 权限
- 页面在前台时在 Dock 显示（图标为程序化绘制的 `BR`），收起后仍常驻菜单栏
- 右上角 `← 返回图书` 回到图书 App，**不影响阅读位置**

## 现在还不能做什么

- PDF 的阅读位置（EPUB 已完整支持）
- 向量检索（当前是零依赖关键词检索，单本书规模够用）
- 划选后就地浮层提问
- 分发（自签名证书仅本机有效）
- 国际化

---

## 快速开始

```bash
# 0. 一次性：创建本地签名证书
#    不做这一步，每次重新编译都会丢失系统授权，理由见 docs/permissions.md
./scripts/setup-signing.sh

# 1. 构建（签名失败会中止，不会静默退回 ad-hoc）
./scripts/build-app.sh

# 2. 运行
./scripts/run-app.sh
```

首次运行后：

1. 打开「设置 → 权限」，点「连接 Apple Books」
2. 按提示授予**完全磁盘访问**与**辅助功能**权限
3. 回到应用点「重新检测」
4. 在「设置 → 模型与 API」填 DeepSeek API Key

> **验收必须用 `./scripts/run-app.sh` 或 Finder 启动。**
> 从终端直接跑可执行文件会继承终端的 TCC 权限，结果不能代表应用自身。

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 分层结构、数据流、前后端契约 |
| [docs/findings.md](docs/findings.md) | 实测得到的关于苹果图书的事实（多条与直觉相反） |
| [docs/permissions.md](docs/permissions.md) | TCC 权限、签名、连接流程、自检报告与排查 |
| [docs/development.md](docs/development.md) | 构建、调试参数、开发工具、代码导航 |
| [docs/known-issues.md](docs/known-issues.md) | 已知限制、取舍、未验证项 |

---

## 项目结构

```
booksbridge/
├── swift/                              # Swift Package
│   ├── Sources/
│   │   ├── BooksBridgeCore/            # 读取苹果图书（与 UI/LLM 无关）
│   │   ├── BooksBridgeLLM/             # LLM 客户端、预处理、上下文组装
│   │   ├── BooksBridgeApp/             # 菜单栏宿主 + WKWebView
│   │   │   └── WebUI/                  # HTML / CSS / JS
│   │   ├── booksbridged/               # 命令行驱动
│   │   ├── axtree/ axmenubar/ axact/   # 界面勘察工具
│   │   └── returnprobe/                # 验证切回图书 App 的副作用
│   ├── Tests/                          # 144 个测试
│   └── Resources/Info.plist
├── scripts/                            # build-app / setup-signing / run-app
├── docs/
└── *.py                                # 最初的 Python 可行性原型（保留参考）
```

---

## 状态

- 测试：**144 个，全部通过**
- 编译：无 error
- 签名：本机自签名证书 `BooksBridge Dev`
- 未做：代码公证、分发、国际化
