#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export PATH=$PATH:$SCRIPT_DIR:/snap/bin
export BORG_DIRS_SYSTEM="/usr/local /etc"
# shellcheck source=backup-common.sh
source "$SCRIPT_DIR/backup-common.sh"
# shellcheck source=backup-borg.sh
source "$SCRIPT_DIR/backup-borg.sh"
# shellcheck source=backup-restic.sh
source "$SCRIPT_DIR/backup-restic.sh"
resolve_backends

html_escape() {
  local s=$1
  s=${s//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  printf '%s' "$s"
}

write_header() {
  echo "<html><body><table>"
}

publish_status_entry() {
  local path=$1
  if [ -d "$path" ]; then
    chmod 755 "$path"
  elif [ -f "$path" ]; then
    chmod 644 "$path"
  fi
}

publish_status_tree() {
  local dir=$1 entry sub
  [ -d "$dir" ] || return 0
  if [ -d /var/spool/borgbackup ]; then
    chmod 755 /var/spool/borgbackup
  fi
  publish_status_entry "$dir"
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    if [ -d "$entry" ]; then
      publish_status_entry "$entry"
      for sub in "$entry"/*; do
        [ -f "$sub" ] || continue
        publish_status_entry "$sub"
      done
    else
      publish_status_entry "$entry"
    fi
  done
}

open_status_dir() {
  if [ ! -d "$1" ]; then
    mkdir -p "$1" || return 0
  fi
  publish_status_tree "$1"
}

touch_status() {
  touch "$1"
  publish_status_entry "$1"
}

write_warning() {
  echo "<tr style='background-color:yellow;color:black'><th>$(html_escape "$1")</th></tr><tr><td><pre>$(html_escape "$2")</pre></td></tr>"
  [[ "${retval:-0}" -eq 0 ]] && retval=2
  echo "$1: $2" >> "$STATUSDIR/warning.log"
  publish_status_entry "$STATUSDIR/warning.log"
}

write_info() {
  echo "<tr style='background-color:lightblue;color:black'><th>$(html_escape "$1")</th></tr><tr><td><pre>$(html_escape "$2")</pre></td></tr>"
  echo "$1: $2" >> "$STATUSDIR/info.log"
  publish_status_entry "$STATUSDIR/info.log"
}

write_success() {
  echo "<tr style='background-color:lightgreen;color:black'><th>$(html_escape "$1")</th></tr><tr><td><pre>$(html_escape "$2")</pre></td></tr>"
  echo "$1: $2" >> "$STATUSDIR/success.log"
  publish_status_entry "$STATUSDIR/success.log"
}

write_error() {
  echo "<tr style='background-color:red;color:white'><th>$(html_escape "$1")</th></tr><tr><td><pre>$(html_escape "$2")</pre></td></tr>"
  retval=1
  echo "$1: $2" >> "$STATUSDIR/error.log"
  publish_status_entry "$STATUSDIR/error.log"
}

do_exit() {
  if [ -n "${GLOBALSTATUSDIR:-}" ]; then
    publish_status_tree "$GLOBALSTATUSDIR"
  fi
  echo '</table></body></html>'
  exit $1
}

each_borg_dirs() {
    local line name dirs
    while IFS= read -r line; do
        [[ "$line" == BORG_DIRS_*=* ]] || continue
        name=${line%%=*}
        name=${name#BORG_DIRS_}
        dirs=${line#*=}
        [[ -n "$name" ]] || continue
        "$@" "$name" "$dirs"
    done < <(env)
}

note_result() {
    local title=$1 body=$2 code=$3
    if [ "$code" -eq 0 ]; then
        write_success "$title" "$body"
    elif [ "$code" -eq 2 ]; then
        write_warning "$title" "$body"
    else
        write_error "$title" "$body"
    fi
}

apply_child_result() {
    local phase_name=$1 target=$2 result=$3 exitCode=$4
    local line tool="" pre="" post="" saw=0 all_ok=1 rc started=0 rest
    local -A body code
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == "@@BACKEND "*" start" ]]; then
            tool=${line#@@BACKEND }
            tool=${tool% start}
            body[$tool]=""
            saw=1
            started=1
            continue
        fi
        if [[ "$line" == "@@BACKEND "*" end "* ]]; then
            rest=${line#@@BACKEND }
            tool=${rest%% end *}
            rc=${rest##* }
            code[$tool]=$rc
            tool=""
            continue
        fi
        if [ -n "$tool" ]; then
            body[$tool]+="$line"$'\n'
        elif [ "$started" -eq 1 ]; then
            post+="$line"$'\n'
        else
            pre+="$line"$'\n'
        fi
    done <<< "$result"

    if [ "$saw" -eq 0 ]; then
        note_result "$phase_name $target" "$result" "$exitCode"
        if [ "$exitCode" -eq 0 ]; then
            touch_status "$STATUSDIR/timestamp"
        fi
        return
    fi
    for tool in borg restic rustic; do
        [ -v "code[$tool]" ] || continue
        note_result "$phase_name $target $tool" "${body[$tool]}" "${code[$tool]}"
        if [ "${code[$tool]}" != "0" ]; then
            all_ok=0
        fi
    done
    if [ "$exitCode" -ne 0 ]; then
        local trailer=""
        if [ "$all_ok" -eq 1 ]; then
            trailer="$pre$post"
        elif [ -n "${post//[[:space:]]/}" ]; then
            trailer=$post
        fi
        if [ -n "${trailer//[[:space:]]/}" ]; then
            if [ "$exitCode" -eq 2 ]; then
                write_warning "$phase_name $target" "$trailer"
            else
                write_error "$phase_name $target" "$trailer"
            fi
            all_ok=0
        fi
    fi
    if [ "$all_ok" -eq 1 ]; then
        touch_status "$STATUSDIR/timestamp"
    fi
}

run_child() {
    local phase_name=$1 target=$2
    shift 2
    local result exitCode
    STATUSDIR=$GLOBALSTATUSDIR/$target
    open_status_dir "$STATUSDIR"
    rm -f "$STATUSDIR"/*.log
    touch_status "$STATUSDIR/running"
    result=$("$@" 2>&1)
    exitCode=$?
    rm -f "$STATUSDIR/running"
    apply_child_result "$phase_name" "$target" "$result" "$exitCode"
}

forget_enabled() {
    local kind=$1 name=$2
    if [ "$BACKUP_BORG" = "y" ]; then
        borg_forget "$name"
    fi
    if [ "$BACKUP_RESTIC" = "y" ]; then
        restic_forget "$kind" "$name"
    fi
}

forget_dir_group() {
    forget_enabled dir "$1"
}

run_retention() {
    local container domain
    phase="alte Backups löschen"
    if [ "x$LXC_BACKUP" = "xy" ]; then
        for container in $LXC_CONTAINERS; do
            if [ -n "$container" ]; then
                forget_enabled lxc "$container"
            fi
        done
    fi
    for domain in $domains; do
        if [ -n "$domain" ]; then
            forget_enabled vm "$domain"
        fi
    done
    each_borg_dirs forget_dir_group
    phase="Speicherplatz freigeben"
    if [ "$BACKUP_BORG" = "y" ]; then
        borg_compact
    fi
    if [ "$BACKUP_RESTIC" = "y" ]; then
        restic_prune
    fi
}

backup_dir_group() {
    local name=$1 dirs=$2
    local -a paths=()
    local tool rc result all_ok=1
    STATUSDIR=$GLOBALSTATUSDIR/$name
    open_status_dir "$STATUSDIR"
    rm -f "$STATUSDIR"/*.log
    touch_status "$STATUSDIR/running"
    set -f
    # shellcheck disable=SC2086
    paths=($dirs)
    set +f
    if [ "$BACKUP_BORG" = "y" ]; then
        result=$(borg_backup_paths "$name" y 1 "${paths[@]}" 2>&1)
        rc=$?
        note_result "$phase $name borg" "$result" "$rc"
        [ "$rc" -eq 0 ] || all_ok=0
    fi
    if [ "$BACKUP_RESTIC" = "y" ]; then
        result=$(restic_backup_paths "$name" dir y 1 "${paths[@]}" 2>&1)
        rc=$?
        note_result "$phase $name $RESTIC_PROGRAM" "$result" "$rc"
        [ "$rc" -eq 0 ] || all_ok=0
    fi
    rm -f "$STATUSDIR/running"
    if [ "$all_ok" -eq 1 ]; then
        touch_status "$STATUSDIR/timestamp"
    fi
}

# repository settings
if [ "x$MOUNTPOINT" == "x" ]; then
  export MOUNTPOINT=
fi
if [ "x$FS_UUID" == "x" ]; then
  export FS_UUID=
fi
if [ "x$NFS_PATH" == "x" ]; then
  export NFS_PATH=
fi

# retention settings
if [ "x$PRUNE_FIRST" == "x" ]; then
  export PRUNE_FIRST=
fi
if [ "x$KEEP_DAILY" == "x" ]; then
  export KEEP_DAILY=7
fi
if [ "x$KEEP_WEEKLY" == "x" ]; then
  export KEEP_WEEKLY=4
fi
if [ "x$KEEP_MONTHLY" == "x" ]; then
  export KEEP_MONTHLY=4
fi

# lxc settings
if [ "x$LXC_BACKUP" == "x" ]; then
  export LXC_BACKUP=y
fi
if [ "x$LXC_BACKUP" == "xy" ]; then
  if [ "x$LXC_CONTAINERS" == "x" ]; then
    if command -v lxc >/dev/null 2>&1; then
      if LXC_CONTAINERS=$(lxc list --format=csv -c n); then
        export LXC_CONTAINERS
      else
        lxc_list_failed=1
      fi
    fi
  fi
  if [ "x$LXC_STOP_MYSQL" == "x" ]; then
    export LXC_STOP_MYSQL=
  fi
  if [ "x$LXC_STORAGE_PATH" == "x" ]; then
    export LXC_STORAGE_PATH=$(lxc storage get default source)
  fi
fi

# domain / container settings
if [ "x$DEFAULT_DOMAINS" == "x" ] && [ -x /usr/bin/virsh ]; then
  if [ "x$BACKUP_SHUTOFF" == "xy" ]; then
    DEFAULT_DOMAINS=$(set -o pipefail; /usr/bin/virsh list --all --name | tr '\n' ' ')
  else
    DEFAULT_DOMAINS=$(set -o pipefail; /usr/bin/virsh list --name | tr '\n' ' ')
  fi
  if [ $? -ne 0 ]; then
    virsh_list_failed=1
  fi
  export DEFAULT_DOMAINS
fi
if [ $# -eq 0 ]; then
    export domains=$DEFAULT_DOMAINS
else
    export domains=$*
fi

# other settings
if [ "x$BORG_TRIES" == "x" ]; then
  export BORG_TRIES=20
fi

retval=0
if [ "$BACKUP_BORG" = "y" ]; then
  status_source=$BORG_REPO
else
  status_source=$RESTIC_REPOSITORY
fi
shortrepo=$(echo "$status_source" | sed -E 's|/\|:|_|g' | sed -E 's|@|_|g' | sed -E 's|_+|_|g' | sed -E 's|^_||g')
GLOBALSTATUSDIR=/var/spool/borgbackup/$shortrepo
rm -rf /var/spool/borgbackup/*\@*
open_status_dir "$GLOBALSTATUSDIR"

STATUSDIR=$GLOBALSTATUSDIR
rm -f "$STATUSDIR"/*.log

write_header

phase="Parameterprüfung"
if [ -z "$BACKUP_BORG" ] && [ -z "$BACKUP_RESTIC" ]; then
  write_error "$phase" "Kein Backup-Backend ausgewählt"
  do_exit 1
fi
if [ "$BACKUP_BORG" = "y" ]; then
  if [ -z "$BORG_PASSPHRASE" ]; then
    write_error "$phase" "Kein Borg-Passwort angegeben"
    do_exit 1
  fi
  if [ -z "$BORG_REPO" ]; then
    write_error "$phase" "Kein Borg-Repository angegeben"
    do_exit 1
  fi
fi
if [ "$BACKUP_RESTIC" = "y" ]; then
  fallback_from_rustic
  if [ -n "$rustic_fallback_warning" ]; then
    write_warning "$phase" "$rustic_fallback_warning"
  fi
  if [ -n "$restic_program_error" ]; then
    write_error "$phase" "$restic_program_error"
    do_exit 1
  fi
  if [ -z "$RESTIC_PASSWORD" ]; then
    write_error "$phase" "Kein Passwort für $RESTIC_PROGRAM angegeben"
    do_exit 1
  fi
  if [ -z "$RESTIC_REPOSITORY" ]; then
    write_error "$phase" "Kein Repository für $RESTIC_PROGRAM angegeben"
    do_exit 1
  fi
fi
if ! apply_ssh_key; then
  write_error "$phase" "$ssh_key_error"
  do_exit 1
fi
if [ -n "$virsh_list_failed" ]; then
  write_error "$phase" "VM-Liste konnte nicht gelesen werden"
  do_exit 1
fi
if [ -n "$lxc_list_failed" ]; then
  write_error "$phase" "Container-Liste konnte nicht gelesen werden"
  do_exit 1
fi

exec 9>/var/lock/qemu-borg-backup.lock
if ! flock -n 9; then
  write_error "Vorbereitung" "Backup läuft bereits..."
  do_exit 1
fi

mounted_by_us=
cleanup() {
  if [ -n "$mounted_by_us" ] && mountpoint -q "$MOUNTPOINT"; then
    umount "$MOUNTPOINT"
  fi
  remove_ssh_wrapper
}
trap cleanup EXIT

phase="Backupziel vorbereiten"
if [ "x" != "x$FS_UUID" -o "x" != "x$NFS_PATH" ]; then
    if [ -z "$MOUNTPOINT" ]; then
       write_error "$phase" "Kein Mountpunkt angegeben"
       do_exit 1
    fi
    if mountpoint -q "$MOUNTPOINT"; then
       write_warning "$phase" "Mountpunkt nicht leer..."
       if ! umount "$MOUNTPOINT"; then
          write_error "$phase" "Konnte nicht ausgehängt werden..."
          do_exit 1
       fi
       write_info "$phase" "Erfolgreich ausgehängt..."
       if mountpoint -q "$MOUNTPOINT"; then
          do_exit 1
       fi
    fi
fi

if [ "x" != "x$FS_UUID" ]; then
    mount UUID="$FS_UUID" "$MOUNTPOINT"
    if ! mountpoint -q "$MOUNTPOINT"; then
       write_error "$phase" "Backupziel konnte nicht eingehängt werden..."
       do_exit 1
    fi
    mounted_by_us=1
elif [ "x" != "x$NFS_PATH" ]; then
    if ! mount.nfs -o rw,tcp,hard,nfsvers=4.0,rsize=65536,wsize=65536,noatime,_netdev "$NFS_PATH" "$MOUNTPOINT"; then
       write_error "$phase" "Backupziel konnte nicht eingehängt werden..."
       do_exit 1
    fi
    if ! mountpoint -q "$MOUNTPOINT"; then
       write_error "$phase" "Backupziel konnte nicht eingehängt werden..."
       do_exit 1
    fi
    mounted_by_us=1
fi

if [ "$BACKUP_BORG" = "y" ]; then
  maybe_break_lock
fi
if [ "$BACKUP_RESTIC" = "y" ]; then
  maybe_unlock_restic
fi

touch_status "$STATUSDIR/running"

if [ "x$PRUNE_FIRST" != "x" ]; then
  run_retention
fi

# backup VMs
if [ -x /usr/bin/virsh ]; then
  phase="VM-Backup"
  for domain in $domains; do
    if [ -n "$domain" ]; then
      run_child "$phase" "$domain" "$SCRIPT_DIR/qemu-backup.sh" "$domain"
    fi
  done
fi

# backup LXC
if [ "x$LXC_BACKUP" == "xy" ]; then
  phase="LXC-Backup"
  for container in $LXC_CONTAINERS; do
    if [ -n "$container" ]; then
      run_child "$phase" "$container" "$SCRIPT_DIR/lxc-backup.sh" "$container"
    fi
  done
fi

if [ "$BACKUP_BORG" = "y" ]; then
  maybe_break_lock
fi
if [ "$BACKUP_RESTIC" = "y" ]; then
  maybe_unlock_restic
fi

phase="Dateibackup"
each_borg_dirs backup_dir_group

STATUSDIR=$GLOBALSTATUSDIR

if [ "x$PRUNE_FIRST" == "x" ]; then
  run_retention
fi

if [ "$BACKUP_BORG" = "y" ]; then
  borg info "$BORG_REPO" > "$STATUSDIR/info"
fi
if [ "$BACKUP_RESTIC" = "y" ]; then
  if [ "$BACKUP_BORG" = "y" ]; then
    run_restic snapshots >> "$STATUSDIR/info"
  else
    run_restic snapshots > "$STATUSDIR/info"
  fi
fi
if [ -f "$STATUSDIR/info" ]; then
  publish_status_entry "$STATUSDIR/info"
fi

if [ -n "$mounted_by_us" ]; then
  umount "$MOUNTPOINT"
  mounted_by_us=
fi

if [ $retval -eq 0 ]; then
  touch_status "$STATUSDIR/timestamp"
  write_success "backup" "erfolgreich"
fi

rm -f $STATUSDIR/running

do_exit $retval
