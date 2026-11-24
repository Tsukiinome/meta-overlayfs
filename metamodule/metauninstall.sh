#!/system/bin/sh
############################################
# meta-overlayfs metauninstall.sh
# Module uninstallation hook for ext4 image cleanup
############################################

# The module id arrives as $MODULE_ID on some KernelSU versions and as $1 on others.
MID="${MODULE_ID:-$1}"

if [ -z "$MID" ]; then
    echo "! Error: MODULE_ID not provided"
    exit 1
fi

# Never let a weird id escape the image directory.
case "$MID" in
    */* | . | .. | .*)
        echo "! Refusing unsafe module id: $MID"
        exit 1
        ;;
esac

if [ -n "$META_MODDIR" ]; then
    : # already provided by the caller
elif [ -d /data/adb/metamodule ]; then
    META_MODDIR="/data/adb/metamodule"
else
    META_MODDIR="/data/adb/modules/meta-overlayfs"
fi
export META_MODDIR
if [ -f "$META_MODDIR/common.sh" ]; then
    . "$META_MODDIR/common.sh"
else
    IMG_FILE="$META_MODDIR/modules.img"
    MNT_DIR="$META_MODDIR/mnt"
    mo_mount_image() {
        mkdir -p "$MNT_DIR"
        mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR"
    }
fi

echo "- Cleaning up module content from image: $MID"

# Mount the image if needed so the content really gets removed (the old script
# skipped the cleanup when the image happened not to be mounted).
if ! mountpoint -q "$MNT_DIR" 2>/dev/null; then
    mo_mount_image 2>/dev/null || {
        echo "! Warning: image could not be mounted, skipping cleanup"
        exit 0
    }
fi

MOD_IMG_DIR="$MNT_DIR/$MID"
if [ -d "$MOD_IMG_DIR" ]; then
    echo "  Removing $MOD_IMG_DIR"
    rm -rf "$MOD_IMG_DIR" || {
        echo "! Warning: Failed to remove module content from image"
    }
    echo "- Module content removed from image"
else
    echo "- No module content found in image, skipping"
fi

exit 0
