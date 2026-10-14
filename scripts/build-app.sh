#!/bin/bash
# 把 SwiftPM 产物组装成一个可运行的 .app。
#
# 为什么需要这一步：`LSUIElement`（无 Dock 图标）只在 bundle 的 Info.plist 里生效，
# 裸可执行文件做不到；WKWebView 也需要 bundle 上下文才能通过 Bundle.module 找到前端资源。
#
# 用法：
#   ./scripts/build-app.sh            # debug 构建
#   ./scripts/build-app.sh release    # release 构建

set -euo pipefail

CONFIG="${1:-debug}"
SWIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../swift" && pwd)"
OUT_DIR="$(cd "$SWIFT_DIR/.." && pwd)/build"
APP="$OUT_DIR/BooksBridge.app"

SIGNING_IDENTITY="${BOOKSBRIDGE_SIGNING_IDENTITY:-BooksBridge Dev}"
security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY" || {
    echo "✗ 缺少有效签名身份 $SIGNING_IDENTITY，保留现有应用。请检查钥匙串。" >&2
    exit 1
}

echo "==> 构建模式 ${CONFIG}"
cd "$SWIFT_DIR"
swift build -c "$CONFIG" --product BooksBridgeApp

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXEC="$BIN_DIR/BooksBridgeApp"
[ -x "$EXEC" ] || { echo "✗ 找不到可执行文件: $EXEC" >&2; exit 1; }

FINAL_APP="$APP"
mkdir -p "$OUT_DIR"
STAGING="$(mktemp -d "$OUT_DIR/.staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/BooksBridge.app"
echo "==> 组装 $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$SWIFT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$EXEC" "$APP/Contents/MacOS/BooksBridgeApp"

# SwiftPM 把 target 资源放在独立的 .bundle 里，必须原样拷进 Contents/Resources，
# 否则运行期 Bundle.module 会找不到 WebUI。
RESOURCE_BUNDLE="$BIN_DIR/BooksBridge_BooksBridgeApp.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
else
    echo "✗ 找不到资源 bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi

# 固定签名身份；失败即停止，不能悄悄改变 TCC 识别的应用身份。
SIGNING_IDENTITY="${BOOKSBRIDGE_SIGNING_IDENTITY:-BooksBridge Dev}"
security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY" || {
    echo "✗ 找不到有效签名身份 $SIGNING_IDENTITY；请检查钥匙串或运行 setup-signing.sh。" >&2
    exit 1
}
codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> 签名已验证"
# 只有完整签名验证成功后才替换旧应用。
if [ -d "$FINAL_APP" ]; then mv "$FINAL_APP" "$STAGING/previous.app"; fi
if ! mv "$APP" "$FINAL_APP"; then
    [ ! -d "$STAGING/previous.app" ] || mv "$STAGING/previous.app" "$FINAL_APP"
    exit 1
fi
APP="$FINAL_APP"

echo "==> 完成"
echo "   $APP"
echo
echo "运行："
echo "   open '$APP'"
echo "   开发模式：./scripts/run-app.sh --dev"
