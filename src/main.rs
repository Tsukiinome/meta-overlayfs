use anyhow::Result;
use log::info;

mod defs;
mod mount;
mod xcp;

fn dirs_from_env() -> (String, String) {
    // Dual-directory support: metadata + content
    let metadata_dir = std::env::var("MODULE_METADATA_DIR")
        .unwrap_or_else(|_| defs::MODULE_METADATA_DIR.to_string());
    let content_dir = std::env::var("MODULE_CONTENT_DIR")
        .unwrap_or_else(|_| defs::MODULE_CONTENT_DIR.to_string());
    (metadata_dir, content_dir)
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("xcp") => return xcp::run(&args[2..]),
        Some("-V") | Some("--version") | Some("version") => {
            println!("meta-overlayfs {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        // Dry run: print what would be mounted, mount nothing.
        Some("plan") => {
            let (metadata_dir, content_dir) = dirs_from_env();
            let plan = mount::build_plan(&metadata_dir, &content_dir)?;
            println!("system:");
            for d in &plan.system {
                println!("  {d}");
            }
            for (name, dirs) in &plan.others {
                println!("{name}:");
                for d in dirs {
                    println!("  {d}");
                }
            }
            return Ok(());
        }
        _ => {}
    }

    // Initialize logger
    env_logger::builder()
        .filter_level(log::LevelFilter::Info)
        .parse_default_env()
        .init();

    info!("meta-overlayfs v{}", env!("CARGO_PKG_VERSION"));

    let (metadata_dir, content_dir) = dirs_from_env();
    info!("Metadata directory: {}", metadata_dir);
    info!("Content directory: {}", content_dir);

    // Execute dual-directory mounting
    mount::mount_modules_systemlessly(&metadata_dir, &content_dir)?;

    info!("Mount completed successfully");
    Ok(())
}
