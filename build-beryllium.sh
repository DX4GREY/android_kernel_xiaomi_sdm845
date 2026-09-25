#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${ROOT_DIR}/../setup.sh"
NETHUNTER_CONFIG="${NETHUNTER_CONFIG:-${ROOT_DIR}/nethunter.config}"

BUILD_TARGETS=(Image.gz Image.gz-dtb modules)
NO_CLEAN=0
NO_SETUP=0
MAKE_OPTIONS=()

while (($#)); do
    case "$1" in
        --kernel-only)
            BUILD_TARGETS=(Image.gz-dtb)
            ;;
        --no-clean)
            NO_CLEAN=1
            ;;
        --no-setup)
            NO_SETUP=1
            ;;
        --make-option)
            if (($# < 2)); then
                echo "Error: --make-option membutuhkan satu nilai" >&2
                echo "Gunakan: $0 --help" >&2
                exit 1
            fi
            MAKE_OPTIONS+=("$2")
            shift 2
            continue
            ;;
        --make-option=*)
            MAKE_OPTIONS+=("${1#*=}")
            ;;
        -h|--help)
            echo "Usage: $0 [--kernel-only] [--no-clean] [--no-setup] [--make-option OPT]"
            echo
            echo "  tanpa opsi          Build Image.gz, Image.gz-dtb, dan modules"
            echo "  --kernel-only       Build Image.gz-dtb saja"
            echo "  --no-clean          Pertahankan output build sebelumnya"
            echo "  --no-setup          Jangan source ../setup.sh; gunakan environment aktif"
            echo "  --make-option OPT   Tambahkan opsi ekstra ke make (bisa diulang)"
            exit 0
            ;;
        *)
            echo "Error: opsi tidak dikenal: $1" >&2
            echo "Gunakan: $0 --help" >&2
            exit 1
            ;;
    esac
    shift
done

BUILD_OUT="${BUILD_OUT:-${ROOT_DIR}/out-beryllium}"
JOBS="${JOBS:-$(nproc)}"
MIN_FREE_GB="${MIN_FREE_GB:-0}"
KCFLAGS="${KCFLAGS:--Wno-error=enum-conversion -Wno-error=self-assign -Wno-error=varargs}"

# Toolchain overrides. The default paths match this workspace.
AARCH64_LD="${AARCH64_LD:-/usr/bin/aarch64-linux-gnu-ld.bfd}"
ARM32_PREFIX="${ARM32_PREFIX:-/usr/bin/arm-linux-gnueabi-}"
AARCH64_OBJCOPY="${AARCH64_OBJCOPY:-${AARCH64_LD%ld.bfd}objcopy}"

if [[ "${BUILD_OUT}" != /* ]]; then
    BUILD_OUT="${ROOT_DIR}/${BUILD_OUT}"
fi

if (( ! NO_SETUP )) && [[ ! -f "${SETUP_SCRIPT}" ]]; then
    echo "Error: setup script tidak ditemukan: ${SETUP_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${NETHUNTER_CONFIG}" ]]; then
    echo "Error: NetHunter config tidak ditemukan: ${NETHUNTER_CONFIG}" >&2
    exit 1
fi

if [[ ! -x "${AARCH64_LD}" ]]; then
    echo "Error: AArch64 linker tidak ditemukan: ${AARCH64_LD}" >&2
    exit 1
fi

if [[ ! -x "${AARCH64_OBJCOPY}" ]]; then
    echo "Error: AArch64 objcopy tidak ditemukan: ${AARCH64_OBJCOPY}" >&2
    exit 1
fi

for tool in nproc awk df make; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "Error: command tidak ditemukan: ${tool}" >&2
        exit 1
    fi
done

if [[ ! -x "${ARM32_PREFIX}ld.bfd" ]]; then
    echo "Error: ARM32 linker tidak ditemukan: ${ARM32_PREFIX}ld.bfd" >&2
    exit 1
fi

# This old kernel tree must be built out-of-tree. Do not run make mrproper
# automatically because it can remove tracked generated files in the source.
if [[ -f "${ROOT_DIR}/.config" || -d "${ROOT_DIR}/include/config" ]]; then
    echo "Error: source tree tidak bersih untuk out-of-tree build." >&2
    echo "Hapus artefak in-tree secara manual setelah memastikan tidak ada perubahan penting." >&2
    exit 1
fi

available_kb="$(df -Pk "${ROOT_DIR}" | awk 'NR == 2 { print $4 }')"
required_kb=$((MIN_FREE_GB * 1024 * 1024))

if [[ -z "${available_kb}" || "${available_kb}" -lt "${required_kb}" ]]; then
    available_gb=$((available_kb / 1024 / 1024))
    echo "Error: ruang kosong tidak cukup: ${available_gb} GiB tersedia, minimal ${MIN_FREE_GB} GiB diperlukan." >&2
    exit 1
fi

echo "==> Memuat toolchain..."
if (( NO_SETUP )); then
    echo "==> setup.sh dilewati; memakai environment yang sedang aktif"
else
    # shellcheck disable=SC1090
    source "${SETUP_SCRIPT}"
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "Error: clang tidak ditemukan setelah setup toolchain dimuat." >&2
    exit 1
fi

export ARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"

MAKE_ARGS=(
    "O=${BUILD_OUT}"
    "ARCH=${ARCH}"
    "CC=${CC:-clang}"
    "LLVM=1"
    "LLVM_IAS=1"
    "LD=${AARCH64_LD}"
    "OBJCOPY=${AARCH64_OBJCOPY}"
    "CROSS_COMPILE=${CROSS_COMPILE}"
    "CROSS_COMPILE_ARM32=${CROSS_COMPILE_ARM32}"
    "CLANG_PREFIX32=--prefix=${ARM32_PREFIX}"
    "KCFLAGS=${KCFLAGS}"
)

echo "==> Output: ${BUILD_OUT}"
echo "==> Parallel jobs: ${JOBS}"
echo "==> Target build: ${BUILD_TARGETS[*]}"
if ((${#MAKE_OPTIONS[@]} > 0)); then
    echo "==> Opsi make tambahan: ${MAKE_OPTIONS[*]}"
fi
if (( NO_CLEAN )); then
    echo "==> Clean dilewati; output build sebelumnya dipertahankan"
else
    echo "==> Tidak ada clean otomatis; build bersifat incremental"
fi
echo "==> Menyiapkan konfigurasi Beryllium..."

make -C "${ROOT_DIR}" "${MAKE_ARGS[@]}" "${MAKE_OPTIONS[@]}" vendor/xiaomi/mi845_defconfig

"${ROOT_DIR}/scripts/kconfig/merge_config.sh" \
    -m -r \
    -O "${BUILD_OUT}" \
    "${BUILD_OUT}/.config" \
    "${ROOT_DIR}/arch/arm64/configs/vendor/xiaomi/beryllium.config" \
    "${NETHUNTER_CONFIG}"

make -C "${ROOT_DIR}" "${MAKE_ARGS[@]}" "${MAKE_OPTIONS[@]}" olddefconfig

if ! grep -q '^CONFIG_QCA_CLD_WLAN=m$' "${BUILD_OUT}/.config"; then
    echo "Error: qcacld-3.0 harus dibangun sebagai CONFIG_QCA_CLD_WLAN=m." >&2
    exit 1
fi

echo "==> Memulai build kernel..."
make -C "${ROOT_DIR}" \
    -j"${JOBS}" \
    "${MAKE_ARGS[@]}" \
    "${MAKE_OPTIONS[@]}" \
    "${BUILD_TARGETS[@]}"

if [[ " ${BUILD_TARGETS[*]} " == *" modules "* ]] && \
   [[ ! -s "${BUILD_OUT}/drivers/staging/qcacld-3.0/wlan.ko" ]]; then
    echo "Error: build tidak menghasilkan qcacld-3.0 module wlan.ko." >&2
    exit 1
fi

echo
echo "Build selesai. Artefak:"
echo "  ${BUILD_OUT}/arch/arm64/boot/Image.gz-dtb"
echo "  ${BUILD_OUT}/arch/arm64/boot/Image.gz"
echo "  ${BUILD_OUT}/arch/arm64/boot/dts/qcom/"
