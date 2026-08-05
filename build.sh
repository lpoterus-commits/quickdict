#!/bin/bash
# 编译并组装 QuickDict.app
#   ./build.sh            只构建，产物在 build/
#   ./build.sh install    构建并安装到 /Applications，然后启动
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QuickDict"
BUNDLE_ID="com.poterus.ocrdict"
APP="build/${APP_NAME}.app"

# 通用二进制。SwiftPM 的 --arch 需要 Xcode 的构建系统，只装了 Command Line Tools 时用不了，
# 所以分别编译两个架构再用 lipo 合并 —— 结果等价，且不依赖完整 Xcode。
echo "==> 编译 arm64"
swift build -c release --scratch-path .build-arm64 \
    -Xswiftc -target -Xswiftc arm64-apple-macos13.0
echo "==> 编译 x86_64"
swift build -c release --scratch-path .build-x86 \
    -Xswiftc -target -Xswiftc x86_64-apple-macos13.0

echo "==> 组装 App Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    "$(find .build-arm64 -type f -name OCRDict -perm +111 | head -1)" \
    "$(find .build-x86   -type f -name OCRDict -perm +111 | head -1)" \
    -output "$APP/Contents/MacOS/OCRDict"
echo "    $(lipo -archs "$APP/Contents/MacOS/OCRDict")"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> 拷入本地化资源"
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done
echo "    $(ls -d Resources/*.lproj 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"

echo "==> 生成图标"
if swift Tools/makeicon.swift build/AppIcon.iconset >/dev/null 2>&1 \
   && iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    ok"
else
    echo "    跳过（不影响使用，只是 Finder 里显示通用图标）"
fi

echo "==> 签名"
# 本地 ad-hoc 签名。没有签名的话 TCC 授权会更不稳定。
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "    ok"

if [ "${1:-}" = "install" ]; then
    echo "==> 安装到 /Applications"
    # 走正常退出，好让「退出时清除浏览数据」真的跑到；pkill 只作兜底
    osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
    sleep 1
    pkill -f "/Applications/${APP_NAME}.app" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" "/Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
    echo "    已启动，看菜单栏右侧的图标"
else
    echo
    echo "构建完成：$APP"
    echo "安装请运行：./build.sh install"
fi
