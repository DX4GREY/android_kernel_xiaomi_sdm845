#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_OUT="${BUILD_OUT:-${ROOT_DIR}/out-beryllium}"
TEMPLATE_DIR="${ANYKERNEL_TEMPLATE:-${ROOT_DIR}/kali-nethunter-kernel-builder/anykernel3}"
OUTPUT_DIR="${ANYKERNEL_OUTPUT:-${ROOT_DIR}/out-anykernel}"

usage() {
    cat <<'EOF'
Usage: ./make-anykernel.sh [options]

Membuat ZIP AnyKernel3 untuk Xiaomi Poco F1 (beryllium).

Options:
  -h, --help            Tampilkan bantuan

Environment:
  BUILD_OUT              Output kernel (default: ./out-beryllium)
  ANYKERNEL_TEMPLATE     Template AnyKernel3 lokal
  ANYKERNEL_OUTPUT       Direktori output ZIP (default: ./out-anykernel)
  ZIP_NAME               Nama ZIP hasil build

Modul qcacld/Magisk dibuat terpisah dengan ./build-magisk-module.sh dan
tidak pernah dipasang atau dimasukkan ke ZIP AnyKernel.

Contoh:
  ./make-anykernel.sh
EOF
}

while (($#)); do
    case "$1" in
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

for tool in cp date unzip zip; do
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

if [[ -z "${ZIP_NAME:-}" ]]; then
    ZIP_NAME="AnyKernel3-beryllium-$(date +%Y%m%d-%H%M).zip"
fi
[[ "$ZIP_NAME" == *.zip ]] || ZIP_NAME="${ZIP_NAME}.zip"

STAGE_DIR="${OUTPUT_DIR}/beryllium-staging"
ZIP_PATH="${OUTPUT_DIR}/${ZIP_NAME}"

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -a "${TEMPLATE_DIR}/." "$STAGE_DIR/"

cp -f "$IMAGE" "$STAGE_DIR/Image.gz-dtb"

# Include the userspace stop wrapper alongside the kernel package. The
# generated AnyKernel installer also installs it into the fixed NetHunter
# rootfs when the original airmon-ng is found there.
SAFE_AIRMON="${ROOT_DIR}/tools/airmon-ng-qcacld"
if [[ ! -x "$SAFE_AIRMON" ]]; then
    echo "Error: wrapper airmon-ng tidak ditemukan atau tidak executable: $SAFE_AIRMON" >&2
    exit 1
fi
cp -f "$SAFE_AIRMON" "${STAGE_DIR}/tools/airmon-ng-qcacld"
chmod 0755 "${STAGE_DIR}/tools/airmon-ng-qcacld"

# The local NetHunter AnyKernel updater is intentionally used here. AnyKernel
# only handles the boot image and the userspace wrapper; Magisk is separate.
cat > "${STAGE_DIR}/anykernel.sh" <<EOF
#!/sbin/sh

# AnyKernel3 setup for Xiaomi Poco F1 (beryllium)
properties() { '
kernel.string=NetHunter Kernel for Xiaomi Poco F1
do.devicecheck=1
do.modules=0
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

install_nethunter_airmon_wrapper() {
    nh_root=/data/local/nhsystem/kalifs;
    for rel in usr/sbin/airmon-ng usr/bin/airmon-ng usr/local/sbin/airmon-ng usr/local/bin/airmon-ng; do
        original=\$nh_root/\$rel;
        backup=\${original}.real;
        test -f \$original || continue;

        if grep -q 'airmon-ng-qcacld' \$original 2>/dev/null; then
            ui_print " " "qcacld airmon-ng wrapper sudah terpasang: \$original";
            return 0;
        fi;

        if [ ! -f \$backup ]; then
            cp -fp \$original \$backup || return 1;
        fi;
        cp -fp tools/airmon-ng-qcacld \$original || return 1;
        chmod 0755 \$original;
        ui_print " " "Memasang qcacld airmon-ng wrapper: \$original";
        return 0;
    done;

    ui_print " " "airmon-ng NetHunter tidak ditemukan; wrapper tersedia di tools/airmon-ng-qcacld";
    return 0;
}

ui_print " " "Installing NetHunter kernel for beryllium...";
dump_boot;
install_nethunter_airmon_wrapper;
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
echo "Magisk module: tidak dimasukkan (gunakan ./build-magisk-module.sh)"
echo "Safe airmon-ng wrapper: tools/airmon-ng-qcacld"
echo "Staging:"
echo "  $STAGE_DIR"
