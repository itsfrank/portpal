# Portpal

Portpal is a macOS utility for managing forwarded SSH ports.

It has two interfaces:

1. A menu bar app for viewing and managing tunnels
2. A CLI for tools and agents to create and inspect managed tunnels

## Current Prototype

This repository currently contains a first working slice with:

1. A local service that manages SSH tunnel processes
2. A `portpal create` CLI command
3. A `portpal check` CLI command
4. A macOS menu bar app that shows:
   - all managed tunnels
   - per-tunnel health dots
   - an aggregate health dot on the menu bar icon
   - a form for manually adding a connection

Health is currently defined as:

1. The managed `ssh` process is still alive
2. The local forwarded port accepts a TCP connection

## Architecture

The Swift package currently has four targets:

1. `PortpalCore`
   Shared models, validation, IPC types, and health logic

2. `PortpalService`
   A local background service that:
   - persists tunnel definitions
   - launches `/usr/bin/ssh`
   - performs health checks
   - serves a local Unix socket JSON API

3. `portpal`
   CLI for creating and checking managed tunnels

4. `PortpalMenuBar`
   macOS menu bar app built with SwiftUI and AppKit

## Build

From the repository root:

```bash
swift build
```

Build release binaries:

```bash
swift build -c release
```

## Run

### Run the menu bar app

```bash
open ./.build/debug/PortpalMenuBar
```

If needed, relaunch it with:

```bash
pkill PortpalMenuBar || true
open ./.build/debug/PortpalMenuBar
```

To package a Spotlight-launchable app bundle locally:

```bash
./scripts/package-release.sh
open ./.dist/Portpal.app
```

To install the packaged app into `/Applications`:

```bash
cp -R ./.dist/Portpal.app /Applications/
open /Applications/Portpal.app
```

### Run the CLI

Create a managed tunnel:

```bash
./.build/debug/portpal create --host my-box --local-port 15432 --remote-host 127.0.0.1 --remote-port 5432
```

Check a managed tunnel:

```bash
./.build/debug/portpal check --host my-box --local-port 15432
```

The CLI auto-starts `PortpalService` when needed.

When installed via Homebrew, the `portpal` wrapper sets `PORTPAL_SERVICE_PATH` so the CLI can launch the installed service binary.

## CLI Reference

### `create`

```bash
portpal create --host <sshHost> --local-port <port> --remote-host <host> --remote-port <port> [--name <name>]
```

Example:

```bash
./.build/debug/portpal create --host prod-db --local-port 15432 --remote-host 127.0.0.1 --remote-port 5432 --name postgres
```

### `check`

```bash
portpal check --host <sshHost> --local-port <port>
```

Example:

```bash
./.build/debug/portpal check --host prod-db --local-port 15432
```

`check` returns JSON and exits non-zero if the tunnel is missing or unhealthy.

## Menu Bar Status

The base icon is always monochrome.

The small dot on the top-right indicates aggregate health:

1. Green if all tunnels are healthy
2. Red if no tunnels are healthy
3. Yellow if some are healthy and some are unhealthy
4. Gray if there are no configured tunnels

Each tunnel row in the popover also shows a per-tunnel status dot:

1. Green for healthy
2. Red for unhealthy

## Storage

Portpal currently stores its local state in:

1. Socket: `~/Library/Application Support/Portpal/portpal.sock`
2. Tunnel definitions: `~/Library/Application Support/Portpal/tunnels.json`

## Homebrew

Portpal's Homebrew tap is maintained separately from this source repo:

1. Tap repo: `https://github.com/itsfrank/homebrew-tap`
2. Source repo: `https://github.com/itsfrank/portpal`

This repo only owns the release artifacts that Homebrew consumes:

1. `scripts/package-release.sh`
2. `.github/workflows/release.yml`
3. `.github/workflows/release-smoke.yml`

### Local packaging

Build the release artifacts:

```bash
./scripts/package-release.sh
```

Optionally set an explicit version string for the packaged app and printed checksums:

```bash
VERSION=0.1.0 ./scripts/package-release.sh
```

That script produces:

1. `.dist/Portpal.app`
2. `.dist/Portpal.app.zip`
3. `.dist/portpal`
4. `.dist/PortpalService`
5. `.dist/portpal-cli.tar.gz`

### Publishing flow

1. Run `Release Smoke` on `main` to verify GitHub Actions can build the release artifacts
2. Tag a new version like `v0.1.0`
3. Run the `Release` workflow against that tag
4. Use the printed SHA256 values to update the formula and cask in `itsfrank/homebrew-tap`
5. Publish the tap changes
6. Install with:
   - `brew install <tap>/portpal`
   - `brew install --cask <tap>/portpal`

## Development Notes

Run tests with:

```bash
swift test
```

The current implementation is intentionally small and prototype-oriented.

Notable current limitations:

1. Persistence uses JSON, not SQLite yet
2. There is no delete or edit command yet
3. There is no reconnect/backoff strategy yet if `ssh` exits
4. The app assumes your normal SSH configuration, keys, and agent already work with `/usr/bin/ssh`

## Example Workflow

1. Start the menu bar app
2. Create a tunnel through the CLI or through the add form
3. Watch the tunnel appear in the popover
4. Use `check` to inspect machine-readable health from automation

Example:

```bash
./.build/debug/portpal create --host my-box --local-port 18080 --remote-host 127.0.0.1 --remote-port 8080
./.build/debug/portpal check --host my-box --local-port 18080
```
