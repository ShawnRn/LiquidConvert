#!/bin/bash

# LiquidConvert Sparkle 自动化发布脚本 (支持双架构 arm64 + x86_64)
# 用法: ./scripts/release.sh <版本号>
# 示例: ./scripts/release.sh 1.0.0

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "错误: 请提供版本号 (例如: 1.0.0)"
    exit 1
fi

# 1. 配置路径
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RELEASE_DIR="$PROJECT_DIR/releases"
APPCAST_FILE="$PROJECT_DIR/appcast.xml"
DMG_ARM64="$RELEASE_DIR/LiquidConvert_${VERSION}_arm64.dmg"
DMG_X86_64="$RELEASE_DIR/LiquidConvert_${VERSION}_x86_64.dmg"
PROJECT_FILE="$PROJECT_DIR/LiquidConvert.xcodeproj"
SCHEME="LiquidConvert"
REMOTE_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/liquidconvert-release-verify.XXXXXX")"

cleanup() {
    rm -rf "$REMOTE_VERIFY_DIR"
}
trap cleanup EXIT

echo "正在搜索 sign_update 工具..."
SIGN_TOOL="${SIGN_TOOL_PATH:-$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/Sparkle/bin/sign_update" | head -n 1)}"

if [ -z "$SIGN_TOOL" ]; then
    echo "警告: 未找到 'sign_update' 工具。"
    echo "请确保已在 Xcode 中添加 Sparkle 依赖并至少构建过一次项目。"
    echo "或者手动指定 SIGN_TOOL 路径。"
    exit 1
fi

# 检查 DMG 是否存在
if [ ! -f "$DMG_ARM64" ]; then
    echo "错误: 找不到 arm64 DMG 文件。"
    echo "请确保 $DMG_ARM64 存在于 $RELEASE_DIR 文件夹下"
    exit 1
fi

if [ ! -f "$DMG_X86_64" ]; then
    echo "错误: 找不到 x86_64 DMG 文件。"
    echo "请确保 $DMG_X86_64 存在于 $RELEASE_DIR 文件夹下"
    exit 1
fi

echo "--- 开始为版本 $VERSION 准备发布 (双架构) ---"

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

# 3. 校验 GitHub 资产
PUB_DATE=$(date -R)
URL_ARM64="https://github.com/ShawnRn/LiquidConvert/releases/download/v$VERSION/LiquidConvert_${VERSION}_arm64.dmg"
URL_X86_64="https://github.com/ShawnRn/LiquidConvert/releases/download/v$VERSION/LiquidConvert_${VERSION}_x86_64.dmg"

REMOTE_ARM64="$REMOTE_VERIFY_DIR/LiquidConvert_${VERSION}_arm64.dmg"
REMOTE_X86_64="$REMOTE_VERIFY_DIR/LiquidConvert_${VERSION}_x86_64.dmg"

echo "正在校验 GitHub Release 上实际可下载的资产..."
if curl -L --fail --retry 3 --retry-delay 1 --retry-all-errors -o "$REMOTE_ARM64" "$URL_ARM64" 2>/dev/null; then
    LOCAL_SHA_ARM64=$(shasum -a 256 "$DMG_ARM64" | awk '{print $1}')
    REMOTE_SHA_ARM64=$(shasum -a 256 "$REMOTE_ARM64" | awk '{print $1}')
    if [ "$LOCAL_SHA_ARM64" != "$REMOTE_SHA_ARM64" ]; then
        echo "警告: GitHub Release arm64 下载资产与本地不一致。"
    fi
else
    echo "警告: 无法从 GitHub 预下载 arm64 资产。"
fi

if curl -L --fail --retry 3 --retry-delay 1 --retry-all-errors -o "$REMOTE_X86_64" "$URL_X86_64" 2>/dev/null; then
    LOCAL_SHA_X86_64=$(shasum -a 256 "$DMG_X86_64" | awk '{print $1}')
    REMOTE_SHA_X86_64=$(shasum -a 256 "$REMOTE_X86_64" | awk '{print $1}')
    if [ "$LOCAL_SHA_X86_64" != "$REMOTE_SHA_X86_64" ]; then
        echo "警告: GitHub Release x86_64 下载资产与本地不一致。"
    fi
else
    echo "警告: 无法从 GitHub 预下载 x86_64 资产。"
fi

# 4. 生成签名与获取大⼩
echo "正在生成 EdDSA 签名..."
sign_update_file() {
    local source_file="$1"
    local raw_output

    if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
        if ! raw_output=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_TOOL" --ed-key-file - -p "$source_file" 2>&1); then
            echo "错误: 签名生成失败: $raw_output" >&2
            return 1
        fi
    else
        if ! raw_output=$("$SIGN_TOOL" -p "$source_file" 2>&1); then
            echo "错误: 签名生成失败: $raw_output" >&2
            return 1
        fi
    fi

    local signature
    signature=$(printf '%s\n' "$raw_output" | grep -Eo '[A-Za-z0-9+/]{80,}={0,2}' | tail -n 1 || true)

    if [ -z "$signature" ] || printf '%s\n' "$raw_output" | grep -qiE 'ERROR|Signing key not found'; then
        echo "错误: sign_update 未返回有效 EdDSA 签名: $raw_output" >&2
        return 1
    fi

    printf '%s' "$signature"
}

TARGET_ARM64="$DMG_ARM64"
if [ -f "$REMOTE_ARM64" ]; then
    TARGET_ARM64="$REMOTE_ARM64"
fi

TARGET_X86_64="$DMG_X86_64"
if [ -f "$REMOTE_X86_64" ]; then
    TARGET_X86_64="$REMOTE_X86_64"
fi

SIG_ARM64=$(sign_update_file "$TARGET_ARM64")
SIG_X86_64=$(sign_update_file "$TARGET_X86_64")

if [ -z "$SIG_ARM64" ] || [ -z "$SIG_X86_64" ]; then
    echo "错误: 双架构签名生成失败，请确保 Sparkle 私钥已配置。"
    exit 1
fi

SIZE_ARM64=$(stat -f%z "$TARGET_ARM64")
SIZE_X86_64=$(stat -f%z "$TARGET_X86_64")

echo "arm64 签名: $SIG_ARM64, 大小: $SIZE_ARM64"
echo "x86_64 签名: $SIG_X86_64, 大小: $SIZE_X86_64"
echo "发布日期: $PUB_DATE"

# 5. 更新 appcast.xml (包含双 enclosure)
echo "正在更新 appcast.xml..."

ITEM_XML="        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$SPARKLE_VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url=\"$URL_ARM64\" length=\"$SIZE_ARM64\" type=\"application/octet-stream\" sparkle:os=\"macos\" sparkle:nativeArchitecture=\"arm64\" sparkle:edSignature=\"$SIG_ARM64\"/>
            <enclosure url=\"$URL_X86_64\" length=\"$SIZE_X86_64\" type=\"application/octet-stream\" sparkle:os=\"macos\" sparkle:nativeArchitecture=\"x86_64\" sparkle:edSignature=\"$SIG_X86_64\"/>
        </item>"

python3 - "$APPCAST_FILE" "$SPARKLE_VERSION" "$VERSION" "$ITEM_XML" <<'PY'
import re
import sys
from pathlib import Path

appcast_path = Path(sys.argv[1])
sparkle_version = sys.argv[2]
short_version = sys.argv[3]
item_xml = sys.argv[4]

if appcast_path.exists():
    content = appcast_path.read_text(encoding="utf-8")
else:
    content = ""

items = re.findall(r"<item>.*?</item>", content, re.S)
items = [
    item
    for item in items
    if f"<sparkle:version>{sparkle_version}</sparkle:version>" not in item
    and f"<sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>" not in item
]

rebuilt = "\n".join(
    [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">',
        "    <channel>",
        "        <title>LiquidConvert</title>",
        item_xml,
        *["        " + item.replace("\n", "\n        ").strip() for item in items],
        "    </channel>",
        "</rss>",
        "",
    ]
)

appcast_path.write_text(rebuilt, encoding="utf-8")
PY

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$APPCAST_FILE" || {
        echo "错误: appcast.xml XML 校验失败，已中止发布。"
        exit 1
    }
    echo "appcast.xml 校验通过"
fi

echo "--- 准备完成！ ---"
echo "appcast.xml 已更新。"
echo "请执行:"
echo "gh release create \"v$VERSION\" \"$DMG_ARM64\" \"$DMG_X86_64\" --title \"LiquidConvert $VERSION\" --notes \"更新日志...\""
