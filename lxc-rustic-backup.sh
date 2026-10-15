#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export BACKUP_BORG=n
export BACKUP_RESTIC=y
export RESTIC_PROGRAM=rustic
exec "$SCRIPT_DIR/lxc-backup.sh" "$@"
