use std::process::{Child, Command, Stdio};

use anyhow::{Context, Result};

use crate::config::ConnectionConfig;

pub fn spawn_connection(connection: &ConnectionConfig) -> Result<Child> {
    Command::new("/usr/bin/ssh")
        .arg("-N")
        .arg("-o")
        .arg("ExitOnForwardFailure=yes")
        .arg("-L")
        .arg(format!(
            "{}:{}:{}",
            connection.local_port, connection.remote_host, connection.remote_port
        ))
        .arg(&connection.ssh_host)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("failed to start ssh for {}", connection.name))
}
