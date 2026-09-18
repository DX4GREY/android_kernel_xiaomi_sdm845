#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_OUT="${BUILD_OUT:-${ROOT_DIR}/out-beryllium}"
OUTPUT_DIR="${HEADERS_OUTPUT:-${ROOT_DIR}/out-headers}"
PACKAGE_NAME="${PACKAGE_NAME:-linux-headers-beryllium}"
DO_PREPARE=1
KEEP_STAGING="${KEEP_STAGING:-0}"

usage() {
    cat <<'EOF'
Usage: ./make-linux-headers-deb.sh [options]

Membuat paket Debian linux headers/build tree arm64 untuk kernel beryllium.
Paket ini ditujukan untuk build modul kernel eksternal di NetHunter chroot.

Options:
  --no-prepare    Jangan menjalankan `make modules_prepare`
  -h, --help      Tampilkan bantuan

Environment:
  BUILD_OUT       Output kernel (default: ./out-beryllium)
  HEADERS_OUTPUT  Direktori output .deb (default: ./out-headers)
  PACKAGE_NAME    Nama paket Debian (default: linux-headers-beryllium)
  KEEP_STAGING=1  Pertahankan staging directory untuk inspeksi

Contoh:
  ./make-linux-headers-deb.sh
  ./make-linux-headers-deb.sh --no-prepare
EOF
}

while (($#)); do
    case "$1" in
        --no-prepare)
            DO_PREPARE=0
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

for tool in awk chmod cp date dpkg-deb find grep install make mkdir rm rsync sed; do
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

CONFIG_FILE="${BUILD_OUT}/.config"
RELEASE_FILE="${BUILD_OUT}/include/config/kernel.release"
MODULE_SYMVERS="${BUILD_OUT}/Module.symvers"

for required in "$CONFIG_FILE" "$RELEASE_FILE" "$MODULE_SYMVERS"; do
    if [[ ! -f "$required" ]]; then
        echo "Error: file build tidak ditemukan: $required" >&2
        echo "Build kernel beryllium terlebih dahulu." >&2
        exit 1
    fi
done

if ! grep -q '^CONFIG_ARM64=y$' "$CONFIG_FILE"; then
    echo "Error: $CONFIG_FILE bukan konfigurasi ARM64 (CONFIG_ARM64=y tidak ditemukan)." >&2
    exit 1
fi
if ! grep -q '^CONFIG_64BIT=y$' "$CONFIG_FILE"; then
    echo "Error: konfigurasi tidak menunjukkan target 64-bit ARM64." >&2
    exit 1
fi

KERNEL_RELEASE="$(sed -n '1p' "$RELEASE_FILE")"
if [[ -z "$KERNEL_RELEASE" || "$KERNEL_RELEASE" == */* || "$KERNEL_RELEASE" == *[[:space:]]* ]]; then
    echo "Error: kernel release tidak valid: $KERNEL_RELEASE" >&2
    exit 1
fi

if [[ ! -d "${BUILD_OUT}/include/generated" || \
      ! -d "${BUILD_OUT}/include/config" || \
      ! -d "${BUILD_OUT}/arch/arm64/include/generated" ]]; then
    echo "Error: generated headers belum lengkap di $BUILD_OUT" >&2
    echo "Jalankan ulang tanpa --no-prepare." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="${OUTPUT_DIR}/.linux-headers-${KERNEL_RELEASE}-$$"
PKG_ROOT="${WORK_DIR}/package"
HEADER_DIR="${PKG_ROOT}/usr/src/linux-headers-${KERNEL_RELEASE}"
DEBIAN_DIR="${PKG_ROOT}/DEBIAN"
DEB_PATH="${OUTPUT_DIR}/${PACKAGE_NAME}_${KERNEL_RELEASE}_arm64.deb"

cleanup() {
    if [[ "$KEEP_STAGING" != 1 ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

rm -rf "$WORK_DIR"
mkdir -p "$HEADER_DIR" "$DEBIAN_DIR"

if (( DO_PREPARE )); then
    echo "==> Menyiapkan build tree ARM64..."
    make -C "$ROOT_DIR" \
        O="$BUILD_OUT" \
        ARCH=arm64 \
        LLVM=1 \
        LLVM_IAS=1 \
        HOSTCC="${HOSTCC:-cc}" \
        modules_prepare
fi

echo "==> Menyalin source tree kernel untuk ARM64..."
rsync -a \
    --exclude='.git/' \
    --exclude='.codex/' \
    --exclude='arch/' \
    --exclude='out-*/' \
    --exclude='out-anykernel/' \
    --exclude='out-headers/' \
    --exclude='kali-nethunter-kernel-builder/' \
    --exclude='*.deb' \
    --exclude='*.zip' \
    --exclude='*.o' \
    --exclude='*.a' \
    --exclude='*.ko' \
    --exclude='*.cmd' \
    --exclude='.tmp_versions/' \
    --exclude='build-beryllium.sh' \
    --exclude='make-anykernel.sh' \
    --exclude='make-linux-headers-deb.sh' \
    --exclude='nethunter.config' \
    "$ROOT_DIR/" "$HEADER_DIR/"

# Only arch/arm64 is copied. Other kernel architectures are intentionally not
# present in this package, so it cannot accidentally be used as a multi-arch
# header package in the beryllium chroot.
mkdir -p "${HEADER_DIR}/arch/arm64"
rsync -a \
    --exclude='*.o' \
    --exclude='*.a' \
    --exclude='*.ko' \
    --exclude='*.cmd' \
    "$ROOT_DIR/arch/arm64/" "${HEADER_DIR}/arch/arm64/"

echo "==> Menambahkan generated headers dan Module.symvers..."
mkdir -p "${HEADER_DIR}/include/config" \
    "${HEADER_DIR}/include/generated" \
    "${HEADER_DIR}/arch/arm64/include/generated"
rsync -a "${BUILD_OUT}/include/config/" "${HEADER_DIR}/include/config/"
rsync -a "${BUILD_OUT}/include/generated/" "${HEADER_DIR}/include/generated/"
rsync -a "${BUILD_OUT}/arch/arm64/include/generated/" \
    "${HEADER_DIR}/arch/arm64/include/generated/"
cp -f "$CONFIG_FILE" "${HEADER_DIR}/.config"
cp -f "$MODULE_SYMVERS" "${HEADER_DIR}/Module.symvers"

cat > "${HEADER_DIR}/README.beryllium-arm64" <<EOF
Kernel build headers for Xiaomi Poco F1 (beryllium)

Kernel release: ${KERNEL_RELEASE}
Architecture: arm64 only
Config: .config

External module example:
  make -C /usr/src/linux-headers-${KERNEL_RELEASE} M=\$PWD ARCH=arm64 modules
EOF

mkdir -p "${PKG_ROOT}/lib/modules/${KERNEL_RELEASE}"
ln -s "/usr/src/linux-headers-${KERNEL_RELEASE}" \
    "${PKG_ROOT}/lib/modules/${KERNEL_RELEASE}/build"
ln -s "/usr/src/linux-headers-${KERNEL_RELEASE}" \
    "${PKG_ROOT}/lib/modules/${KERNEL_RELEASE}/source"

if find "${HEADER_DIR}/arch" -mindepth 1 -maxdepth 1 -type d ! -name arm64 -print -quit | grep -q .; then
    echo "Error: ditemukan arsitektur selain arm64 di staging package." >&2
    exit 1
fi

if find "${HEADER_DIR}" -type f \( -name '*.o' -o -name '*.a' -o -name '*.ko' \) -print -quit | grep -q .; then
    echo "Error: artefak binary kernel ditemukan di header package." >&2
    exit 1
fi

cat > "${DEBIAN_DIR}/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${KERNEL_RELEASE}
Section: devel
Priority: optional
Architecture: arm64
Maintainer: NetHunter beryllium builder <root@localhost>
Depends: make, gcc, binutils
Description: Linux kernel build headers for Xiaomi Poco F1 beryllium
 ARM64-only kernel build tree for compiling external NetHunter modules.
EOF

cat > "${DEBIAN_DIR}/copyright" <<'EOF'
This package contains build headers and source files from the Linux kernel
tree used for Xiaomi Poco F1 (beryllium). Refer to the source tree LICENSES
and COPYING files for the applicable licenses.
EOF

chmod 0755 "${DEBIAN_DIR}"
chmod 0644 "${DEBIAN_DIR}/control" "${DEBIAN_DIR}/copyright"

rm -f "$DEB_PATH"
echo "==> Membuat paket Debian ARM64..."
dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DEB_PATH" >/dev/null

echo "==> Validasi metadata dan isi paket..."
dpkg-deb --info "$DEB_PATH" | sed -n '1,18p'
if dpkg-deb --contents "$DEB_PATH" | awk '{print $6}' | \
    grep -E '^\./usr/src/linux-headers-[^/]+/arch/(alpha|arc|arm/|avr32|blackfin|c6x|cris|frv|h8300|hexagon|ia64|m32r|m68k|metag|microblaze|mips|mn10300|nios2|openrisc|parisc|powerpc|s390|score|sh|sparc|tile|um|unicore32|x86|xtensa)(/|$)' >/dev/null; then
    echo "Error: paket memuat arsitektur selain arm64." >&2
    exit 1
fi

echo
echo "Linux headers ARM64 selesai:"
echo "  $DEB_PATH"
echo "  Release: $KERNEL_RELEASE"
echo "  Install di chroot: dpkg -i $(basename "$DEB_PATH")"
echo "  Build modul: make -C /usr/src/linux-headers-$KERNEL_RELEASE M=\$PWD ARCH=arm64 modules"
