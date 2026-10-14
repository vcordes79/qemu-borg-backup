#!/bin/bash

archive_glob() {
    printf '%s-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*' "$1"
}

load_borg_excludes() {
    if [ -z "$BORG_EXCLUDE" ]; then
        borg_excludes=(--exclude '*/.btrfs' --exclude '*/.snapshots')
    else
        set -f
        read -r -a borg_excludes <<< "$BORG_EXCLUDE"
        set +f
    fi
}

maybe_break_lock() {
    if [ "x$BORG_BREAK_LOCK" == "x" -o "x$BORG_BREAK_LOCK" == "xy" ]; then
        if borg list 2>&1 | grep lock.exclusive; then
            if pidof borg >/dev/null; then
                echo "warning: Borg-Prozess läuft, Sperre bleibt bestehen"
            else
                borg break-lock
            fi
        fi
    fi
}

borg_backup_paths() {
    local name=$1 use_excludes=$2 tries=$3
    shift 3
    local -a paths=("$@")
    local -a exclude_args=()
    local attempt=1 last=0
    if [ "$use_excludes" = "y" ]; then
        load_borg_excludes
        exclude_args=("${borg_excludes[@]}")
    fi
    while true; do
        borg create -v -C zstd --stats "${exclude_args[@]}" "$BORG_REPO::$name-{now}" -- "${paths[@]}" 2>&1
        last=$?
        if [ "$last" -eq 0 ]; then
            return 0
        fi
        if [ "$attempt" -ge "$tries" ]; then
            echo "error creating borg backup for $name"
            if [ "$tries" -eq 1 ] && [ "$last" -eq 2 ]; then
                return 2
            fi
            return 1
        fi
        maybe_break_lock
        sleep 60
        attempt=$((attempt + 1))
    done
}

borg_forget() {
    local name=$1 result
    maybe_break_lock
    result=$(borg prune -v --list --glob-archives "$(archive_glob "$name")" --keep-daily="$KEEP_DAILY" --keep-weekly="$KEEP_WEEKLY" --keep-monthly="$KEEP_MONTHLY" "$BORG_REPO" 2>&1)
    if [ $? -gt 0 ]; then
        write_warning "$phase $name borg" "Backups für $name konnten nicht aufgeräumt werden"
        write_warning "$phase $name borg" "$result"
    else
        write_success "$phase $name borg" "$result"
    fi
}

borg_compact() {
    local result
    if borg --help 2>&1 | grep -q compact; then
        result=$(borg compact -v 2>&1)
        if [ $? -gt 0 ]; then
            write_warning "$phase borg" "Repository konnte nicht komprimiert werden"
            write_warning "$phase borg" "$result"
        else
            write_success "$phase borg" "$result"
        fi
    else
        write_info "$phase borg" "BORG: Compact nicht unterstützt"
    fi
}
