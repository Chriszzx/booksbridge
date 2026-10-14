// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BooksBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BooksBridgeCore", targets: ["BooksBridgeCore"]),
        .library(name: "BooksBridgeLLM", targets: ["BooksBridgeLLM"]),
        .executable(name: "booksbridged", targets: ["booksbridged"]),
        .executable(name: "BooksBridgeApp", targets: ["BooksBridgeApp"]),
    ],
    targets: [
        // 系统 libsqlite3 —— 不引入任何第三方依赖
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "BooksBridgeCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "booksbridged",
            dependencies: ["BooksBridgeCore"]
        ),
        // LLM 侧：DeepSeek/OpenAI 兼容客户端、书籍预处理、上下文组装
        .target(
            name: "BooksBridgeLLM",
            dependencies: ["BooksBridgeCore"]
        ),
        // 菜单栏 App 宿主：状态栏图标 + 窗口 + WKWebView 前端
        .executableTarget(
            name: "BooksBridgeApp",
            dependencies: ["BooksBridgeCore", "BooksBridgeLLM"],
            resources: [.copy("WebUI")]
        ),
        // 设计阶段的小工具：读出任一运行中 App 的辅助功能树
        .executableTarget(
            name: "axtree"
        ),
        // 设计阶段的小工具：验证切回图书 App 是否影响阅读位置
        .executableTarget(
            name: "returnprobe"
        ),
        // 设计阶段的小工具：对辅助功能元素执行动作（如打开菜单）
        .executableTarget(
            name: "axact"
        ),
        // 设计阶段的小工具：读菜单栏与弹出菜单结构
        .executableTarget(
            name: "axmenubar"
        ),
        .testTarget(
            name: "BooksBridgeCoreTests",
            dependencies: ["BooksBridgeCore", "BooksBridgeLLM", "BooksBridgeApp"]
        ),
    ]
)
