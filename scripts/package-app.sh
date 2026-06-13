#!/bin/bash
# 将 YibanCheckin 可执行文件打包为 macOS .app
set -e

BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)/.build/release"
APP_NAME="YibanCheckin"
BINARY="$BUILD_DIR/$APP_NAME"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "📦 打包 $APP_NAME.app..."

# 创建 app bundle 目录结构
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制可执行文件
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 创建 Info.plist（包含所有需要的权限声明）
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>YibanCheckin</string>
	<key>CFBundleIdentifier</key>
	<string>com.yiban.checkin</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>易班签到</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>易班签到需要获取你的位置来判断是否在校园范围内</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>易班签到需要发送系统通知来告知签到结果</string>
	<key>LSUIElement</key>
	<false/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# 创建 entitlements.plist（声明辅助功能权限）
cat > "$BUILD_DIR/entitlements.plist" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.automation.apple-events</key>
	<true/>
</dict>
</plist>
ENTITLEMENTS

# 复制 App 图标
ICON_SRC="$(cd "$(dirname "$0")" && pwd)/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# 创建 PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 代码签名（ad-hoc，让 macOS 记住权限）
echo "🔐 签名 App..."
codesign --force --deep --sign - \
    --entitlements "$BUILD_DIR/entitlements.plist" \
    "$APP_BUNDLE" 2>/dev/null

echo "✅ App 已打包: $APP_BUNDLE"
echo ""
echo "打开方式："
echo "  open \"$APP_BUNDLE\""
echo ""
echo "或者复制到 Applications："
echo "  cp -r \"$APP_BUNDLE\" /Applications/"
echo ""
echo "⚠️  如果权限弹窗一直弹出："
echo "  1. 系统设置 → 隐私与安全性 → 辅助功能 → 添加 YibanCheckin"
echo "  2. 系统设置 → 隐私与安全性 → 录屏 → 添加 YibanCheckin"
echo "  3. 系统设置 → 隐私与安全性 → 定位服务 → 开启"
