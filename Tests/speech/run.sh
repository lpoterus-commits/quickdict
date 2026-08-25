#!/bin/bash
# 朗读引擎的无界面测试。
#
# 编的是**真模块**：Sources/OCRDict 下除 main.swift 之外的全部源码，
# 加上 Tests/speech/main.swift 作为入口。不复制逻辑、不打桩内部实现 ——
# 测的就是 App 里跑的那些代码。
#
#   ./Tests/speech/run.sh
#
# 全程不出声：队列那段用假引擎。
set -uo pipefail
cd "$(dirname "$0")/../.."

BUILD=".build-tests"
BIN="$BUILD/speech-tests"
mkdir -p "$BUILD"

echo "==> 编译"
# 配置目录隔离：测试会走 ConfigStore.load()，不能碰到真配置
export CFFIXED_USER_HOME="$BUILD/home"
mkdir -p "$CFFIXED_USER_HOME"

SOURCES=$(find Sources/OCRDict -name '*.swift' ! -name 'main.swift')
# shellcheck disable=SC2086
swiftc -O -o "$BIN" $SOURCES Tests/speech/main.swift \
    -target arm64-apple-macos13.0 \
    -framework AppKit -framework AVFoundation -framework WebKit \
    -framework NaturalLanguage -framework Vision -framework ServiceManagement \
    2>&1 | grep -vE "^\s*$" | head -30
[ -x "$BIN" ] || { echo "编译失败"; exit 1; }

echo "==> 跑 Swift 侧"
"$BIN"
swift_status=$?

sidecar_status=0
if [ -n "${QUICKDICT_TEST_PORT:-}" ]; then
    # 边车自己那套（取消语义、孤儿回收、内存、令牌）另起一个进程验 ——
    # 它要杀父进程，不能和上面那个共用同一个边车
    echo
    echo "==> 跑边车侧"
    # wait 一下再往下走，否则 shell 会把「Terminated: 15」打进测试输出里
    { kill "$SIDECAR_PID"; wait "$SIDECAR_PID"; } 2>/dev/null
    SIDECAR_PID=""
    python3 Tests/speech/sidecar.py
    sidecar_status=$?
fi

[ "$swift_status" -eq 0 ] && [ "$sidecar_status" -eq 0 ]
