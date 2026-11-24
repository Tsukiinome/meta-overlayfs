#!/bin/sh
# Simulation harness for the metamodule shell scripts (stubs for mount, getprop...).
REPO="$1"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { # desc, command...
  d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

setup() {
  R=$(mktemp -d)
  mkdir -p "$R/bin" "$R/meta/mnt" "$R/state"
  cp "$REPO"/*.sh "$REPO/module.prop" "$R/meta/"
  : > "$R/mounted"
  : > "$R/meta/modules.img"
  cat > "$R/meta/meta-overlayfs" <<'B'
#!/bin/sh
echo "stub-binary args=$* content=$MODULE_CONTENT_DIR meta=$MODULE_METADATA_DIR"
if [ "$1" = xcp ]; then cp "$2" "$3"; exit 0; fi
touch "$(dirname "$0")/../binary_ran"
exit ${BIN_RC:-0}
B
  chmod 755 "$R/meta/meta-overlayfs"
  cat > "$R/bin/mountpoint" <<'B'
#!/bin/sh
[ "$1" = -q ] && shift
grep -qx "$1" "$R/mounted"
B
  cat > "$R/bin/mount" <<'B'
#!/bin/sh
for a; do last="$a"; done
[ -n "$MOUNT_FAIL" ] && exit 1
echo "$last" >> "$R/mounted"
B
  cat > "$R/bin/getprop" <<'B'
#!/bin/sh
case "$1" in
  sys.boot_completed) echo 1 ;;
  ro.product.cpu.abi) echo "$FAKE_ABI" ;;
esac
B
  cat > "$R/bin/pidof" <<'B'
#!/bin/sh
if [ "$PID_MODE" = changing ]; then
  n=$(cat "$R/pidn" 2>/dev/null || echo 100); n=$((n+1)); echo $n > "$R/pidn"; echo $n
else echo 4242; fi
B
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/sleep"
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/e2fsck"
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/chcon"
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/ksud"
  printf '#!/bin/sh\nexit 1\n' > "$R/bin/losetup"
  printf '#!/bin/sh\nfor a; do last="$a"; done\ncp /dev/null "$last"\n' > "$R/bin/mke2fs"
  chmod 755 "$R"/bin/*
  export R META_STATE_DIR="$R/state"
  export PATH="$R/bin:$PATH"
}
# find_tool looks in absolute dirs first; stubs in $R/bin are found via `command -v`.
mm() { sh "$R/meta/metamount.sh" >/dev/null 2>&1; }

echo "== 1. normal boot mounts and tracks the boot"
setup
mm
check "binary executed"            test -f "$R/binary_ran"
check "boot_pending created"       test -f "$R/state/boot_pending"
check "image 'mounted'"            grep -qx "$R/meta/mnt" "$R/mounted"
check "log written"                grep -q "boot mount start" "$R/state/meta-overlayfs.log"
check "binary output in log"       grep -q "stub-binary" "$R/state/meta-overlayfs.log"
check "status in module.prop"      grep -q '^description=\[OK' "$R/meta/module.prop"
check "module.prop keeps one description" test "$(grep -c '^description=' "$R/meta/module.prop")" = 1
check "module.prop id intact"      grep -q '^id=meta-overlayfs' "$R/meta/module.prop"

echo "== 2. anti-bootloop: 3 failed boots then safe mode (latched)"
setup
for i in 1 2 3; do rm -f "$R/binary_ran"; mm; test -f "$R/binary_ran" || bad "boot $i should mount"; done
ok "boots 1-3 mounted"
rm -f "$R/binary_ran"; mm
check "boot 4: binary NOT executed" test ! -f "$R/binary_ran"
check "safe_mode latched"          test -f "$R/state/safe_mode"
check "status says SAFE MODE"      grep -q '^description=\[SAFE MODE' "$R/meta/module.prop"
rm -f "$R/binary_ran"; mm
check "boot 5: still safe"         test ! -f "$R/binary_ran"

echo "== 3. Action button re-enables mounts"
sh "$R/meta/action.sh" >"$R/action.out" 2>&1
check "safe_mode removed"          test ! -f "$R/state/safe_mode"
check "action explains"            grep -q "Mounts re-enabled" "$R/action.out"
rm -f "$R/binary_ran"; mm
check "mounts again after action"  test -f "$R/binary_ran"

echo "== 4. service.sh marks a stable boot"
setup
mm
echo 1 > "$R/state/stable_seconds"
sh "$R/meta/service.sh" >/dev/null 2>&1
check "pending cleared (stable)"   test ! -f "$R/state/boot_pending"
check "fails reset to 0"           test "$(cat "$R/state/fails")" = 0
# 4b: SystemUI restarts during the window -> not good
setup; mm; echo 1 > "$R/state/stable_seconds"
PID_MODE=changing sh "$R/meta/service.sh" >/dev/null 2>&1
check "pending kept when SystemUI restarts" test -f "$R/state/boot_pending"
# 4c: a good boot in between resets the counter, so isolated failures never trigger safe mode
setup
mm; mm            # two failed boots (fails=1)
echo 1 > "$R/state/stable_seconds"
rm -f "$R/binary_ran"; mm   # third attempt (fails=2)
sh "$R/meta/service.sh" >/dev/null 2>&1   # ...which turns out stable
for i in 1 2 3; do rm -f "$R/binary_ran"; mm; sh "$R/meta/service.sh" >/dev/null 2>&1; test -f "$R/binary_ran" || bad "boot after reset $i must mount"; done
check "no safe mode after recovery" test ! -f "$R/state/safe_mode"

echo "== 5. skip_all flag and image failures"
setup; touch "$R/state/skip_all"; mm
check "skip_all: binary not run"   test ! -f "$R/binary_ran"
setup; MOUNT_FAIL=1 sh "$R/meta/metamount.sh" >/dev/null 2>&1; rc=$?
check "mount failure -> nonzero exit" test "$rc" != 0
check "mount failure logged"       grep -q "failed to mount" "$R/state/meta-overlayfs.log"
setup; BIN_RC=7 sh "$R/meta/metamount.sh" >/dev/null 2>&1; rc=$?
check "binary failure propagates exit code" test "$rc" = 7
setup; rm "$R/meta/meta-overlayfs"; mm
check "missing binary logged"      grep -q "binary not found" "$R/state/meta-overlayfs.log"
setup; dd if=/dev/zero of="$R/state/meta-overlayfs.log" bs=1024 count=300 2>/dev/null; mm
check "big log rotated"            test -f "$R/state/meta-overlayfs.log.old"

echo "== 6. metainstall.sh"
runinstall() { # MODID, then uses $MODPATH prepared by caller
  (
    export META_MODDIR="$R/meta"
    MODID="$1"; export MODID
    ui_print() { echo "$*"; }
    abort() { echo "ABORT: $*"; exit 1; }
    set_perm() { return 0; }
    install_module() { return 0; }
    . "$R/meta/metainstall.sh"
  )
}
setup
echo "$R/meta/mnt" >> "$R/mounted"     # image already mounted
MODPATH="$R/modpath"; export MODPATH
mkdir -p "$MODPATH/vendor/lib64" "$MODPATH/product/overlay"
echo a > "$MODPATH/vendor/lib64/x.so"; echo b > "$MODPATH/product/overlay/o.apk"
runinstall modA >"$R/inst.out" 2>&1
check "vendor-only module copied (old bug)"  test -f "$R/meta/mnt/modA/vendor/lib64/x.so"
check "product copied"             test -f "$R/meta/mnt/modA/product/overlay/o.apk"
# update: new version drops a file -> stale content must go
rm "$MODPATH/vendor/lib64/x.so"; echo c > "$MODPATH/vendor/lib64/y.so"
runinstall modA >"$R/inst.out" 2>&1
check "stale file removed on update" test ! -e "$R/meta/mnt/modA/vendor/lib64/x.so"
check "new file present"           test -f "$R/meta/mnt/modA/vendor/lib64/y.so"
# new version has no partitions at all -> stale content removed, nothing copied
rm -rf "$MODPATH"; mkdir -p "$MODPATH/webroot"; touch "$MODPATH/webroot/i.html"
runinstall modA >"$R/inst.out" 2>&1
check "no-partition update purges old content" test ! -e "$R/meta/mnt/modA"
# skip_mount respected
rm -rf "$MODPATH"; mkdir -p "$MODPATH/system"; touch "$MODPATH/skip_mount"
runinstall modB >"$R/inst.out" 2>&1
check "skip_mount: nothing copied" test ! -e "$R/meta/mnt/modB"
# system module still works (regression)
rm -rf "$MODPATH"; mkdir -p "$MODPATH/system/app"; echo z > "$MODPATH/system/app/z"
runinstall modC >"$R/inst.out" 2>&1
check "system/ module copied"      test -f "$R/meta/mnt/modC/system/app/z"
# copy failure aborts
cat > "$R/bin/cp" <<'B'
#!/bin/sh
exit 1
B
chmod 755 "$R/bin/cp"
runinstall modD >"$R/inst.out" 2>&1; rc=$?
check "failed copy aborts"         test "$rc" != 0
check "abort message shown"        grep -q "ABORT: ! Failed to copy" "$R/inst.out"
check "partial dir cleaned"        test ! -e "$R/meta/mnt/modD"
rm -f "$R/bin/cp"
# image not mounted -> installer mounts it
setup; : > "$R/mounted"
MODPATH="$R/modpath"; export MODPATH; mkdir -p "$MODPATH/odm/x"; touch "$MODPATH/odm/x/f"
runinstall modE >"$R/inst.out" 2>&1
check "unmounted image gets mounted" grep -qx "$R/meta/mnt" "$R/mounted"
check "odm-only module copied"     test -f "$R/meta/mnt/modE/odm/x/f"

echo "== 7. metauninstall.sh"
setup; echo "$R/meta/mnt" >> "$R/mounted"
mkdir -p "$R/meta/mnt/victim/system" "$R/meta/mnt/keep/system"
META_MODDIR="$R/meta" MODULE_ID=victim sh "$R/meta/metauninstall.sh" >/dev/null 2>&1
check "removed via \$MODULE_ID"    test ! -e "$R/meta/mnt/victim"
check "other module untouched"     test -d "$R/meta/mnt/keep"
mkdir -p "$R/meta/mnt/v2/system"
env -u MODULE_ID META_MODDIR="$R/meta" sh "$R/meta/metauninstall.sh" v2 >/dev/null 2>&1
check "removed via \$1"            test ! -e "$R/meta/mnt/v2"
META_MODDIR="$R/meta" sh "$R/meta/metauninstall.sh" ../meta >/dev/null 2>&1; rc=$?
check "unsafe id refused"          test "$rc" != 0
check "image dir not wiped by unsafe id" test -d "$R/meta/mnt/keep"
env -u MODULE_ID META_MODDIR="$R/meta" sh "$R/meta/metauninstall.sh" >/dev/null 2>&1; rc=$?
check "no id -> error"             test "$rc" != 0
# image not mounted: cleanup still happens
: > "$R/mounted"; mkdir -p "$R/meta/mnt/v3/system"
META_MODDIR="$R/meta" MODULE_ID=v3 sh "$R/meta/metauninstall.sh" >/dev/null 2>&1
check "unmounted image: mounted and cleaned" test ! -e "$R/meta/mnt/v3"

echo "== 8. customize.sh (metamodule installer)"
cust() { # ABI
  (
    export FAKE_ABI="$1" MODID=meta-overlayfs
    MODPATH="$R/mp"; export MODPATH
    rm -rf "$MODPATH"; mkdir -p "$MODPATH"
    for a in aarch64 x86_64 $EXTRA; do cp "$R/meta/meta-overlayfs" "$MODPATH/meta-overlayfs-$a"; done
    cp "$R"/meta/*.sh "$MODPATH/"
    ui_print() { echo "$*"; }
    abort() { echo "ABORT: $*"; exit 1; }
    . "$MODPATH/customize.sh"
  )
}
setup
cust arm64-v8a >"$R/c.out" 2>&1; rc=$?
check "arm64: installs"            test "$rc" = 0
check "arm64: binary renamed"      test -x "$R/mp/meta-overlayfs"
check "arm64: other binaries removed" test "$(ls "$R"/mp/meta-overlayfs-* 2>/dev/null | wc -l)" = 0
check "arm64: image created"       test -f "$R/mp/modules.img"
check "arm64: defaults written"    test "$(cat "$R/state/max_fails")" = 3
check "reboot warning shown"       grep -q "REBOOT" "$R/c.out"
cust x86_64 >"$R/c.out" 2>&1; check "x86_64 installs" test $? = 0
cust armeabi-v7a >"$R/c.out" 2>&1; rc=$?
check "armv7 without binary: clear abort" grep -q "no binary for armv7" "$R/c.out"
EXTRA=armv7 cust armeabi-v7a >"$R/c.out" 2>&1; check "armv7 with binary installs" test $? = 0
cust mips >"$R/c.out" 2>&1; check "unknown ABI aborts" grep -q "Unsupported architecture" "$R/c.out"
# update path reuses (and checks) the existing image
mkdir -p "$R/data/adb/modules/meta-overlayfs"
setup2() { :; }
(
  export FAKE_ABI=arm64-v8a MODID=meta-overlayfs
  MODPATH="$R/mp2"; export MODPATH; rm -rf "$MODPATH"; mkdir -p "$MODPATH"
  cp "$R/meta/meta-overlayfs" "$MODPATH/meta-overlayfs-aarch64"
  echo "OLDIMAGE" > "$R/old.img"
  # point EXISTING_IMG at our fake by wrapping the script
  sed "s#/data/adb/modules/\$MODID/modules.img#$R/old.img#" "$R/meta/customize.sh" > "$MODPATH/customize.sh"
  ui_print() { echo "$*"; }; abort() { echo "ABORT: $*"; exit 1; }
  . "$MODPATH/customize.sh"
) >"$R/c2.out" 2>&1
check "update: reuses existing image" grep -q "Reusing modules image" "$R/c2.out"
check "update: content carried over"  grep -q OLDIMAGE "$R/mp2/modules.img"
# damaged image -> abort and no half-installed image left
printf '#!/bin/sh\nexit 8\n' > "$R/bin/e2fsck"; chmod 755 "$R/bin/e2fsck"
(
  export FAKE_ABI=arm64-v8a MODID=meta-overlayfs
  MODPATH="$R/mp3"; export MODPATH; rm -rf "$MODPATH"; mkdir -p "$MODPATH"
  cp "$R/meta/meta-overlayfs" "$MODPATH/meta-overlayfs-aarch64"
  sed "s#/data/adb/modules/\$MODID/modules.img#$R/old.img#" "$R/meta/customize.sh" > "$MODPATH/customize.sh"
  ui_print() { echo "$*"; }; abort() { echo "ABORT: $*"; exit 1; }
  . "$MODPATH/customize.sh"
) >"$R/c3.out" 2>&1
check "damaged image: abort with instructions" grep -q "damaged" "$R/c3.out"
check "damaged image: no leftover copy" test ! -e "$R/mp3/modules.img"

echo "== 9. post-mount.sh / uninstall.sh"
setup; echo "$R/meta/mnt" >> "$R/mounted"
sh "$R/meta/post-mount.sh" >/dev/null 2>&1
check "post-mount logs nuke result" grep -q "nuke-ext4-sysfs" "$R/state/meta-overlayfs.log"
setup; sh "$R/meta/post-mount.sh" >/dev/null 2>&1; rc=$?
check "post-mount: nothing mounted -> clean exit" test "$rc" = 0
setup; echo "$R/meta/mnt" >> "$R/mounted"; touch "$R/state/x"
sh "$R/meta/uninstall.sh" >/dev/null 2>&1
check "uninstall removes state dir" test ! -e "$R/state"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
