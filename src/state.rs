use std::collections::BTreeMap;
use std::process::Child;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};

use crate::config::{ConfigFile, ConnectionConfig};
use crate::health;
use crate::ipc::{aggregate_health, ConnectionState, ConnectionStatus, ServiceSnapshot};
use crate::ssh;

const STARTUP_GRACE_PERIOD: Duration = Duration::from_secs(3);

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

        match ssh::spawn_connection(&self.config) {
            Ok(child) => {
                self.process_id = Some(child.id());
                self.child = Some(child);
                self.process_alive = true;
                self.port_reachable = false;
                self.last_error = None;
                self.next_retry_at = None;
                self.last_started_at = Some(Instant::now());
            }
            Err(error) => {
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
        if let Some(child) = self.child.as_mut() {
            match health::is_process_alive(child) {
                Ok(alive) => {
                    self.process_alive = alive;
                    if !alive {
                        self.last_error = Some("ssh process exited".to_string());
                        self.child = None;
                        self.process_id = None;
                        self.port_reachable = false;
                        self.schedule_retry();
                        return;
                    }
                }
                Err(error) => {
                    self.process_alive = false;
                    self.last_error = Some(error.to_string());
                    self.child = None;
                    self.process_id = None;
                    self.port_reachable = false;
                    self.schedule_retry();
                    return;
                }
            }

            self.port_reachable = health::can_reach_local_port(self.config.local_port);

            if !self.port_reachable
                && self
                    .last_started_at
                    .map(|started| started.elapsed() >= STARTUP_GRACE_PERIOD)
                    .unwrap_or(true)
            {
                self.last_error = Some("forwarded port is not reachable".to_string());
                self.stop();
                self.schedule_retry();
            }
        } else {
            self.process_alive = false;
            self.port_reachable = false;
        }
    }

    fn schedule_retry(&mut self) {
        if self.restart_suppressed || !self.config.auto_start {
            self.next_retry_at = None;
            return;
        }

        self.next_retry_at =
            Some(Instant::now() + Duration::from_secs(self.config.reconnect_delay_seconds));
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
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
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
    use crate::config::{ConfigFile, ConnectionConfig};

    use super::AppState;

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
            }],
        }
    }

    #[test]
    fn stop_marks_connection_as_suppressed() {
        let mut state = AppState::new(config(false));
        let status = state.stop_connection("postgres").unwrap();
        assert!(status.restart_suppressed);
    }

    #[test]
    fn reload_preserves_stopped_state_for_unchanged_connection() {
        let mut state = AppState::new(config(false));
        let _ = state.stop_connection("postgres").unwrap();
        state.reload(config(false));
        let status = state.status("postgres").unwrap();
        assert!(status.restart_suppressed);
    }
}
