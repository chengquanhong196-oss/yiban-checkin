#!/bin/bash
# 将 SPM 构建产物打包为完整 .app bundle
set -e

BUILD_DIR="$(cd "$(dirname "$0")/../.build/release" && pwd)"
APP_NAME="YibanCheckin"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BINARY="$BUILD_DIR/$APP_NAME"
ICON="$(cd "$(dirname "$0")/../Sources/GUI/Resources" && pwd)/AppIcon.icns"

echo "📦 打包 $APP_NAME.app..."

# 清理旧包
rm -rf "$APP_DIR"

# 创建 bundle 结构
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 复制二进制
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

# 复制图标
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 生成 Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>YibanCheckin</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.yiban.checkin.app</string>
    <key>CFBundleName</key>
    <string>易班签到</string>
    <key>CFBundleDisplayName</key>
    <string>易班签到</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "✅ $APP_DIR"
echo "   $(du -sh "$APP_DIR" | cut -f1)"
