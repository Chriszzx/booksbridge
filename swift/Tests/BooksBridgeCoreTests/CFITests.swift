import XCTest

@testable import BooksBridgeCore

final class CFITests: XCTestCase {
    // MARK: - 真实样本（取自本机图书 App 实际写入的数据库）

    func testParsesRealDeadGirlCFI() throws {
        let cfi = try XCTUnwrap(CFI(raw: "epubcfi(/6/22[chapter-10]!/4/146/1,:1)"))
        XCTAssertEqual(cfi.spineIndex, 11)
        XCTAssertEqual(cfi.idAssertion, "chapter-10")
        XCTAssertEqual(cfi.charOffset, 1)
        XCTAssertEqual(cfi.charEnd, 1, "点位置：起止相同")
    }

    func testParsesRealFireGirlCFI() throws {
        let cfi = try XCTUnwrap(CFI(raw: "epubcfi(/6/30[id54]!/4/2/124/1,:1)"))
        XCTAssertEqual(cfi.spineIndex, 15)
        XCTAssertEqual(cfi.idAssertion, "id54")
        XCTAssertEqual(cfi.charOffset, 1)
    }

    func testParsesCFIWithDottedID() throws {
        let cfi = try XCTUnwrap(CFI(raw: "/6/10[x0004.xhtml]!/4/2[a005]/1,:1"))
        XCTAssertEqual(cfi.spineIndex, 5)
        XCTAssertEqual(cfi.idAssertion, "x0004.xhtml")
    }

    func testParsesRangeWithDifferentStartAndEnd() throws {
        let cfi = try XCTUnwrap(CFI(raw: "epubcfi(/6/14[chapter_2]!/4/18/1,:319)"))
        XCTAssertEqual(cfi.spineIndex, 7)
        XCTAssertEqual(cfi.idAssertion, "chapter_2")
        XCTAssertEqual(cfi.charOffset, 319)
        XCTAssertEqual(cfi.charEnd, 319)
    }

    func testParsesDeepPathCFI() throws {
        let cfi = try XCTUnwrap(CFI(raw: "epubcfi(/6/88[id172]!/4[147LC0-e000c0f20ab243389700eb360dad0263]/2[heading_id_2]/1,:0,:1)"))
        XCTAssertEqual(cfi.spineIndex, 44)
        XCTAssertEqual(cfi.idAssertion, "id172")
    }

    func testParsesHugeSpineIndex() throws {
        let cfi = try XCTUnwrap(CFI(raw: "/6/832[Colophon.xhtml]!/4/2/2/1,:1"))
        XCTAssertEqual(cfi.spineIndex, 416)
        XCTAssertEqual(cfi.idAssertion, "Colophon.xhtml")
    }

    // MARK: - 边界情况

    func testRejectsOddStep() {
        // 奇数步进指向文本节点而非元素，无法映射到 spine
        XCTAssertNil(CFI(raw: "/6/21[x]!/4/2/1,:1"))
    }

    func testRejectsMissingSpineStep() {
        XCTAssertNil(CFI(raw: "/4/2/1,:1"))
    }

    func testRejectsEmptyAssertion() throws {
        // [/6/12[]!/4/2/1] —— 空断言应视为"没有断言"，回退到数字路径
        let cfi = try XCTUnwrap(CFI(raw: "/6/12[]!/4/2/1,:1"))
        XCTAssertEqual(cfi.spineIndex, 6)
        XCTAssertNil(cfi.idAssertion)
    }

    func testCFIWithoutOffsetHasNilOffset() throws {
        // ,/3 是子节点索引，不代表字符偏移
        let cfi = try XCTUnwrap(CFI(raw: "/6/16[Section003.xhtml]!/4/2/2,/2,/3"))
        XCTAssertEqual(cfi.spineIndex, 8)
        XCTAssertNil(cfi.charOffset, "子节点索引不应被当成字符偏移")
    }

    func testParsesLargeOffset() throws {
        let cfi = try XCTUnwrap(CFI(raw: "/6/2[id_1]!/4/1046/1,:1321"))
        XCTAssertEqual(cfi.charOffset, 1321)
        XCTAssertEqual(cfi.charEnd, 1321)
    }

    func testAcceptsRawWithoutWrapper() throws {
        let cfi = try XCTUnwrap(CFI(raw: "/6/30[id54]!/4/2/124/1,:1"))
        XCTAssertEqual(cfi.spineIndex, 15)
    }
}

final class HTMLTextTests: XCTestCase {
    func testStripsTagsAndKeepsParagraphBreaks() {
        let html = "<p>第一段</p><p>第二段</p>"
        XCTAssertEqual(HTMLText.plainText(from: html), "第一段\n第二段")
    }

    func testDropsScriptAndStyleContent() {
        let html = "<p>保留</p><script>var x = 1;</script><style>p{color:red}</style><p>也保留</p>"
        let out = HTMLText.plainText(from: html)
        XCTAssertTrue(out.contains("保留"))
        XCTAssertFalse(out.contains("var x"))
        XCTAssertFalse(out.contains("color:red"))
    }

    func testDropsHeadContent() {
        let html = "<head><title>书名</title></head><body>正文</body>"
        let out = HTMLText.plainText(from: html)
        XCTAssertEqual(out, "正文")
    }

    func testDecodesNumericEntities() {
        XCTAssertEqual(HTMLText.plainText(from: "<p>&#20013;&#25991;</p>"), "中文")
    }

    func testDecodesHexEntities() {
        XCTAssertEqual(HTMLText.plainText(from: "<p>&#x4E2D;&#x6587;</p>"), "中文")
    }

    func testDecodesNamedEntities() {
        XCTAssertEqual(HTMLText.plainText(from: "<p>a&amp;b&nbsp;c&hellip;</p>"), "a&b c…")
    }

    func testKeepsBareAmpersand() {
        XCTAssertEqual(HTMLText.plainText(from: "<p>Tom & Jerry</p>"), "Tom & Jerry")
    }

    func testCollapsesWhitespaceButKeepsNewlines() {
        let out = HTMLText.plainText(from: "<p>a    b\n\n\nc</p>")
        XCTAssertEqual(out, "a b\nc")
    }

    func testHandlesCJKWithoutSpuriousSpaces() {
        let out = HTMLText.plainText(from: "<p>这是<em>中文</em>混排</p>")
        XCTAssertEqual(out, "这是中文混排")
    }
}
