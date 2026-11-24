#!/system/bin/sh
# meta-overlayfs action.sh
# "Action" button in the KernelSU Manager: show status and, if the anti-bootloop
# guard disabled the mounts, re-enable them for the next boot.

MODDIR="${0%/*}"
META_MODDIR="$MODDIR"
. "$MODDIR/common.sh"

VERSION=$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)
echo "OverlayFS MetaModule v${VERSION:-?}"
echo

if [ -f "$STATE_DIR/safe_mode" ] || [ -f "$STATE_DIR/skip_all" ]; then
    echo "SAFE MODE was active: no module was mounted."
    rm -f "$STATE_DIR/safe_mode" "$STATE_DIR/skip_all" "$STATE_DIR/boot_pending"
    echo 0 >"$STATE_DIR/fails"
    mo_log "Safe mode cleared from Action button"
    echo "Mounts re-enabled. REBOOT to apply."
    echo "If the phone loops again, disable or remove the last module you installed first."
else
    N=$(grep -c ' overlay ' /proc/mounts 2>/dev/null)
    echo "Status: normal. Active overlays: ${N:-0}"
    echo "Failed boots counted: $(mo_read_int "$STATE_DIR/fails" 0) / $(mo_read_int "$STATE_DIR/max_fails" 3)"
fi

echo
echo "--- last log lines ($LOG_FILE) ---"
tail -n 15 "$LOG_FILE" 2>/dev/null
exit 0
