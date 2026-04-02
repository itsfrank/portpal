use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};

pub fn config_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME").context("HOME is not set")?;
    let path = PathBuf::from(home).join(".config").join("portpal");
    fs::create_dir_all(&path).with_context(|| format!("failed to create {}", path.display()))?;
    Ok(path)
}

pub fn socket_path() -> Result<PathBuf> {
    Ok(config_dir()?.join("portpal.sock"))
}

pub fn config_path() -> Result<PathBuf> {
    Ok(config_dir()?.join("portpal.toml"))
}
