#!/bin/bash

restic_ssh_opts=()
ssh_wrapper_dir=

apply_ssh_key() {
    restic_ssh_opts=()
    ssh_key_error=
    if [ -z "$BACKUP_SSH_KEY" ]; then
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
    if [ "$BACKUP_RESTIC" = "y" ] && [[ ${RESTIC_REPOSITORY:-} == sftp:* ]]; then
        if [ -z "$ssh_wrapper_dir" ]; then
            ssh_wrapper_dir=$(mktemp -d "${TMPDIR:-/tmp}/backup-ssh.XXXXXX") || {
                ssh_key_error="Verzeichnis für den SSH-Aufruf konnte nicht angelegt werden"
                return 1
            }
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
        fi
        restic_ssh_opts=(-o "sftp.command=$ssh_wrapper_dir/ssh")
    fi
}

remove_ssh_wrapper() {
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
