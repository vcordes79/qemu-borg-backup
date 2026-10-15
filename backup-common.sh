#!/bin/bash

restic_ssh_opts=()
ssh_wrapper_dir=
socat_pid=
nghttpx_pid=
rustic_rest_repository=
rustic_fallback_warning=

apply_ssh_key() {
    restic_ssh_opts=()
    ssh_key_error=
    if [ -z "$BACKUP_SSH_KEY" ]; then
        if ! apply_restic_immutable; then
            remove_ssh_wrapper
            ssh_key_error=$restic_immutable_error
            return 1
        fi
        return 0
    fi
    if [ ! -e "$BACKUP_SSH_KEY" ]; then
        ssh_key_error="SSH-Key nicht gefunden: $BACKUP_SSH_KEY"
        return 1
    fi
    if [ ! -r "$BACKUP_SSH_KEY" ]; then
        ssh_key_error="SSH-Key nicht lesbar: $BACKUP_SSH_KEY"
        return 1
    fi
    local perm
    perm=$(stat -c '%a' "$BACKUP_SSH_KEY")
    if (( (8#$perm & 8#077) != 0 )); then
        ssh_key_error="SSH-Key darf für Gruppe und Andere keine Rechte haben: $BACKUP_SSH_KEY"
        return 1
    fi
    local q
    q=${BACKUP_SSH_KEY//\'/\'\\\'\'}
    export BORG_RSH="ssh -i '$q' -o IdentitiesOnly=yes"
    if [ "$BACKUP_RESTIC" = "y" ] && [ "$RESTIC_PROGRAM" != "rustic" ] && [[ ${RESTIC_REPOSITORY:-} == sftp:* ]]; then
        if ! ensure_ssh_wrapper_dir; then
            return 1
        fi
        printf '%s\n' '#!/bin/sh' "exec ssh -i '$q' -o IdentitiesOnly=yes \"\$@\"" > "$ssh_wrapper_dir/ssh" || {
            ssh_key_error="SSH-Aufruf konnte nicht geschrieben werden"
            remove_ssh_wrapper
            return 1
        }
        chmod 700 "$ssh_wrapper_dir/ssh" || {
            ssh_key_error="SSH-Aufruf konnte nicht ausführbar gemacht werden"
            remove_ssh_wrapper
            return 1
        }
        restic_ssh_opts=(-o "sftp.command=$ssh_wrapper_dir/ssh")
    fi
    if ! apply_restic_immutable; then
        remove_ssh_wrapper
        if [ -z "$ssh_key_error" ]; then
            ssh_key_error=$restic_immutable_error
        fi
        return 1
    fi
}

ensure_ssh_wrapper_dir() {
    if [ -n "$ssh_wrapper_dir" ]; then
        return 0
    fi
    ssh_wrapper_dir=$(mktemp -d "${TMPDIR:-/tmp}/backup-ssh.XXXXXX") || {
        ssh_key_error="Verzeichnis für den SSH-Aufruf konnte nicht angelegt werden"
        return 1
    }
}

parse_immutable_target() {
    local spec=${RESTIC_REPOSITORY#rclone:}
    restic_immutable_target=
    restic_immutable_port=
    if [ "$spec" = "$RESTIC_REPOSITORY" ] || [ -z "$spec" ]; then
        restic_immutable_error="RESTIC_REPOSITORY muss im Immutable-Modus die Form rclone:user@host haben"
        return 1
    fi
    if [[ "$spec" == */* ]]; then
        spec=${spec%%/*}
    fi
    if [[ "$spec" =~ ^(.+@[^:]+):([0-9]+)$ ]]; then
        restic_immutable_target=${BASH_REMATCH[1]}
        restic_immutable_port=${BASH_REMATCH[2]}
    elif [[ "$spec" =~ ^(.+@[^:]+):.+$ ]]; then
        restic_immutable_target=${BASH_REMATCH[1]}
    else
        restic_immutable_target=$spec
    fi
    if [[ "$restic_immutable_target" != *@* ]]; then
        restic_immutable_error="RESTIC_REPOSITORY muss im Immutable-Modus die Form rclone:user@host haben"
        return 1
    fi
}

apply_restic_immutable() {
    restic_immutable_error=
    if [ "$RESTIC_IMMUTABLE" != "y" ] || [ "$BACKUP_RESTIC" != "y" ]; then
        return 0
    fi
    if ! parse_immutable_target; then
        return 1
    fi
    if [ "$RESTIC_PROGRAM" = "rustic" ]; then
        apply_rustic_immutable
        return $?
    fi
    local program q
    program="ssh -o BatchMode=yes"
    if [ -n "$restic_immutable_port" ]; then
        program+=" -p $restic_immutable_port"
    fi
    if [ -n "$BACKUP_SSH_KEY" ]; then
        q=${BACKUP_SSH_KEY//\'/\'\\\'\'}
        program+=" -i '$q' -o IdentitiesOnly=yes"
    fi
    program+=" $restic_immutable_target"
    restic_ssh_opts+=(-o "rclone.program=$program")
}

nghttpx_bin() {
    if command -v nghttpx >/dev/null 2>&1; then
        command -v nghttpx
        return 0
    fi
    if [ -x /usr/sbin/nghttpx ]; then
        printf '%s\n' /usr/sbin/nghttpx
        return 0
    fi
    return 1
}

fallback_from_rustic() {
    rustic_fallback_warning=
    if [ "$BACKUP_RESTIC" != "y" ] || [ "$RESTIC_PROGRAM" != "rustic" ]; then
        return 0
    fi
    local -a missing=()
    local last head
    if ! command -v rustic >/dev/null 2>&1; then
        missing+=(rustic)
    fi
    if [ "$RESTIC_IMMUTABLE" = "y" ]; then
        if ! command -v socat >/dev/null 2>&1; then
            missing+=(socat)
        fi
        if ! nghttpx_bin >/dev/null 2>&1; then
            missing+=(nghttpx)
        fi
    fi
    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi
    RESTIC_PROGRAM=restic
    export RESTIC_PROGRAM
    if [ "${#missing[@]}" -eq 1 ]; then
        rustic_fallback_warning="Rustic wird nicht verwendet, weil ${missing[0]} fehlt. Es wird Restic verwendet."
        return 0
    fi
    last=${missing[-1]}
    unset 'missing[-1]'
    head=$(IFS=,; printf '%s' "${missing[*]}")
    head=${head//,/, }
    rustic_fallback_warning="Rustic wird nicht verwendet, weil ${head} und ${last} fehlen. Es wird Restic verwendet."
}

wait_for_port() {
    local pid=$1 log=$2 pattern=$3 i port
    for i in $(seq 1 50); do
        if [ ! -d "/proc/$pid" ]; then
            return 1
        fi
        port=$(sed -n "$pattern" "$log" | head -1)
        if [ -n "$port" ]; then
            printf '%s\n' "$port"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

stop_recorded_pid() {
    local pid=$1 pgid child
    [ -n "$pid" ] || return 0
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
        kill -- -"$pid" 2>/dev/null || true
        return 0
    fi
    for child in $(ps -o pid= --ppid "$pid" 2>/dev/null); do
        kill "$child" 2>/dev/null || true
    done
    kill "$pid" 2>/dev/null || true
}

start_detached() {
    local log=$1
    shift
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" >"$log" 2>&1 &
    else
        "$@" >"$log" 2>&1 &
    fi
    start_detached_pid=$!
}

apply_rustic_immutable() {
    local ssh_exec q log sport hport i nghttpx
    if [ -n "$socat_pid" ] && [ -d "/proc/$socat_pid" ] && [ -n "$nghttpx_pid" ] && [ -d "/proc/$nghttpx_pid" ]; then
        return 0
    fi
    stop_recorded_pid "$nghttpx_pid"
    stop_recorded_pid "$socat_pid"
    nghttpx_pid=
    socat_pid=
    command -v socat >/dev/null 2>&1 || {
        restic_immutable_error="Für den Immutable-Modus mit Rustic wird socat benötigt"
        return 1
    }
    nghttpx=$(nghttpx_bin) || {
        restic_immutable_error="Für den Immutable-Modus mit Rustic wird nghttpx benötigt"
        return 1
    }
    if ! ensure_ssh_wrapper_dir; then
        restic_immutable_error=$ssh_key_error
        return 1
    fi
    ssh_exec="ssh -o BatchMode=yes"
    if [ -n "$restic_immutable_port" ]; then
        ssh_exec+=" -p $restic_immutable_port"
    fi
    if [ -n "$BACKUP_SSH_KEY" ]; then
        q=${BACKUP_SSH_KEY//\'/\'\\\'\'}
        ssh_exec+=" -i '$q' -o IdentitiesOnly=yes"
    fi
    ssh_exec+=" $restic_immutable_target"
    log=$ssh_wrapper_dir/socat.log
    start_detached "$log" socat -d -d "TCP-LISTEN:0,bind=127.0.0.1,reuseaddr,fork" "EXEC:$ssh_exec"
    socat_pid=$start_detached_pid
    sport=$(wait_for_port "$socat_pid" "$log" 's/.*listening on .*:\([0-9][0-9]*\).*/\1/p') || {
        restic_immutable_error="Socat-Tunnel konnte nicht gestartet werden"
        if [ -s "$log" ]; then
            restic_immutable_error+=": $(tr '\n' ' ' < "$log")"
        fi
        return 1
    }
    log=$ssh_wrapper_dir/nghttpx.log
    hport=
    for i in 1 2 3 4 5; do
        hport=$((20000 + RANDOM % 20000))
        : >"$log"
        start_detached "$log" "$nghttpx" -f "127.0.0.1,${hport};no-tls" -b "127.0.0.1,${sport};/;proto=h2"
        nghttpx_pid=$start_detached_pid
        if wait_for_port "$nghttpx_pid" "$log" "s/.*Listening on 127\\.0\\.0\\.1:\\(${hport}\\).*/\\1/p" >/dev/null; then
            break
        fi
        stop_recorded_pid "$nghttpx_pid"
        nghttpx_pid=
        hport=
    done
    if [ -z "$hport" ]; then
        restic_immutable_error="nghttpx konnte nicht gestartet werden"
        if [ -s "$log" ]; then
            restic_immutable_error+=": $(tr '\n' ' ' < "$log")"
        fi
        return 1
    fi
    rustic_rest_repository="rest:http://127.0.0.1:${hport}/"
    export rustic_rest_repository
}

remove_ssh_wrapper() {
    stop_recorded_pid "$nghttpx_pid"
    stop_recorded_pid "$socat_pid"
    nghttpx_pid=
    socat_pid=
    rustic_rest_repository=
    if [ -n "$ssh_wrapper_dir" ]; then
        rm -rf "$ssh_wrapper_dir"
        ssh_wrapper_dir=
    fi
}

resolve_backends() {
    if [ -z "$BACKUP_BORG" ] && [ -z "$BACKUP_RESTIC" ]; then
        BACKUP_BORG=y
    fi
    if [ "$BACKUP_BORG" != "y" ]; then
        BACKUP_BORG=
    fi
    if [ "$BACKUP_RESTIC" != "y" ]; then
        BACKUP_RESTIC=
    fi
    if [ "$RESTIC_IMMUTABLE" != "y" ]; then
        RESTIC_IMMUTABLE=
    fi
    restic_program_error=
    if [ -z "$RESTIC_PROGRAM" ]; then
        RESTIC_PROGRAM=restic
    fi
    if [ "$RESTIC_PROGRAM" != "restic" ] && [ "$RESTIC_PROGRAM" != "rustic" ]; then
        restic_program_error="RESTIC_PROGRAM muss restic oder rustic sein"
    fi
    export BACKUP_BORG BACKUP_RESTIC RESTIC_IMMUTABLE RESTIC_PROGRAM
}

run_enabled_backends() {
    local name=$1 kind=$2 use_excludes=$3 tries=$4
    shift 4
    local backup_failed=0 rc

    if [ "$BACKUP_BORG" = "y" ]; then
        echo "@@BACKEND borg start"
        echo "Creating backup with borg of $*"
        borg_backup_paths "$name" "$use_excludes" "$tries" "$@"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            backup_failed=1
        fi
        echo "@@BACKEND borg end $rc"
    fi
    if [ "$BACKUP_RESTIC" = "y" ]; then
        echo "@@BACKEND $RESTIC_PROGRAM start"
        echo "Creating backup with $RESTIC_PROGRAM of $*"
        restic_backup_paths "$name" "$kind" "$use_excludes" "$tries" "$@"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            backup_failed=1
        fi
        echo "@@BACKEND $RESTIC_PROGRAM end $rc"
    fi
    return $backup_failed
}
