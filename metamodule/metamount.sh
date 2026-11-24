#!/system/bin/sh
# meta-overlayfs Module Mount Handler
# Entry point called by KernelSU after all post-fs-data scripts.

MODDIR="${0%/*}"
META_MODDIR="$MODDIR"
. "$MODDIR/common.sh"

RW_ROOT="/data/adb/modules/.rw"
VERSION=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)

mo_rotate_log
mo_log "=== boot mount start (v${VERSION:-?}) ==="

# --- Anti-bootloop guard ----------------------------------------------------
if mo_safe_check; then
    mo_set_status "SAFE MODE - mounts disabled, open Action to re-enable"
    exit 0
fi

# --- Mount the ext4 image ---------------------------------------------------
BINARY="$MODDIR/meta-overlayfs"
if [ ! -f "$BINARY" ]; then
    mo_log "ERROR: binary not found: $BINARY"
    mo_set_status "ERROR - binary missing, reinstall"
    exit 1
fi

if ! mountpoint -q "$MNT_DIR" 2>/dev/null; then
    if [ ! -f "$IMG_FILE" ]; then
        mo_log "ERROR: image file not found at $IMG_FILE"
        mo_set_status "ERROR - modules.img missing"
        exit 1
    fi
    mo_log "Image not mounted, checking and mounting it"
    mo_fsck "$IMG_FILE"
    if ! mo_mount_image; then
        mo_log "ERROR: failed to mount $IMG_FILE"
        mo_set_status "ERROR - could not mount modules.img"
        exit 1
    fi
    mo_log "Image mounted at $MNT_DIR"
else
    mo_log "Image already mounted at $MNT_DIR"
fi

# --- SELinux contexts for the optional read-write layer ---------------------
if [ -d "$RW_ROOT" ]; then
    mo_log "Applying SELinux contexts for RW partition structures"
    for part in $PARTITIONS; do
        PART_DIR="$RW_ROOT/$part"
        REFERENCE_PATH="/$part"
        if [ -d "$PART_DIR" ] && [ -e "$REFERENCE_PATH" ]; then
            chcon --reference="$REFERENCE_PATH" "$PART_DIR" 2>/dev/null
            [ -d "$PART_DIR/upperdir" ] && chcon --reference="$PART_DIR" "$PART_DIR/upperdir" 2>/dev/null
            [ -d "$PART_DIR/workdir" ] && chcon --reference="$PART_DIR" "$PART_DIR/workdir" 2>/dev/null
        fi
    done
fi

# --- Run the mount binary ---------------------------------------------------
export MODULE_METADATA_DIR="/data/adb/modules"
export MODULE_CONTENT_DIR="$MNT_DIR"
export RUST_LOG="${RUST_LOG:-info}"

mo_log "Metadata directory: $MODULE_METADATA_DIR"
mo_log "Content directory: $MODULE_CONTENT_DIR"
mo_log "Executing $BINARY"

# The binary logs to stderr: keep everything in the persistent log.
"$BINARY" >>"$LOG_FILE" 2>&1
EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
    mo_log "Mount failed with exit code $EXIT_CODE"
    mo_set_status "ERROR - mount failed (code $EXIT_CODE), see log"
    exit "$EXIT_CODE"
fi

N=$(grep -c ' overlay ' /proc/mounts 2>/dev/null)
mo_log "Mount completed successfully"
mo_set_status "OK - overlays active: ${N:-0}"
exit 0
