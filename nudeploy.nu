#!/usr/bin/env nu
# nudeploy.nu - Nushell entrypoint
# Import lib.nu (assumes it’s in the same directory when run via nupm/bin or wrapper)
use lib.nu *

export def main [
  command: string # Commands: deploy (apply changes), status (service status), restart (restart service), hosts (list hosts), exec (run command or playbook), download (fetch artifacts), copy (copy local files to remote)
  payload?: string # Command string or playbook file path for 'exec'
  --config: string # Path to config TOML (default: ./nudeploy.toml)
  --service: string # Service name; when omitted, operates on all services with enable=true
  --group: string # Filter hosts by group
  --hosts: string # Comma-separated host aliases (overrides --group)
  --sudo # Use sudo -n for systemctl actions and unit install to /etc; other file and directory operations run as the SSH user
  --name: string # For download/copy: comma-separated item names
  --json # Emit JSON records for CI-friendly output
  --dry-run # For deploy: show changes without applying them (formerly 'plan')
] {
  let cfg_path = (if ($config | is-empty) { ([$env.PWD "nudeploy.toml"] | path join) } else { $config })
  let cfg = (load_config $cfg_path)
  let needs_service = ($command in ["deploy" "status" "restart"])
  let target_hosts = (select_targets $cfg $group $hosts)
  if ($command != "hosts" and $command != "exec" and $command != "download" and $command != "copy") {
    if ($target_hosts | is-empty) { error make {msg: "No target hosts selected (check --group/--hosts or config)"} }
  }
  # Resolve service names to operate on
  let service_names = (
    if ($service | is-empty) {
      if $needs_service { $cfg.services | where {|s| ($s.enable? | default true) } | each {|s| $s.name } } else { [] }
    } else { [$service] }
  )
  if ($needs_service and ($service_names | length) == 0) { error make {msg: "No services selected (provide --service or mark services enable=true)"} }
  let out = (
    match $command {
      "hosts" => { list_hosts_cmd $cfg $group --all=false }
      "exec" => {
        if ($payload | is-empty) { error make {msg: "Payload (command or file) is required for exec"} }
        if ($target_hosts | is-empty) { error make {msg: "No hosts selected for exec (use --group or --hosts)"} }
        
        if ($payload | path exists) {
            # Playbook mode
            let lines = (parse_playbook $payload)
            let rows = ($target_hosts | each {|h| play_host $h $lines --sudo=$sudo })
            if $json {
              $rows
            } else {
              let summary = ($rows | each {|r| { host: $r.host ok: $r.ok failed_line: ($r.failed_line? | default null) exit: ($r.exit? | default null) } })
              $summary | table -e
              for r in $rows {
                if (not $r.ok) {
                  print $"\nHost: ($r.host) FAILED at line ($r.failed_line)"
                  print $"Cmd:    (($r.failed_cmd? | default ""))"
                  let se = ($r.stderr? | default "")
                  if ($se | is-not-empty) { print $"Stderr: ($se)" }
                }
              }
              $summary
            }
        } else {
            # Shell command mode
            $target_hosts | each {|h| shell_host $h $payload --sudo=$sudo }
        }
      }
      "deploy" => {
        if $dry_run {
            # Plan logic
            if $json {
              # Aggregate all rows with service name for JSON
              $service_names | reduce -f [] {|svc acc|
                let meta = (build_service_meta (resolve_service $cfg $svc))
                let rows = (plan_hosts_cmd $meta $target_hosts --sudo=$sudo)
                $acc | append ($rows | each {|r| $r | insert service $svc })
              }
            } else {
              mut summary_all = []
              for svc in $service_names {
                let meta = (build_service_meta (resolve_service $cfg $svc))
                let rows = (plan_hosts_cmd $meta $target_hosts --sudo=$sudo)
                print $"\nService: ($svc)"
                let summary = ($rows | each {|r| {host: $r.host unit_action: $r.unit_action daemon_reload: $r.daemon_reload enable: $r.enable start: $r.start restart: $r.restart files_changed: $r.files_changed} })
                $summary | table -e
                $summary_all = ($summary_all | append ($summary | each {|x| $x | insert service $svc }))
                for r in $rows {
                  let file_rows = ($r.files | default [])
                  if (($file_rows | length) > 0) {
                    print $"\nHost: ($r.host)"
                    ($file_rows | select from to dest source action reason) | table -e
                  } else {
                    print $"\nHost: ($r.host)\nNo file changes"
                  }
                }
              }
              $summary_all
            }
        } else {
            # Deploy logic
            let rows_all = (
              $service_names | reduce -f [] {|svc acc|
                let meta = (build_service_meta (resolve_service $cfg $svc))
                let rows = (deploy_hosts_cmd $meta $target_hosts --sudo=$sudo)
                $acc | append ($rows | each {|r| $r | insert service $svc })
              }
            )
            if $json {
              $rows_all
            } else {
              let summary = ($rows_all | each {|r| {host: $r.host service: ($r.service? | default "") changed: $r.changed event_count: (($r.events | default []) | length) error: ($r.error? | default "")} })
              $summary | table -e
              for r in $rows_all {
                let ev = ($r.events | default [])
                print $"\nHost: ($r.host) Service: (($r.service? | default ""))"
                if ($r.error? | is-not-empty) {
                    print $"ERROR: ($r.error)"
                }
                if (($ev | length) > 0) {
                  ($ev | each {|e| {type: ($e.type? | default "") target: ($e.target? | default "") dest: ($e.dest? | default "") action: ($e.action? | default "") reason: ($e.reason? | default "") cause: ($e.cause? | default "") source: ($e.source? | default "")} } | table -e)
                } else {
                  if ($r.error? | is-empty) {
                      print "No events"
                  }
                }
              }
              $summary
            }
        }
      }
      "status" => {
        let rows_all = (
          $service_names | reduce -f [] {|svc acc|
            let meta = (build_service_meta (resolve_service $cfg $svc))
            let rows = (status_hosts_cmd $meta $target_hosts --sudo=$sudo)
            $acc | append ($rows | each {|r| $r | insert service $svc })
          }
        )
        if $json {
          $rows_all
        } else {
          # Flatten key raw fields for a readable summary
          let summary = (
            $rows_all | each {|r|
              {
                host: $r.host
                service: ($r.service? | default "")
                enabled: $r.enabled
                active: $r.active
                ActiveState: ($r.raw.ActiveState? | default "")
                UnitFileState: ($r.raw.UnitFileState? | default "")
                MainPID: ($r.raw.MainPID? | default "")
                ExecMainStatus: ($r.raw.ExecMainStatus? | default "")
                ExecMainStartTimestamp: ($r.raw.ExecMainStartTimestamp? | default "")
                FragmentPath: ($r.raw.FragmentPath? | default "")
              }
            }
          )
          $summary | table -e
          # Also print full raw key-values per host for inspection
          for r in $rows_all {
            print $"\nHost: ($r.host) Service: (($r.service? | default ""))"
            ($r.raw | transpose key value) | table -e
          }
          $summary
        }
      }
      "restart" => {
        $service_names | reduce -f [] {|svc acc|
          let meta = (build_service_meta (resolve_service $cfg $svc))
          let rows = (restart_hosts_cmd $meta $target_hosts --sudo=$sudo)
          $acc | append ($rows | each {|r| $r | insert service $svc })
        }
      }
      "download" => {
        if ($target_hosts | is-empty) { error make {msg: "No hosts selected for download (use --group or --hosts)"} }
        let dl_conf = (load_downloads $cfg_path)
        let names = (if ($name | is-empty) { [] } else { $name | split row "," | each {|it| $it | str trim } })
        download_items_remote $dl_conf $target_hosts $names --sudo=$sudo
      }
      "copy" => {
        if ($target_hosts | is-empty) { error make {msg: "No hosts selected for copy (use --group or --hosts)"} }
        let cp_conf = (load_copies $cfg_path)
        let names = (if ($name | is-empty) { [] } else { $name | split row "," | each {|it| $it | str trim } })
        copy_items_cmd $cp_conf $target_hosts $names --sudo=$sudo
      }
      _ => { error make {msg: $"Unknown command: ($command)"} }
    }
  )
  if $json { $out | to json } else { $out | table }
}

export def plan_hosts_cmd [meta: record hosts: list<record> --sudo = false] {
  $hosts | each {|h| plan_host $meta $h --sudo=$sudo | insert action "plan" }
}

export def deploy_hosts_cmd [meta: record hosts: list<record> --sudo = false] {
  $hosts | each {|h| deploy_host $meta $h --sudo=$sudo }
}

export def status_hosts_cmd [meta: record hosts: list<record> --sudo = false] { $hosts | each {|h| status_host $meta $h --sudo=$sudo } }

export def restart_hosts_cmd [meta: record hosts: list<record> --sudo = false] { $hosts | each {|h| restart_host $meta $h --sudo=$sudo } }
