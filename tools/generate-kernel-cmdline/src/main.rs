use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;
use uapi_config::SearchDirectories;

fn main() -> Result<(), String> {
    let config_root = env::var("CONFIG_ROOT").unwrap_or("/".to_string());
    let config_root_path = Path::new(&config_root)
        .canonicalize()
        .map_err(|e| format!("Unable to find config root '{config_root}': {e}"))?;

    // "classic system" searches /usr/lib and /etc
    let search_dirs = SearchDirectories::classic_system()
        .chroot(config_root_path.as_path())
        .map_err(|e| format!("Invalid search root '{config_root}': {e}"))?;

    let files = search_dirs
        .with_project("kernel-cmdline")
        .find_files(".conf")
        .map_err(|e| format!("Unable to open config files under '{config_root}': {e}"))?;

    let mut cmdline: Vec<String> = Vec::new();

    for (path, file) in files {
        eprintln!("Parsing {}", path.display());
        apply_config(
            &mut cmdline,
            read_lines(file)
                .map_err(|e| format!("Error parsing file '{}': {e}", path.display()))?,
        )
    }

    println!("{}", cmdline.join(" "));
    Ok(())
}

fn apply_config(cmdline: &mut Vec<String>, config_lines: Vec<String>) {
    for line in config_lines {
        if line.starts_with("#") || line.is_empty() {
            continue;
        } else if line.starts_with("-") {
            cmdline.retain(|x| *x != line[1..])
        } else if !cmdline.contains(&line) {
            cmdline.push(line)
        }
    }
}

fn read_lines(file: File) -> Result<Vec<String>, String> {
    let mut options = Vec::new();
    let mut lineno = 1;

    for line in BufReader::new(file).lines() {
        options.push(
            line.map_err(|e| format!("Unable to parse line number {lineno}: {e}"))?
                .trim()
                .to_string(),
        );
        lineno += 1;
    }
    Ok(options)
}
