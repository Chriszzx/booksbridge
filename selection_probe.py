#!/usr/bin/env python3
"""探测：在图书 App 里划选文本时，辅助功能 API 能否实时读到划选内容与位置。"""
import ctypes, ctypes.util, subprocess, time, datetime

asl = ctypes.util.find_library('ApplicationServices')
cfl = ctypes.util.find_library('CoreFoundation')
lib = ctypes.CDLL(asl); cf = ctypes.CDLL(cfl)
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
cf.CFRelease.argtypes=[ctypes.c_void_p]
lib.AXUIElementCreateApplication.restype=ctypes.c_void_p
lib.AXUIElementCreateApplication.argtypes=[ctypes.c_int]
lib.AXUIElementCopyAttributeValue.restype=ctypes.c_int
lib.AXUIElementCopyAttributeValue.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)]
# 位置相关：AXPosition / AXSize / AXBoundsForRange
lib.AXValueGetValue.restype=ctypes.c_bool
lib.AXValueGetValue.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p]

UTF8=0x08000100; ARRAY=cf.CFArrayGetTypeID()
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

class CGPoint(ctypes.Structure): _fields_=[("x",ctypes.c_double),("y",ctypes.c_double)]
class CGSize(ctypes.Structure):  _fields_=[("width",ctypes.c_double),("height",ctypes.c_double)]

def bounds(el):
    """取元素的屏幕矩形（AXPosition + AXSize）。"""
    p = attr(el,"AXPosition"); s = attr(el,"AXSize")
    if not p or not s: return None
    pt=CGPoint(); sz=CGSize()
    kAXValueCGPointType=1; kAXValueCGSizeType=2
    ok1=lib.AXValueGetValue(ctypes.c_void_p(p), kAXValueCGPointType, ctypes.byref(pt))
    ok2=lib.AXValueGetValue(ctypes.c_void_p(s), kAXValueCGSizeType, ctypes.byref(sz))
    if ok1 and ok2:
        return (round(pt.x),round(pt.y),round(sz.width),round(sz.height))
    return None

try:
    pid=int(subprocess.check_output(["pgrep","-x","Books"]).split()[0])
except Exception:
    print("✗ 图书 App 未运行"); raise SystemExit(1)
app=lib.AXUIElementCreateApplication(pid)

print("="*88)
print("请现在到图书 App 里【用鼠标划选一句话】，保持选中状态约 3 秒。")
print("监测 40 秒，每 0.4 秒扫描一次选中文本与它的屏幕位置。")
print("="*88)

last=None; hits=0; t0=time.time()
while time.time()-t0 < 40:
    found=[]
    def walk(el,d=0):
        if d>18 or len(found)>40: return
        sel=cf2s(attr(el,"AXSelectedText"))
        if sel and len(sel.strip())>=2:
            found.append((cf2s(attr(el,"AXRole")), sel, bounds(el)))
        kids=attr(el,"AXChildren")
        if kids and cf.CFGetTypeID(ctypes.c_void_p(kids))==ARRAY:
            for j in range(min(cf.CFArrayGetCount(ctypes.c_void_p(kids)),100)):
                walk(cf.CFArrayGetValueAtIndex(ctypes.c_void_p(kids),j),d+1)
    walk(app)
    sig=tuple((r,s) for r,s,_ in found)
    if sig!=last and found:
        hits+=1
        now=datetime.datetime.now().strftime("%H:%M:%S")
        print(f"\n[{now}] 检测到划选（第 {hits} 次）")
        for role,sel,b in found[:4]:
            print(f"   角色={role}")
            print(f"   内容={sel[:90]!r}")
            print(f"   屏幕位置={b}")
        last=sig
    time.sleep(0.4)

print("\n"+"="*88)
print(f"结果：捕获到 {hits} 次划选事件")
if hits==0:
    print("→ 未能读到划选。可能：没划选、划选被清除太快、或 Books 不上报 AXSelectedText。")
else:
    print("→ AX 能读到划选内容；若同时给出屏幕位置，则「就地浮层」形态技术可行。")
print("="*88)
