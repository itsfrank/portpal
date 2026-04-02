use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::Command as ProcessCommand;

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};

use crate::config::{initialize_config, validate_config_file, ConfigFile};
use crate::daemon;
use crate::ipc::{
    ConnectionState, ConnectionStatus, PortpalRequest, PortpalResponse, RequestAction,
    ServiceSnapshot,
};
use crate::paths;

#[derive(Parser)]
#[command(name = "portpal")]
#[command(about = "Manage Portpal SSH connections")]
pub struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Serve,
    List,
    Debug,
    Status {
        name: String,
    },
    Refresh {
        name: String,
    },
    Stop {
        name: String,
    },
    Reload,
    ValidateConfig,
    Config {
        #[command(subcommand)]
        command: ConfigCommand,
    },
}

#[derive(Subcommand)]
enum ConfigCommand {
    Path,
    Init,
}

pub fn run() -> Result<()> {
    let cli = Cli::parse();
    let config_path = paths::config_path()?;
    let socket_path = paths::socket_path()?;

    match cli.command {
        Command::Serve => daemon::serve(config_path, socket_path),
        Command::List => {
            let response = send(PortpalRequest {
                action: RequestAction::List,
                name: None,
            })?;
            let snapshot = response.snapshot.context("missing snapshot")?;
            print_snapshot(&snapshot);
            Ok(())
        }
        Command::Debug => print_debug(&config_path),
        Command::Status { name } => {
            let response = send(PortpalRequest {
                action: RequestAction::Status,
                name: Some(name.clone()),
            })?;
            let status = response.status.context("missing status")?;
            print_status(&status);
            if status.state == ConnectionState::Healthy {
                Ok(())
            } else {
                bail!("{} is {:?}", status.name, status.state);
            }
        }
        Command::Refresh { name } => {
            let response = send(PortpalRequest {
                action: RequestAction::Refresh,
                name: Some(name),
            })?;
            let status = response.status.context("missing status")?;
            print_status(&status);
            Ok(())
        }
        Command::Stop { name } => {
            let response = send(PortpalRequest {
                action: RequestAction::Stop,
                name: Some(name),
            })?;
            let status = response.status.context("missing status")?;
            print_status(&status);
            Ok(())
        }
        Command::Reload => {
            let response = send(PortpalRequest {
                action: RequestAction::Reload,
                name: None,
            })?;
            if let Some(message) = response.message {
                println!("{message}");
            }
            if let Some(snapshot) = response.snapshot {
                print_snapshot(&snapshot);
            }
            Ok(())
        }
        Command::ValidateConfig => {
            validate_config_file(&config_path)?;
            println!("config is valid: {}", config_path.display());
            Ok(())
        }
        Command::Config {
            command: ConfigCommand::Path,
        } => {
            println!("{}", config_path.display());
            Ok(())
        }
        Command::Config {
            command: ConfigCommand::Init,
        } => {
            initialize_config(&config_path)?;
            println!("initialized config at {}", config_path.display());
            Ok(())
        }
    }
}

fn send(request: PortpalRequest) -> Result<PortpalResponse> {
    let socket_path = paths::socket_path()?;
    let mut stream = UnixStream::connect(&socket_path).with_context(|| {
        format!(
            "failed to connect to {}. Start the daemon with `brew services start portpal` or run `portpal serve`.",
            socket_path.display()
        )
    })?;

    let payload = serde_json::to_vec(&request)?;
    stream.write_all(&payload)?;
    stream.shutdown(std::net::Shutdown::Write)?;

    let mut response = Vec::new();
    stream.read_to_end(&mut response)?;
    let response: PortpalResponse = serde_json::from_slice(&response)?;
    if !response.ok {
        return Err(anyhow!(response
            .message
            .unwrap_or_else(|| "request failed".to_string())));
    }
    Ok(response)
}

fn print_snapshot(snapshot: &ServiceSnapshot) {
    if snapshot.connections.is_empty() {
        println!("No configured connections.");
        return;
    }

    for connection in &snapshot.connections {
        print_status(connection);
    }
}

fn print_status(status: &crate::ipc::ConnectionStatus) {
    let extra = status
        .next_retry_in_seconds
        .map(|seconds| format!(", retry in {}s", seconds))
        .unwrap_or_default();
    let error = status
        .last_error
        .as_ref()
        .map(|message| format!(", error: {}", message))
        .unwrap_or_default();

    println!(
        "{} [{:?}] {}:{} -> {}:{}{}{}",
        status.name,
        status.state,
        status.ssh_host,
        status.local_port,
        status.remote_host,
        status.remote_port,
        extra,
        error,
    );
}

fn print_debug(config_path: &std::path::Path) -> Result<()> {
    let socket_path = paths::socket_path()?;
    let config = ConfigFile::load(config_path)?;
    let daemons = detect_portpal_daemons()?;
    let socket_owners = socket_owner_pids(&socket_path)?;

    println!("Config: {}", config_path.display());
    println!("Socket: {}", socket_path.display());

    if daemons.is_empty() {
        println!("Daemons: none");
    } else if daemons.len() == 1 {
        println!("Daemons: 1 ({})", format_process(&daemons[0]));
    } else {
        println!("Daemons: {}", daemons.len());
        for process in &daemons {
            println!("- {}", format_process(process));
        }
    }

    if socket_owners.is_empty() {
        println!("Socket owners: none");
    } else {
        println!(
            "Socket owners: {}",
            socket_owners
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    let snapshot = send(PortpalRequest {
        action: RequestAction::List,
        name: None,
    })
    .ok()
    .and_then(|response| response.snapshot);

    match snapshot {
        Some(snapshot) => {
            if config.connections.is_empty() {
                println!("Connections: none configured");
                return Ok(());
            }

            println!("Connections:");
            for config_connection in &config.connections {
                let status = snapshot
                    .connections
                    .iter()
                    .find(|status| status.name == config_connection.name);

                match status {
                    Some(status) => print_debug_status(status)?,
                    None => println!("- {}: missing from daemon snapshot", config_connection.name),
                }
            }
        }
        None => {
            println!("Connections: daemon unavailable");
            for config_connection in &config.connections {
                println!(
                    "- {}: unable to query daemon status",
                    config_connection.name
                );
            }
        }
    }

    Ok(())
}

fn print_debug_status(status: &ConnectionStatus) -> Result<()> {
    let listeners = listening_processes(status.local_port)?;
    println!(
        "- {}: {:?} (pid: {}, local port: {})",
        status.name,
        status.state,
        status
            .process_id
            .map(|pid| pid.to_string())
            .unwrap_or_else(|| "none".to_string()),
        status.local_port
    );

    if status.state == ConnectionState::Healthy {
        println!("  healthy");
        return Ok(());
    }

    println!("  {}", explain_unhealthy_status(status, &listeners));

    if !listeners.is_empty() {
        println!(
            "  listeners on {}: {}",
            status.local_port,
            listeners
                .iter()
                .map(format_process)
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ProcessInfo {
    pid: u32,
    command: String,
}

fn detect_portpal_daemons() -> Result<Vec<ProcessInfo>> {
    let output = ProcessCommand::new("/bin/ps")
        .args(["-axo", "pid=,command="])
        .output()
        .context("failed to inspect running processes")?;

    if !output.status.success() {
        bail!("ps failed while inspecting running processes");
    }

    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(parse_process_line)
        .filter(|process| is_portpal_daemon_command(&process.command))
        .collect())
}

fn socket_owner_pids(socket_path: &std::path::Path) -> Result<Vec<u32>> {
    let output = ProcessCommand::new("/usr/sbin/lsof")
        .arg("-t")
        .arg(socket_path)
        .output()
        .with_context(|| format!("failed to inspect {}", socket_path.display()))?;

    if !output.status.success() && !output.stdout.is_empty() {
        bail!("lsof failed while inspecting {}", socket_path.display());
    }

    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse::<u32>().ok())
        .collect())
}

fn listening_processes(port: u16) -> Result<Vec<ProcessInfo>> {
    let output = ProcessCommand::new("/usr/sbin/lsof")
        .args(["-nP", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-Fpc"])
        .output()
        .with_context(|| format!("failed to inspect listeners on port {port}"))?;

    if !output.status.success() && !output.stdout.is_empty() {
        bail!("lsof failed while inspecting listeners on port {port}");
    }

    Ok(parse_lsof_processes(&String::from_utf8_lossy(
        &output.stdout,
    )))
}

fn parse_process_line(line: &str) -> Option<ProcessInfo> {
    let trimmed = line.trim();
    let mut parts = trimmed.splitn(2, char::is_whitespace);
    let pid = parts.next()?.trim().parse().ok()?;
    let command = parts.next()?.trim();
    if command.is_empty() {
        return None;
    }
    Some(ProcessInfo {
        pid,
        command: command.to_string(),
    })
}

fn is_portpal_daemon_command(command: &str) -> bool {
    (command.contains("portpal serve") || command.contains("PortpalService serve"))
        && !command.contains("portpal-test-ssh")
}

fn parse_lsof_processes(output: &str) -> Vec<ProcessInfo> {
    let mut processes = Vec::new();
    let mut current_pid = None;
    let mut current_command = None;

    for line in output.lines() {
        if let Some(pid_text) = line.strip_prefix('p') {
            if let (Some(pid), Some(command)) = (current_pid.take(), current_command.take()) {
                processes.push(ProcessInfo { pid, command });
            }
            if let Some(pid) = pid_text.parse::<u32>().ok() {
                current_pid = Some(pid);
                current_command = None;
            }
        } else if let Some(command) = line.strip_prefix('c') {
            current_command = Some(command.to_string());
        }
    }

    if let (Some(pid), Some(command)) = (current_pid.take(), current_command.take()) {
        processes.push(ProcessInfo { pid, command });
    }

    processes.sort_by_key(|process| process.pid);
    processes.dedup_by_key(|process| process.pid);
    processes
}

fn format_process(process: &ProcessInfo) -> String {
    format!("pid {} ({})", process.pid, process.command)
}

fn explain_unhealthy_status(status: &ConnectionStatus, listeners: &[ProcessInfo]) -> String {
    match status.state {
        ConnectionState::Healthy => "healthy".to_string(),
        ConnectionState::Stopped => "restart is suppressed".to_string(),
        ConnectionState::WaitingToRetry => {
            if let Some(error) = &status.last_error {
                if listeners.is_empty() {
                    format!("waiting to retry because {error}")
                } else {
                    format!(
                        "waiting to retry because {error}; local port is currently held by another process"
                    )
                }
            } else if let Some(seconds) = status.next_retry_in_seconds {
                format!("waiting {}s before the next retry", seconds)
            } else {
                "waiting for the next retry".to_string()
            }
        }
        ConnectionState::Starting => {
            let conflicting_listeners = listeners
                .iter()
                .filter(|listener| Some(listener.pid) != status.process_id)
                .collect::<Vec<_>>();
            if !conflicting_listeners.is_empty() {
                format!(
                    "tunnel process is running but the local port is held by {}",
                    conflicting_listeners
                        .iter()
                        .map(|listener| listener.pid.to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            } else if let Some(error) = &status.last_error {
                format!("tunnel process is starting; last error: {error}")
            } else {
                "tunnel process is running but the forwarded port is not reachable yet".to_string()
            }
        }
        ConnectionState::Failed => {
            if let Some(error) = &status.last_error {
                if listeners.is_empty() {
                    format!("failed because {error}")
                } else {
                    format!("failed because {error}; local port is held by another process")
                }
            } else if !listeners.is_empty() {
                "failed and the local port is held by another process".to_string()
            } else {
                "failed for an unknown reason".to_string()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        explain_unhealthy_status, is_portpal_daemon_command, parse_lsof_processes,
        parse_process_line, ProcessInfo,
    };
    use crate::ipc::{ConnectionState, ConnectionStatus};

    fn status(state: ConnectionState) -> ConnectionStatus {
        ConnectionStatus {
            name: "docker-http".to_string(),
            ssh_host: "portpal-docker".to_string(),
            local_port: 18080,
            remote_host: "127.0.0.1".to_string(),
            remote_port: 8080,
            auto_start: true,
            reconnect_delay_seconds: 5,
            process_id: Some(123),
            process_alive: false,
            port_reachable: false,
            state,
            restart_suppressed: false,
            last_error: None,
            next_retry_in_seconds: None,
        }
    }

    #[test]
    fn parse_process_line_extracts_pid_and_command() {
        let process =
            parse_process_line(" 42524 /opt/homebrew/opt/portpal/bin/portpal serve").unwrap();
        assert_eq!(process.pid, 42524);
        assert_eq!(
            process.command,
            "/opt/homebrew/opt/portpal/bin/portpal serve"
        );
    }

    #[test]
    fn daemon_command_detection_ignores_test_helper() {
        assert!(is_portpal_daemon_command(
            "/opt/homebrew/opt/portpal/bin/portpal serve"
        ));
        assert!(is_portpal_daemon_command(
            "./.build/debug/PortpalService serve"
        ));
        assert!(!is_portpal_daemon_command(
            "/Users/frk/dev/portpal/target/debug/portpal-test-ssh -N"
        ));
    }

    #[test]
    fn parse_lsof_processes_extracts_unique_processes() {
        let processes = parse_lsof_processes("p42045\ncssh\np42045\ncssh\np42524\ncportpal\n");
        assert_eq!(
            processes,
            vec![
                ProcessInfo {
                    pid: 42045,
                    command: "ssh".to_string()
                },
                ProcessInfo {
                    pid: 42524,
                    command: "portpal".to_string()
                }
            ]
        );
    }

    #[test]
    fn waiting_to_retry_mentions_port_holder_when_present() {
        let mut status = status(ConnectionState::WaitingToRetry);
        status.last_error = Some("ssh process exited".to_string());

        let reason = explain_unhealthy_status(
            &status,
            &[ProcessInfo {
                pid: 42045,
                command: "ssh".to_string(),
            }],
        );

        assert!(reason.contains("ssh process exited"));
        assert!(reason.contains("held by another process"));
    }

    #[test]
    fn starting_mentions_conflicting_listener_pid() {
        let mut status = status(ConnectionState::Starting);
        status.process_id = Some(123);

        let reason = explain_unhealthy_status(
            &status,
            &[
                ProcessInfo {
                    pid: 123,
                    command: "ssh".to_string(),
                },
                ProcessInfo {
                    pid: 42045,
                    command: "ssh".to_string(),
                },
            ],
        );

        assert!(reason.contains("42045"));
    }
}
