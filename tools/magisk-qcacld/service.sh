#!/system/bin/sh

MODDIR=${0%/*}
MODULE_NAME=wlan
MODULE_DIR="$MODDIR/system/lib/modules"
MODULES_LOAD="$MODULE_DIR/modules.load"

MODULE_PATH=""
for candidate in \
    "$MODULE_DIR/${MODULE_NAME}.ko" \
    "$MODULE_DIR/kernel/drivers/staging/qcacld-3.0/${MODULE_NAME}.ko"; do
    [ -s "$candidate" ] || continue
    MODULE_PATH="$candidate"
    break
done

log_msg() {
    log -t qcacld-autoload "$*" 2>/dev/null || echo "qcacld-autoload: $*" > /dev/kmsg
}

module_loaded() {
    grep -q "^${MODULE_NAME} " /proc/modules 2>/dev/null ||
        [ -d "/sys/module/${MODULE_NAME}" ]
}

module_loaded && exit 0

if [ ! -s "$MODULE_PATH" ]; then
    log_msg "module tidak ditemukan: $MODULE_PATH"
    exit 1
fi

if [ ! -s "$MODULES_LOAD" ]; then
    log_msg "modules.load tidak ditemukan: $MODULES_LOAD"
    exit 1
fi

if command -v insmod >/dev/null 2>&1 && insmod "$MODULE_PATH" 2>/dev/null; then
    log_msg "wlan.ko berhasil dimuat dari Magisk module"
    exit 0
fi

for modprobe in /vendor/bin/modprobe /system/bin/modprobe /system/xbin/modprobe; do
    [ -x "$modprobe" ] || continue
    for module_dir in /system/lib/modules /vendor/lib/modules /lib/modules; do
        [ -f "$module_dir/modules.dep" ] || continue
        if "$modprobe" -a -d "$module_dir" "$MODULE_NAME" 2>/dev/null; then
            log_msg "wlan berhasil dimuat melalui modprobe dari $module_dir"
            exit 0
        fi
    done
done

log_msg "gagal memuat $MODULE_NAME"
exit 1
