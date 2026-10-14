import Foundation

/// 把 XHTML 转成适合喂给 LLM 的纯文本。
///
/// 刻意不用 `NSAttributedString` 的 HTML 导入：那条路会走完整的 HTML 排版，
/// 既慢又会在遇到非标准 XHTML 时静默失败。这里只需要"去标签 + 解实体"。
public enum HTMLText {
    /// 需要在标签位置补一个空格/换行的块级元素，保证段落不被粘连。
    private static let breakTags: Set<String> = [
        "p", "div", "br", "hr", "li", "tr", "td", "th", "h1", "h2", "h3",
        "h4", "h5", "h6", "section", "article", "blockquote", "figcaption",
        "header", "footer", "nav", "aside", "pre", "table", "ul", "ol", "dl", "dt", "dd",
    ]

    /// 整段丢弃内容的元素。
    private static let dropTags: Set<String> = ["script", "style", "head", "title", "svg"]

    public static func plainText(from html: String) -> String {
        let stripped = stripTags(html)
        let decoded = decodeEntities(stripped)
        return collapseWhitespace(decoded)
    }

    // MARK: - 去标签

    static func stripTags(_ html: String) -> String {
        var output = String()
        output.reserveCapacity(html.count)

        var index = html.startIndex
        let end = html.endIndex

        while index < end {
            let ch = html[index]

            // 注释
            if ch == "<", html[index...].hasPrefix("<!--") {
                if let close = html.range(of: "-->", range: index..<end) {
                    index = close.upperBound
                } else {
                    index = end
                }
                continue
            }

            if ch == "<", let close = html.range(of: ">", range: index..<end) {
                let inner = html[html.index(after: index)..<close.lowerBound]
                let (name, isClosing) = tagName(String(inner))
                if dropTags.contains(name) {
                    // 丢弃该元素到其闭合标签为止
                    if isClosing {
                        index = close.upperBound
                    } else if let closeTag = html.range(
                        of: "</\(name)",
                        options: [.caseInsensitive],
                        range: close.upperBound..<end
                    ) {
                        index = html.range(of: ">", range: closeTag.lowerBound..<end)?.upperBound ?? end
                    } else {
                        index = end
                    }
                    continue
                }
                if breakTags.contains(name) { output.append("\n") }
                index = close.upperBound
                continue
            }

            output.append(ch)
            index = html.index(after: index)
        }
        return output
    }

    /// 从 `<p class="x">` 或 `</p>` 里取出小写标签名与是否闭合。
    private static func tagName(_ inner: String) -> (name: String, isClosing: Bool) {
        var s = Substring(inner)
        var isClosing = false
        if s.hasPrefix("/") {
            isClosing = true
            s = s.dropFirst()
        }
        let name = s.prefix { !$0.isWhitespace && $0 != "/" }
        return (name.lowercased(), isClosing)
    }

    // MARK: - 实体解码

    /// 覆盖 XHTML 与中文 EPUB 常见的命名实体。
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "shy": "", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "hellip": "…", "mdash": "—", "ndash": "–", "minus": "−",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "sbquo": "‚", "bdquo": "„", "laquo": "«", "raquo": "»",
        "dagger": "†", "Dagger": "‡", "bull": "•", "middot": "·",
        "times": "×", "divide": "÷", "plusmn": "±", "deg": "°",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "frac12": "½", "frac14": "¼", "frac34": "¾",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = String()
        output.reserveCapacity(text.count)

        var index = text.startIndex
        let end = text.endIndex

        while index < end {
            guard text[index] == "&",
                  let semicolon = text.range(of: ";", range: index..<end),
                  // 实体名有长度上限，避免把远处的分号误当结尾
                  text.distance(from: index, to: semicolon.lowerBound) <= 12
            else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            let body = String(text[text.index(after: index)..<semicolon.lowerBound])
            if let decoded = decodeEntityBody(body) {
                output.append(decoded)
                index = semicolon.upperBound
            } else {
                output.append(text[index])
                index = text.index(after: index)
            }
        }
        return output
    }

    private static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body]
    }

    // MARK: - 空白归一

    /// 把连续空白压成单个空格，但保留换行作为段落分隔。
    static func collapseWhitespace(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        var pendingNewline = false
        var pendingSpace = false

        for ch in text {
            if ch.isNewline {
                pendingNewline = true
                pendingSpace = false
                continue
            }
            if ch.isWhitespace {
                if !pendingNewline { pendingSpace = true }
                continue
            }
            if pendingNewline {
                if !output.isEmpty { output.append("\n") }
                pendingNewline = false
                pendingSpace = false
            } else if pendingSpace {
                if !output.isEmpty { output.append(" ") }
                pendingSpace = false
            }
            output.append(ch)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
