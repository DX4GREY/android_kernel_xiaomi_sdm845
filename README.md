# NetHunter Kernel — Xiaomi POCO F1 (Beryllium)

Kernel Linux 4.9 untuk Xiaomi POCO F1/Beryllium berbasis Snapdragon 845 dengan dukungan NetHunter, monitor mode, frame injection, dan `qcacld-3.0` sebagai kernel module.

## Fitur

- Backport NetHunter dari [Loukious/nethunter_kernel_oneplus_sdm845](https://github.com/Loukious/nethunter_kernel_oneplus_sdm845/commit/809befa8b860eaad8f2bec9418b98fba2adba28e).
- Monitor mode dan frame injection pada driver Qualcomm WLAN.
- Teardown monitor-vdev yang diserialisasi untuk menghindari firmware assertion saat monitor mode dihentikan.
- `qcacld-3.0` dibangun sebagai `wlan.ko`, bukan built-in kernel.
- `wlan.ko` dimuat otomatis melalui `modules.load` pada paket AnyKernel.
- Wrapper `airmon-ng` yang me-reset module `wlan` setelah `airmon-ng stop wlan0`.
- GitHub Actions untuk build kernel dan paket AnyKernel3.

## Toolchain

Build menggunakan [DX4GREY Cosmic Clang](https://gitlab.com/DX4GREY/cosmic-clang/).

Workflow CI memakai commit toolchain yang dipin di `.github/workflows/build-beryllium.yml`.

Untuk build lokal, toolchain default yang dipakai script adalah:

```text
../toolchains/cosmic-clang-master
```

## Persyaratan host

Ubuntu/Debian disarankan. Paket minimum:

```sh
sudo apt install bc bison device-tree-compiler flex libelf-dev \
    libncurses-dev libssl-dev rsync unzip zip
```

Pastikan toolchain memiliki `clang`, linker/objcopy/strip AArch64, dan linker ARM32 `arm-linux-gnueabi-ld.bfd`.

## Build kernel

Build dilakukan out-of-tree ke `out-beryllium`.

```sh
export TOOLCHAIN=/path/to/cosmic-clang-master
export PATH="$TOOLCHAIN/bin:$PATH"
export AARCH64_LD="$TOOLCHAIN/bin/aarch64-linux-gnu-ld.bfd"
export AARCH64_OBJCOPY="$TOOLCHAIN/bin/aarch64-linux-gnu-objcopy"
export ARM32_PREFIX="$TOOLCHAIN/bin/arm-linux-gnueabi-"
export CC=clang

./build-beryllium.sh --no-setup
```

Opsi:

```text
--kernel-only    hanya membuat Image.gz-dtb
--no-clean       mempertahankan output build sebelumnya
--no-setup       tidak menjalankan ../setup.sh
```

Build akan gagal jika konfigurasi tidak memenuhi:

```text
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODULE_FORCE_UNLOAD=y
CONFIG_QCA_CLD_WLAN=m
```

Artefak utama:

```text
out-beryllium/arch/arm64/boot/Image.gz-dtb
out-beryllium/drivers/staging/qcacld-3.0/wlan.ko
```

Jika script menolak source tree karena artefak in-tree lama, hapus hanya artefak generated berikut setelah memastikan tidak ada pekerjaan penting di dalamnya:

```sh
rm -rf include/config .config
```

## Membuat paket AnyKernel3

```sh
export AARCH64_STRIP="$TOOLCHAIN/bin/aarch64-linux-gnu-strip"
./make-anykernel.sh --with-modules
```

ZIP dibuat di `out-anykernel/AnyKernel3-beryllium-*.zip` dan berisi `Image.gz-dtb`, semua module hasil `modules_install`, `modules.load`, serta `tools/airmon-ng-qcacld`.

Default lokasi module adalah `system_root`, yang dipasang sebagai `/system/lib/modules` oleh installer NetHunter. Jika ROM mengharuskan module vendor:

```sh
MODULE_DEST=vendor ./make-anykernel.sh --with-modules
```

## Autoload `wlan.ko`

`make-anykernel.sh` membuat dua daftar load:

```text
lib/modules/modules.load
lib/modules/<kernel-release>/modules.load
```

Keduanya memuat module `wlan`. Android init/modprobe pada ROM yang mendukung loadable kernel modules akan membaca daftar tersebut saat boot.

Referensi mekanisme Android: [AOSP — Loadable kernel modules](https://source.android.com/docs/core/architecture/kernel/loadable-kernel-modules).

Verifikasi setelah boot:

```sh
cat /system/lib/modules/modules.load
cat /proc/modules | grep '^wlan[[:space:] ]'
```

Jika `wlan` belum ter-load dan ROM tidak menjalankan `modprobe -a` saat boot, muat manual untuk pengujian:

```sh
modprobe wlan
```

## Wrapper `airmon-ng`

Wrapper berada di `tools/airmon-ng-qcacld`. AnyKernel memasangnya ke rootfs NetHunter `/data/local/nhsystem/kalifs`; ketika masuk ke chroot Kali, lokasi yang sama terlihat sebagai `/usr/sbin/airmon-ng` atau `/usr/bin/airmon-ng`.

Wrapper dijalankan dari dalam chroot Kali, bukan dari shell Android biasa. Operasi unload/load tetap memengaruhi kernel Android yang sama dan membutuhkan root.

Binary asli dibackup sebagai `airmon-ng.real`, lalu wrapper dipasang di lokasi binary asli. Jika binary tidak ditemukan saat flashing, wrapper tetap tersedia di dalam ZIP dan bisa dipasang manual.

Contoh pemasangan di NetHunter rootfs:

```sh
# Jika AnyKernel tidak menemukan binary saat flashing, pasang manual:
cp tools/airmon-ng-qcacld /data/local/nhsystem/kalifs/usr/sbin/airmon-ng
chmod 0755 /data/local/nhsystem/kalifs/usr/sbin/airmon-ng
export AIRMONG_REAL=/data/local/nhsystem/kalifs/usr/sbin/airmon-ng.real
airmon-ng stop wlan0
```

Saat `stop wlan0` dijalankan, wrapper:

1. menjalankan `airmon-ng` asli di background;
2. menunggu maksimal 5 detik;
3. menghentikan proses jika teardown macet;
4. menurunkan interface `wlan0`;
5. menjalankan `modprobe -r wlan` atau `rmmod wlan`;
6. menunggu module benar-benar hilang;
7. menjalankan `modprobe wlan` atau `insmod`;
8. memastikan module kembali muncul di `/sys/module/wlan`.

Konfigurasi opsional:

```sh
export AIRMONG_REAL=/path/ke/airmon-ng-asli
export QCACLD_STOP_TIMEOUT=5
export QCACLD_RELOAD_WAIT=10
export QCACLD_MODULE=wlan
export QCACLD_INTERFACE=wlan0
```

Wrapper membutuhkan akses root serta `modprobe`, atau kombinasi `rmmod` dan `insmod`.

## Pengujian monitor mode

```sh
airmon-ng check kill
airmon-ng start wlan0
iw dev
aireplay-ng --test wlan0mon
airmon-ng stop wlan0
lsmod | grep '^wlan[[:space:] ]'
```

Sesudah stop, cek apakah terminal kembali normal dan interface managed muncul kembali:

```sh
iw dev
ip link show wlan0
dmesg | tail -n 100
```

## Header Debian

Untuk membuat paket header ARM64:

```sh
./make-linux-headers-deb.sh
```

Output berada di `out-headers/`.

## GitHub Actions

Workflow berada di `.github/workflows/build-beryllium.yml`. Workflow akan mengambil Cosmic Clang pada commit yang dipin, membuat image dan module, memastikan `CONFIG_QCA_CLD_WLAN=m`, memeriksa `wlan.ko` dan `modules.load`, lalu mengunggah ZIP AnyKernel3.

## Debugging

Kumpulkan informasi berikut saat terjadi hang:

```sh
uname -a
cat /proc/modules
ls -l /sys/module/wlan
dmesg | grep -iE 'wlan|qcacld|wma|vdev|peer|assert|timeout|firmware'
```

Jangan melakukan `rmmod -f wlan` sebagai langkah pertama. Force unload dapat meninggalkan callback driver atau firmware dalam keadaan tidak konsisten. Wrapper menggunakan unload normal dan hanya melanjutkan setelah module benar-benar hilang.

## Catatan keamanan

Kernel dan module harus berasal dari build yang sama karena `CONFIG_MODVERSIONS` aktif. Selalu simpan boot image/kernel lama sebelum flashing dan siapkan cara restore jika perangkat gagal boot.
