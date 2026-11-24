#!/system/bin/sh
# meta-overlayfs post-mount.sh
# Hide the ext4 sysfs node of the modules image (KernelSU feature, best effort).

MODDIR="${0%/*}"
META_MODDIR="$MODDIR"
. "$MODDIR/common.sh"

# Nothing mounted (safe mode, or the image failed to mount): nothing to hide.
mountpoint -q "$MNT_DIR" 2>/dev/null || exit 0

KSUD=$(command -v ksud 2>/dev/null)
[ -n "$KSUD" ] || { [ -x /data/adb/ksud ] && KSUD=/data/adb/ksud; }
if [ -z "$KSUD" ]; then
    mo_log "ksud not found, skipping nuke-ext4-sysfs"
    exit 0
fi

if "$KSUD" kernel nuke-ext4-sysfs "$MNT_DIR" >/dev/null 2>&1; then
    mo_log "nuke-ext4-sysfs applied"
else
    mo_log "nuke-ext4-sysfs not supported by this KernelSU build (harmless)"
fi
exit 0
