#!/usr/bin/env python3
"""实时探针：同时监测 Apple Books 的数据库写入 与 辅助功能(AX)可读内容。"""
import ctypes, ctypes.util, datetime as dt, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import booksbridge as bb

# ---------- AX 工具 ----------
lib = ctypes.CDLL(ctypes.util.find_library('ApplicationServices'))
cf  = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))
cf.CFStringCreateWithCString.restype=ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_uint32]
cf.CFStringGetCString.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_long,ctypes.c_uint32]
cf.CFStringGetLength.restype=ctypes.c_long
cf.CFStringGetMaximumSizeForEncoding.restype=ctypes.c_long
cf.CFArrayGetCount.restype=ctypes.c_long
cf.CFArrayGetValueAtIndex.restype=ctypes.c_void_p
cf.CFArrayGetValueAtIndex.argtypes=[ctypes.c_void_p,ctypes.c_long]
cf.CFGetTypeID.restype=ctypes.c_ulong
cf.CFArrayGetTypeID.restype=ctypes.c_ulong
lib.AXUIElementCreateApplication.restype=ctypes.c_void_p
lib.AXUIElementCreateApplication.argtypes=[ctypes.c_int]
lib.AXUIElementCopyAttributeValue.restype=ctypes.c_int
lib.AXUIElementCopyAttributeValue.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)]
UTF8=0x08000100
ARRAY_TID = cf.CFArrayGetTypeID()
def s2cf(s): return cf.CFStringCreateWithCString(None,s.encode(),UTF8)
def cf2s(x):
    if not x: return None
    n=cf.CFStringGetMaximumSizeForEncoding(cf.CFStringGetLength(ctypes.c_void_p(x)),UTF8)+1
    buf=ctypes.create_string_buffer(n)
    return buf.value.decode('utf-8','replace') if cf.CFStringGetCString(ctypes.c_void_p(x),buf,n,UTF8) else None
def attr(el,name):
    o=ctypes.c_void_p()
    e=lib.AXUIElementCopyAttributeValue(ctypes.c_void_p(el),ctypes.c_void_p(s2cf(name)),ctypes.byref(o))
    return o.value if e==0 else None

def ax_snapshot():
    """返回 (窗口标题, 含文本的节点数, 文本样本, 选中文本)"""
    try:
        pid=int(subprocess.check_output(["pgrep","-x","Books"]).split()[0])
    except Exception:
        return None
    app=lib.AXUIElementCreateApplication(pid)
    titles=[]; texts=[]; sels=[]
    def walk(el, d=0):
        if d>16 or len(texts)>200: return
        r=cf2s(attr(el,"AXRole"))
        v=cf2s(attr(el,"AXValue"))
        s=cf2s(attr(el,"AXSelectedText"))
        if r=="AXWindow" or r=="AXSheet":
            t=cf2s(attr(el,"AXTitle"))
            if t: titles.append(t)
        if v and len(v)>15: texts.append(v)
        if s: sels.append(s)
        kids=attr(el,"AXChildren")
        if kids and cf.CFGetTypeID(ctypes.c_void_p(kids))==ARRAY_TID:
            for j in range(min(cf.CFArrayGetCount(ctypes.c_void_p(kids)),80)):
                walk(cf.CFArrayGetValueAtIndex(ctypes.c_void_p(kids),j), d+1)
    walk(app)
    return titles, texts, sels

FILES = {
 "AEAnnotation-wal": os.path.join(bb.DOCS,"AEAnnotation","AEAnnotation_v10312011_1727_local.sqlite-wal"),
 "BKLibrary-wal":    os.path.join(bb.DOCS,"BKLibrary","BKLibrary-1-091020131601.sqlite-wal"),
 "prefs":            bb.PREFS,
}
def mtimes():
    return {k:(os.path.getmtime(v) if os.path.exists(v) else 0) for k,v in FILES.items()}

print("=" * 100)
print("实时探针启动 —— 请现在打开图书 App 里的一本书，并翻 2~3 页")
print("=" * 100)
start=time.time(); last_pos=None; last_mt=mtimes(); last_ax=None; events=[]
while time.time()-start < 90:
    now=dt.datetime.now().strftime("%H:%M:%S")
    aid=bb.current_asset_id()
    b=bb.get_book(aid) if aid else None
    p=bb.reading_position(aid) if aid else None
    mt=mtimes()
    changed=[k for k in mt if mt[k]!=last_mt[k]]
    poskey=(aid, p.cfi if p else None, round(b.progress,4) if b else None)
    ax=ax_snapshot()
    axkey=(tuple(ax[0]), len(ax[1]), tuple(ax[2]))
    ax_changed = ax is not None and axkey!=last_ax

    if changed or poskey!=last_pos or ax_changed:
        print(f"\n[{now}] ── 变化检测 ──")
        if changed:  print(f"   文件写入: {', '.join(changed)}")
        if poskey!=last_pos:
            print(f"   当前书  : {b.title if b else '-'}  进度 {b.progress*100 if b else 0:.1f}%")
            print(f"   CFI     : {p.cfi if p and p.cfi else '-'}")
            if p and p.modified:
                print(f"   位置时间: {dt.datetime.fromtimestamp(p.modified):%H:%M:%S} ({int(time.time()-p.modified)} 秒前)")
            events.append((now, p.cfi if p else None))
        if ax_changed and ax:
            titles, texts, sels = ax
            print(f"   [AX] 窗口: {titles}")
            print(f"   [AX] 含文本节点: {len(texts)} 个   选中文本: {len(sels)} 处")
            if sels: print(f"   [AX] 选中内容: {sels[0][:120]!r}")
            for t in texts[-3:]:
                print(f"   [AX] 文本: {t[:100]!r}")
        last_mt, last_pos, last_ax = mt, poskey, axkey
    time.sleep(1)

print("\n" + "=" * 100)
print(f"监测结束，共捕获 {len(events)} 次位置变化事件：")
for t, c in events: print(f"   {t}  {c}")
print("=" * 100)
