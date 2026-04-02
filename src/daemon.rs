use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};

use crate::config::ConfigFile;
use crate::ipc::{PortpalRequest, PortpalResponse, RequestAction};
use crate::state::{require_name, AppState};

pub fn serve(config_path: PathBuf, socket_path: PathBuf) -> Result<()> {
    let initial_config = ConfigFile::load(&config_path)?;
    let state = Arc::new(Mutex::new(AppState::new(initial_config)));
    state
        .lock()
        .map_err(|_| anyhow!("state lock poisoned"))?
        .start_auto_connections();

    let health_state = Arc::clone(&state);
    thread::spawn(move || loop {
        thread::sleep(Duration::from_secs(1));
        if let Ok(mut state) = health_state.lock() {
            state.tick();
        }
    });

    if socket_path.exists() {
        fs::remove_file(&socket_path)
            .with_context(|| format!("failed to remove {}", socket_path.display()))?;
    }

    let listener = UnixListener::bind(&socket_path)
        .with_context(|| format!("failed to bind {}", socket_path.display()))?;

    for stream in listener.incoming() {
        let mut stream = match stream {
            Ok(stream) => stream,
            Err(_) => continue,
        };

        let response = match read_request(&mut stream)
            .and_then(|request| handle_request(&state, &config_path, request))
        {
            Ok(response) => response,
            Err(error) => PortpalResponse {
                ok: false,
                message: Some(error.to_string()),
                snapshot: None,
                status: None,
                config_path: None,
            },
        };

        let payload = serde_json::to_vec(&response)?;
        stream.write_all(&payload)?;
    }

    Ok(())
}

fn read_request(stream: &mut impl Read) -> Result<PortpalRequest> {
    let mut payload = Vec::new();
    stream.read_to_end(&mut payload)?;
    let request = serde_json::from_slice(&payload).context("invalid request")?;
    Ok(request)
}

fn handle_request(
    state: &Arc<Mutex<AppState>>,
    config_path: &PathBuf,
    request: PortpalRequest,
) -> Result<PortpalResponse> {
    let mut state = state.lock().map_err(|_| anyhow!("state lock poisoned"))?;

    match request.action {
        RequestAction::List => Ok(PortpalResponse {
            ok: true,
            message: None,
            snapshot: Some(state.snapshot()),
            status: None,
            config_path: None,
        }),
        RequestAction::Status => {
            let name = require_name(request.name, "status")?;
            let status = state
                .status(&name)
                .ok_or_else(|| anyhow!("unknown connection: {name}"))?;
            Ok(PortpalResponse {
                ok: true,
                message: None,
                snapshot: None,
                status: Some(status),
                config_path: None,
            })
        }
        RequestAction::Refresh => {
            let name = require_name(request.name, "refresh")?;
            let status = state.refresh_connection(&name)?;
            Ok(PortpalResponse {
                ok: true,
                message: Some(format!("refreshed {name}")),
                snapshot: None,
                status: Some(status),
                config_path: None,
            })
        }
        RequestAction::Stop => {
            let name = require_name(request.name, "stop")?;
            let status = state.stop_connection(&name)?;
            Ok(PortpalResponse {
                ok: true,
                message: Some(format!("stopped {name}")),
                snapshot: None,
                status: Some(status),
                config_path: None,
            })
        }
        RequestAction::Reload => {
            let config = ConfigFile::load(config_path)?;
            state.reload(config);
            Ok(PortpalResponse {
                ok: true,
                message: Some("reloaded config".to_string()),
                snapshot: Some(state.snapshot()),
                status: None,
                config_path: None,
            })
        }
        RequestAction::ConfigPath => Ok(PortpalResponse {
            ok: true,
            message: None,
            snapshot: None,
            status: None,
            config_path: Some(config_path.display().to_string()),
        }),
    }
}
