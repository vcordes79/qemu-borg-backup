#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export BACKUP_BORG=y
export BACKUP_RESTIC=n
exec "$SCRIPT_DIR/lxc-backup.sh" "$@"
