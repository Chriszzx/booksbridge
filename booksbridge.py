#!/usr/bin/env python3
"""
booksbridge —— 从 macOS「图书」App (Apple Books) 读取"用户当前正在读什么"并取回正文上下文。

这是可行性验证原型：仅用 Python 标准库，直接读取 Apple Books 自己的数据文件。
它是"给 LLM 喂书籍上下文"这件事的技术内核（读取侧）。

已验证的完整链路
----------------
  1. 当前书      ~/Library/Containers/com.apple.iBooksX/Data/Library/Preferences/
                 com.apple.iBooksX.plist  →  kLastCurrentBookKey (= assetID)
  2. 书元数据    Data/Documents/BKLibrary/BKLibrary-*.sqlite   →  ZBKLIBRARYASSET
                 (书名/作者/进度/EPUB 文件路径)
  3. 精确阅读位置 Data/Documents/AEAnnotation/AEAnnotation_*.sqlite → ZAEANNOTATION
                 ZANNOTATIONTYPE=3 的记录里 ZANNOTATIONLOCATION 就是 EPUB CFI
  4. CFI → 正文  CFI 的数字路径 /6/N 映射到 OPF spine 的第 N/2 项；
                 配合 [id] 断言可交叉校验；EPUB 已被 Books 解包成目录，正文是明文。

CFI 解析规则（已在 4 本真实书籍上验证 100% 一致）
-------------------------------------------------
  epubcfi(/6/22[chapter-10]!/4/146/1,:0,:1)
           │  │  └─ id 断言（manifest 里的 item id，可交叉校验）
           │  └──── 偶数 N → spine 第 N/2 项（从 1 开始计数）
           └─────── 指向 OPF 的 <spine>

依赖：macOS + 已安装「图书」App。读取容器需要"完全磁盘访问权限"。
用法：
    python3 booksbridge.py                 # 查看当前在读的书 + 阅读位置上下文
    python3 booksbridge.py --context 4000  # 取当前位置前后共 4000 字
    python3 booksbridge.py --list          # 列出最近在读的书
"""

from __future__ import annotations

import argparse
import glob
import html
import os
import plistlib
import re
import sqlite3
import sys
import urllib.parse
from dataclasses import dataclass, field

HOME = os.path.expanduser("~")
CONTAINER = os.path.join(HOME, "Library/Containers/com.apple.iBooksX/Data")
DOCS = os.path.join(CONTAINER, "Documents")
PREFS = os.path.join(CONTAINER, "Library/Preferences/com.apple.iBooksX.plist")

# Core Data 的时间戳基准：2001-01-01，需加 978307200 秒才是 Unix 时间
APPLE_EPOCH = 978307200


# --------------------------------------------------------------------------- #
# 数据访问层
# --------------------------------------------------------------------------- #
def _ro(path: str) -> sqlite3.Connection:
    """以只读 URI 打开 sqlite，避免在他人数据库上创建 -journal/-wal。"""
    uri = "file:" + urllib.parse.quote(os.path.abspath(path)) + "?mode=ro"
    con = sqlite3.connect(uri, uri=True)
    con.row_factory = sqlite3.Row
    return con


def _first(pattern_glob: str) -> str | None:
    hits = sorted(glob.glob(pattern_glob))
    return hits[0] if hits else None


def library_db() -> str:
    p = _first(os.path.join(DOCS, "BKLibrary", "BKLibrary-*.sqlite"))
    if not p:
        raise FileNotFoundError("找不到 BKLibrary 数据库，请确认已安装图书 App 并授予完全磁盘访问权限")
    return p


def annotation_db() -> str | None:
    return _first(os.path.join(DOCS, "AEAnnotation", "AEAnnotation_*.sqlite"))


def current_asset_id() -> str | None:
    """
    图书 App 把"当前正在读的书"记在偏好设置里，键名 kLastCurrentBookKey。

    注意：这个 plist 里可能存在越界日期字段，会让 plistlib 整体解析失败，
    因此准备三级降级：plistlib → plutil → 二进制裸扫描。
    """
    key = b"kLastCurrentBookKey"

    # 1) 首选 plistlib
    try:
        with open(PREFS, "rb") as f:
            val = plistlib.load(f).get("kLastCurrentBookKey")
        if val:
            return val
    except Exception:
        pass

    # 2) 降级：plutil 只提取这一个键（它能容忍坏字段）
    try:
        import subprocess
        out = subprocess.run(
            ["plutil", "-extract", "kLastCurrentBookKey", "raw", "-o", "-", PREFS],
            capture_output=True, text=True, timeout=5,
        )
        val = out.stdout.strip()
        if out.returncode == 0 and val:
            return val
    except Exception:
        pass

    # 3) 兜底：在二进制 plist 里直接找键后面的字符串
    try:
        blob = open(PREFS, "rb").read()
        i = blob.find(key)
        if i != -1:
            tail = blob[i + len(key): i + len(key) + 32]
            m = re.search(rb"[0-9A-Fa-f]{16,}", tail)
            if m:
                return m.group(0).decode()
    except Exception:
        pass
    return None


# --------------------------------------------------------------------------- #
# 数据模型
# --------------------------------------------------------------------------- #
@dataclass
class Book:
    asset_id: str
    title: str
    author: str = ""
    progress: float = 0.0
    path: str | None = None
    last_open: float | None = None
    content_type: int = 1

    @property
    def kind(self) -> str:
        return {1: "EPUB", 3: "PDF", 5: "Audiobook"}.get(self.content_type, f"type{self.content_type}")

    def __str__(self) -> str:
        return f"《{self.title}》{f' — {self.author}' if self.author not in ('', 'UnknownAuthor') else ''}"


@dataclass
class Position:
    """一条阅读位置记录。cfi 为 EPUB 定位符，PDF 则为 nil。"""
    cfi: str | None = None
    modified: float | None = None
    selected_text: str | None = None
    note: str | None = None
    raw_location: str | None = None


# --------------------------------------------------------------------------- #
# 查询
# --------------------------------------------------------------------------- #
def get_book(asset_id: str) -> Book | None:
    con = _ro(library_db())
    try:
        row = con.execute(
            "SELECT ZASSETID, ZTITLE, ZAUTHOR, ZREADINGPROGRESS, ZPATH, "
            "       ZLASTOPENDATE, ZCONTENTTYPE "
            "FROM ZBKLIBRARYASSET WHERE ZASSETID = ?",
            (asset_id,),
        ).fetchone()
    finally:
        con.close()
    if not row:
        return None
    return Book(
        asset_id=row["ZASSETID"],
        title=row["ZTITLE"] or "(无标题)",
        author=row["ZAUTHOR"] or "",
        progress=row["ZREADINGPROGRESS"] or 0.0,
        path=row["ZPATH"],
        last_open=(row["ZLASTOPENDATE"] + APPLE_EPOCH) if row["ZLASTOPENDATE"] else None,
        content_type=row["ZCONTENTTYPE"] or 1,
    )


def recent_books(limit: int = 15) -> list[Book]:
    con = _ro(library_db())
    try:
        rows = con.execute(
            "SELECT ZASSETID, ZTITLE, ZAUTHOR, ZREADINGPROGRESS, ZPATH, "
            "       ZLASTOPENDATE, ZCONTENTTYPE "
            "FROM ZBKLIBRARYASSET WHERE ZLASTOPENDATE IS NOT NULL "
            "ORDER BY ZLASTOPENDATE DESC LIMIT ?",
            (limit,),
        ).fetchall()
    finally:
        con.close()
    return [
        Book(
            asset_id=r["ZASSETID"],
            title=r["ZTITLE"] or "(无标题)",
            author=r["ZAUTHOR"] or "",
            progress=r["ZREADINGPROGRESS"] or 0.0,
            path=r["ZPATH"],
            last_open=(r["ZLASTOPENDATE"] + APPLE_EPOCH) if r["ZLASTOPENDATE"] else None,
            content_type=r["ZCONTENTTYPE"] or 1,
        )
        for r in rows
    ]


def reading_position(asset_id: str) -> Position | None:
    """ZANNOTATIONTYPE=3 是图书 App 自动写入的阅读位置标记。"""
    db = annotation_db()
    if not db:
        return None
    con = _ro(db)
    try:
        row = con.execute(
            "SELECT ZANNOTATIONLOCATION, ZANNOTATIONMODIFICATIONDATE, "
            "       ZANNOTATIONSELECTEDTEXT, ZANNOTATIONNOTE "
            "FROM ZAEANNOTATION "
            "WHERE ZANNOTATIONASSETID = ? AND ZANNOTATIONTYPE = 3 "
            "  AND ZANNOTATIONLOCATION IS NOT NULL "
            "ORDER BY ZANNOTATIONMODIFICATIONDATE DESC LIMIT 1",
            (asset_id,),
        ).fetchone()
    finally:
        con.close()
    if not row:
        return None
    loc = row["ZANNOTATIONLOCATION"]
    m = re.search(r"epubcfi\((.*)\)", loc or "")
    return Position(
        cfi=m.group(1) if m else None,
        modified=(row["ZANNOTATIONMODIFICATIONDATE"] + APPLE_EPOCH)
        if row["ZANNOTATIONMODIFICATIONDATE"] else None,
        selected_text=row["ZANNOTATIONSELECTEDTEXT"],
        note=row["ZANNOTATIONNOTE"],
        raw_location=loc,
    )


# --------------------------------------------------------------------------- #
# EPUB 解析
# --------------------------------------------------------------------------- #
OPF_CANDIDATES = ("content.opf", "EPUB/content.opf", "OEBPS/content.opf")


def _find_opf(book_dir: str) -> str | None:
    for cand in OPF_CANDIDATES:
        p = os.path.join(book_dir, cand)
        if os.path.exists(p):
            return p
    # 兜底：浅层搜索
    for depth in ("*", "*/*"):
        for p in glob.glob(os.path.join(book_dir, depth, "*.opf")):
            return p
    return None


def _normalize_id(s: str) -> str:
    """CFI 的 id 断言会把 '.' '-' 归一化成 '_'。"""
    return s.replace(".", "_").replace("-", "_")


class Epub:
    """把被 Books 解包成目录的 EPUB 变成可查询的正文。"""

    def __init__(self, path: str):
        self.path = path
        self.opf = _find_opf(path)
        if not self.opf:
            raise ValueError(f"不是解包形式的 EPUB（找不到 OPF）: {path}")
        self.opf_dir = os.path.dirname(self.opf)
        raw = open(self.opf, encoding="utf-8", errors="replace").read()
        # manifest: id -> href
        self.manifest: dict[str, str] = {}
        for tag in re.findall(r"<item\b[^>]*>", raw):
            i = re.search(r'\bid="([^"]+)"', tag)
            h = re.search(r'\bhref="([^"]+)"', tag)
            if i and h:
                self.manifest[i.group(1)] = h.group(1)
        # spine: 有序的 idref 列表
        self.spine: list[str] = re.findall(r'<itemref\b[^>]*\bidref="([^"]+)"', raw)

    def href_for_spine_index(self, n: int) -> str | None:
        """n 为 1-based 的 spine 序号。"""
        if 1 <= n <= len(self.spine):
            return self.manifest.get(self.spine[n - 1])
        return None

    def href_for_id(self, item_id: str) -> str | None:
        if item_id in self.manifest:
            return self.manifest[item_id]
        target = _normalize_id(item_id)
        for k, v in self.manifest.items():
            if _normalize_id(k) == target:
                return v
        return None

    def file_for_href(self, href: str) -> str:
        rel = os.path.normpath(os.path.join(os.path.relpath(self.opf_dir, self.path), href))
        return os.path.join(self.path, rel)

    def text_of(self, href: str) -> str:
        raw = open(self.file_for_href(href), encoding="utf-8", errors="replace").read()
        raw = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", raw)
        txt = html.unescape(re.sub(r"<[^>]+>", " ", raw))
        return re.sub(r"\s+", " ", txt).strip()


@dataclass
class CfiTarget:
    spine_index: int
    href: str
    char_offset: int | None = None
    char_end: int | None = None
    path: list[str] = field(default_factory=list)


def parse_cfi(cfi: str, epub: Epub) -> CfiTarget | None:
    """
    解析 BookEPUB 风格 CFI，定位到章节文件与（可选的）字符偏移。

    形如：/6/22[chapter-10]!/4/146/1,:0,:1
    """
    body = cfi.strip()
    if body.startswith("epubcfi(") and body.endswith(")"):
        body = body[len("epubcfi("):-1]
    head = body.split("!")[0]

    m = re.search(r"/6/(\d+)(?:\[([^\]]*)\])?", head)
    if not m:
        return None
    step = int(m.group(1))
    assert_id = m.group(2)
    if step % 2 != 0:
        return None
    spine_index = step // 2

    # 断言 id 优先（更稳），数字路径兜底，两者不一致时以断言为准
    href = None
    if assert_id:
        href = epub.href_for_id(assert_id)
    if not href:
        href = epub.href_for_spine_index(spine_index)

    # 字符偏移：CFI 尾部的 ":start,:end"
    off = end = None
    cm = re.search(r":(\d+)(?::(\d+))?\s*$", body)
    if cm:
        off = int(cm.group(1))
        end = int(cm.group(2)) if cm.group(2) else off

    return CfiTarget(
        spine_index=spine_index,
        href=href or "",
        char_offset=off,
        char_end=end,
        path=re.findall(r"/(\d+)(?:\[[^\]]*\])?", body),
    )


# --------------------------------------------------------------------------- #
# 组装给 LLM 的上下文
# --------------------------------------------------------------------------- #
def build_context(book: Book, pos: Position, chars: int = 3000) -> str:
    """返回当前阅读位置附近的一段正文，可直接作为 LLM 上下文。"""
    if not book.path or not os.path.exists(book.path):
        return f"[书籍文件不在本地：{book.path}]"

    if book.kind == "PDF":
        return "[PDF 书籍：需走 PDF 文本层或 OCR 路线，本原型暂不覆盖]"

    try:
        epub = Epub(book.path)
    except ValueError as e:
        return f"[EPUB 解析失败：{e}]"

    if not pos.cfi:
        return "[没有可用的阅读位置信息]"

    target = parse_cfi(pos.cfi, epub)
    if not target or not target.href:
        return f"[CFI 无法定位到章节：{pos.cfi}]"

    text = epub.text_of(target.href)
    total = len(text)

    # 图书 App 的字符偏移是相对其自身排版文档的，与纯文本字符数不完全等价，
    # 因此偏移只作为提示，异常时退化为"章节开头"。
    center = target.char_offset or 0
    if center > total:
        center = 0
    half = max(chars // 2, 200)
    start = max(0, center - half)
    end = min(total, center + half)

    snippet = text[start:end]
    pct = book.progress * 100
    head = (
        f"书名：{book.title}\n"
        f"作者：{book.author or '未知'}\n"
        f"阅读进度：{pct:.1f}%\n"
        f"定位：CFI {pos.cfi}\n"
        f"章节文件：{os.path.relpath(epub.file_for_href(target.href), book.path)}"
        f"（spine 第 {target.spine_index} 项，全文 {total} 字）\n"
        f"{'─' * 60}\n"
    )
    return head + snippet


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="读取 macOS 图书 App 当前阅读内容")
    ap.add_argument("--list", action="store_true", help="列出最近在读的书")
    ap.add_argument("--context", type=int, default=2000, help="取多少字的上下文（默认 2000）")
    args = ap.parse_args()

    if args.list:
        for i, b in enumerate(recent_books(), 1):
            print(f"{i:2d}. {b}  [{b.kind} {b.progress * 100:.1f}%]")
        return 0

    asset_id = current_asset_id()
    if not asset_id:
        print("✗ 无法确定当前在读的书（偏好设置里没有 kLastCurrentBookKey）", file=sys.stderr)
        return 1

    book = get_book(asset_id)
    if not book:
        print(f"✗ 书库里找不到 assetID={asset_id}", file=sys.stderr)
        return 1

    pos = reading_position(asset_id)
    print(f"当前正在读：{book}  [{book.kind} {book.progress * 100:.1f}%]")
    if pos and pos.modified:
        import datetime
        print(f"位置记录时间：{datetime.datetime.fromtimestamp(pos.modified):%Y-%m-%d %H:%M:%S}")
    if pos and pos.selected_text:
        print(f"最近划选文本：{pos.selected_text[:80]}")
    print()
    print(build_context(book, pos, args.context) if pos else "[没有阅读位置记录]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
