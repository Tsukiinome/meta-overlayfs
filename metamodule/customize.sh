#!/system/bin/sh
# meta-overlayfs customize.sh (installer of the metamodule itself)

STATE_DIR="${META_STATE_DIR:-/data/adb/meta-overlayfs}"

ui_print "- Detecting device architecture..."

ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
[ -n "$ABI" ] || ABI="$ARCH"
[ -n "$ABI" ] || ABI=$(uname -m)
ui_print "- Detected ABI: $ABI"

case "$ABI" in
    arm64-v8a | arm64 | aarch64) ARCH_NAME="aarch64" ;;
    x86_64 | x64) ARCH_NAME="x86_64" ;;
    armeabi-v7a | armeabi | arm | armv7* | armv8l) ARCH_NAME="armv7" ;;
    x86 | i686) ARCH_NAME="x86" ;;
    *) abort "! Unsupported architecture: $ABI" ;;
esac

ARCH_BINARY="meta-overlayfs-$ARCH_NAME"
if [ ! -f "$MODPATH/$ARCH_BINARY" ]; then
    abort "! This zip has no binary for $ARCH_NAME ($ARCH_BINARY). Build it with build.sh and try again."
fi
ui_print "- Selected architecture: $ARCH_NAME"

ui_print "- Installing $ARCH_BINARY as meta-overlayfs"
mv "$MODPATH/$ARCH_BINARY" "$MODPATH/meta-overlayfs" || abort "! Failed to rename binary"
rm -f "$MODPATH"/meta-overlayfs-*
chmod 755 "$MODPATH/meta-overlayfs" || abort "! Failed to set permissions"
chmod 755 "$MODPATH"/*.sh 2>/dev/null
ui_print "- Architecture-specific binary installed successfully"

# The kernel must support overlayfs (informational only: it may be a lazy-loaded module).
if ! grep -qw overlay /proc/filesystems 2>/dev/null; then
    ui_print "! Warning: 'overlay' not listed in /proc/filesystems. The kernel may lack CONFIG_OVERLAY_FS."
fi

# Persistent state (survives updates): logs, anti-bootloop counters, options.
mkdir -p "$STATE_DIR"
[ -f "$STATE_DIR/max_fails" ] || echo 3 >"$STATE_DIR/max_fails"
[ -f "$STATE_DIR/stable_seconds" ] || echo 60 >"$STATE_DIR/stable_seconds"

# --- helpers (customize.sh runs before common.sh is available) ---------------
find_tool() {
    for _t in "$@"; do
        for _d in /system/bin /system/xbin /vendor/bin /data/adb/ksu/bin /data/adb/magisk; do
            if [ -x "$_d/$_t" ]; then
                echo "$_d/$_t"
                return 0
            fi
        done
        _p=$(command -v "$_t" 2>/dev/null)
        if [ -n "$_p" ] && [ -x "$_p" ]; then
            echo "$_p"
            return 0
        fi
    done
    return 1
}

fsck_image() {
    _fsck=$(find_tool e2fsck) || return 0
    "$_fsck" -p -f "$1" >/dev/null 2>&1
    [ $? -le 1 ] && return 0
    "$_fsck" -fy "$1" >/dev/null 2>&1
    [ $? -le 2 ]
}

# --- ext4 image for module content ------------------------------------------
IMG_FILE="$MODPATH/modules.img"
EXISTING_IMG="/data/adb/modules/$MODID/modules.img"

IMG_SIZE_MB=$(cat "$STATE_DIR/image_size_mb" 2>/dev/null)
case "$IMG_SIZE_MB" in '' | *[!0-9]*) IMG_SIZE_MB=2048 ;; esac
[ "$IMG_SIZE_MB" -lt 64 ] && IMG_SIZE_MB=2048

if [ -f "$EXISTING_IMG" ]; then
    ui_print "- Reusing modules image from previous install"
    # The old image is mounted read-write and has no journal: flush before copying.
    sync
    "$MODPATH/meta-overlayfs" xcp "$EXISTING_IMG" "$IMG_FILE" ||
        abort "! Failed to copy existing modules image"
    ui_print "- Checking the copied image"
    if ! fsck_image "$IMG_FILE"; then
        rm -f "$IMG_FILE"
        abort "! The existing modules image is damaged and could not be repaired. Remove $EXISTING_IMG and reinstall your modules."
    fi
else
    ui_print "- Creating ${IMG_SIZE_MB}MB ext4 image for module storage"

    MKE2FS=$(find_tool mke2fs mkfs.ext4) || abort "! mke2fs not found on this device"

    # Sparse file (logical size only, ~0 bytes of real storage)
    if ! truncate -s "${IMG_SIZE_MB}M" "$IMG_FILE" 2>/dev/null; then
        dd if=/dev/zero of="$IMG_FILE" bs=1048576 count=0 seek="$IMG_SIZE_MB" 2>/dev/null ||
            abort "! Failed to create image file"
    fi

    # No journal: avoids creating a jbd2 sysfs node.
    "$MKE2FS" -t ext4 -O ^has_journal -F "$IMG_FILE" >/dev/null 2>&1 ||
        abort "! Failed to format ext4 image"

    ui_print "- Image created successfully (sparse file)"
fi

ui_print "- Installation complete"
ui_print "! REBOOT now, before installing or updating any other module:"
ui_print "  modules installed before the reboot are stored in the old image."
