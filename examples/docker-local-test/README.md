# Local Docker SSH Target

This creates one container with:

1. `sshd` listening on host port `2222`
2. A tiny HTTP server listening inside the container on `127.0.0.1:8080`

That gives `portpal` a real SSH target and a real remote port to forward.

## Start The Container

From this directory:

```bash
docker-compose up -d --build
```

This setup expects your public key at `~/.ssh/portpal-local-test.pub`.

If you use a different key, either:

1. Change the bind mount in `docker-compose.yml`
2. Or create a temporary copy at that path

## Add An SSH Alias

Add this to `~/.ssh/config`:

```sshconfig
Host portpal-docker
  HostName 127.0.0.1
  Port 2222
  User tester
  IdentityFile ~/.ssh/portpal-local-test
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
```

Verify it works before using `portpal`:

```bash
ssh portpal-docker
```

## Portpal Config

Edit `~/.config/portpal/portpal.toml`:

```toml
[[connections]]
name = "docker-http"
ssh_host = "portpal-docker"
local_port = 18080
remote_host = "127.0.0.1"
remote_port = 8080
auto_start = true
reconnect_delay_seconds = 5
```

## Run Portpal

Start or restart the daemon, then check status:

```bash
portpal serve
portpal list
portpal status docker-http
```

In another terminal, verify the forwarded port:

```bash
curl http://127.0.0.1:18080
```

Expected response:

```text
portpal docker local test
```

## Notes

1. `portpal` only passes a host string to `ssh`, so the `~/.ssh/config` alias is the easiest way to target Docker on port `2222`.
2. This uses key-based auth because `portpal` launches `ssh` non-interactively.
3. The remote service is intentionally bound to `127.0.0.1` inside the container so the SSH forward is exercising the real path you care about.
