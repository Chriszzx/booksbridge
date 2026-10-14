import Foundation

/// EPUB 的 Canonical Fragment Identifier（CFI）。
///
/// 图书 App 用 CFI 记录 EPUB 的阅读位置，实测本机真实样本形如：
/// ```
/// epubcfi(/6/30[id54]!/4/2/124/1,:1)
///          └┬┘ └─┬─┘  └──┬───┘ └┬┘
///           │    │       │       └── 字符偏移（点位置；也可能是 ,/3 形式的子节点索引）
///           │    │       └────────── indirection 之后的元素路径
///           │    └────────────────── 断言 id（manifest 里的 item id）
///           └─────────────────────── 偶数步进 → spine 的第 (N/2) 项
/// ```
///
/// 实测（4 本真实书籍）数字路径与 id 断言 **100% 一致**；
/// 两者都存在时以 id 断言为准，因为它直接对应 OPF manifest，不依赖计数规则。
///
/// ⚠️ 关于 `charOffset`：它是相对图书 App 自己排版文档的位置，
/// 与剥离 HTML 后的纯文本字符数**不同源**，不能直接用来切片正文。
/// 需要"此刻这一页"时应改用辅助功能 API 读取可见文本。
public struct CFI: Sendable, Equatable {
    /// 指向的 spine 项序号（1-based）。
    public let spineIndex: Int
    /// CFI 中括号内的 id 断言，可能为 nil（部分生成器不写）。
    public let idAssertion: String?
    /// 字符偏移。
    public let charOffset: Int?
    public let charEnd: Int?
    /// 原始字符串（含 `epubcfi(...)` 外壳）。
    public let raw: String

    public init?(raw: String) {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("epubcfi(") {
            body = String(body.dropFirst("epubcfi(".count))
            if body.hasSuffix(")") { body = String(body.dropLast()) }
        }
        // 只看第一个 "!" 之前的部分（indirection 之后是元素路径，不影响章节定位）
        let head = body.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? body

        guard let match = Self.stepPattern.firstMatch(in: head) else { return nil }
        let step = match.step
        // 偶数步进：元素序号 = step / 2
        guard step % 2 == 0, step >= 2 else { return nil }

        self.spineIndex = step / 2
        self.idAssertion = match.assertion
        self.raw = raw

        if let range = Self.offsetPattern.firstMatch(in: body) {
            self.charOffset = range.start
            self.charEnd = range.end ?? range.start
        } else {
            self.charOffset = nil
            self.charEnd = nil
        }
    }

    // MARK: - 解析辅助

    private struct StepMatch {
        let step: Int
        let assertion: String?
    }

    private struct OffsetMatch {
        let start: Int
        let end: Int?
    }

    /// 匹配 `/6/30[id54]`，捕获步进数字与可选断言。
    private static let stepPattern = RegexRunner<StepMatch>(
        pattern: #"/6/(\d+)(?:\[([^\]]*)\])?"#
    ) { text, match in
        guard let stepRange = Range(match.range(at: 1), in: text),
              let step = Int(text[stepRange]) else { return nil }
        var assertion: String?
        if match.range(at: 2).location != NSNotFound,
           let r = Range(match.range(at: 2), in: text) {
            let value = String(text[r])
            assertion = value.isEmpty ? nil : value
        }
        return StepMatch(step: step, assertion: assertion)
    }

    /// 匹配尾部的 `:a,b`（两个偏移）或 `:n`（单个偏移，起止相同）。
    ///
    /// 实测本机 271 条真实位置记录，尾部只有两种形态：
    /// - `,:1` 这类 —— 点位置，起止相同（占绝大多数，如 `,:1` `,:86` `,:1321`）；
    /// - `,/3` 这类 —— 子节点索引，不代表字符偏移。
    /// 没有出现过 `:a,:b` 形态，因此这里只认 `:a,b` 与 `:n`。
    private static let offsetPattern = RegexRunner<OffsetMatch>(
        pattern: #",:\s*(\d+)(?:\s*,\s*(\d+))?\s*$"#
    ) { text, match in
        guard let startRange = Range(match.range(at: 1), in: text),
              let start = Int(text[startRange]) else { return nil }
        var end: Int?
        if match.range(at: 2).location != NSNotFound,
           let r = Range(match.range(at: 2), in: text) {
            end = Int(text[r])
        }
        return OffsetMatch(start: start, end: end)
    }
}

/// 把 `NSRegularExpression` 包成可静态持有、线程安全的匹配器。
///
/// `NSRegularExpression` 本身是不可变的、可安全并发使用的，
/// 这里只是把"构造 + 首匹配 + 映射"收敛成一个泛型工具，避免各处重复样板。
final class RegexRunner<Output>: @unchecked Sendable {
    private let regex: NSRegularExpression?

    init(pattern: String, map: @escaping (String, NSTextCheckingResult) -> Output?) {
        self.regex = try? NSRegularExpression(pattern: pattern)
        self.map = map
    }

    private let map: (String, NSTextCheckingResult) -> Output?

    func firstMatch(in text: String) -> Output? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return map(text, match)
    }
}
