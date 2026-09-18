#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_OUT="${BUILD_OUT:-${ROOT_DIR}/out-beryllium}"
TEMPLATE_DIR="${ANYKERNEL_TEMPLATE:-${ROOT_DIR}/kali-nethunter-kernel-builder/anykernel3}"
OUTPUT_DIR="${ANYKERNEL_OUTPUT:-${ROOT_DIR}/out-anykernel}"
MODULE_DEST="${MODULE_DEST:-system_root}"
MODULE_MODE=auto

usage() {
    cat <<'EOF'
Usage: ./make-anykernel.sh [options]

Membuat ZIP AnyKernel3 untuk Xiaomi Poco F1 (beryllium).

Options:
  --no-modules          Jangan masukkan kernel modules ke ZIP
  --with-modules        Wajib masukkan modules; gagal jika .ko belum dibuild
  --module-dest PATH    Target modules di device (default: system_root)
  -h, --help            Tampilkan bantuan

Environment:
  BUILD_OUT              Output kernel (default: ./out-beryllium)
  ANYKERNEL_TEMPLATE     Template AnyKernel3 lokal
  ANYKERNEL_OUTPUT       Direktori output ZIP (default: ./out-anykernel)
  ZIP_NAME               Nama ZIP hasil build

Contoh:
  ./make-anykernel.sh
  ./make-anykernel.sh --no-modules
  MODULE_DEST=system ./make-anykernel.sh --with-modules
EOF
}

while (($#)); do
    case "$1" in
        --no-modules)
            MODULE_MODE=none
            ;;
        --with-modules)
            MODULE_MODE=required
            ;;
        --module-dest)
            (($# >= 2)) || { echo "Error: --module-dest membutuhkan PATH." >&2; exit 1; }
            MODULE_DEST="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: opsi tidak dikenal: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

for tool in cp date find make unzip zip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: command tidak ditemukan: $tool" >&2
        exit 1
    fi
done

if [[ "$BUILD_OUT" != /* ]]; then
    BUILD_OUT="${ROOT_DIR}/${BUILD_OUT}"
fi
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}"
fi
if [[ "$TEMPLATE_DIR" != /* ]]; then
    TEMPLATE_DIR="${ROOT_DIR}/${TEMPLATE_DIR}"
fi

IMAGE="${BUILD_OUT}/arch/arm64/boot/Image.gz-dtb"
if [[ ! -f "$IMAGE" ]]; then
    echo "Error: Image.gz-dtb tidak ditemukan:" >&2
    echo "  $IMAGE" >&2
    echo "Build kernel dulu dengan ./build-beryllium.sh atau gunakan --kernel-only." >&2
    exit 1
fi

if [[ ! -f "${TEMPLATE_DIR}/META-INF/com/google/android/update-binary" || \
      ! -f "${TEMPLATE_DIR}/tools/ak3-core.sh" ]]; then
    echo "Error: template AnyKernel3 tidak lengkap: $TEMPLATE_DIR" >&2
    exit 1
fi

case "$MODULE_DEST" in
    ""|/*|*..*)
        echo "Error: --module-dest harus berupa path relatif tanpa '..': $MODULE_DEST" >&2
        exit 1
        ;;
esac

if [[ -z "${ZIP_NAME:-}" ]]; then
    ZIP_NAME="AnyKernel3-beryllium-$(date +%Y%m%d-%H%M).zip"
fi
[[ "$ZIP_NAME" == *.zip ]] || ZIP_NAME="${ZIP_NAME}.zip"

STAGE_DIR="${OUTPUT_DIR}/beryllium-staging"
ZIP_PATH="${OUTPUT_DIR}/${ZIP_NAME}"

module_objects=0
if find "$BUILD_OUT" -type f -name '*.ko' -print -quit | grep -q .; then
    module_objects=1
fi

case "$MODULE_MODE" in
    none)
        PACKAGE_MODULES=0
        ;;
    required)
        if (( ! module_objects )); then
            echo "Error: --with-modules dipilih, tetapi tidak ada file .ko di $BUILD_OUT" >&2
            echo "Build ulang dengan ./build-beryllium.sh tanpa --kernel-only." >&2
            exit 1
        fi
        PACKAGE_MODULES=1
        ;;
    auto)
        PACKAGE_MODULES="$module_objects"
        ;;
esac

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -a "${TEMPLATE_DIR}/." "$STAGE_DIR/"

cp -f "$IMAGE" "$STAGE_DIR/Image.gz-dtb"

if (( PACKAGE_MODULES )); then
    module_install_root="${STAGE_DIR}/modules/${MODULE_DEST}"
    echo "==> Memasang modules ke /${MODULE_DEST}/lib/modules ..."
    mkdir -p "$module_install_root"
    make -C "$ROOT_DIR" \
        O="$BUILD_OUT" \
        ARCH=arm64 \
        INSTALL_MOD_PATH="$module_install_root" \
        INSTALL_MOD_STRIP=1 \
        modules_install

    rm -f "${module_install_root}/lib/modules/"*/source
    rm -f "${module_install_root}/lib/modules/"*/build

    if ! find "${module_install_root}/lib/modules" -type f -name '*.ko' -print -quit | grep -q .; then
        echo "Error: modules_install tidak menghasilkan file .ko." >&2
        exit 1
    fi
fi

# The local NetHunter AnyKernel updater is intentionally used here. It pushes
# modules from /modules/system_root (or the selected MODULE_DEST) directly to
# the real filesystem, so do.systemless must remain disabled.
cat > "${STAGE_DIR}/anykernel.sh" <<EOF
#!/sbin/sh

# AnyKernel3 setup for Xiaomi Poco F1 (beryllium)
properties() { '
kernel.string=NetHunter Kernel for Xiaomi Poco F1
do.devicecheck=1
do.modules=${PACKAGE_MODULES}
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=beryllium
device.name2=POCOF1
device.name3=Pocophone F1
device.name4=POCO F1
device.name5=Poco F1
supported.versions=
supported.patchlevels=
'; }

# Poco F1 is an A-only device.
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=0;
ramdisk_compression=auto;

. tools/ak3-core.sh;

ui_print " " "Installing NetHunter kernel for beryllium...";
dump_boot;
write_boot;
EOF
chmod 0755 "${STAGE_DIR}/anykernel.sh"

if [[ -e "$ZIP_PATH" ]]; then
    rm -f "$ZIP_PATH"
fi

echo "==> Membuat ZIP AnyKernel3 ..."
(
    cd "$STAGE_DIR"
    zip -r9 "$ZIP_PATH" * -x '.git/*' 'README.md' '*placeholder*' >/dev/null
)

unzip -t "$ZIP_PATH" >/dev/null

echo
echo "AnyKernel3 ZIP selesai:"
echo "  $ZIP_PATH"
echo "Image:"
echo "  Image.gz-dtb"
if (( PACKAGE_MODULES )); then
    echo "Modules: /modules/${MODULE_DEST}/lib/modules"
else
    echo "Modules: tidak dimasukkan"
fi
echo "Staging:"
echo "  $STAGE_DIR"
