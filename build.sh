#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
APP="$TASK_ROOT/薄荷健康桌宠.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TASK_CACHE="$(mktemp -d "${TMPDIR:-/tmp/}mint-swift.XXXXXX")"
trap 'rm -rf "$TASK_CACHE"' EXIT
swiftc "$TASK_ROOT/Source/main.swift" -o "$APP/Contents/MacOS/MintHealthPet" \
  -target arm64-apple-macosx13.0 -module-cache-path "$TASK_CACHE" -framework AppKit -O
cp "$TASK_ROOT/Source/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$TASK_ROOT/Source/AppIcon.icns" ]]; then
  cp "$TASK_ROOT/Source/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"
cp "$APP/Contents/MacOS/MintHealthPet" "$TASK_ROOT/MintHealthPet"
chmod +x "$TASK_ROOT/备用启动.command"
"$APP/Contents/MacOS/MintHealthPet" --self-test
echo "构建完成：$APP"
