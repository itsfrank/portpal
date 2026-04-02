use std::collections::HashSet;
use std::fs;
use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigFile {
    #[serde(default)]
    pub connections: Vec<ConnectionConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionConfig {
    pub name: String,
    pub ssh_host: String,
    pub local_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
    pub auto_start: bool,
    pub reconnect_delay_seconds: u64,
}

impl ConfigFile {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self {
                connections: Vec::new(),
            });
        }

        let contents = fs::read_to_string(path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let config: ConfigFile = toml::from_str(&contents)
            .with_context(|| format!("failed to parse {}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        let mut names = HashSet::new();
        let mut local_ports = HashSet::new();

        for connection in &self.connections {
            connection.validate()?;

            if !names.insert(connection.name.clone()) {
                bail!("duplicate connection name: {}", connection.name);
            }

            if !local_ports.insert(connection.local_port) {
                bail!("duplicate local port: {}", connection.local_port);
            }
        }

        Ok(())
    }
}

impl ConnectionConfig {
    pub fn validate(&self) -> Result<()> {
        if self.name.trim().is_empty() {
            bail!("connection name is required");
        }
        if self.ssh_host.trim().is_empty() {
            bail!("ssh_host is required for {}", self.name);
        }
        if self.remote_host.trim().is_empty() {
            bail!("remote_host is required for {}", self.name);
        }
        if self.local_port == 0 {
            bail!("local_port must be between 1 and 65535 for {}", self.name);
        }
        if self.remote_port == 0 {
            bail!("remote_port must be between 1 and 65535 for {}", self.name);
        }

        Ok(())
    }
}

pub fn initialize_config(path: &Path) -> Result<()> {
    if path.exists() {
        bail!("config already exists at {}", path.display());
    }

    let sample = sample_config();
    fs::write(path, sample).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

pub fn sample_config() -> String {
    [
        "[[connections]]",
        "name = \"example-postgres\"",
        "ssh_host = \"prod-db\"",
        "local_port = 15432",
        "remote_host = \"127.0.0.1\"",
        "remote_port = 5432",
        "auto_start = true",
        "reconnect_delay_seconds = 10",
        "",
    ]
    .join("\n")
}

pub fn validate_config_file(path: &Path) -> Result<()> {
    let config = ConfigFile::load(path)?;
    if config.connections.is_empty() && !path.exists() {
        return Err(anyhow!("config file does not exist at {}", path.display()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{ConfigFile, ConnectionConfig};

    fn connection(name: &str, local_port: u16) -> ConnectionConfig {
        ConnectionConfig {
            name: name.to_string(),
            ssh_host: "box".to_string(),
            local_port,
            remote_host: "127.0.0.1".to_string(),
            remote_port: 5432,
            auto_start: true,
            reconnect_delay_seconds: 10,
        }
    }

    #[test]
    fn rejects_duplicate_names() {
        let config = ConfigFile {
            connections: vec![connection("db", 15432), connection("db", 15433)],
        };

        let error = config.validate().unwrap_err().to_string();
        assert!(error.contains("duplicate connection name"));
    }

    #[test]
    fn rejects_duplicate_local_ports() {
        let config = ConfigFile {
            connections: vec![connection("db-a", 15432), connection("db-b", 15432)],
        };

        let error = config.validate().unwrap_err().to_string();
        assert!(error.contains("duplicate local port"));
    }

    #[test]
    fn rejects_blank_name() {
        let connection = connection("", 15432);
        let error = connection.validate().unwrap_err().to_string();
        assert!(error.contains("connection name is required"));
    }
}
