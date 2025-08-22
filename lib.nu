# nudeploy lib.nu - unified config + ssh helpers + deploy logic

# Load unified config TOML with [[hosts]] and [[services]]
export def load_config [path: string] {
    mut p = $path
    if (not ($p | path exists)) {
    error make { msg: $"Config not found: ($path)" }
    }
    let raw = (open --raw $p)
    let data = ($raw | from toml)
    {
        hosts: ($data.hosts? | default []),
        services: ($data.services? | default [])
    }
}

# Build host list based on group/hosts filters. When no filter, return enabled hosts.
export def select_targets [cfg: record, group?: string, hosts?: string] {
    if ($hosts | is-not-empty) {
        let wanted = ($hosts | split row "," | where ($it | str length) > 0 | uniq)
        $cfg.hosts | where {|h| $wanted | any {|w| ($h.name | default "") == $w }}
    } else {
        if ($group | is-not-empty) {
            $cfg.hosts | where {|h| ($h.group? | default "") == $group } | where {|h| ($h.enable? | default true) }
        } else {
            $cfg.hosts | where {|h| ($h.enable? | default true) }
        }
    }
}

# Resolve a service by name
export def resolve_service [cfg: record, name: string] {
    let svc = ($cfg.services | where {|s| ($s.name | default "") == $name } | first)
    if ($svc == null) { error make { msg: $"Service not found in config: ($name)" } } else { $svc }
}

# Normalize service meta into internal shape
export def build_service_meta [svc: record] {
    let name = ($svc.name)
    let src_dir = ($svc.src_dir)
    let dst_dir = ($svc.dst_dir)
    let unit_file0 = ($svc.unit_file)
    let unit_file = (if ((($unit_file0 | path type) == "file") or ($unit_file0 | str starts-with "/")) { $unit_file0 } else { [$src_dir $unit_file0] | path join })
    let unit_dest = $"/etc/systemd/system/($name).service"
    let restart_mode = (if ($svc.restart? | default false) { "on-change" } else { "never" })
    let enable_service = ($svc.enable? | default true)
    let sync0 = ($svc.sync_files? | default [])
    let sync_items = ($sync0 | each {|it|
        let from = ($it.from)
        let to = ($it.to)
        let has_chmod = (not (($it.chmod? | default "") | is-empty))
        let mode_val = (if $has_chmod { ($it.chmod | into string) } else { "0644" })
        let is_url = ((($from | str starts-with "http://") or ($from | str starts-with "https://")))
        let local_path = (if $is_url { null } else { if ($from | str starts-with "/") { $from } else { [$src_dir $from] | path join } })
        let dest_path = (if ($to | str starts-with "/") { $to } else { [$dst_dir $to] | path join })
        { from: $from, to: $to, from_type: (if $is_url { "url" } else { "local" }), local_path: $local_path, url: (if $is_url { $from } else { null }), dest_path: $dest_path, mode: $mode_val, chmod_after: $has_chmod }
    })
    {
        service_name: $name,
        src_dir: $src_dir,
        dst_dir: $dst_dir,
        unit_file: $unit_file,
        unit_dest: $unit_dest,
        restart: $restart_mode,
        enable: $enable_service,
        sync_items: $sync_items,
    }
}

# Build ssh/scp target args from host record
def build_target [h: record] {
    let user = ($h.user? | default "")
    let port = ($h.port? | default null)
    let host = (if ((($h.ip? | default "") | is-not-empty)) { $h.ip } else { $h.name })
    let login = (if ($user | is-not-empty) { $"($user)@($host)" } else { $host })
    { login: $login, port: $port }
}

export def ssh_run [h: record, cmd: string, --sudo=false] {
    let t = (build_target $h)
    let full = (if $sudo { $"sudo -n bash -lc '($cmd)'" } else { $"bash -lc '($cmd)'" })
    if ($t.port == null) {
        (^ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new $t.login $full | complete)
    } else {
        (^ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p ($t.port | into string) $t.login $full | complete)
    }
}

export def scp_upload [h: record, local: string, remote: string] {
    let t = (build_target $h)
    if ($t.port == null) {
        (^scp -q -p $local $"($t.login):($remote)" | complete)
    } else {
        (^scp -q -P ($t.port | into string) -p $local $"($t.login):($remote)" | complete)
    }
}


export def local_sha256 [path: string] {
    if (which sha256sum | is-not-empty) {
        let out = (^sha256sum -b $path | str trim)
        parse_hash_output $out
    } else {
        if (which shasum | is-not-empty) {
            let out = (^shasum -a 256 $path | str trim)
            parse_hash_output $out
        } else {
            if (which openssl | is-not-empty) {
                let out = (^openssl dgst -sha256 $path | str trim)
                parse_hash_output $out
            } else {
                error make { msg: "No local hasher found (sha256sum/shasum/openssl)" }
            }
        }
    }
}

export def parse_hash_output [s: string] { if ($s | str contains "=") { $s | split row "=" | last | str trim } else { $s | split row ' ' | first | str trim } }

export def remote_sha256 [h: record, path: string] {
        let script = $"if [ -f '($path)' ]; then if command -v sha256sum >/dev/null 2>&1; then sha256sum -b '($path)' | cut -d ' ' -f1; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 '($path)' | cut -d ' ' -f1; elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 '($path)' | sed -e 's/^.*= //'; else echo NONE; fi; else echo MISSING; fi"
    let res = (ssh_run $h $script)
    if ($res.exit_code != 0) { "ERROR" } else { $res.stdout | str trim }
}

export def ensure_dir [h: record, path: string, --sudo=false] { ssh_run $h $"mkdir -p '($path)'" --sudo=$sudo }

export def ensure_parent_dir [h: record, path: string, --sudo=false] {
    let parent = ($path | path dirname)
    ensure_dir $h $parent --sudo=$sudo
}

export def install_file [h: record, tmp: string, dest: string, mode: string, --sudo=false] {
    let cmd = $"if command -v install >/dev/null 2>&1; then install -m ($mode) '($tmp)' '($dest)'; else mv '($tmp)' '($dest)' && chmod ($mode) '($dest)'; fi"
    ssh_run $h $cmd --sudo=$sudo
}

export def compare_and_upload [h: record, svc: record, local_path: string, dest_path: string, mode: string, --sudo=false] {
    let local_hash = (local_sha256 $local_path)
    let rhash = (remote_sha256 $h $dest_path)
    if ($rhash == $local_hash) {
        { changed: false, reason: "up-to-date" }
    } else {
            let uid = (random uuid)
            let tmp = $"/tmp/nudeploy-($svc.service_name)-($dest_path | path basename)-($uid).tmp"
            let res1 = (scp_upload $h $local_path $tmp)
            if ($res1.exit_code != 0) { error make { msg: $"scp failed: ($res1.stderr)" } }
            let res2 = (install_file $h $tmp $dest_path $mode --sudo=$sudo)
            if ($res2.exit_code != 0) {
                let hint = (if ((not $sudo) and ($res2.stderr | str contains "Permission denied") and ($dest_path | str starts-with "/etc/")) { " (unit under /etc; try --sudo)" } else { "" })
                error make { msg: $"remote install failed: (($res2.stderr | str trim))($hint)" }
            }
            { changed: true, reason: "copied" }
    }
}

export def remote_download_and_place [h: record, svc: record, url: string, dest_path: string, mode: string, --sudo=false] {
    let current_hash = (remote_sha256 $h $dest_path)
    let uid = (random uuid)
    let tmp = $"/tmp/nudeploy-($svc.service_name)-dl-($uid).tmp"
    let dl = (ssh_run $h $"set -e; if command -v curl >/dev/null 2>&1; then curl -fsSL '($url)' -o '($tmp)'; elif command -v wget >/dev/null 2>&1; then wget -qO '($tmp)' '($url)'; else echo 'ERR:NO_DOWNLOADER' >&2; exit 127; fi")
    if ($dl.exit_code != 0) { error make { msg: $"remote download failed: ($dl.stderr | str trim)" } }
    let new_hash = (remote_sha256 $h $tmp)
    if ($new_hash == $current_hash) {
        # no change; remove tmp
        ssh_run $h $"rm -f '($tmp)'" | ignore
        { changed: false, reason: "up-to-date" }
    } else {
        let res2 = (install_file $h $tmp $dest_path $mode --sudo=$sudo)
        if ($res2.exit_code != 0) {
            let hint = (if ((not $sudo) and ($res2.stderr | str contains "Permission denied") and ($dest_path | str starts-with "/etc/")) { " (unit under /etc; try --sudo)" } else { "" })
            error make { msg: $"remote install failed: (($res2.stderr | str trim))($hint)" }
        }
        { changed: true, reason: "downloaded" }
    }
}

export def systemd_action [h: record, svc_name: string, action: string, --sudo=false] { ssh_run $h $"systemctl ($action) '($svc_name)'" --sudo=$sudo }

export def is_enabled [h: record, svc_name: string, --sudo=false] { let r = (ssh_run $h $"systemctl is-enabled '($svc_name)'" --sudo=$sudo); $r.exit_code == 0 }

export def is_active [h: record, svc_name: string, --sudo=false] { let r = (ssh_run $h $"systemctl is-active '($svc_name)'" --sudo=$sudo); $r.exit_code == 0 }

export def plan_host [meta: record, host: record, --sudo=false] {
    let unit_local = (local_sha256 $meta.unit_file)
    let unit_remote = (remote_sha256 $host $meta.unit_dest)
    let unit_action = (if ($unit_remote != $unit_local) { "upload-unit" } else { "ok" })
    # Build per-file plan details
    let file_plans = (
        $meta.sync_items | each {|x|
            let remote_hash = (remote_sha256 $host $x.dest_path)
            if ($x.from_type == "local") {
                let local_hash = (local_sha256 $x.local_path)
                if ($remote_hash == "MISSING") {
                    { from: $x.from, to: $x.to, dest: $x.dest_path, source: "local", mode: $x.mode, remote_hash: $remote_hash, local_hash: $local_hash, changed: true, action: "create", reason: "remote missing" }
                } else if ($remote_hash != $local_hash) {
                    { from: $x.from, to: $x.to, dest: $x.dest_path, source: "local", mode: $x.mode, remote_hash: $remote_hash, local_hash: $local_hash, changed: true, action: "update", reason: "sha mismatch" }
                } else {
                    { from: $x.from, to: $x.to, dest: $x.dest_path, source: "local", mode: $x.mode, remote_hash: $remote_hash, local_hash: $local_hash, changed: false, action: "none", reason: "up-to-date" }
                }
            } else {
                # URL source: we don't download during plan; we can only tell if dest missing now
                if ($remote_hash == "MISSING") {
                    { from: $x.from, to: $x.to, dest: $x.dest_path, source: "url", mode: $x.mode, remote_hash: $remote_hash, changed: true, action: "create", reason: "remote missing (will download)" }
                } else {
                    { from: $x.from, to: $x.to, dest: $x.dest_path, source: "url", mode: $x.mode, remote_hash: $remote_hash, changed: false, action: "maybe-update", reason: "url source; hash unknown until download" }
                }
            }
        }
    )
    let files_changed = ($file_plans | where changed | length)
    # Predict systemd actions
    let enabled_now = (is_enabled $host $meta.service_name --sudo=$sudo)
    let active_now = (is_active $host $meta.service_name --sudo=$sudo)
    let daemon_reload = ($unit_action != "ok")
    let will_enable = (if $meta.enable { (not $enabled_now) } else { false })
    let will_start = (not $active_now)
    let will_restart = (if ($meta.restart == "on-change") { ($files_changed > 0 or $daemon_reload) and $active_now } else { false })
    {
        host: ($host.name | default (build_target $host).login),
        unit_action: $unit_action,
        daemon_reload: $daemon_reload,
        enable: $will_enable,
        start: $will_start,
        restart: $will_restart,
        files_changed: $files_changed,
        files: $file_plans,
        details: {
            unit: { remote: $unit_remote, local: $unit_local },
            systemd: { enabled_now: $enabled_now, active_now: $active_now }
        }
    }
}

export def deploy_host [meta: record, host: record, --sudo=false] {
    mut changed = false
    mut events = []
    # File/dir operations run as SSH user even when --sudo is set; only systemd actions use sudo.
    let mkdst = (ensure_dir $host $meta.dst_dir --sudo=false)
    if ($mkdst.exit_code != 0) { error make { msg: $"mkdir failed for dst_dir: ($meta.dst_dir): ($mkdst.stderr | str trim)" } }
    # unit upload goes to /etc; honor --sudo here. Other file/dir ops below run as SSH user.
    let unit_res = (compare_and_upload $host $meta $meta.unit_file $meta.unit_dest "0644" --sudo=$sudo)
    if ($unit_res.changed) { $changed = true; $events = ($events | append { type: "upload", target: "unit", dest: $meta.unit_dest, reason: $unit_res.reason }) }
    # sync files
    for x in $meta.sync_items {
        let mkparent = (ensure_parent_dir $host $x.dest_path --sudo=false)
        if ($mkparent.exit_code != 0) { error make { msg: $"mkdir failed for parent of: ($x.dest_path): ($mkparent.stderr | str trim)" } }
        if ($x.from_type == "local") {
            let res = (compare_and_upload $host $meta $x.local_path $x.dest_path $x.mode --sudo=false)
            if ($res.changed) { $changed = true; $events = ($events | append { type: "upload", target: "file", dest: $x.dest_path, reason: $res.reason }) }
        } else {
            let res = (remote_download_and_place $host $meta $x.url $x.dest_path $x.mode --sudo=false)
            if ($res.changed) { $changed = true; $events = ($events | append { type: "download", target: "file", dest: $x.dest_path, reason: $res.reason, source: $x.url }) }
        }
        # If chmod explicitly configured, enforce it after sync with sudo
        if ($x.chmod_after == true) {
            let ch = (ssh_run $host $"chmod ($x.mode) '($x.dest_path)'" --sudo=false)
            if ($ch.exit_code != 0) {
                error make { msg: $"chmod failed for: ($x.dest_path): ($ch.stderr | str trim)" }
            }
            $events = ($events | append { type: "chmod", target: "file", dest: $x.dest_path, mode: $x.mode })
        }
    }
    if ($unit_res.changed) {
        let dr = (ssh_run $host "systemctl daemon-reload" --sudo=$sudo)
        if ($dr.exit_code != 0) { error make { msg: $"daemon-reload failed: ($dr.stderr | str trim)" } }
        $events = ($events | append { type: "systemd", action: "daemon-reload" })
    }
    if ($meta.enable) {
        if (not (is_enabled $host $meta.service_name --sudo=$sudo)) {
            let en = (systemd_action $host $meta.service_name "enable" --sudo=$sudo)
            if ($en.exit_code != 0) { error make { msg: $"systemctl enable failed: ($en.stderr | str trim)" } }
            $events = ($events | append { type: "systemd", action: "enable" })
        }
    }
    if (not (is_active $host $meta.service_name --sudo=$sudo)) {
        let st = (systemd_action $host $meta.service_name "start" --sudo=$sudo)
        if ($st.exit_code != 0) { error make { msg: $"systemctl start failed: ($st.stderr | str trim)" } }
        $events = ($events | append { type: "systemd", action: "start" })
    } else {
        if ($changed and $meta.restart == "on-change") {
            let rr = (systemd_action $host $meta.service_name "restart" --sudo=$sudo)
            if ($rr.exit_code != 0) { error make { msg: $"systemctl restart failed: ($rr.stderr | str trim)" } }
            $events = ($events | append { type: "systemd", action: "restart", cause: "changed" })
        }
    }
    { host: ($host.name | default (build_target $host).login), changed: $changed, events: $events }
}

export def status_host [meta: record, host: record, --sudo=false] {
    let enabled = (is_enabled $host $meta.service_name --sudo=$sudo)
    let active = (is_active $host $meta.service_name --sudo=$sudo)
    let info = (ssh_run $host $"systemctl show '($meta.service_name)' --no-page --property=MainPID,ExecMainStatus,ExecMainStartTimestamp,FragmentPath,ActiveState,UnitFileState" --sudo=$sudo)
    let kv = ($info.stdout | lines | where ($it | str contains "=") | parse --regex '^(?<key>[^=]+)=(?<val>.*)$' | reduce -f {} {|it, acc| $acc | upsert $it.key $it.val })
    { host: ($host.name | default (build_target $host).login), enabled: $enabled, active: $active, raw: $kv }
}

export def restart_host [meta: record, host: record, --sudo=false] {
    let r = (systemd_action $host $meta.service_name "restart" --sudo=$sudo)
    { host: ($host.name | default (build_target $host).login), ok: ($r.exit_code == 0), event: { type: "systemd", action: "restart" } }
}

# shell command across hosts
export def shell_host [host: record, cmd: string, --sudo=false] {
    let res = (ssh_run $host $cmd --sudo=$sudo)
    { host: ($host.name | default (build_target $host).login), exit: $res.exit_code, stdout: ($res.stdout | str trim), stderr: ($res.stderr | str trim) }
}

export def list_hosts_cmd [cfg: record, group?: string, --all=false] {
    let hs = (if $all { $cfg.hosts } else { select_targets $cfg $group "" })
    $hs | each {|h| { name: $h.name, ip: ($h.ip? | default ""), port: ($h.port? | default 22), user: ($h.user? | default ""), group: ($h.group? | default ""), enable: ($h.enable? | default true) } }
}

# -------------------------------
# Local downloads (curl + extract)
# -------------------------------

# -------------------------------
# Playbook helpers (line-by-line Nushell/bash commands over SSH)
# -------------------------------

export def parse_playbook [path: string] {
    let raw = (open --raw $path)
    $raw
    | lines
    | enumerate
    | reduce -f [] {|it, acc|
        let line_no = ($it.index + 1)
        let line = ($it.item | str trim)
        if (($line | is-empty) or ($line | str starts-with "#")) {
            $acc
        } else {
            $acc | append { line: $line_no, cmd: $it.item }
        }
    }
}

export def play_host [host: record, steps: list<record>, --sudo=false] {
    mut events = []
    mut ok = true
    mut failed_line = null
    mut failed_cmd = null
    mut exit = 0
    mut stderr = ""
    for s in $steps {
        let res = (ssh_run $host $s.cmd --sudo=$sudo)
        $events = ($events | append { line: $s.line cmd: $s.cmd exit: $res.exit_code stdout: ($res.stdout | str trim) stderr: ($res.stderr | str trim) })
        if ($res.exit_code != 0) {
            $ok = false
            $failed_line = $s.line
            $failed_cmd = $s.cmd
            $exit = $res.exit_code
            $stderr = ($res.stderr | str trim)
            break
        }
    }
    {
        host: ($host.name | default (build_target $host).login),
        ok: $ok,
        failed_line: $failed_line,
        failed_cmd: $failed_cmd,
        exit: $exit,
        stderr: $stderr,
        events: $events
    }
}

# Load only download-related config with sensible defaults
export def load_downloads [path: string] {
    mut p = $path
    if (not ($p | path exists)) {
        error make { msg: $"Config not found: ($path)" }
    }
    let raw = (open --raw $p)
    let data = ($raw | from toml)
    let dir = ($data.download_dir? | default "./downloads")
    let items = ($data.downloads? | default [])
    { download_dir: $dir, downloads: $items }
}

def infer_archive_type [filename: string] {
    if ($filename | str ends-with ".tar.gz") { "tar.gz" } else if ($filename | str ends-with ".tgz") { "tar.gz" } else if ($filename | str ends-with ".tar.xz") { "tar.xz" } else if ($filename | str ends-with ".zip") { "zip" } else if ($filename | str ends-with ".tar") { "tar" } else if ($filename | str ends-with ".gz") { "gz" } else if ($filename | str ends-with ".xz") { "xz" } else { "file" }
}

def extract_archive [archive: string, etype: string, dir: string] {
    match $etype {
        "tar.gz" => { ^tar -xzf $archive -C $dir }
        "tar.xz" => { ^tar -xJf $archive -C $dir }
        "zip" => {
            if (which unzip | is-not-empty) {
                ^unzip -o $archive -d $dir | complete | ignore
            } else if (which ditto | is-not-empty) {
                ^ditto -x -k $archive $dir | complete | ignore
            } else { error make { msg: "Neither unzip nor ditto found to extract zip" } }
        }
        "tar" => { ^tar -xf $archive -C $dir }
        "gz" => {
            if (which gunzip | is-not-empty) { ^gunzip -f $archive } else { error make { msg: "gunzip not found" } }
        }
        "xz" => {
            if (which unxz | is-not-empty) { ^unxz -f $archive } else if (which xz | is-not-empty) { ^xz -d -f $archive } else { error make { msg: "xz/unxz not found" } }
        }
        _ => { }
    }
}

def download_one [dir: string, d: record] {
    let url = ($d.url | into string)
    let filename = ($url | split row "/" | last)
    let target_dir = ($dir | path expand)
    let archive = ($target_dir | path join $filename)
    mut events = []
    mut ok = true
    mut error = null
    let etype = (infer_archive_type $filename)

    mkdir $target_dir | ignore
    ^curl --fail --silent --show-error -L -o $archive $url
    $events = ($events | append "downloaded")
    if ($etype != "file") {
        extract_archive $archive $etype $target_dir
        $events = ($events | append "extracted")
        if ($etype in ["tar.gz", "tar.xz", "zip", "tar"]) {
            rm -f $archive
            $events = ($events | append "removed-archive")
        }
    } else {
        $events = ($events | append "no-extract")
    }

    {
        name: ($d.name? | default null),
        version: ($d.version? | default null),
        url: $url,
        download_dir: $target_dir,
        archive: $archive,
        extract_type: $etype,
        ok: $ok,
        events: $events,
        error: $error,
    }
}

export def download_items [downloads_conf: record, names?: list<string> = []] {
    let dir = ($downloads_conf.download_dir | path expand)
    let items = (
        if ($names | is-empty) {
            $downloads_conf.downloads | where { |d| ($d.enable? | default true) }
        } else {
            let set = ($names | each {|n| $n | str trim } | uniq)
            $downloads_conf.downloads | where { |d| $set | any {|n| $n == ($d.name | into string) } }
        }
    )
    $items | each {|d| download_one $dir $d }
}
