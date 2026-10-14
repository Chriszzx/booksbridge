#!/bin/bash
# 运行 BooksBridge.app。
#
# 用法：
#   ./scripts/run-app.sh              正常启动（标准窗口）
#   ./scripts/run-app.sh --dev        直接跑源码里的前端资源，改 HTML/CSS/JS 只需重开窗口
#   ./scripts/run-app.sh --fullscreen 以原生全屏启动
#
# 首次运行前请先执行 ./scripts/build-app.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/BooksBridge.app"

if [ ! -d "$APP" ]; then
    echo "✗ 还没有构建产物，先执行：./scripts/build-app.sh" >&2
    exit 1
fi

MODE="${BOOKSBRIDGE_WINDOW_MODE:-windowed}"
DEV=0
ARGS=()

for arg in "$@"; do
    case "$arg" in
        --dev) DEV=1 ;;
        --fullscreen) MODE="fullscreen" ;;
        *) ARGS+=("$arg") ;;
    esac
done

if [ "$DEV" = "1" ]; then
    export BOOKSBRIDGE_WEB_ROOT="$ROOT/swift/Sources/BooksBridgeApp/WebUI"
    echo "==> 开发模式：前端资源直接取自源码目录"
    echo "    $BOOKSBRIDGE_WEB_ROOT"
fi

export BOOKSBRIDGE_WINDOW_MODE="$MODE"
echo "==> 窗口模式：$MODE"
echo "==> 启动 $APP"
LAUNCH_ENV=(--env "BOOKSBRIDGE_WINDOW_MODE=$MODE")
if [ "$DEV" = "1" ]; then
    LAUNCH_ENV+=(--env "BOOKSBRIDGE_WEB_ROOT=$BOOKSBRIDGE_WEB_ROOT")
fi
exec open "${LAUNCH_ENV[@]}" "$APP" --args "${ARGS[@]+"${ARGS[@]}"}"
