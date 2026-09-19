#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_OUT="${BUILD_OUT:-${ROOT_DIR}/out-beryllium}"
OUTPUT_DIR="${MAGISK_OUTPUT:-${ROOT_DIR}/out-magisk}"
AARCH64_STRIP="${AARCH64_STRIP:-/usr/bin/aarch64-linux-gnu-strip}"

for tool in cp date find make mkdir rm unzip zip; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Error: command tidak ditemukan: $tool" >&2
        exit 1
    }
done
[[ -x "$AARCH64_STRIP" ]] || {
    echo "Error: AArch64 strip tidak ditemukan: $AARCH64_STRIP" >&2
    exit 1
}

[[ "$BUILD_OUT" = /* ]] || BUILD_OUT="${ROOT_DIR}/${BUILD_OUT}"
[[ "$OUTPUT_DIR" = /* ]] || OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}"

MODULE_SOURCE="${BUILD_OUT}/drivers/staging/qcacld-3.0/wlan.ko"
MODULE_TEMPLATE="${ROOT_DIR}/tools/magisk-qcacld"
[[ -s "$MODULE_SOURCE" ]] || {
    echo "Error: wlan.ko tidak ditemukan: $MODULE_SOURCE" >&2
    echo "Build kernel terlebih dahulu dengan ./build-beryllium.sh." >&2
    exit 1
}

for required in module.prop service.sh; do
    [[ -f "${MODULE_TEMPLATE}/${required}" ]] || {
        echo "Error: file module tidak ditemukan: ${MODULE_TEMPLATE}/${required}" >&2
        exit 1
    }
done

MODULE_ID=qcacld_autoload
STAGE_DIR="${OUTPUT_DIR}/${MODULE_ID}-staging"
KERNEL_MODULE_STAGE="${OUTPUT_DIR}/${MODULE_ID}-kernel-staging"
ZIP_NAME="${ZIP_NAME:-${MODULE_ID}-$(date +%Y%m%d-%H%M).zip}"
[[ "$ZIP_NAME" = *.zip ]] || ZIP_NAME="${ZIP_NAME}.zip"
ZIP_PATH="${OUTPUT_DIR}/${ZIP_NAME}"

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGE_DIR"
rm -rf "$KERNEL_MODULE_STAGE"
mkdir -p "$STAGE_DIR"
cp -f "${MODULE_TEMPLATE}/module.prop" "$STAGE_DIR/module.prop"
cp -f "${MODULE_TEMPLATE}/service.sh" "$STAGE_DIR/service.sh"
mkdir -p "$STAGE_DIR/system/lib/modules"
# Use the kernel's modules_install output so every .ko and its dependency
# metadata (modules.dep, modules.alias, modules.order, ...) is preserved.
mkdir -p "$KERNEL_MODULE_STAGE"
if ! make -C "$ROOT_DIR" \
        O="$BUILD_OUT" \
        ARCH=arm64 \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}" \
        STRIP="$AARCH64_STRIP" \
        INSTALL_MOD_PATH="$KERNEL_MODULE_STAGE" \
        INSTALL_MOD_STRIP=1 \
        modules_install; then
    echo "Warning: depmod kernel 4.9 mengembalikan status non-zero; memvalidasi hasil install." >&2
fi

MODULE_RELEASE_DIR="$(find "$KERNEL_MODULE_STAGE/lib/modules" \
    -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$MODULE_RELEASE_DIR" ]] || {
    echo "Error: direktori hasil modules_install tidak ditemukan." >&2
    exit 1
}
cp -a "$MODULE_RELEASE_DIR/." "$STAGE_DIR/system/lib/modules/"
rm -f "$STAGE_DIR/system/lib/modules/source" \
    "$STAGE_DIR/system/lib/modules/build"

MODULE_COUNT="$(find "$STAGE_DIR/system/lib/modules" -type f -name '*.ko' | wc -l)"
[[ "$MODULE_COUNT" -gt 0 ]] || {
    echo "Error: tidak ada .ko di module Magisk." >&2
    exit 1
}
printf '%s\n' wlan > "$STAGE_DIR/system/lib/modules/modules.load"
chmod 0644 "$STAGE_DIR/module.prop" \
    "$STAGE_DIR/system/lib/modules/modules.load"
find "$STAGE_DIR/system/lib/modules" -type f -name '*.ko' -exec chmod 0644 {} +
chmod 0755 "$STAGE_DIR/service.sh"
test -s "$STAGE_DIR/system/lib/modules/kernel/drivers/staging/qcacld-3.0/wlan.ko"
grep -q '^id=qcacld_autoload$' "$STAGE_DIR/module.prop" || exit 1

rm -f "$ZIP_PATH"
(
    cd "$STAGE_DIR"
    zip -q -r9 "$ZIP_PATH" module.prop service.sh system
)
unzip -t "$ZIP_PATH" >/dev/null
rm -rf "$KERNEL_MODULE_STAGE"
echo "Magisk module selesai dibuat: $ZIP_PATH"
echo "Kernel modules included: $MODULE_COUNT"
