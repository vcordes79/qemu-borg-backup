#!/bin/bash

run_restic() {
    restic "${restic_ssh_opts[@]}" "$@"
}

load_restic_excludes() {
    if [ -z "$BORG_EXCLUDE" ]; then
        restic_excludes=(--exclude '*/.btrfs' --exclude '*/.snapshots')
    else
        set -f
        read -r -a restic_excludes <<< "$BORG_EXCLUDE"
        set +f
    fi
}

restic_compression_args() {
    if restic backup --help 2>&1 | grep -q -- '--compression'; then
        restic_compression=(--compression max)
    else
        restic_compression=()
    fi
}

maybe_unlock_restic() {
    local out
    if [ "$RESTIC_IMMUTABLE" = "y" ]; then
        return 0
    fi
    if [ "x$BORG_BREAK_LOCK" != "x" ] && [ "x$BORG_BREAK_LOCK" != "xy" ]; then
        return 0
    fi
    if out=$(run_restic snapshots 2>&1); then
        return 0
    fi
    if printf '%s\n' "$out" | grep -q -i 'lock'; then
        if pidof restic >/dev/null; then
            echo "warning: Restic-Prozess läuft, Sperre bleibt bestehen"
        else
            run_restic unlock
        fi
    fi
}

restic_backup_paths() {
    local name=$1 kind=$2 use_excludes=$3 tries=$4
    shift 4
    local -a paths=("$@")
    local -a exclude_args=()
    local attempt=1 last=0
    restic_compression_args
    if [ "$use_excludes" = "y" ]; then
        load_restic_excludes
        exclude_args=("${restic_excludes[@]}")
    fi
    while true; do
        run_restic backup --verbose "${restic_compression[@]}" \
            --tag "kind=$kind" --tag "name=$name" --host "$name" \
            "${exclude_args[@]}" -- "${paths[@]}" 2>&1
        last=$?
        if [ "$last" -eq 0 ]; then
            return 0
        fi
        if [ "$attempt" -ge "$tries" ]; then
            echo "error creating restic backup for $name"
            if [ "$tries" -eq 1 ] && [ "$last" -eq 2 ]; then
                return 2
            fi
            return 1
        fi
        maybe_unlock_restic
        sleep 60
        attempt=$((attempt + 1))
    done
}

restic_forget() {
    local kind=$1 name=$2 result
    if [ "$RESTIC_IMMUTABLE" = "y" ]; then
        return 0
    fi
    maybe_unlock_restic
    result=$(run_restic forget --verbose \
        --tag "kind=$kind" --tag "name=$name" \
        --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" 2>&1)
    if [ $? -gt 0 ]; then
        write_warning "$phase $name restic" "Backups für $name konnten nicht aufgeräumt werden"
        write_warning "$phase $name restic" "$result"
    else
        write_success "$phase $name restic" "$result"
    fi
}

restic_prune() {
    local result
    if [ "$RESTIC_IMMUTABLE" = "y" ]; then
        write_info "$phase restic" "Immutable-Modus, Aufbewahrung bleibt unverändert"
        return 0
    fi
    result=$(run_restic prune 2>&1)
    if [ $? -gt 0 ]; then
        write_warning "$phase restic" "Repository konnte nicht aufgeräumt werden"
        write_warning "$phase restic" "$result"
    else
        write_success "$phase restic" "$result"
    fi
}
