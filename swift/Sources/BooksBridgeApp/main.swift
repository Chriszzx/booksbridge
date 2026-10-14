import AppKit
import Foundation

// BooksBridgeApp —— 菜单栏常驻 + Dock 图标的图书问答页面宿主。
//
// 这里手写 NSApplication 启动流程而不用 SwiftUI 的 `@main App`：
// 窗口需要精细控制（标准窗口 / 原生全屏），且要同时管状态栏项与 Dock 图标，
// AppKit 直接控制更清楚。
//
// 关于激活策略：用 `.regular` 而不是 `.accessory`。
// `.accessory` 虽然能让应用不进 Dock，但副作用是它在「系统设置 → 隐私与安全性」
// 的权限列表里很难被找到和勾选，用户根本没法授权完全磁盘访问。
// `.regular` 让应用成为正常前台应用：有 Dock 图标、有菜单栏、能被列出并授权。
// 页面隐藏时仍用 `NSApp.hide(nil)` 让出 Dock 与前台，状态栏图标不受影响。

// 顶层代码在 Swift 6 下默认是 MainActor 隔离的，这里显式声明意图
@MainActor
func runApplication() {
    let application = NSApplication.shared
    let delegate = AppDelegate()

    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}

MainActor.assumeIsolated { runApplication() }
