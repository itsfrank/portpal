use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};

use crate::config::{initialize_config, validate_config_file};
use crate::daemon;
use crate::ipc::{
    ConnectionState, PortpalRequest, PortpalResponse, RequestAction, ServiceSnapshot,
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
