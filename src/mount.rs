// Overlayfs mounting implementation
// Migrated from ksud/src/mount.rs and ksud/src/init_event.rs

use anyhow::{Context, Result, bail};
use log::{info, warn};
use std::path::{Path, PathBuf};

use procfs::process::Process;
use rustix::{fd::AsFd, fs::CWD, mount::*};

use crate::defs::{DISABLE_FILE_NAME, KSU_OVERLAY_SOURCE, SKIP_MOUNT_FILE_NAME, SYSTEM_RW_DIR};

pub fn mount_overlayfs(
    lower_dirs: &[String],
    lowest: &str,
    upperdir: Option<PathBuf>,
    workdir: Option<PathBuf>,
    dest: impl AsRef<Path>,
) -> Result<()> {
    let lowerdir_config = lower_dirs
        .iter()
        .map(|s| s.as_ref())
        .chain(std::iter::once(lowest))
        .collect::<Vec<_>>()
        .join(":");
    info!(
        "mount overlayfs on {:?}, lowerdir={}, upperdir={:?}, workdir={:?}",
        dest.as_ref(),
        lowerdir_config,
        upperdir,
        workdir
    );

    let upperdir = upperdir
        .filter(|up| up.exists())
        .map(|e| e.display().to_string());
    let workdir = workdir
        .filter(|wd| wd.exists())
        .map(|e| e.display().to_string());

    let result = (|| {
        let fs = fsopen("overlay", FsOpenFlags::FSOPEN_CLOEXEC)?;
        let fs = fs.as_fd();
        fsconfig_set_string(fs, "lowerdir", &lowerdir_config)?;
        if let (Some(upperdir), Some(workdir)) = (&upperdir, &workdir) {
            fsconfig_set_string(fs, "upperdir", upperdir)?;
            fsconfig_set_string(fs, "workdir", workdir)?;
        }
        fsconfig_set_string(fs, "source", KSU_OVERLAY_SOURCE)?;
        fsconfig_create(fs)?;
        let mount = fsmount(fs, FsMountFlags::FSMOUNT_CLOEXEC, MountAttrFlags::empty())?;
        move_mount(
            mount.as_fd(),
            "",
            CWD,
            dest.as_ref(),
            MoveMountFlags::MOVE_MOUNT_F_EMPTY_PATH,
        )
    })();

    if let Err(e) = result {
        warn!("fsopen mount failed: {e:#}, fallback to mount");
        let mut data = format!("lowerdir={lowerdir_config}");
        if let (Some(upperdir), Some(workdir)) = (upperdir, workdir) {
            data = format!("{data},upperdir={upperdir},workdir={workdir}");
        }
        mount(
            KSU_OVERLAY_SOURCE,
            dest.as_ref(),
            "overlay",
            MountFlags::empty(),
            data,
        )?;
    }
    Ok(())
}

pub fn bind_mount(from: impl AsRef<Path>, to: impl AsRef<Path>) -> Result<()> {
    info!(
        "bind mount {} -> {}",
        from.as_ref().display(),
        to.as_ref().display()
    );
    let tree = open_tree(
        CWD,
        from.as_ref(),
        OpenTreeFlags::OPEN_TREE_CLOEXEC
            | OpenTreeFlags::OPEN_TREE_CLONE
            | OpenTreeFlags::AT_RECURSIVE,
    )?;
    move_mount(
        tree.as_fd(),
        "",
        CWD,
        to.as_ref(),
        MoveMountFlags::MOVE_MOUNT_F_EMPTY_PATH,
    )?;
    Ok(())
}

fn mount_overlay_child(
    mount_point: &str,
    relative: &String,
    module_roots: &Vec<String>,
    stock_root: &String,
) -> Result<()> {
    if !module_roots
        .iter()
        .any(|lower| Path::new(&format!("{lower}{relative}")).exists())
    {
        return bind_mount(stock_root, mount_point);
    }
    if !Path::new(&stock_root).is_dir() {
        return Ok(());
    }
    let mut lower_dirs: Vec<String> = vec![];
    for lower in module_roots {
        let lower_dir = format!("{lower}{relative}");
        let path = Path::new(&lower_dir);
        if path.is_dir() {
            lower_dirs.push(lower_dir);
        } else if path.exists() {
            // stock root has been blocked by this file
            return Ok(());
        }
    }
    if lower_dirs.is_empty() {
        return Ok(());
    }
    // merge modules and stock
    if let Err(e) = mount_overlayfs(&lower_dirs, stock_root, None, None, mount_point) {
        warn!("failed: {e:#}, fallback to bind mount");
        bind_mount(stock_root, mount_point)?;
    }
    Ok(())
}

pub fn mount_overlay(
    root: &String,
    module_roots: &Vec<String>,
    workdir: Option<PathBuf>,
    upperdir: Option<PathBuf>,
) -> Result<()> {
    info!("mount overlay for {root}");
    std::env::set_current_dir(root).with_context(|| format!("failed to chdir to {root}"))?;
    let stock_root = ".";

    // collect child mounts before mounting the root
    let mounts = Process::myself()?
        .mountinfo()
        .with_context(|| "get mountinfo")?;
    let mut mount_seq = mounts
        .0
        .iter()
        .filter(|m| {
            m.mount_point.starts_with(root) && !Path::new(&root).starts_with(&m.mount_point)
        })
        .map(|m| m.mount_point.to_str())
        .collect::<Vec<_>>();
    mount_seq.sort();
    mount_seq.dedup();

    mount_overlayfs(module_roots, root, upperdir, workdir, root)
        .with_context(|| "mount overlayfs for root failed")?;
    for mount_point in mount_seq.iter() {
        let Some(mount_point) = mount_point else {
            continue;
        };
        let relative = mount_point.replacen(root, "", 1);
        let stock_root: String = format!("{stock_root}{relative}");
        if !Path::new(&stock_root).exists() {
            continue;
        }
        if let Err(e) = mount_overlay_child(mount_point, &relative, module_roots, &stock_root) {
            warn!("failed to mount overlay for child {mount_point}: {e:#}, revert");
            umount_dir(root).with_context(|| format!("failed to revert {root}"))?;
            bail!(e);
        }
    }
    Ok(())
}

pub fn umount_dir(src: impl AsRef<Path>) -> Result<()> {
    unmount(src.as_ref(), UnmountFlags::empty())
        .with_context(|| format!("Failed to umount {}", src.as_ref().display()))?;
    Ok(())
}

// ========== Mount coordination logic (from init_event.rs) ==========

fn mount_partition(partition_name: &str, lowerdir: &Vec<String>) -> Result<()> {
    if lowerdir.is_empty() {
        warn!("partition: {partition_name} lowerdir is empty");
        return Ok(());
    }

    let partition = format!("/{partition_name}");

    // if /partition is a symlink and linked to /system/partition, then we don't need to overlay it separately
    if Path::new(&partition).read_link().is_ok() {
        warn!("partition: {partition} is a symlink");
        return Ok(());
    }

    let mut workdir = None;
    let mut upperdir = None;
    let system_rw_dir = Path::new(SYSTEM_RW_DIR);
    if system_rw_dir.exists() {
        workdir = Some(system_rw_dir.join(partition_name).join("workdir"));
        upperdir = Some(system_rw_dir.join(partition_name).join("upperdir"));
    }

    mount_overlay(&partition, lowerdir, workdir, upperdir)
}

/// Partitions mounted besides `system`, in a fixed order (the old code iterated a
/// `HashMap`, so the order changed from boot to boot).
pub const EXTRA_PARTITIONS: [&str; 5] = ["vendor", "product", "system_ext", "odm", "oem"];

/// What is going to be mounted: for every partition, the module directories used
/// as overlay lower layers. The FIRST entry has the HIGHEST priority.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct MountPlan {
    pub system: Vec<String>,
    pub others: Vec<(&'static str, Vec<String>)>,
}

/// Collect enabled module IDs from metadata directory.
///
/// Reads module list and status from metadata directory and returns the enabled
/// module IDs sorted alphabetically, so that conflicts between two modules
/// that ship the same file are always resolved the same way.
fn collect_enabled_modules(metadata_dir: &str) -> Result<Vec<String>> {
    let dir = std::fs::read_dir(metadata_dir)
        .with_context(|| format!("Failed to read metadata directory: {}", metadata_dir))?;

    let mut enabled = Vec::new();

    for entry in dir.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        let module_id = match entry.file_name().to_str() {
            Some(id) => id.to_string(),
            None => continue,
        };

        // Hidden directories (".rw", ...) are not modules.
        if module_id.starts_with('.') {
            continue;
        }

        // Check status markers
        if path.join(DISABLE_FILE_NAME).exists() {
            info!("Module {} is disabled, skipping", module_id);
            continue;
        }

        if path.join(SKIP_MOUNT_FILE_NAME).exists() {
            info!("Module {} has skip_mount, skipping", module_id);
            continue;
        }

        if !path.join("module.prop").exists() {
            warn!("Module {} has no module.prop, skipping", module_id);
            continue;
        }

        info!("Module {} enabled", module_id);
        enabled.push(module_id);
    }

    enabled.sort();
    Ok(enabled)
}

/// Build the mount plan without touching any mount (also used by `plan`).
///
/// Parameters:
/// - metadata_dir: Metadata directory, stores module.prop, disable, skip_mount, etc.
/// - content_dir: Content directory, stores system/, vendor/ and other partition content (ext4 image mount point)
pub fn build_plan(metadata_dir: &str, content_dir: &str) -> Result<MountPlan> {
    let enabled_modules = collect_enabled_modules(metadata_dir)?;

    let mut plan = MountPlan {
        system: Vec::new(),
        others: EXTRA_PARTITIONS
            .iter()
            .map(|p| (*p, Vec::new()))
            .collect(),
    };

    for module_id in &enabled_modules {
        let module_content_path = Path::new(content_dir).join(module_id);

        if !module_content_path.exists() {
            warn!("Module {} has no content directory, skipping", module_id);
            continue;
        }

        info!("Processing module: {}", module_id);

        let system_path = module_content_path.join("system");
        if system_path.is_dir() {
            plan.system.push(system_path.display().to_string());
            info!("  + system/");
        }

        for (part, dirs) in plan.others.iter_mut() {
            let part_path = module_content_path.join(*part);
            if part_path.is_dir() {
                dirs.push(part_path.display().to_string());
                info!("  + {}/", part);
            }
        }
    }

    Ok(plan)
}

/// Dual-directory version of mount_modules_systemlessly
pub fn mount_modules_systemlessly(metadata_dir: &str, content_dir: &str) -> Result<()> {
    info!("Scanning modules (dual-directory mode)");
    info!("  Metadata: {}", metadata_dir);
    info!("  Content: {}", content_dir);

    let plan = build_plan(metadata_dir, content_dir)?;

    info!("Mounting partitions...");

    if let Err(e) = mount_partition("system", &plan.system) {
        warn!("mount system failed: {e:#}");
    }

    for (name, dirs) in &plan.others {
        if let Err(e) = mount_partition(name, dirs) {
            warn!("mount {name} failed: {e:#}");
        }
    }

    info!("All partitions processed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn scratch() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "meta-overlayfs-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn module(meta: &Path, content: &Path, id: &str, parts: &[&str], markers: &[&str]) {
        fs::create_dir_all(meta.join(id)).unwrap();
        fs::write(meta.join(id).join("module.prop"), format!("id={id}\n")).unwrap();
        for m in markers {
            fs::write(meta.join(id).join(m), "").unwrap();
        }
        fs::create_dir_all(content.join(id)).unwrap();
        for p in parts {
            fs::create_dir_all(content.join(id).join(p)).unwrap();
        }
    }

    #[test]
    fn modules_are_sorted_and_filtered() {
        let root = scratch();
        let (meta, content) = (root.join("meta"), root.join("content"));
        module(&meta, &content, "zeta", &["system"], &[]);
        module(&meta, &content, "alpha", &["system"], &[]);
        module(&meta, &content, "off", &["system"], &["disable"]);
        module(&meta, &content, "skipped", &["system"], &["skip_mount"]);
        fs::create_dir_all(meta.join(".rw/system/upperdir")).unwrap();
        fs::create_dir_all(meta.join("noprop")).unwrap();
        fs::write(meta.join("a-file"), "").unwrap();

        let ids = collect_enabled_modules(meta.to_str().unwrap()).unwrap();
        assert_eq!(ids, vec!["alpha".to_string(), "zeta".to_string()]);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn plan_covers_modules_without_system_dir() {
        // A module that only ships product/ must still be planned.
        let root = scratch();
        let (meta, content) = (root.join("meta"), root.join("content"));
        module(&meta, &content, "only-product", &["product"], &[]);
        module(&meta, &content, "both", &["system", "vendor", "product"], &[]);

        let plan = build_plan(meta.to_str().unwrap(), content.to_str().unwrap()).unwrap();
        let c = content.display();
        assert_eq!(plan.system, vec![format!("{c}/both/system")]);

        let get = |name: &str| {
            plan.others
                .iter()
                .find(|(n, _)| *n == name)
                .map(|(_, v)| v.clone())
                .unwrap()
        };
        assert_eq!(
            get("product"),
            vec![format!("{c}/both/product"), format!("{c}/only-product/product")]
        );
        assert_eq!(get("vendor"), vec![format!("{c}/both/vendor")]);
        assert!(get("odm").is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn plan_order_is_stable_and_partitions_fixed() {
        let root = scratch();
        let (meta, content) = (root.join("meta"), root.join("content"));
        for id in ["m3", "m1", "m2"] {
            module(&meta, &content, id, &["system"], &[]);
        }
        let names: Vec<_> = (0..5)
            .map(|_| build_plan(meta.to_str().unwrap(), content.to_str().unwrap()).unwrap())
            .collect();
        assert!(names.windows(2).all(|w| w[0] == w[1]));
        let order: Vec<&str> = names[0].others.iter().map(|(n, _)| *n).collect();
        assert_eq!(order, EXTRA_PARTITIONS.to_vec());
        let c = content.display();
        assert_eq!(
            names[0].system,
            vec![
                format!("{c}/m1/system"),
                format!("{c}/m2/system"),
                format!("{c}/m3/system")
            ]
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn module_without_content_is_skipped() {
        let root = scratch();
        let (meta, content) = (root.join("meta"), root.join("content"));
        fs::create_dir_all(&content).unwrap();
        fs::create_dir_all(meta.join("ghost")).unwrap();
        fs::write(meta.join("ghost/module.prop"), "id=ghost\n").unwrap();
        let plan = build_plan(meta.to_str().unwrap(), content.to_str().unwrap()).unwrap();
        assert!(plan.system.is_empty());
        assert!(plan.others.iter().all(|(_, v)| v.is_empty()));
        let _ = fs::remove_dir_all(&root);
    }
}
