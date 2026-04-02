use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::json;

struct TestHome {
    root: PathBuf,
}

impl TestHome {
    fn new(name: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = PathBuf::from(format!("/tmp/pp-{name}-{unique}"));
        fs::create_dir_all(&root).unwrap();
        Self { root }
    }

    fn path(&self) -> &Path {
        &self.root
    }

    fn config_dir(&self) -> PathBuf {
        self.root.join(".config").join("portpal")
    }

    fn config_path(&self) -> PathBuf {
        self.config_dir().join("portpal.toml")
    }

    fn socket_path(&self) -> PathBuf {
        self.config_dir().join("portpal.sock")
    }
}

impl Drop for TestHome {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn bin_path() -> &'static str {
    env!("CARGO_BIN_EXE_portpal")
}

fn test_ssh_bin_path() -> &'static str {
    env!("CARGO_BIN_EXE_portpal-test-ssh")
}

fn run_portpal(home: &TestHome, args: &[&str]) -> Output {
    Command::new(bin_path())
        .args(args)
        .env("HOME", home.path())
        .output()
        .unwrap()
}

fn spawn_daemon(home: &TestHome) -> Child {
    spawn_daemon_with_env(home, &[])
}

fn spawn_daemon_with_env(home: &TestHome, envs: &[(&str, &str)]) -> Child {
    Command::new(bin_path())
        .args(["serve"])
        .env("HOME", home.path())
        .envs(envs.iter().copied())
        .spawn()
        .unwrap()
}

fn wait_for_daemon(home: &TestHome) {
    for _ in 0..50 {
        if home.socket_path().exists() {
            let output = run_portpal(home, &["list"]);
            if output.status.success() {
                return;
            }
        }
        thread::sleep(Duration::from_millis(100));
    }

    panic!(
        "daemon did not become ready at {}",
        home.socket_path().display()
    );
}

fn stop_daemon(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn send_request(home: &TestHome, request: serde_json::Value) -> serde_json::Value {
    let mut stream = UnixStream::connect(home.socket_path()).unwrap();
    stream
        .write_all(&serde_json::to_vec(&request).unwrap())
        .unwrap();
    stream.shutdown(std::net::Shutdown::Write).unwrap();

    let mut response = Vec::new();
    stream.read_to_end(&mut response).unwrap();
    serde_json::from_slice(&response).unwrap()
}

fn status_response(home: &TestHome, name: &str) -> serde_json::Value {
    send_request(home, json!({ "action": "status", "name": name }))
}

fn status_state(home: &TestHome, name: &str) -> String {
    status_response(home, name)["status"]["state"]
        .as_str()
        .unwrap()
        .to_string()
}

fn wait_for_status_state(home: &TestHome, name: &str, expected: &str) -> serde_json::Value {
    for _ in 0..80 {
        let response = status_response(home, name);
        if response["ok"] == true && response["status"]["state"] == expected {
            return response;
        }
        thread::sleep(Duration::from_millis(100));
    }

    panic!("connection {name} did not reach state {expected}");
}

fn wait_for_condition<F>(mut condition: F, message: &str)
where
    F: FnMut() -> bool,
{
    for _ in 0..80 {
        if condition() {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }

    panic!("{message}");
}

fn manual_config(name: &str, local_port: u16, remote_port: u16) -> String {
    format!(
        "[[connections]]\nname = \"{name}\"\nssh_host = \"box\"\nlocal_port = {local_port}\nremote_host = \"127.0.0.1\"\nremote_port = {remote_port}\nauto_start = false\nreconnect_delay_seconds = 10\n"
    )
}

fn auto_config(
    name: &str,
    local_port: u16,
    remote_port: u16,
    reconnect_delay_seconds: u64,
) -> String {
    format!(
        "[[connections]]\nname = \"{name}\"\nssh_host = \"box\"\nlocal_port = {local_port}\nremote_host = \"127.0.0.1\"\nremote_port = {remote_port}\nauto_start = true\nreconnect_delay_seconds = {reconnect_delay_seconds}\n"
    )
}

#[test]
fn config_commands_use_home_scoped_paths() {
    let home = TestHome::new("config-commands");

    let path_output = run_portpal(&home, &["config", "path"]);
    assert!(path_output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&path_output.stdout).trim(),
        home.config_path().display().to_string()
    );

    let init_output = run_portpal(&home, &["config", "init"]);
    assert!(init_output.status.success());
    assert!(home.config_path().exists());

    let validate_output = run_portpal(&home, &["validate-config"]);
    assert!(validate_output.status.success());
    assert!(String::from_utf8_lossy(&validate_output.stdout).contains("config is valid"));

    let second_init_output = run_portpal(&home, &["config", "init"]);
    assert!(!second_init_output.status.success());
    assert!(String::from_utf8_lossy(&second_init_output.stderr).contains("config already exists"));
}

#[test]
fn daemon_serves_cli_requests_and_reloads_config() {
    let home = TestHome::new("daemon-requests");
    fs::create_dir_all(home.config_dir()).unwrap();
    fs::write(home.config_path(), manual_config("postgres", 15432, 5432)).unwrap();

    let mut daemon = spawn_daemon(&home);
    wait_for_daemon(&home);

    let list_output = run_portpal(&home, &["list"]);
    assert!(list_output.status.success());
    assert!(String::from_utf8_lossy(&list_output.stdout)
        .contains("postgres [Failed] box:15432 -> 127.0.0.1:5432"));

    let stop_output = run_portpal(&home, &["stop", "postgres"]);
    assert!(stop_output.status.success());
    assert!(String::from_utf8_lossy(&stop_output.stdout)
        .contains("postgres [Stopped] box:15432 -> 127.0.0.1:5432"));

    let status_output = run_portpal(&home, &["status", "postgres"]);
    assert!(!status_output.status.success());
    assert!(String::from_utf8_lossy(&status_output.stdout)
        .contains("postgres [Stopped] box:15432 -> 127.0.0.1:5432"));
    assert!(String::from_utf8_lossy(&status_output.stderr).contains("postgres is Stopped"));

    let missing_output = run_portpal(&home, &["status", "missing"]);
    assert!(!missing_output.status.success());
    assert!(String::from_utf8_lossy(&missing_output.stderr).contains("unknown connection: missing"));

    fs::write(home.config_path(), manual_config("mysql", 13306, 3306)).unwrap();
    let reload_output = run_portpal(&home, &["reload"]);
    assert!(reload_output.status.success());
    let reload_stdout = String::from_utf8_lossy(&reload_output.stdout);
    assert!(reload_stdout.contains("reloaded config"));
    assert!(reload_stdout.contains("mysql [Failed] box:13306 -> 127.0.0.1:3306"));

    stop_daemon(&mut daemon);
}

#[test]
fn daemon_returns_json_error_for_invalid_socket_payload() {
    let home = TestHome::new("invalid-request");
    fs::create_dir_all(home.config_dir()).unwrap();
    fs::write(home.config_path(), manual_config("postgres", 15432, 5432)).unwrap();

    let mut daemon = spawn_daemon(&home);
    wait_for_daemon(&home);

    let mut stream = UnixStream::connect(home.socket_path()).unwrap();
    stream.write_all(b"{").unwrap();
    stream.shutdown(std::net::Shutdown::Write).unwrap();

    let mut response = Vec::new();
    stream.read_to_end(&mut response).unwrap();

    let response: serde_json::Value = serde_json::from_slice(&response).unwrap();
    assert_eq!(response["ok"], false);
    assert!(response["message"]
        .as_str()
        .unwrap()
        .contains("invalid request"));

    stop_daemon(&mut daemon);
}

#[test]
fn auto_started_connection_enters_starting_before_port_is_reachable() {
    let home = TestHome::new("ssh-starting");
    fs::create_dir_all(home.config_dir()).unwrap();
    fs::write(home.config_path(), auto_config("postgres", 15432, 5432, 1)).unwrap();

    let mut daemon = spawn_daemon_with_env(
        &home,
        &[
            ("PORTPAL_SSH_BIN", test_ssh_bin_path()),
            ("PORTPAL_TEST_SSH_MODE", "hold-open"),
        ],
    );
    wait_for_daemon(&home);

    let response = wait_for_status_state(&home, "postgres", "starting");
    assert_eq!(response["status"]["processAlive"], true);
    assert_eq!(response["status"]["portReachable"], false);

    stop_daemon(&mut daemon);
}

#[test]
fn auto_started_connection_becomes_healthy_when_helper_listens_on_forwarded_port() {
    let home = TestHome::new("ssh-healthy");
    fs::create_dir_all(home.config_dir()).unwrap();
    fs::write(home.config_path(), auto_config("postgres", 15433, 5432, 1)).unwrap();

    let mut daemon = spawn_daemon_with_env(
        &home,
        &[
            ("PORTPAL_SSH_BIN", test_ssh_bin_path()),
            ("PORTPAL_TEST_SSH_MODE", "listen"),
        ],
    );
    wait_for_daemon(&home);

    let response = wait_for_status_state(&home, "postgres", "healthy");
    assert_eq!(response["status"]["processAlive"], true);
    assert_eq!(response["status"]["portReachable"], true);

    stop_daemon(&mut daemon);
}

#[test]
fn auto_started_connection_retries_when_ssh_process_exits() {
    let home = TestHome::new("ssh-exit");
    fs::create_dir_all(home.config_dir()).unwrap();
    fs::write(home.config_path(), auto_config("postgres", 15434, 5432, 1)).unwrap();

    let mut daemon = spawn_daemon_with_env(
        &home,
        &[
            ("PORTPAL_SSH_BIN", test_ssh_bin_path()),
            ("PORTPAL_TEST_SSH_MODE", "exit-immediately"),
        ],
    );
    wait_for_daemon(&home);

    let response = wait_for_status_state(&home, "postgres", "waitingToRetry");
    assert_eq!(response["status"]["processAlive"], false);
    assert!(response["status"]["lastError"]
        .as_str()
        .unwrap()
        .contains("ssh process exited"));

    stop_daemon(&mut daemon);
}

#[test]
fn auto_started_connection_retries_when_port_never_becomes_reachable() {
    let home = TestHome::new("ssh-unreachable");
    fs::create_dir_all(home.config_dir()).unwrap();
    fs::write(home.config_path(), auto_config("postgres", 15435, 5432, 1)).unwrap();

    let mut daemon = spawn_daemon_with_env(
        &home,
        &[
            ("PORTPAL_SSH_BIN", test_ssh_bin_path()),
            ("PORTPAL_TEST_SSH_MODE", "hold-open"),
        ],
    );
    wait_for_daemon(&home);

    let response = wait_for_status_state(&home, "postgres", "waitingToRetry");
    assert_eq!(response["status"]["processAlive"], false);
    assert!(response["status"]["lastError"]
        .as_str()
        .unwrap()
        .contains("forwarded port is not reachable"));

    stop_daemon(&mut daemon);
}

#[test]
fn stop_suppresses_restart_until_refresh_restarts_the_connection() {
    let home = TestHome::new("ssh-stop-refresh");
    fs::create_dir_all(home.config_dir()).unwrap();
    fs::write(home.config_path(), auto_config("postgres", 15436, 5432, 1)).unwrap();

    let mut daemon = spawn_daemon_with_env(
        &home,
        &[
            ("PORTPAL_SSH_BIN", test_ssh_bin_path()),
            ("PORTPAL_TEST_SSH_MODE", "listen"),
        ],
    );
    wait_for_daemon(&home);
    wait_for_status_state(&home, "postgres", "healthy");

    let stop_output = run_portpal(&home, &["stop", "postgres"]);
    assert!(stop_output.status.success());

    let stopped = wait_for_status_state(&home, "postgres", "stopped");
    assert_eq!(stopped["status"]["restartSuppressed"], true);

    thread::sleep(Duration::from_millis(1500));
    assert_eq!(status_state(&home, "postgres"), "stopped");

    let refresh_output = run_portpal(&home, &["refresh", "postgres"]);
    assert!(refresh_output.status.success());

    wait_for_condition(
        || {
            let state = status_state(&home, "postgres");
            state == "starting" || state == "healthy"
        },
        "connection did not restart after refresh",
    );
    let refreshed = wait_for_status_state(&home, "postgres", "healthy");
    assert_eq!(refreshed["status"]["restartSuppressed"], false);

    stop_daemon(&mut daemon);
}
