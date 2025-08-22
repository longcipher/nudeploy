# nudeploy

A tiny, stable, idempotent deployment helper to roll out a systemd service to multiple remote hosts using:

- Nushell for orchestration
- SSH/SCP for remote execution and file transfer

It reuses your existing SSH config at `~/.ssh/config`. No extra SSH config in this repo.

## Configuration: one TOML file

Define hosts and services in a single TOML config (defaults to `./nudeploy.toml`). Example:

```toml
[[hosts]]
name = "localhost"
ip = "127.0.0.1"
port = 22
user = "akagi201"
enable = true
group = "prod"

[[services]]
name = "axon"
src_dir = "./axon"
dst_dir = "/home/akagi201/axon"
unit_file = "axon.service"  # relative to src_dir or absolute
sync_files = [
  { from = "foo.conf", to = "bar.conf" },
  # Support downloading on remote directly:
  # { from = "https://example.com/file.conf", to = "bar.conf" }
  # Optional per-file chmod (applied with sudo after sync); defaults to "0644"
  # { from = "bin/myapp", to = "bin/myapp", chmod = "0755" },
]
restart = true   # restart service when files changed
enable = true    # enable service (default true)
```

You can target hosts by group or explicitly via `--hosts hostA,hostB`.

## Requirements

- macOS or Linux
- Nushell v0.90+ (newer preferred)
- bash (for the CLI wrapper)
- ssh, scp
- Remote machines run systemd and have sudo available if you need to install into /etc
- Remote tools: one of sha256sum | shasum | openssl must be available (most distros have at least one)

## Install

- Ensure Nushell is installed:
  - brew install nushell
- Make the wrapper executable:
  - chmod +x nudeploy/nudeploy.sh

### Install via nupm (for Nu users)

The repo includes `nupm.nuon`. You can install via nupm and get a `nudeploy` bin on PATH (points to `nudeploy.nu`).

```shell
# Local install from the current directory (install nupm first per its docs)
nu -c 'nupm install --path .'

# Or install from Git (example)
nu -c 'nupm install --git https://github.com/longcipher/nudeploy'

# Now you can run it directly (nupm exposes `nudeploy` on PATH)
nudeploy --help
```

Note: After nupm install, `nudeploy` runs `nudeploy.nu`. The Bash wrapper `nudeploy.sh` still works standalone.

## Usage

- Plan (no changes; shows what would change):

```shell
# All enabled services
nudeploy plan --group prod
# Single service
nudeploy plan --service axon --group prod
```

- Deploy to a group (idempotent):

```shell
# All enabled services
nudeploy deploy --group prod --sudo
# Single service
nudeploy deploy --service axon --group prod --sudo
```

- Deploy to specific hosts:

```shell
nudeploy deploy --service axon --hosts host1,host2 --sudo
```

- Check status:

```shell
# All enabled services
nudeploy status --group prod
# Single service
nudeploy status --service axon --group prod
```

- Restart without redeploying files:

```shell
# All enabled services
nudeploy restart --hosts host1
# Single service
nudeploy restart --service axon --hosts host1
```

- List hosts (enabled by default):

```shell
nudeploy hosts --group prod
```

- Run a shell command on targets:

```shell
nudeploy shell --group prod --cmd 'uname -a'
```

- Run a playbook (line-by-line, stop on error):

```shell
nudeploy play --group prod --file playbooks/arch.nu
```

- Download artifacts locally (curl + extract):

```shell
# All enabled downloads in config
nudeploy download

# Only selected names
nudeploy download --name openobserve

# Alternate config file
nudeploy download --config ./nudeploy.toml
```

## Options

- --config: Path to config TOML (default: ./nudeploy.toml)
- --service: Service name from config (optional for plan/deploy/status/restart). If omitted, acts on all services with `enable = true`.
- --group: Hosts group
- --hosts: Comma-separated hostnames (SSH Host aliases)
- --cmd: Command to run for shell
- --file: Path to playbook file for `play` (one command per line; `#` comments and blank lines ignored)
- --sudo: Use sudo for systemd actions (daemon-reload/enable/start/restart) and installing unit files into /etc. All other file and directory operations run as the SSH user.
- --json: Emit JSON output suitable for CI
- --name: For `download`, comma-separated artifact names to fetch (defaults to all enabled)

## Idempotency strategy

- Files are uploaded only if remote checksum differs
- Optional chmod is enforced after sync as the SSH user when `chmod` is set on an item
- Systemd daemon-reload runs only when unit changed
- Service is enabled once if not enabled
- Service is restarted only when changes detected (or restart mode forces it)

## Notes

- nudeploy does not install software on remote machines; it only pushes your service unit/config and manages systemd
- Per-file permissions: set `chmod = "0755"` on binaries you need to execute; default mode is `0644`.
- Local `download` subcommand reads `download_dir` and `[[downloads]]` from your config, fetches with curl, extracts by suffix (tar.gz/tgz, tar.xz, zip, tar, gz, xz), and removes archives after extraction.
- For sudo prompts, passwordless sudo is recommended for automation

### Playbooks

Playbooks are simple text files that nudeploy executes remotely, one command per line. Ensure each line is idempotent. On the first failure (non-zero exit code), execution stops for that host and the failing line and command are reported. Use `--sudo` when commands require privileges.

Example `playbooks/bootstrap.sh`:

```sh
# Ensure curl exists
which curl >/dev/null 2>&1 || (apt-get update -y && apt-get install -y curl)

# Create user if missing
id -u deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy

# Ensure directory and ownership
mkdir -p /opt/myapp && chown -R deploy:deploy /opt/myapp
```

## Dev tips

- The Bash wrapper only parses CLI; all orchestration lives in Nushell

## Quick start

1. Install prerequisites (macOS):

```shell
brew install nushell
```

1. Ensure the CLI is executable and callable:

```shell
chmod +x nudeploy/nudeploy.sh
./nudeploy/nudeploy.sh --help
```

1. Define your config at `./nudeploy.toml` with [[hosts]] and [[services]]. Host names are arbitrary labels; you can also set ip/user/port.

```shell
./nudeploy/nudeploy.sh plan \
  --service example-service \
  --group all \
  --sudo
```

When you’re ready:

```shell
./nudeploy/nudeploy.sh deploy \
  --service example-service \
  --group all \
  --sudo
```

Tip: If Nushell is not on PATH or is named differently, set `NU=/path/to/nu` before running.

## Model and behavior

- Unit file is copied to `/etc/systemd/system/<service>.service`.
- sync_files entries copy local files (hash-compared) or download URLs on the remote; only changed files are installed.
- Idempotent: files only update on hash change; `daemon-reload` only when unit changes; enable once; restart on change when `restart=true`.

## End-to-end example

Use the included example config/service to get a feel for the workflow:

```shell
# Plan the changes (no writes)
./nudeploy/nudeploy.sh plan \
  --service axon \
  --group prod \
  --sudo

# Apply changes idempotently
./nudeploy/nudeploy.sh deploy \
  --service axon \
  --group prod \
  --sudo

# Check status
./nudeploy/nudeploy.sh status \
  --service example-service \
  --group all
```

Outputs:

- Plan shows which items would be uploaded per host.
- Deploy uploads/downloads only when checksums differ, reloads systemd if unit changed, enables once, and restarts only when needed.
- Status reports enabled/active states, plus a few systemctl properties in JSON mode.


## JSON output for CI

Use `--json` to emit structured records per host that you can pipe to `jq` or parse in CI:

```shell
./nudeploy/nudeploy.sh deploy \
  --service axon \
  --group prod \
  --sudo \
  --json
```

You can fail a CI job if any host failed or if changes are found (policy dependent). Example:

```shell
./nudeploy/nudeploy.sh deploy --service foo --group all --sudo --json \
  | jq -e 'all(.[]; .ok? // true)'
```

## Output details

Plan prints a detailed summary plus per-file actions by default. Use `--json` for structured data.

Note: The main entry is `nudeploy.sh`. You can symlink it to `nudeploy` to match the examples above.

## Troubleshooting

- First SSH to a host prompts for key: we use `StrictHostKeyChecking=accept-new` which will trust new hosts on first connect.
- Permission denied writing files: destinations must be writable by the SSH user. Pre-create directories/files with proper ownership if needed.
- Permission denied (systemctl): configure passwordless sudo for systemctl for your deployment user, or run with a TTY if prompts are needed.
- Remote host missing hasher: needs one of `sha256sum`, `shasum`, or `openssl`. Install `coreutils` or `perl` packages accordingly.
- Remote not systemd: this tool targets systemd-based Linux. Non-systemd hosts aren’t supported.
- Unit not restarting: with `restart = true`, restarts occur when files changed; otherwise not.
- File destinations: ensure the destination parent directory exists or is creatable; we auto-create with `mkdir -p` when needed.

## Environment variables

- `NU`: path to Nushell executable. Defaults to `nu` on PATH.

## Release with nupm

The project includes `nupm.nuon`:

```nu
{
  name: "nudeploy",
  version: "0.1.0",
  description: "Idempotent systemd deploy helper over SSH using Nushell",
  license: "MIT",
  bins: { nudeploy: "nudeploy.nu" },
  modules: ["lib.nu"],
}
```

Example release flow (using nupm install from Git tags):

```shell
# Tag a release (version must match `nupm.nuon`)
git tag v0.1.0 && git push origin v0.1.0

# Verify install from the Git tag
nu -c 'nupm install --git https://github.com/longcipher/nudeploy --tag v0.1.0'

# When bumping versions:
# 1) Update `version` in nupm.nuon
# 2) Update README examples
# 3) Re-tag and push
```
