# Portpal

Portpal is a macOS utility for managing forwarded SSH ports.

It ships as:

1. A Rust `portpal` binary
2. A Swift menu bar app

`portpal serve` is the daemon entrypoint. All other `portpal` subcommands act as clients that talk to the daemon over a local Unix socket.

## Architecture

The repository now has two runtime pieces:

1. Rust `portpal`
   - parses user-edited TOML config
   - runs the local daemon with `portpal serve`
   - launches `/usr/bin/ssh`
   - performs health checks and reconnect scheduling
   - exposes a local JSON API over a Unix socket

2. Swift `PortpalMenuBar`
   - displays configured connections and aggregate health
   - reloads config
   - refreshes individual connections
   - stops individual connections for the current daemon session

## Config

Persistent config lives at:

1. Socket: `~/.config/portpal/portpal.sock`
2. Config: `~/.config/portpal/portpal.toml`

Initialize a sample config with:

```bash
cargo run -- config init
```

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

Rules:

1. `name` is required and must be unique
2. `local_port` must be unique
3. `auto_start` controls whether the daemon should try to keep the connection running
4. `reconnect_delay_seconds` controls retry timing when a connection is failed or unhealthy

## CLI

Run the daemon locally:

```bash
cargo run -- serve
```

Useful commands:

```bash
cargo run -- list
cargo run -- status example-postgres
cargo run -- refresh example-postgres
cargo run -- stop example-postgres
cargo run -- reload
cargo run -- validate-config
cargo run -- config path
cargo run -- config init
```

When installed via Homebrew, the intended model is to run the daemon with `brew services` and use `portpal` as the client binary.

## Menu Bar App

Build and run the menu bar app:

```bash
swift build
open ./.build/debug/PortpalMenuBar
```

The menu bar UI now includes:

1. Per-connection refresh
2. Per-connection stop
3. A top-level `Reload Config` button

It no longer includes an add-connection window or a global refresh button.

## Build

Build both runtimes from the repository root:

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

## Homebrew

Portpal's Homebrew tap is maintained separately from this source repo:

1. Tap repo: `https://github.com/itsfrank/homebrew-tap`
2. Source repo: `https://github.com/itsfrank/portpal`

Expected install model:

1. Formula installs `portpal`
2. `brew services start portpal` runs `portpal serve`
3. Cask installs `Portpal.app`

## Current Behavior

Health is currently defined as:

1. The managed `ssh` process is alive
2. The local forwarded port accepts a TCP connection

Runtime stop behavior is intentionally not persisted.

1. `portpal stop <name>` kills the connection and suppresses restart for the current daemon session
2. `portpal refresh <name>` clears suppression and attempts an immediate restart
3. `portpal reload` re-reads `portpal.toml` without writing back runtime state
