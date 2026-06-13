#!/bin/bash
# 易班签到自动工具 — 安装脚本
set -e

BIN_NAME="yiban-checkin"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="$HOME/.config/yiban-checkin"
LOG_DIR="$HOME/Library/Logs"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.yiban.checkin.plist"

echo "🚀 安装易班签到自动工具..."
echo "================================"

# 1. 编译项目
echo ""
echo "[1/5] 编译项目..."
cd "$(dirname "$0")/.."
swift build -c release
echo "✅ 编译完成"

# 2. 安装二进制文件
echo ""
echo "[2/5] 安装二进制到 $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
cp ".build/release/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
chmod +x "$INSTALL_DIR/$BIN_NAME"
echo "✅ 已安装到 $INSTALL_DIR/$BIN_NAME"

# 3. 创建配置文件
echo ""
echo "[3/5] 配置..."
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOF'
{
  "campusLatitude": 24.5580,
  "campusLongitude": 118.5874,
  "campusName": "晋江",
  "checkinEndHour": 23,
  "checkinEndMinute": 0,
  "checkinMethod": "auto",
  "checkinStartHour": 21,
  "checkinStartMinute": 30,
  "locationTimeout": 15,
  "logLevel": 1,
  "maxRetries": 3,
  "radiusMeters": 500,
  "schoolName": "",
  "stepDelay": 2,
  "uiTimeout": 10,
  "yibanAct": "",
  "yibanBundleID": "com.yiban.app",
  "yibanClientId": "",
  "yibanUsername": ""
}
EOF
    echo "✅ 配置文件已创建: $CONFIG_FILE"
    echo ""
    echo "⚠️  请编辑配置文件，填写以下信息:"
    echo "   - yibanBundleID: 易班 app 的 Bundle ID（如果不确定先用默认值，运行 --inspect 探查）"
    echo "   - yibanUsername: 易班账号（如果 app 需要手动输入）"
    echo "   - yibanPassword: 易班密码（如果 app 需要手动输入）"
    echo "   - campusLatitude/campusLongitude: 校区坐标"
    echo ""
    echo "   配置文件位置: $CONFIG_FILE"
else
    echo "ℹ️  配置文件已存在，跳过创建"
fi

# 4. 创建日志目录
echo ""
echo "[4/5] 创建日志目录..."
mkdir -p "$LOG_DIR"
echo "✅ 日志将输出到: $LOG_DIR/yiban-checkin.log"

# 5. 安装 launchd 定时任务
echo ""
echo "[5/5] 安装定时任务 (每天 9:30 执行)..."
mkdir -p "$LAUNCHD_DIR"

# 替换 plist 中的路径
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sed "s|/usr/local/bin/yiban-checkin|$INSTALL_DIR/$BIN_NAME|g" \
    "$SCRIPT_DIR/com.yiban.checkin.plist" > "$LAUNCHD_DIR/$PLIST_NAME"

# 卸载旧版本 (如果存在)
launchctl unload "$LAUNCHD_DIR/$PLIST_NAME" 2>/dev/null || true
# 加载新版本
launchctl load "$LAUNCHD_DIR/$PLIST_NAME"

echo "✅ 定时任务已安装"
echo ""
echo "================================"
echo "🎉 安装完成！"
echo ""
echo "下一步操作:"
echo ""
echo "1. 确保在「系统设置 → 隐私与安全性 → 辅助功能」中"
echo "   授权终端 (Terminal) 或 iTerm 的辅助功能权限"
echo ""
echo "2. 先手动打开易班 app，然后运行 UI 探查工具："
echo "   $INSTALL_DIR/$BIN_NAME --inspect"
echo ""
echo "3. 根据探查结果，更新配置文件:"
echo "   $CONFIG_FILE"
echo ""
echo "4. 手动测试签到流程:"
echo "   $INSTALL_DIR/$BIN_NAME"
echo ""
echo "5. 定时任务状态查看:"
echo "   launchctl list | grep yiban"
echo ""
echo "6. 查看日志:"
echo "   tail -f $LOG_DIR/yiban-checkin.log"
echo ""
echo "📅 定时任务已设置为每天 9:30 自动执行"
