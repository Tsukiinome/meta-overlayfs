#!/system/bin/sh
# meta-overlayfs service.sh
# Marks the boot as successful once the system has been stable for a while.
# (Counterpart of the anti-bootloop guard in common.sh / metamount.sh.)

MODDIR="${0%/*}"
META_MODDIR="$MODDIR"
. "$MODDIR/common.sh"

STABLE_SECONDS=$(mo_read_int "$STATE_DIR/stable_seconds" 60)

# Nothing to do if this boot is not being tracked (e.g. safe mode).
[ -f "$STATE_DIR/boot_pending" ] || exit 0

# Wait for boot to complete (give up after 10 minutes: the marker stays and the
# next boot counts as a failed one).
waited=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 3
    waited=$((waited + 3))
    [ "$waited" -ge 600 ] && exit 0
done

# SystemUI must survive the stability window without being restarted.
ui_pid_before=$(pidof com.android.systemui 2>/dev/null)
sleep "$STABLE_SECONDS"
ui_pid_after=$(pidof com.android.systemui 2>/dev/null)

if command -v pidof >/dev/null 2>&1; then
    if [ -z "$ui_pid_after" ] || [ "$ui_pid_before" != "$ui_pid_after" ]; then
        mo_log "SystemUI restarted during the stability window: boot NOT marked as good"
        exit 0
    fi
fi

rm -f "$STATE_DIR/boot_pending"
echo 0 >"$STATE_DIR/fails"
mo_log "Boot stable for ${STABLE_SECONDS}s: marked as good"
exit 0
