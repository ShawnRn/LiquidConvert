#!/usr/bin/env bash

# LiquidConvert Build & Package Script
# Usage: ./scripts/build.sh [debug|release]

set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PROJECT_NAME="LiquidConvert"
SCHEME="LiquidConvert"
APP_NAME="LiquidConvert.app"
ARCHIVE_PATH="$ROOT/.build/archive/${PROJECT_NAME}.xcarchive"
APP_BUNDLE="$ROOT/${APP_NAME}"
SKIP_DMG="${SKIP_DMG:-0}"

create_dmg_with_layout() {
    local app_bundle="$1"
    local dmg_path="$2"
    local target_arch="$3"
    local display_app_name="${PROJECT_NAME}.app"
    local dmg_dir
    dmg_dir=$(dirname "$dmg_path")
    local styled_dmg_path="${dmg_dir}/${PROJECT_NAME} ${MARKETING_VERSION}.dmg"
    local staging_dir
    staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/liquidconvert-dmg-${target_arch}.XXXXXX")
    local fallback_volume
    fallback_volume="${staging_dir}/${PROJECT_NAME}"

    cleanup_dmg_staging() {
        rm -rf "$staging_dir"
    }
    trap cleanup_dmg_staging RETURN

    mkdir -p "$staging_dir"
    ditto --noextattr --norsrc "$app_bundle" "${staging_dir}/${display_app_name}"
    xattr -cr "${staging_dir}/${display_app_name}" || true
    find "${staging_dir}/${display_app_name}" -name ".DS_Store" -depth -exec rm {} \; 2>/dev/null || true

    if command -v create-dmg >/dev/null 2>&1; then
        echo "==> Creating styled DMG with create-dmg for ${target_arch}..."
        rm -f "${styled_dmg_path}"
        create-dmg \
            --overwrite \
            --dmg-title "${PROJECT_NAME}" \
            --no-code-sign \
            "${staging_dir}/${display_app_name}" \
            "${dmg_dir}" || echo "Warning: create-dmg failed, falling back to hdiutil..."

        if [[ -f "${styled_dmg_path}" && "${styled_dmg_path}" != "${dmg_path}" ]]; then
            mv -f "${styled_dmg_path}" "${dmg_path}"
        fi
    fi

    if [[ ! -f "${dmg_path}" ]]; then
        echo "==> Falling back to plain DMG with Applications shortcut for ${target_arch}..."
        rm -rf "${fallback_volume}"
        mkdir -p "${fallback_volume}"
        cp -R "$app_bundle" "${fallback_volume}/${display_app_name}"
        ln -s /Applications "${fallback_volume}/Applications"

        hdiutil create \
            -volname "${PROJECT_NAME}" \
            -srcfolder "${fallback_volume}" \
            -ov \
            -format UDZO \
            "${dmg_path}"
    fi
}

if [[ -n "${BUILD_ARCHS:-}" ]]; then
    read -r -a TARGET_ARCHS <<< "${BUILD_ARCHS}"
else
    TARGET_ARCHS=("arm64")
fi

# Detect version from Xcode project
echo "==> Detecting version from project settings..."
XCODE_SETTINGS=$(set +o pipefail; xcodebuild -showBuildSettings -project "${PROJECT_NAME}.xcodeproj" -scheme "${SCHEME}" -configuration "${CONF}" 2>/dev/null)
MARKETING_VERSION=$(echo "$XCODE_SETTINGS" | grep " MARKETING_VERSION =" | head -n 1 | awk '{print $3}')
BUILD_NUMBER=$(echo "$XCODE_SETTINGS" | grep " CURRENT_PROJECT_VERSION =" | head -n 1 | awk '{print $3}')

echo "==> Version: ${MARKETING_VERSION} (Build: ${BUILD_NUMBER})"

# Detect architecture
ARCH=$(uname -m)
SDK="macosx"

if [[ "$CONF" == "debug" ]]; then
    XCODE_CONF="Debug"
else
    XCODE_CONF="Release"
fi

# 1. Resolve dependencies
echo "==> Resolving package dependencies..."
xcodebuild -resolvePackageDependencies -project "${PROJECT_NAME}.xcodeproj" -scheme "${SCHEME}" -scmProvider xcode

# 2. Build or Archive (Loop per architecture)
for TARGET_ARCH in "${TARGET_ARCHS[@]}"; do
    echo "=================================================="
    echo "==> Starting build process for architecture: ${TARGET_ARCH}"
    echo "=================================================="
    
    ARCH_APP_BUNDLE="${ROOT}/${PROJECT_NAME}_${TARGET_ARCH}.app"
    ARCH_ARCHIVE_PATH="${ROOT}/.build/archive/${PROJECT_NAME}_${TARGET_ARCH}.xcarchive"
    
    if [[ "$XCODE_CONF" == "Debug" ]]; then
        echo "==> Building project (${XCODE_CONF}) for ${TARGET_ARCH}..."
        xcodebuild build \
            -project "${PROJECT_NAME}.xcodeproj" \
            -scheme "${SCHEME}" \
            -configuration "${XCODE_CONF}" \
            -destination "platform=macOS" \
            -scmProvider xcode \
            MARKETING_VERSION="${MARKETING_VERSION}" \
            CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
            ARCHS="${TARGET_ARCH}" \
            CODE_SIGNING_ALLOWED=NO
        
        # Locate products
        echo "==> Locating built app..."
        BUILT_PRODUCTS_DIR=$(xcodebuild -showBuildSettings -project "${PROJECT_NAME}.xcodeproj" -scheme "${SCHEME}" -configuration "${XCODE_CONF}" ARCHS="${TARGET_ARCH}" | grep -m 1 " BUILT_PRODUCTS_DIR =" | awk '{print $3}')
        
        if [[ -z "$BUILT_PRODUCTS_DIR" || ! -d "$BUILT_PRODUCTS_DIR/${APP_NAME}" ]]; then
            echo "ERROR: Could not locate built app in ${BUILT_PRODUCTS_DIR:-unknown}"
            exit 1
        fi
        
        rm -rf "${ARCH_APP_BUNDLE}"
        cp -R "${BUILT_PRODUCTS_DIR}/${APP_NAME}" "${ARCH_APP_BUNDLE}"
    else
        echo "==> Archiving project (${XCODE_CONF}) for ${TARGET_ARCH}..."
        xcodebuild archive \
            -project "${PROJECT_NAME}.xcodeproj" \
            -scheme "${SCHEME}" \
            -configuration "${XCODE_CONF}" \
            -archivePath "${ARCH_ARCHIVE_PATH}" \
            -destination "generic/platform=macOS,name=Any Mac" \
            -scmProvider xcode \
            MARKETING_VERSION="${MARKETING_VERSION}" \
            CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
            ARCHS="${TARGET_ARCH}" \
            SKIP_INSTALL=NO
        
        echo "==> Exporting app bundle from archive for ${TARGET_ARCH}..."
        rm -rf "${ARCH_APP_BUNDLE}"
        cp -R "${ARCH_ARCHIVE_PATH}/Products/Applications/${APP_NAME}" "${ARCH_APP_BUNDLE}"
    fi

    # 3. Post-processing (Signing)
    SIGNING_IDENTITY="-"
    echo "==> Removing extended attributes before signing for ${TARGET_ARCH}..."
    xattr -cr "${ARCH_APP_BUNDLE}" || true
    find "${ARCH_APP_BUNDLE}" -name ".DS_Store" -depth -exec rm {} \; 2>/dev/null || true

    echo "==> Signing app bundle (Ad-hoc) for ${TARGET_ARCH}..."
    codesign --force --deep --sign "${SIGNING_IDENTITY}" "${ARCH_APP_BUNDLE}"

    echo "==> Successfully created ${ARCH_APP_BUNDLE}"

    # 4. Create DMG
    if [[ "${SKIP_DMG}" == "1" ]]; then
        echo "==> Skipping DMG creation for ${TARGET_ARCH} (SKIP_DMG=1)"
    else
        echo "==> Creating DMG for ${TARGET_ARCH}..."
        DMG_DIR="$ROOT/releases"
        mkdir -p "$DMG_DIR"
        
        # Target name for release.sh
        DMG_FINAL_NAME="${PROJECT_NAME}_${MARKETING_VERSION}_${TARGET_ARCH}.dmg"
        DMG_FINAL_PATH="$DMG_DIR/$DMG_FINAL_NAME"
        rm -f "$DMG_FINAL_PATH"

        create_dmg_with_layout "${ARCH_APP_BUNDLE}" "${DMG_FINAL_PATH}" "${TARGET_ARCH}"

        if [[ -f "$DMG_FINAL_PATH" ]]; then
            echo "==> Successfully created $DMG_FINAL_PATH"
        else
            echo "==> Warning: DMG creation failed for ${TARGET_ARCH}."
        fi
    fi
done
