#!/system/bin/sh
############################################
# meta-overlayfs common.sh
# Shared helpers (sourced by metamount.sh, post-mount.sh, service.sh,
# action.sh, metainstall.sh and metauninstall.sh).
# Written for toybox/mksh: POSIX sh only, no awk/sed/bashisms.
############################################

META_ID="meta-overlayfs"

# Persistent state that must survive module updates (logs, boot counter, flags).
STATE_DIR="${META_STATE_DIR:-/data/adb/meta-overlayfs}"
LOG_FILE="$STATE_DIR/meta-overlayfs.log"
MAX_LOG_BYTES=262144

# Where the metamodule lives. KernelSU exposes /data/adb/metamodule as a symlink;
# fall back to the regular module path on versions that don't create it.
if [ -z "$META_MODDIR" ]; then
    if [ -n "$MODDIR" ] && [ -f "$MODDIR/module.prop" ]; then
        META_MODDIR="$MODDIR"
    elif [ -d /data/adb/metamodule ]; then
        META_MODDIR="/data/adb/metamodule"
    else
        META_MODDIR="/data/adb/modules/$META_ID"
    fi
fi

IMG_FILE="$META_MODDIR/modules.img"
MNT_DIR="$META_MODDIR/mnt"
# shellcheck disable=SC2034 # used by the scripts that source this file
PARTITIONS="system vendor product system_ext odm oem"

mo_log() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S' 2>/dev/null)] $*" >>"$LOG_FILE" 2>/dev/null
    echo "[meta-overlayfs] $*"
}

mo_rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    _size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
    case "$_size" in '' | *[!0-9]*) return 0 ;; esac
    if [ "$_size" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null
    fi
}

# mo_find_tool name... -> prints the path of the first tool found
mo_find_tool() {
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

# mo_fsck <image>: repair the ext4 image if needed. Returns 0 when usable.
mo_fsck() {
    _img="$1"
    _fsck=$(mo_find_tool e2fsck) || return 0 # no tool: nothing we can do, try mounting anyway
    "$_fsck" -p -f "$_img" >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" -le 1 ]; then
        return 0
    fi
    mo_log "e2fsck -p returned $_rc on $_img, retrying with -fy"
    "$_fsck" -fy "$_img" >/dev/null 2>&1
    _rc=$?
    [ "$_rc" -le 2 ] && return 0
    mo_log "e2fsck could not repair $_img (rc=$_rc)"
    return 1
}

# mo_mount_image: mount $IMG_FILE on $MNT_DIR with several fallbacks so it works
# on any ROM/toolbox. Returns 0 if mounted (or already mounted).
mo_mount_image() {
    if mountpoint -q "$MNT_DIR" 2>/dev/null; then
        return 0
    fi
    [ -f "$IMG_FILE" ] || return 1
    mkdir -p "$MNT_DIR"
    chcon u:object_r:ksu_file:s0 "$IMG_FILE" 2>/dev/null

    mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR" 2>/dev/null && return 0

    for _bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox; do
        if [ -x "$_bb" ]; then
            "$_bb" mount -t ext4 -o loop,rw,noatime "$IMG_FILE" "$MNT_DIR" 2>/dev/null && return 0
        fi
    done

    _loop=$(losetup -f 2>/dev/null)
    if [ -n "$_loop" ] && losetup "$_loop" "$IMG_FILE" 2>/dev/null; then
        if mount -t ext4 -o rw,noatime "$_loop" "$MNT_DIR" 2>/dev/null; then
            return 0
        fi
        losetup -d "$_loop" 2>/dev/null
    fi
    return 1
}

# mo_set_status <text>: show the current state in the module description
# (visible in the KernelSU Manager). Best effort.
mo_set_status() {
    _prop="$META_MODDIR/module.prop"
    [ -w "$_prop" ] || return 0
    _tmp="$_prop.tmp"
    grep -v '^description=' "$_prop" >"$_tmp" 2>/dev/null || return 0
    echo "description=[$1] OverlayFS metamodule for KernelSU/KowSU" >>"$_tmp"
    cat "$_tmp" >"$_prop" 2>/dev/null
    rm -f "$_tmp"
}

# mo_read_int <file> <default>
mo_read_int() {
    _v=$(cat "$1" 2>/dev/null)
    case "$_v" in '' | *[!0-9]*) _v="$2" ;; esac
    echo "$_v"
}

# Anti-bootloop guard.
# Each boot that mounts modules drops a "boot_pending" marker. service.sh removes
# it once the system has been stable for a while. If the marker is still there on
# the next boot, the previous boot never finished: count it. After MAX_FAILS
# consecutive failed boots, mounting is skipped (and latched in "safe_mode") so
# the phone can boot stock and the user can fix things.
# Returns 0 when mounting must be SKIPPED, 1 when it may proceed.
mo_safe_check() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    if [ -f "$STATE_DIR/skip_all" ]; then
        mo_log "skip_all flag present: not mounting anything"
        return 0
    fi
    if [ -f "$STATE_DIR/safe_mode" ]; then
        mo_log "safe mode is latched: not mounting anything"
        return 0
    fi
    _max=$(mo_read_int "$STATE_DIR/max_fails" 3)
    [ "$_max" -lt 1 ] && _max=3
    _fails=0
    if [ -f "$STATE_DIR/boot_pending" ]; then
        _fails=$(mo_read_int "$STATE_DIR/fails" 0)
        _fails=$((_fails + 1))
    fi
    echo "$_fails" >"$STATE_DIR/fails"
    if [ "$_fails" -ge "$_max" ]; then
        : >"$STATE_DIR/safe_mode"
        mo_log "SAFE MODE: $_fails consecutive boots did not finish, mounts disabled"
        return 0
    fi
    : >"$STATE_DIR/boot_pending"
    return 1
}
