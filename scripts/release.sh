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

# 定位签名工具
# 尝试在 DerivedData 中搜索 sign_update
# 注意：即使路径变化，find 命令也能找到它
echo "正在搜索 sign_update 工具..."
SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/Sparkle/bin/sign_update" | head -n 1)

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

# 2. 生成基于日期的 Build 号 (YYYYMMDDxx)
echo "正在生成流水号 Build 号..."
TODAY=$(date +"%Y%m%d")
# 从 appcast.xml 中查找今天已有的最高版本号
if [ -f "$APPCAST_FILE" ]; then
    LAST_BUILD=$(grep -oE "<sparkle:version>${TODAY}[0-9]{2}</sparkle:version>" "$APPCAST_FILE" | grep -oE "${TODAY}[0-9]{2}" | sort -nr | head -n 1)
else
    LAST_BUILD=""
fi

if [ -z "$LAST_BUILD" ]; then
    SPARKLE_VERSION="${TODAY}00"
else
    # 提取最后两位并加 1
    SUFFIX=${LAST_BUILD:8:2}
    NEXT_SUFFIX=$(printf "%02d" $((10#$SUFFIX + 1)))
    SPARKLE_VERSION="${TODAY}${NEXT_SUFFIX}"
fi

echo "生成的 Build 号 (sparkle:version): $SPARKLE_VERSION"

# 3. 生成签名与获取大⼩
echo "正在为双架构生成 EdDSA 签名..."
SIG_ARM64=$($SIGN_TOOL -p "$DMG_ARM64")
SIG_X86_64=$($SIGN_TOOL -p "$DMG_X86_64")

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
            <sparkle:version>${SPARKLE_VERSION//./}</sparkle:version>
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

# 6. 完成提示
echo "--- 准备完成！ ---"
echo "appcast.xml 已更新。"
echo "请执行:"
echo "gh release create \"v\$VERSION\" \"$DMG_ARM64\" \"$DMG_X86_64\" --title \"LiquidConvert \$VERSION\" --notes \"更新日志...\""
