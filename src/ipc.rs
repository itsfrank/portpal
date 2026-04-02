use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortpalRequest {
    pub action: RequestAction,
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortpalResponse {
    pub ok: bool,
    pub message: Option<String>,
    pub snapshot: Option<ServiceSnapshot>,
    pub status: Option<ConnectionStatus>,
    pub config_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RequestAction {
    List,
    Status,
    Refresh,
    Stop,
    Reload,
    ConfigPath,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConnectionState {
    Healthy,
    Starting,
    WaitingToRetry,
    Stopped,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AggregateHealth {
    Empty,
    AllHealthy,
    NoneHealthy,
    Mixed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionStatus {
    pub name: String,
    pub ssh_host: String,
    pub local_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
    pub auto_start: bool,
    pub reconnect_delay_seconds: u64,
    pub process_id: Option<u32>,
    pub process_alive: bool,
    pub port_reachable: bool,
    pub state: ConnectionState,
    pub restart_suppressed: bool,
    pub last_error: Option<String>,
    pub next_retry_in_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceSnapshot {
    pub connections: Vec<ConnectionStatus>,
    pub aggregate_health: AggregateHealth,
}

pub fn aggregate_health(statuses: &[ConnectionStatus]) -> AggregateHealth {
    if statuses.is_empty() {
        return AggregateHealth::Empty;
    }

    let healthy_count = statuses
        .iter()
        .filter(|status| status.state == ConnectionState::Healthy)
        .count();

    if healthy_count == statuses.len() {
        AggregateHealth::AllHealthy
    } else if healthy_count == 0 {
        AggregateHealth::NoneHealthy
    } else {
        AggregateHealth::Mixed
    }
}

#[cfg(test)]
mod tests {
    use super::{aggregate_health, AggregateHealth, ConnectionState, ConnectionStatus};

    fn status(state: ConnectionState) -> ConnectionStatus {
        ConnectionStatus {
            name: "db".to_string(),
            ssh_host: "box".to_string(),
            local_port: 15432,
            remote_host: "127.0.0.1".to_string(),
            remote_port: 5432,
            auto_start: true,
            reconnect_delay_seconds: 10,
            process_id: None,
            process_alive: false,
            port_reachable: false,
            state,
            restart_suppressed: false,
            last_error: None,
            next_retry_in_seconds: None,
        }
    }

    #[test]
    fn aggregate_is_empty_for_no_connections() {
        let aggregate = aggregate_health(&[]);
        assert_eq!(aggregate, AggregateHealth::Empty);
    }

    #[test]
    fn aggregate_is_all_healthy_when_every_connection_is_healthy() {
        let aggregate = aggregate_health(&[
            status(ConnectionState::Healthy),
            status(ConnectionState::Healthy),
        ]);

        assert_eq!(aggregate, AggregateHealth::AllHealthy);
    }

    #[test]
    fn aggregate_is_none_healthy_when_no_connections_are_healthy() {
        let aggregate = aggregate_health(&[
            status(ConnectionState::Starting),
            status(ConnectionState::Failed),
        ]);

        assert_eq!(aggregate, AggregateHealth::NoneHealthy);
    }

    #[test]
    fn aggregate_is_mixed_when_some_are_healthy() {
        let aggregate = aggregate_health(&[
            status(ConnectionState::Healthy),
            status(ConnectionState::Failed),
        ]);

        assert_eq!(aggregate, AggregateHealth::Mixed);
    }
}
