#!/usr/bin/env bash
# @describe nudeploy - deploy systemd services to multiple hosts over SSH
# @version 0.1.0
#
# @cmd deploy      Apply changes idempotently: upload files on hash change, reload systemd on unit change, enable once, start/restart as needed
# @cmd status      Show systemd status for the service on each host
# @cmd restart     Restart the service on targets without syncing files
# @cmd hosts       List hosts (optionally filtered by group); prints name/ip/port/user/group/enabled
# @cmd exec        Run a command string or a playbook file on selected hosts
# @cmd download    Download artifacts defined in [[downloads]] to download_dir and extract them
# @cmd copy        Copy local files/dirs to remote hosts
#
# @option --config!     Path to config TOML (default: ./nudeploy.toml)
# @option --service     Service name from config (optional for deploy/status/restart; defaults to all services with enable=true)
# @option --group       Filter targets by group from the config
# @option --hosts       Comma-separated host aliases (overrides --group)
# @option --name        For download/copy: comma-separated item names
# @flag --sudo          Use sudo -n for remote privileged actions (install to /etc, systemctl)
# @flag --json          Emit JSON records suitable for CI (changes/events/status per host)
# @flag --dry-run       For deploy: show what would change without applying (formerly plan)
#
# @example nudeploy deploy --service helix --group web --sudo
# @example nudeploy deploy --dry-run --service helix --hosts h1,h2
# @example nudeploy exec "uname -a" --hosts h1
# @example nudeploy exec ./playbooks/setup.nu --hosts h1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NU=${NU:-nu}

# Forward all user args to Nushell implementation.
exec "$NU" "$SCRIPT_DIR/nudeploy.nu" "$@"
