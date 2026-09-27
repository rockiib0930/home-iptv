#!/bin/bash
# 在 MacBook Pro (192.168.3.210) 上跑这一行，一键建工程并编译
# 用法: bash setup_on_mac.sh
set -e

cd "$(dirname "$0")"

echo "==> [1/4] 检查 Xcode 命令行工具"
xcode-select -p || xcode-select --install

echo "==> [2/4] 检查/安装 XcodeGen"
if ! command -v xcodegen &>/dev/null; then
    echo "    未安装 xcodegen，用 brew 安装..."
    which brew || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    brew install xcodegen
fi

echo "==> [3/4] 生成 Xcode 工程"
xcodegen generate

echo "==> [4/4] 编译 tvOS App（先编模拟器版本验证语法）"
xcodebuild -project HomeIPTV.xcodeproj -scheme HomeIPTV \
    -destination 'generic/platform=tvOS Simulator' \
    -configuration Debug build \
    CODE_SIGNING_ALLOWED=NO \
    | tail -30

echo ""
echo "================================================"
echo "编译完成。下一步："
echo "  1. open HomeIPTV.xcodeproj"
echo "  2. 在 Xcode 顶部选你的 Apple TV 真机"
echo "  3. 选 Team（Signing 里选你已有的开发者账号）"
echo "  4. 点 Run"
echo "================================================"
