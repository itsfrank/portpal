# Portpal

Portpal is a macOS utility for managing SSH port forwards you want to keep around.

It is built for the common case where you regularly tunnel into remote services like Postgres, Redis, or internal HTTP apps and do not want to keep re-running long `ssh -L ...` commands by hand.

Portpal gives you:

1. A CLI for defining, starting, stopping, and inspecting forwarded ports
2. A background daemon that keeps configured tunnels healthy
3. A menu bar app for quick visibility and control

## Install

Install the CLI from Homebrew:

```bash
brew tap itsfrank/tap
brew install itsfrank/tap/portpal
```

Start the daemon as a background service:

```bash
brew services start portpal
```

After install, you can use the CLI directly:

```bash
portpal config init
portpal list
portpal status example-postgres
```

Useful service commands:

```bash
brew services list
brew services restart portpal
brew services stop portpal
```

### Menu bar app

<img width="380" height="174" alt="image" src="https://github.com/user-attachments/assets/19e879cb-9d4a-4d2b-bc6f-7daa2ca6ea99" />

If you want the menu bar app too, install `Portpal.app` separately from the same release set used for distribution.

```bash
brew tap itsfrank/tap
brew install --cask itsfrank/tap/portpal-app
```
The portpal app is not signed, the first time you launch it you will have to go to `System Settings > Privacy & Security` sroll down to `security` and click `allow` next to the request to launch portpal.app

## What It Does

Each Portpal connection describes a local port forward, for example:

1. listen on `localhost:15432`
2. connect through SSH to `prod-db`
3. forward traffic to `127.0.0.1:5432` on the remote side

Portpal can then:

1. start that tunnel for you
2. restart it if it dies
3. show whether it is currently healthy
4. let you refresh or stop it without rebuilding the config by hand

## Quick Start

Initialize a sample config:

```bash
portpal config init
```

Check where Portpal stores its config:

```bash
portpal config path
```

Start the daemon:

```bash
portpal serve
```

In another terminal, inspect what is running:

```bash
portpal list
```

## How Portpal Works Day To Day

Portpal has two user-facing pieces:

1. `portpal`, the CLI
2. `portpal.app`, the macOS menu bar app

The daemon can be started directly with `portpal serve` (if not useing brew services). After that, other `portpal` commands talk to the running daemon over a local Unix socket.

That means the normal flow is:

1. define your connections in `portpal.toml`
2. run the daemon
3. use the CLI or menu bar app to monitor and control those connections

## Config

Portpal stores its files at:

1. Socket: `~/.config/portpal/portpal.sock`
2. Config: `~/.config/portpal/portpal.toml`

Example config:

```toml
[[connections]]
name = "example-postgres"
ssh_host = "prod-db"
local_port = 15432
remote_host = "127.0.0.1"
remote_port = 5432
auto_start = true
reconnect_delay_seconds = 10
```

Field meanings:

1. `name`: unique name for the connection
2. `ssh_host`: SSH host or SSH config alias to connect through
3. `local_port`: port opened on your machine
4. `remote_host`: host reached from the SSH server side
5. `remote_port`: port reached on the remote side
6. `auto_start`: whether the daemon should try to keep this tunnel running
7. `reconnect_delay_seconds`: how long to wait before retrying a failed connection

Rules:

1. `name` is required and must be unique
2. `local_port` must be unique
3. `auto_start = true` means the daemon will try to keep the tunnel up

## Common CLI Commands

Start the daemon:

```bash
# manually
portpal serve

# as a brew service
brew services start portpal
```

List all configured connections:

```bash
portpal list
```

Inspect one connection:

```bash
portpal status example-postgres
```

Force a reconnect:

```bash
portpal refresh example-postgres
```

Stop one connection for the current daemon session:

```bash
portpal stop example-postgres
```

Reload the config file without restarting the daemon:

```bash
portpal reload
```

Validate the config file:

```bash
portpal validate-config
```

## Menu Bar App

Start the menubar by launching the `Portpal.app` app installed with `brew install --cask itsfrank/tap/portpal-app`

The menu bar app is useful when you want quick visibility into tunnel state without using the terminal. It supports:

1. viewing configured connections and overall health
2. refreshing a single connection
3. stopping a single connection for the current daemon session
4. reloading config from the menu

## Health And Runtime Behavior

Portpal currently considers a connection healthy when:

1. the managed `ssh` process is alive
2. the local forwarded port accepts a TCP connection

Runtime stop behavior is not persisted:

1. `portpal stop <name>` kills the connection and suppresses restart for the current daemon session
2. `portpal refresh <name>` clears suppression and attempts an immediate restart
3. `portpal reload` re-reads `portpal.toml` without writing runtime state back into it

## Homebrew

Homebrew repos:

1. Tap repo: `https://github.com/itsfrank/homebrew-tap`
2. Source repo: `https://github.com/itsfrank/portpal`

## Building From Source

Build both binaries from the repository root:

```bash
cargo build
swift build
```

Release builds:

```bash
cargo build --release
swift build -c release --product PortpalMenuBar
```

## Tests

Run both test suites:

```bash
cargo test
swift test
```

## Packaging

Build release artifacts:

```bash
./scripts/package-release.sh
```

That script produces:

1. `.dist/Portpal.app`
2. `.dist/Portpal.app.zip`
3. `.dist/portpal`
4. `.dist/portpal-cli.tar.gz`
