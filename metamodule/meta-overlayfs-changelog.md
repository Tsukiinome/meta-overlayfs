# v1.4.0 Changelog

Fixes
- Modules that only ship `vendor/`, `product/`, `system_ext/`, `odm/` or `oem/` (no `system/`) are now copied to the image and mounted. Before they were silently ignored.
- Updating a module now removes the files of its previous version from the image (stale files used to stay mounted).
- A failed copy into the image now aborts the install instead of leaving a module that never mounts.
- Free space in the image is checked before copying.
- `metauninstall.sh` accepts the module id as `$MODULE_ID` or `$1` and mounts the image if needed, so content is always cleaned up.
- Updating the metamodule syncs and `e2fsck`s the copied image (the live image has no journal).
- Mount order between modules is deterministic (alphabetical) and partitions are mounted in a fixed order.
- Hidden directories such as `.rw` are no longer treated as modules.

New
- Anti-bootloop guard: if 3 consecutive boots do not finish (or SystemUI restarts during the first minute), mounting is disabled and the phone boots stock. Re-enable it from the Action button or by deleting `/data/adb/meta-overlayfs/safe_mode`.
- Persistent log at `/data/adb/meta-overlayfs/meta-overlayfs.log` (binary output included, auto-rotated).
- Status shown in the module description (Manager): OK / SAFE MODE / ERROR.
- `e2fsck` of the image before mounting, and loop-mount fallbacks (busybox, manual losetup).
- More tolerant installer: ABI detection with fallbacks, `mke2fs`/`mkfs.ext4` lookup, `dd` fallback when `truncate` is missing, configurable image size (`/data/adb/meta-overlayfs/image_size_mb`, new installs only).
- Optional `armv7` / `x86` binaries are picked up automatically if present in the zip.
- `meta-overlayfs plan` (dry run) and `--version` in the binary.

Flags (in `/data/adb/meta-overlayfs/`): `skip_all` (disable mounts), `max_fails` (default 3), `stable_seconds` (default 60).
