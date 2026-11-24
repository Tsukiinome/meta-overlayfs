#!/system/bin/sh
############################################
# meta-overlayfs metainstall.sh
# Module installation hook for ext4 image support.
# NOTE: this file is SOURCED by the installer, so it must not call `exit`.
############################################

# Locate the metamodule (KernelSU symlinks /data/adb/metamodule on recent versions).
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
    # Metamodule older than 1.4.0 still active (not rebooted yet): minimal fallback.
    IMG_FILE="$META_MODDIR/modules.img"
    MNT_DIR="$META_MODDIR/mnt"
    PARTITIONS="system vendor product system_ext odm oem"
    mo_mount_image() {
        mountpoint -q "$MNT_DIR" 2>/dev/null && return 0
        mkdir -p "$MNT_DIR"
        chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null
        mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR"
    }
fi

ensure_image_mounted() {
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then
        ui_print "- Image already mounted"
        return 0
    fi
    ui_print "- Mounting modules image"
    mo_mount_image || abort "! Failed to mount modules image"
    ui_print "- Image mounted successfully"
}

# Does the module ship anything for any overlayable partition?
# (The old check only looked at system/, so modules shipping only vendor/,
# product/, system_ext/, odm/ or oem/ were never mounted.)
module_partitions() {
    for _p in $PARTITIONS; do
        [ -d "$MODPATH/$_p" ] && echo "$_p"
    done
}

module_requires_overlay_move() {
    if [ -f "$MODPATH/skip_mount" ]; then
        ui_print "- skip_mount flag detected; keeping files under /data/adb/modules"
        return 1
    fi
    if [ -z "$(module_partitions)" ]; then
        ui_print "- No partition directories detected; keeping files under /data/adb/modules"
        return 1
    fi
    return 0
}

# Copy SELinux contexts from src tree to destination by mirroring each entry.
copy_selinux_contexts() {
    command -v chcon >/dev/null 2>&1 || return 0

    SRC="$1"
    DST="$2"

    if [ -z "$SRC" ] || [ -z "$DST" ] || [ ! -e "$SRC" ] || [ ! -e "$DST" ]; then
        return 0
    fi

    CHCON_FLAG=""
    if [ -L "$SRC" ]; then
        CHCON_FLAG="-h"
    fi
    chcon $CHCON_FLAG --reference="$SRC" "$DST" 2>/dev/null || true

    find "$SRC" -print | while IFS= read -r PATH_SRC; do
        if [ "$PATH_SRC" = "$SRC" ]; then
            continue
        fi
        REL_PATH="${PATH_SRC#"${SRC}/"}"
        PATH_DST="$DST/$REL_PATH"
        if [ -e "$PATH_DST" ] || [ -L "$PATH_DST" ]; then
            CHCON_FLAG=""
            if [ -L "$PATH_SRC" ]; then
                CHCON_FLAG="-h"
            fi
            chcon $CHCON_FLAG --reference="$PATH_SRC" "$PATH_DST" 2>/dev/null || true
        fi
    done
}

# Free space (KB) on the image, empty if it cannot be determined.
image_free_kb() {
    # shellcheck disable=SC2046
    set -- $(df -k "$MNT_DIR" 2>/dev/null | tail -n 1)
    [ "$#" -ge 4 ] || return 0
    eval "_free=\${$(($# - 2))}"
    case "$_free" in '' | *[!0-9]*) return 0 ;; esac
    echo "$_free"
}

# Remove whatever an older version of this module left in the image, so files
# deleted in the new version do not stay mounted.
purge_stale_content() {
    [ -n "$MODID" ] || return 0
    case "$MODID" in */* | .*) return 0 ;; esac
    if [ -d "$MNT_DIR/$MODID" ]; then
        ui_print "- Removing previous content of $MODID from the image"
        rm -rf "${MNT_DIR:?}/${MODID:?}"
    fi
}

# Post-installation: copy partition directories to the ext4 image
post_install_to_image() {
    MOD_IMG_DIR="$MNT_DIR/$MODID"
    PARTS=$(module_partitions)

    # Space check (the image is sparse with a fixed logical size).
    NEED_KB=0
    for partition in $PARTS; do
        _kb=$(du -sk "$MODPATH/$partition" 2>/dev/null | cut -f1)
        case "$_kb" in '' | *[!0-9]*) _kb=0 ;; esac
        NEED_KB=$((NEED_KB + _kb))
    done
    FREE_KB=$(image_free_kb)
    # Content of the previous version is purged first, so count it as free.
    OLD_KB=$(du -sk "$MOD_IMG_DIR" 2>/dev/null | cut -f1)
    case "$OLD_KB" in '' | *[!0-9]*) OLD_KB=0 ;; esac
    if [ -n "$FREE_KB" ] && [ "$NEED_KB" -gt $((FREE_KB + OLD_KB)) ]; then
        abort "! Not enough space in the modules image: need ${NEED_KB}KB, free $((FREE_KB + OLD_KB))KB"
    fi

    purge_stale_content

    ui_print "- Copying module content to image"
    set_perm "$MNT_DIR" 0 0 0755 0644
    mkdir -p "$MOD_IMG_DIR"
    set_perm "$MOD_IMG_DIR" 0 0 0755 0644

    for partition in $PARTS; do
        ui_print "- Copying $partition/"
        if ! cp -af "$MODPATH/$partition" "$MOD_IMG_DIR/" || [ ! -d "$MOD_IMG_DIR/$partition" ]; then
            rm -rf "$MOD_IMG_DIR"
            abort "! Failed to copy $partition/ into the modules image"
        fi
        copy_selinux_contexts "$MODPATH/$partition" "$MOD_IMG_DIR/$partition"
    done
}

# REPLACE
mark_replace() {
    replace_target="$1"
    mkdir -p "$replace_target"
    setfattr -n trusted.overlay.opaque -v y "$replace_target"
}

ui_print "- Using meta-overlayfs metainstall"

install_module

if module_requires_overlay_move; then
    ensure_image_mounted
    post_install_to_image
else
    # The new version ships nothing overlayable: drop stale content of older versions.
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then
        purge_stale_content
    fi
    ui_print "- Skipping move to modules image"
fi

ui_print "- Installation complete"
