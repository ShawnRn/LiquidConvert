#!/bin/bash

# LiquidConvert Sparkle 自动化发布脚本
# 用法: ./scripts/release.sh <版本号>
# 示例: ./scripts/release.sh 1.0.0

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "错误: 请提供版本号 (例如: 1.0.0)"
    exit 1
fi

# 1. 配置路径
# 获取脚本所在目录的上一级目录作为项目根目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RELEASE_DIR="$PROJECT_DIR/releases"
APPCAST_FILE="$PROJECT_DIR/appcast.xml"
DMG_ARM64="$RELEASE_DIR/LiquidConvert_${VERSION}_arm64.dmg"
DMG_X86_64="$RELEASE_DIR/LiquidConvert_${VERSION}_x86_64.dmg"
PROJECT_FILE="$PROJECT_DIR/LiquidConvert.xcodeproj"
SCHEME="LiquidConvert"

echo "正在搜索 sign_update 工具..."
SIGN_TOOL="${SIGN_TOOL_PATH:-$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/Sparkle/bin/sign_update" | head -n 1)}"

if [ -z "$SIGN_TOOL" ]; then
    echo "警告: 未找到 'sign_update' 工具。"
    echo "请确保已在 Xcode 中添加 Sparkle 依赖并至少构建过一次项目。"
    echo "或者手动指定 SIGN_TOOL 路径。"
    exit 1
fi

# 检查 DMG 是否存在
if [ ! -f "$DMG_ARM64" ] || [ ! -f "$DMG_X86_64" ]; then
    echo "错误: 找不到 DMG 文件。"
    echo "请确保 $DMG_ARM64 和 $DMG_X86_64 都存在于 $RELEASE_DIR 文件夹下"
    exit 1
fi

echo "--- 开始为版本 $VERSION 准备发布 ---"

# 2. 从项目配置中读取 Build 号，确保与 App 本体一致
echo "正在读取项目中的 Build 号..."
XCODE_SETTINGS=$(xcodebuild -showBuildSettings -project "$PROJECT_FILE" -scheme "$SCHEME" -configuration Release 2>/dev/null)
SPARKLE_VERSION=$(echo "$XCODE_SETTINGS" | awk '/ CURRENT_PROJECT_VERSION = / {print $3; exit}')
PROJECT_VERSION=$(echo "$XCODE_SETTINGS" | awk '/ MARKETING_VERSION = / {print $3; exit}')

if [ -z "$SPARKLE_VERSION" ] || [ -z "$PROJECT_VERSION" ]; then
    echo "错误: 无法从项目中读取版本号或 Build 号。"
    exit 1
fi

if [ "$PROJECT_VERSION" != "$VERSION" ]; then
    echo "错误: 传入版本号 $VERSION 与项目 MARKETING_VERSION ($PROJECT_VERSION) 不一致。"
    exit 1
fi

if [ -f "$APPCAST_FILE" ]; then
    LAST_BUILD=$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$APPCAST_FILE" | grep -oE '[0-9]+' | sort -nr | head -n 1)
    if [ -n "$LAST_BUILD" ] && [ "$SPARKLE_VERSION" -lt "$LAST_BUILD" ]; then
        echo "错误: 项目 Build 号 $SPARKLE_VERSION 小于现有 appcast 里的最新版本 $LAST_BUILD。"
        exit 1
    fi
fi

echo "使用项目 Build 号 (sparkle:version): $SPARKLE_VERSION"

# 3. 生成签名与获取大⼩
echo "正在为双架构生成 EdDSA 签名..."
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    SIG_ARM64=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_TOOL" --ed-key-file - -p "$DMG_ARM64")
    SIG_X86_64=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_TOOL" --ed-key-file - -p "$DMG_X86_64")
else
    SIG_ARM64=$("$SIGN_TOOL" -p "$DMG_ARM64")
    SIG_X86_64=$("$SIGN_TOOL" -p "$DMG_X86_64")
fi

if [ -z "$SIG_ARM64" ] || [ -z "$SIG_X86_64" ]; then
    echo "错误: 签名生成失败，请确保 Sparkle 私钥已配置。"
    exit 1
fi

SIZE_ARM64=$(stat -f%z "$DMG_ARM64")
SIZE_X86_64=$(stat -f%z "$DMG_X86_64")
PUB_DATE=$(date -R)

URL_ARM64="https://github.com/ShawnRn/LiquidConvert/releases/download/v$VERSION/LiquidConvert_${VERSION}_arm64.dmg"
URL_X86_64="https://github.com/ShawnRn/LiquidConvert/releases/download/v$VERSION/LiquidConvert_${VERSION}_x86_64.dmg"

echo "arm64 签名: $SIG_ARM64, 大小: $SIZE_ARM64"
echo "x86_64 签名: $SIG_X86_64, 大小: $SIZE_X86_64"
echo "发布日期: $PUB_DATE"


# 5. 更新 appcast.xml
echo "正在更新 appcast.xml..."

# 检查 appcast.xml 是否已存在，如果不存在则创建头
if [ ! -f "$APPCAST_FILE" ]; then
    cat <<EOF > "$APPCAST_FILE"
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>LiquidConvert</title>
    </channel>
</rss>
EOF
fi

# 生成新的 ITEM XML (多 enclosure)
ITEM_XML="        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$SPARKLE_VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url=\"$URL_ARM64\" length=\"$SIZE_ARM64\" type=\"application/octet-stream\" sparkle:os=\"macos\" sparkle:nativeArchitecture=\"arm64\" sparkle:edSignature=\"$SIG_ARM64\"/>
            <enclosure url=\"$URL_X86_64\" length=\"$SIZE_X86_64\" type=\"application/octet-stream\" sparkle:os=\"macos\" sparkle:nativeArchitecture=\"x86_64\" sparkle:edSignature=\"$SIG_X86_64\"/>
        </item>"

# 将新 ITEM 插入到 <channel> 标签之后 (简单的插入逻辑，适用于简单维护)
# 使用临时文件处理
TEMP_FILE=$(mktemp)
# 读取文件直到 <channel>
sed '/<channel>/q' "$APPCAST_FILE" > "$TEMP_FILE"
# 写入新 Item
echo "$ITEM_XML" >> "$TEMP_FILE"
# 读取 <channel> 之后的内容 (不包含 <channel>)
sed -n '/<channel>/,$p' "$APPCAST_FILE" | tail -n +2 >> "$TEMP_FILE"

mv "$TEMP_FILE" "$APPCAST_FILE"

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$APPCAST_FILE"
    echo "appcast.xml 校验通过"
fi

# 6. 完成提示
echo "--- 准备完成！ ---"
echo "appcast.xml 已更新。"
echo "请执行:"
echo "gh release create \"v\$VERSION\" \"$DMG_ARM64\" \"$DMG_X86_64\" --title \"LiquidConvert \$VERSION\" --notes \"更新日志...\""
