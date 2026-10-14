#!/bin/bash

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
    export BACKUP_BORG BACKUP_RESTIC
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
        echo "@@BACKEND restic start"
        echo "Creating backup with restic of $*"
        restic_backup_paths "$name" "$kind" "$use_excludes" "$tries" "$@"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            backup_failed=1
        fi
        echo "@@BACKEND restic end $rc"
    fi
    return $backup_failed
}
