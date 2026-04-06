use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

use crate::config::ConnectionConfig;

pub fn spawn_connection(connection: &ConnectionConfig, log_prefix: &str) -> Result<Child> {
    terminate_stale_portpal_listener(connection)?;

    let ssh_bin = ssh_binary();
    let forward_spec = format!(
        "{}:{}:{}",
        connection.local_port, connection.remote_host, connection.remote_port
    );

    eprintln!(
        "{} Spawning SSH connection: {} -L {} {}",
        log_prefix, ssh_bin, forward_spec, connection.ssh_host
    );

    let mut cmd = Command::new(&ssh_bin);
    cmd.arg("-N")
        .arg("-o")
        .arg("ExitOnForwardFailure=yes")
        .arg("-o")
        .arg("ServerAliveInterval=30")
        .arg("-o")
        .arg("ServerAliveCountMax=3")
        .arg("-L")
        .arg(&forward_spec)
        .arg(&connection.ssh_host)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());

    let mut child = cmd.spawn().with_context(|| {
        format!(
            "{} failed to start ssh process for {}",
            log_prefix, connection.name
        )
    })?;

    let pid = child.id();
    eprintln!(
        "{} SSH process started with PID {} for {}",
        log_prefix, pid, connection.name
    );

    // Capture stderr in a separate thread to log any immediate errors
    if let Some(stderr) = child.stderr.take() {
        let name = connection.name.clone();
        let prefix = log_prefix.to_string();
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().flatten() {
                if !line.trim().is_empty() {
                    eprintln!("{} SSH stderr [{}]: {}", prefix, name, line);
                }
            }
        });
    }

    // Give the process a moment to fail immediately (e.g., bad host key, auth failure)
    thread::sleep(Duration::from_millis(500));

    match child.try_wait() {
        Ok(Some(status)) => {
            bail!(
                "{} SSH process exited immediately with status {} for {}",
                log_prefix,
                status,
                connection.name
            );
        }
        Ok(None) => {
            eprintln!(
                "{} SSH process {} still running after startup check",
                log_prefix, pid
            );
        }
        Err(e) => {
            eprintln!("{} Failed to check SSH process status: {}", log_prefix, e);
        }
    }

    Ok(child)
}

fn ssh_binary() -> String {
    std::env::var("PORTPAL_SSH_BIN").unwrap_or_else(|_| "/usr/bin/ssh".to_string())
}

fn terminate_stale_portpal_listener(connection: &ConnectionConfig) -> Result<()> {
    let ssh_bin = ssh_binary();
    let forward_spec = format!(
        "{}:{}:{}",
        connection.local_port, connection.remote_host, connection.remote_port
    );

    for pid in listening_pids(connection.local_port)? {
        let command_line = command_line_for_pid(pid)?;
        if !matches_connection_process(&command_line, &ssh_bin, &forward_spec, connection) {
            continue;
        }

        terminate_pid(pid).with_context(|| {
            format!(
                "failed to terminate stale tunnel process {pid} for {}",
                connection.name
            )
        })?;
    }

    Ok(())
}

fn listening_pids(port: u16) -> Result<Vec<u32>> {
    let output = Command::new("/usr/sbin/lsof")
        .args(["-nP", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-t"])
        .output()
        .context("failed to inspect listening local ports")?;

    if !output.status.success() && !output.stdout.is_empty() {
        bail!("lsof failed while inspecting port {port}");
    }

    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse::<u32>().ok())
        .collect())
}

fn command_line_for_pid(pid: u32) -> Result<String> {
    let output = Command::new("/bin/ps")
        .args(["-o", "command=", "-p", &pid.to_string()])
        .output()
        .with_context(|| format!("failed to inspect process {pid}"))?;

    if !output.status.success() {
        bail!("ps failed for pid {pid}");
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn matches_connection_process(
    command_line: &str,
    ssh_bin: &str,
    forward_spec: &str,
    connection: &ConnectionConfig,
) -> bool {
    if command_line.is_empty() {
        return false;
    }

    command_line.contains(ssh_bin)
        && command_line.contains("-N")
        && command_line.contains("ExitOnForwardFailure=yes")
        && command_line.contains(&format!("-L {forward_spec}"))
        && command_line.contains(&connection.ssh_host)
}

fn terminate_pid(pid: u32) -> Result<()> {
    let pid_text = pid.to_string();
    let term_output = Command::new("/bin/kill")
        .args(["-TERM", &pid_text])
        .output()
        .with_context(|| format!("failed to signal pid {pid}"))?;

    if !term_output.status.success() {
        bail!("kill -TERM failed for pid {pid}");
    }

    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        if !pid_exists(pid)? {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }

    let kill_output = Command::new("/bin/kill")
        .args(["-KILL", &pid_text])
        .output()
        .with_context(|| format!("failed to force kill pid {pid}"))?;

    if !kill_output.status.success() {
        bail!("kill -KILL failed for pid {pid}");
    }

    Ok(())
}

fn pid_exists(pid: u32) -> Result<bool> {
    let output = Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .output()
        .with_context(|| format!("failed to probe pid {pid}"))?;

    Ok(output.status.success())
}
