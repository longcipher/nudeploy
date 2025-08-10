## Copilot instructions for `nudeploy`

Purpose: Enable agents to ship/extend a tiny, idempotent systemd deploy tool over SSH using Nushell.

Big picture
- Entrypoint is `nudeploy.sh` (Bash wrapper) which forwards to `nudeploy.nu`; core logic lives in `lib.nu`.
- Goal: Upload unit/config files to multiple hosts and manage systemd idempotently.
- Config: single TOML at repo root `./nudeploy.toml` (no fallback). Host names match SSH Host aliases in `~/.ssh/config`.

CLI (from `nudeploy.nu`)
- Commands: `plan | deploy | status | restart | hosts | shell`.
- Common flags: `--config` (path to TOML, default `./nudeploy.toml`), `--service` (optional; defaults to all services with `enable=true`), `--group`, `--hosts` (comma-separated; overrides group), `--sudo`, `--json`, and `--cmd` (for `shell`).
- Examples:
	- Plan all enabled services in a group: `./nudeploy/nudeploy.sh plan --group prod`
	- Deploy one service with sudo: `./nudeploy/nudeploy.sh deploy --service axon --group prod --sudo`
	- Status for all enabled services: `./nudeploy/nudeploy.sh status --group prod`
	- Ad-hoc command: `./nudeploy/nudeploy.sh shell --hosts web1,web2 --cmd 'uname -a'`

How it works (see `lib.nu`)
- Config loading: `load_config` reads TOML and returns `{ hosts, services }`.
- Target selection: `select_targets` honors `--hosts` over `--group`; when neither, uses enabled hosts.
- Service meta: `build_service_meta` computes paths (unit goes to `/etc/systemd/system/<name>.service`), sync items (local files or remote URLs), restart policy, enable flag.
- File sync: `compare_and_upload` (local -> remote) and `remote_download_and_place` (URL -> remote) use sha256; only update on change and set mode.
- Systemd: After changes, `daemon-reload` on unit change; `enable` once if configured; `start` if inactive; `restart` on change when `restart=on-change`.
- Status: `status_host` shells `systemctl show` and returns `{ host, enabled, active, raw }` (raw is a key/value map).

I/O modes
- Text: `plan` shows per-service summary plus per-host file actions; `deploy` shows per-host summary and event tables; `status` shows a flattened summary and per-host raw key/values.
- JSON (`--json`): returns per-host records. Shapes include:
	- plan: `{ host, service, unit_action, daemon_reload, enable, start, restart, files_changed, files: [...], details: {...} }`
	- deploy: `{ host, service, changed, events: [...] }`
	- status: `{ host, service, enabled, active, raw }`
	- restart: `{ host, service, ok, event }`

Integration expectations
- SSH uses `StrictHostKeyChecking=accept-new`; commands run via `bash -lc` and `sudo -n` when `--sudo`.
- Remote must have one hasher: `sha256sum` | `shasum` | `openssl`.

Dev workflow
- Install: `brew install nushell`; make wrapper executable: `chmod +x nudeploy/nudeploy.sh`.
- Run help: `./nudeploy/nudeploy.sh --help`; override Nushell path with `NU=/path/to/nu` when needed.

Conventions when extending
- Add subcommands by updating the `match` in `nudeploy.nu`; implement behavior in `lib.nu`. Return lists of records; respect `--json` mode.
- Preserve idempotency; route file changes through `compare_and_upload` / `remote_download_and_place`.

Key files
- `nudeploy.sh` (wrapper), `nudeploy.nu` (CLI + orchestration), `lib.nu` (SSH/file/systemd helpers), `README.md` (usage/config), `example-service/*`.

Questions to clarify
- If additional config formats or extra systemd actions are desired, specify them before adding new logic.
