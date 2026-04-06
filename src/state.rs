use std::collections::BTreeMap;
use std::process::Child;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};

use crate::config::{ConfigFile, ConnectionConfig};
use crate::health;
use crate::ipc::{aggregate_health, ConnectionState, ConnectionStatus, ServiceSnapshot};
use crate::ssh;

pub struct AppState {
    connections: BTreeMap<String, ManagedConnection>,
}

struct ManagedConnection {
    config: ConnectionConfig,
    child: Option<Child>,
    process_id: Option<u32>,
    process_alive: bool,
    port_reachable: bool,
    restart_suppressed: bool,
    last_error: Option<String>,
    next_retry_at: Option<Instant>,
    last_started_at: Option<Instant>,
}

impl AppState {
    pub fn new(config: ConfigFile) -> Self {
        let connections = config
            .connections
            .into_iter()
            .map(|connection| {
                let name = connection.name.clone();
                (name, ManagedConnection::new(connection))
            })
            .collect();

        Self { connections }
    }

    pub fn start_auto_connections(&mut self) {
        for connection in self.connections.values_mut() {
            if connection.config.auto_start {
                connection.ensure_started();
            }
        }
    }

    pub fn snapshot(&mut self) -> ServiceSnapshot {
        self.refresh_all();
        let connections = self
            .connections
            .values()
            .map(ManagedConnection::status)
            .collect::<Vec<_>>();
        ServiceSnapshot {
            aggregate_health: aggregate_health(&connections),
            connections,
        }
    }

    pub fn status(&mut self, name: &str) -> Option<ConnectionStatus> {
        self.refresh_all();
        self.connections.get(name).map(ManagedConnection::status)
    }

    pub fn refresh_connection(&mut self, name: &str) -> Result<ConnectionStatus> {
        {
            let connection = self
                .connections
                .get_mut(name)
                .ok_or_else(|| anyhow!("unknown connection: {name}"))?;
            connection.stop();
            connection.restart_suppressed = false;
            connection.next_retry_at = None;
            connection.last_error = None;
            connection.ensure_started();
        }
        self.refresh_all();
        self.connections
            .get(name)
            .map(ManagedConnection::status)
            .ok_or_else(|| anyhow!("unknown connection: {name}"))
    }

    pub fn stop_connection(&mut self, name: &str) -> Result<ConnectionStatus> {
        let connection = self
            .connections
            .get_mut(name)
            .ok_or_else(|| anyhow!("unknown connection: {name}"))?;
        connection.restart_suppressed = true;
        connection.next_retry_at = None;
        connection.stop();
        Ok(connection.status())
    }

    pub fn reload(&mut self, config: ConfigFile) {
        let mut next = BTreeMap::new();

        for connection in config.connections {
            let name = connection.name.clone();
            let managed = match self.connections.remove(&name) {
                Some(existing) if existing.config == connection => existing,
                Some(mut existing) => {
                    existing.stop();
                    ManagedConnection::new(connection)
                }
                None => ManagedConnection::new(connection),
            };
            next.insert(name, managed);
        }

        for (_, mut removed) in std::mem::take(&mut self.connections) {
            removed.stop();
        }

        self.connections = next;

        for connection in self.connections.values_mut() {
            if !connection.restart_suppressed && connection.config.auto_start {
                connection.ensure_started();
            }
        }
    }

    pub fn tick(&mut self) {
        self.refresh_all();
        for connection in self.connections.values_mut() {
            connection.tick();
        }
    }

    fn refresh_all(&mut self) {
        for connection in self.connections.values_mut() {
            connection.refresh_runtime();
        }
    }
}

impl ManagedConnection {
    fn new(config: ConnectionConfig) -> Self {
        Self {
            config,
            child: None,
            process_id: None,
            process_alive: false,
            port_reachable: false,
            restart_suppressed: false,
            last_error: None,
            next_retry_at: None,
            last_started_at: None,
        }
    }

    fn ensure_started(&mut self) {
        if self.restart_suppressed || self.child.is_some() {
            return;
        }

        let log_prefix = format!("[{}]", self.config.name);
        eprintln!("{} Attempting to start connection...", log_prefix);

        match ssh::spawn_connection(&self.config, &log_prefix) {
            Ok(child) => {
                let pid = child.id();
                eprintln!(
                    "{} Connection started successfully (PID: {})",
                    log_prefix, pid
                );
                self.process_id = Some(pid);
                self.child = Some(child);
                self.process_alive = true;
                self.port_reachable = false;
                self.last_error = None;
                self.next_retry_at = None;
                self.last_started_at = Some(Instant::now());
            }
            Err(error) => {
                eprintln!("{} Failed to start connection: {}", log_prefix, error);
                self.child = None;
                self.process_id = None;
                self.process_alive = false;
                self.port_reachable = false;
                self.last_error = Some(error.to_string());
                self.next_retry_at =
                    Some(Instant::now() + Duration::from_secs(self.config.reconnect_delay_seconds));
                self.last_started_at = None;
            }
        }
    }

    fn refresh_runtime(&mut self) {
        let log_prefix = format!("[{}]", self.config.name);

        if let Some(child) = self.child.as_mut() {
            match health::is_process_alive(child) {
                Ok(alive) => {
                    if !alive {
                        eprintln!(
                            "{} SSH process (PID: {:?}) has exited",
                            log_prefix, self.process_id
                        );
                        self.process_alive = false;
                        self.last_error = Some("ssh process exited".to_string());
                        self.child = None;
                        self.process_id = None;
                        self.port_reachable = false;
                        self.schedule_retry();
                        return;
                    }
                }
                Err(error) => {
                    eprintln!("{} Error checking process health: {}", log_prefix, error);
                    self.process_alive = false;
                    self.last_error = Some(error.to_string());
                    self.child = None;
                    self.process_id = None;
                    self.port_reachable = false;
                    self.schedule_retry();
                    return;
                }
            }

            let was_reachable = self.port_reachable;
            self.port_reachable = health::can_reach_local_port(self.config.local_port);

            if !was_reachable && self.port_reachable {
                eprintln!(
                    "{} Port {} is now reachable",
                    log_prefix, self.config.local_port
                );
            } else if was_reachable && !self.port_reachable {
                eprintln!(
                    "{} Port {} is no longer reachable",
                    log_prefix, self.config.local_port
                );
            }

            if !self.port_reachable
                && self
                    .last_started_at
                    .map(|started| {
                        started.elapsed()
                            >= Duration::from_secs(self.config.startup_grace_period_secs())
                    })
                    .unwrap_or(true)
            {
                eprintln!(
                    "{} Port {} not reachable after {}s grace period - terminating SSH process",
                    log_prefix,
                    self.config.local_port,
                    self.config.startup_grace_period_secs()
                );
                self.last_error = Some(format!(
                    "forwarded port {} is not reachable after {}s startup grace period",
                    self.config.local_port,
                    self.config.startup_grace_period_secs()
                ));
                self.stop();
                self.schedule_retry();
            }
        } else {
            if self.process_alive {
                eprintln!(
                    "{} Process no longer tracked but was marked alive",
                    log_prefix
                );
            }
            self.process_alive = false;
            self.port_reachable = false;
        }
    }

    fn schedule_retry(&mut self) {
        let log_prefix = format!("[{}]", self.config.name);

        if self.restart_suppressed || !self.config.auto_start {
            eprintln!(
                "{} Retry suppressed (restart_suppressed={}, auto_start={})",
                log_prefix, self.restart_suppressed, self.config.auto_start
            );
            self.next_retry_at = None;
            return;
        }

        let retry_at = Instant::now() + Duration::from_secs(self.config.reconnect_delay_seconds);
        eprintln!(
            "{} Scheduling retry in {} seconds (at {:?})",
            log_prefix, self.config.reconnect_delay_seconds, retry_at
        );
        self.next_retry_at = Some(retry_at);
    }

    fn tick(&mut self) {
        if self.restart_suppressed || self.child.is_some() {
            return;
        }

        if !self.config.auto_start && self.next_retry_at.is_none() {
            return;
        }

        let should_start = match self.next_retry_at {
            Some(deadline) => Instant::now() >= deadline,
            None => self.config.auto_start,
        };

        if should_start {
            self.ensure_started();
        }
    }

    fn stop(&mut self) {
        let log_prefix = format!("[{}]", self.config.name);

        if let Some(mut child) = self.child.take() {
            let pid = self.process_id;
            eprintln!("{} Stopping SSH process (PID: {:?})", log_prefix, pid);
            if let Err(e) = child.kill() {
                eprintln!("{} Failed to kill SSH process: {}", log_prefix, e);
            }
            if let Err(e) = child.wait() {
                eprintln!("{} Failed to wait for SSH process: {}", log_prefix, e);
            } else {
                eprintln!("{} SSH process (PID: {:?}) stopped", log_prefix, pid);
            }
        }

        self.process_id = None;
        self.process_alive = false;
        self.port_reachable = false;
        self.last_started_at = None;
    }

    fn status(&self) -> ConnectionStatus {
        let state = if self.restart_suppressed {
            ConnectionState::Stopped
        } else if self.process_alive && self.port_reachable {
            ConnectionState::Healthy
        } else if self.process_alive {
            ConnectionState::Starting
        } else if self.next_retry_at.is_some() {
            ConnectionState::WaitingToRetry
        } else {
            ConnectionState::Failed
        };

        ConnectionStatus {
            name: self.config.name.clone(),
            ssh_host: self.config.ssh_host.clone(),
            local_port: self.config.local_port,
            remote_host: self.config.remote_host.clone(),
            remote_port: self.config.remote_port,
            auto_start: self.config.auto_start,
            reconnect_delay_seconds: self.config.reconnect_delay_seconds,
            process_id: self.process_id,
            process_alive: self.process_alive,
            port_reachable: self.port_reachable,
            state,
            restart_suppressed: self.restart_suppressed,
            last_error: self.last_error.clone(),
            next_retry_in_seconds: self
                .next_retry_at
                .map(|deadline| deadline.saturating_duration_since(Instant::now()).as_secs()),
        }
    }
}

impl Drop for ManagedConnection {
    fn drop(&mut self) {
        self.stop();
    }
}

pub fn require_name(name: Option<String>, action: &str) -> Result<String> {
    match name {
        Some(name) if !name.trim().is_empty() => Ok(name),
        _ => bail!("{action} requires a connection name"),
    }
}

#[cfg(test)]
mod tests {
    use crate::ipc::ConnectionState;

    use crate::config::{ConfigFile, ConnectionConfig};

    use super::{require_name, AppState};

    fn config(auto_start: bool) -> ConfigFile {
        ConfigFile {
            connections: vec![ConnectionConfig {
                name: "postgres".to_string(),
                ssh_host: "box".to_string(),
                local_port: 15432,
                remote_host: "127.0.0.1".to_string(),
                remote_port: 5432,
                auto_start,
                reconnect_delay_seconds: 10,
                startup_grace_period_seconds: None,
            }],
        }
    }

    #[test]
    fn stop_marks_connection_as_suppressed() {
        let mut state = AppState::new(config(false));
        let status = state.stop_connection("postgres").unwrap();
        assert!(status.restart_suppressed);
        assert_eq!(status.state, ConnectionState::Stopped);
    }

    #[test]
    fn reload_preserves_stopped_state_for_unchanged_connection() {
        let mut state = AppState::new(config(false));
        let _ = state.stop_connection("postgres").unwrap();
        state.reload(config(false));
        let status = state.status("postgres").unwrap();
        assert!(status.restart_suppressed);
        assert_eq!(status.state, ConnectionState::Stopped);
    }

    #[test]
    fn status_defaults_to_failed_for_idle_manual_connection() {
        let mut state = AppState::new(config(false));

        let status = state.status("postgres").unwrap();

        assert_eq!(status.state, ConnectionState::Failed);
        assert!(!status.restart_suppressed);
        assert_eq!(status.next_retry_in_seconds, None);
    }

    #[test]
    fn stop_unknown_connection_returns_error() {
        let mut state = AppState::new(config(false));

        let error = state.stop_connection("missing").unwrap_err().to_string();

        assert!(error.contains("unknown connection: missing"));
    }

    #[test]
    fn refresh_unknown_connection_returns_error() {
        let mut state = AppState::new(config(false));

        let error = state.refresh_connection("missing").unwrap_err().to_string();

        assert!(error.contains("unknown connection: missing"));
    }

    #[test]
    fn require_name_accepts_non_blank_names() {
        let name = require_name(Some("postgres".to_string()), "status").unwrap();
        assert_eq!(name, "postgres");
    }

    #[test]
    fn require_name_rejects_missing_or_blank_names() {
        let missing = require_name(None, "status").unwrap_err().to_string();
        assert!(missing.contains("status requires a connection name"));

        let blank = require_name(Some("   ".to_string()), "refresh")
            .unwrap_err()
            .to_string();
        assert!(blank.contains("refresh requires a connection name"));
    }
}
