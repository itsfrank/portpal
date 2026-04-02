use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};

pub fn application_support_dir() -> Result<PathBuf> {
    let home = std::env::var("HOME").context("HOME is not set")?;
    let path = PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Portpal");
    fs::create_dir_all(&path).with_context(|| format!("failed to create {}", path.display()))?;
    Ok(path)
}

pub fn socket_path() -> Result<PathBuf> {
    Ok(application_support_dir()?.join("portpal.sock"))
}

pub fn config_path() -> Result<PathBuf> {
    Ok(application_support_dir()?.join("config.toml"))
}
