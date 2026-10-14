import AppKit
import Foundation

/// 运行期生成应用图标（大写 `BR`）。
///
/// 为什么程序化生成而不是放一个 `.icns`：
/// - 需求只是"图标就 BR"，文字图标用代码画比维护二进制资源更直接；
/// - 省掉 `iconutil` 打包步骤，`build-app.sh` 不必多一步资源处理；
/// - 改字号/配色只改一个文件，不需要重新导出图标。
///
/// 之后若要换成美术图标，把 `.icns` 放进 `Contents/Resources` 并在 Info.plist 里
/// 声明 `CFBundleIconFile` 即可，这里的 `apply()` 会自然被覆盖。
public enum AppIconFactory {
    /// 生成指定边长的图标。
    ///
    /// - Parameter size: 边长（pt）。macOS 会自动缩放到 Dock 需要的各种尺寸。
    public static func makeBR(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return image }

        // 圆角矩形底：用 macOS 图标习惯的圆角比例（约 22%）
        let inset = size * 0.06
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = size * 0.22
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 渐变底：从亮蓝到深蓝，深浅色外观下都能看清
        context.saveGState()
        context.addPath(path)
        context.clip()
        let colors = [
            NSColor(srgbRed: 0.16, green: 0.55, blue: 1.00, alpha: 1).cgColor,
            NSColor(srgbRed: 0.04, green: 0.35, blue: 0.85, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: []
            )
        }
        context.restoreGState()

        // 文字 BR
        let text = "BR" as NSString  
        let fontSize = size * 0.43
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let origin = NSPoint(
            x: (size - textSize.width) / 2,
            y: (size - textSize.height) / 2
        )
        text.draw(at: origin, withAttributes: attributes)

        return image
    }

    /// 把图标设为本应用的图标（显示在 Dock 与 Cmd+Tab 里）。
    public static func apply() {
        NSApp.applicationIconImage = makeBR()
    }
}
