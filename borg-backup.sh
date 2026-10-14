#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export PATH=$PATH:$SCRIPT_DIR:/snap/bin
export BORG_DIRS_SYSTEM="/usr/local /etc"

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

write_warning() {
  echo "<tr style='background-color:yellow;color:black'><th>$(html_escape "$1")</th></tr><tr><td><pre>$(html_escape "$2")</pre></td></tr>"
  [[ "${retval:-0}" -eq 0 ]] && retval=2
  echo "$1: $2" >> "$STATUSDIR/warning.log"
}

write_info() {
  echo "<tr style='background-color:lightblue;color:black'><th>$(html_escape "$1")</th></tr><tr><td><pre>$(html_escape "$2")</pre></td></tr>"
  echo "$1: $2" >> "$STATUSDIR/info.log"
}

write_success() {
  echo "<tr style='background-color:lightgreen;color:black'><th>$(html_escape "$1")</th></tr><tr><td><pre>$(html_escape "$2")</pre></td></tr>"
  echo "$1: $2" >> "$STATUSDIR/success.log"
}

write_error() {
  echo "<tr style='background-color:red;color:white'><th>$(html_escape "$1")</th></tr><tr><td><pre>$(html_escape "$2")</pre></td></tr>"
  retval=1
  echo "$1: $2" >> "$STATUSDIR/error.log"
}

do_exit() {
  echo '</table></body></html>'
  exit $1
}

archive_glob() {
    printf '%s-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*' "$1"
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

load_borg_excludes() {
    if [ -z "$BORG_EXCLUDE" ]; then
        borg_excludes=(--exclude '*/.btrfs' --exclude '*/.snapshots')
    else
        set -f
        read -r -a borg_excludes <<< "$BORG_EXCLUDE"
        set +f
    fi
}

prune_borg_dirs() {
    local name=$1 result
    result=$(borg prune -v --list --glob-archives "$(archive_glob "$name")" --keep-daily="$KEEP_DAILY" --keep-weekly="$KEEP_WEEKLY" --keep-monthly="$KEEP_MONTHLY" "$BORG_REPO" 2>&1)
    if [ $? -gt 0 ]; then
        write_warning "$phase $name" "Backups für $name konnten nicht aufgeräumt werden"
        write_warning "$phase $name" "$result"
    else
        write_success "$phase $name" "$result"
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

borg_prune() {
    maybe_break_lock
    phase="alte Backups löschen"
    if [ "x$LXC_BACKUP" == "xy" ]; then
      for container in $LXC_CONTAINERS; do
        if [ $container != "" ]; then
          result=$(borg prune -v --list --glob-archives "$(archive_glob "$container")" --keep-daily="$KEEP_DAILY" --keep-weekly="$KEEP_WEEKLY" --keep-monthly="$KEEP_MONTHLY" "$BORG_REPO" 2>&1)
          if [ $? -gt 0 ]; then
            write_warning "$phase $container" "Backups für $container konnten nicht aufgeräumt werden"
            write_warning "$phase $container" "$result"
          else
            write_success "$phase $container" "$result" 
          fi
        fi
      done
    fi
    for domain in $domains; do
        if [ $domain != "" ]; then
            result=$(borg prune -v --list --glob-archives "$(archive_glob "$domain")" --keep-daily="$KEEP_DAILY" --keep-weekly="$KEEP_WEEKLY" --keep-monthly="$KEEP_MONTHLY" "$BORG_REPO" 2>&1)
            if [ $? -gt 0 ]; then
                write_warning "$phase $domain" "Backups für $domain konnten nicht aufgeräumt werden"
                write_warning "$phase $domain" "$result"
            else
                write_success "$phase $domain" "$result" 
            fi
        fi
    done
    each_borg_dirs prune_borg_dirs

    phase="Speicherplatz freigeben"
    if borg --help |grep compact >/dev/null; then
      result=`borg compact -v 2>&1`
      if [ $? -gt 0 ]; then
          write_warning "$phase" "Repository konnte nicht komprimiert werden"
          write_warning "$phase" "$result"
      else
          write_success "$phase" "$result" 
      fi
    else
      write_info "$phase" "BORG: Compact nicht unterstützt"
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
    export LXC_CONTAINERS=$(lxc list --format=csv -c n)
  fi
  if [ "x$LXC_STOP_MYSQL" == "x" ]; then
    export LXC_STOP_MYSQL=
  fi
  if [ "x$LXC_STORAGE_PATH" == "x" ]; then
    export LXC_STORAGE_PATH=`lxc storage get default source`
  fi
fi

# domain / container settings
if [ "x$DEFAULT_DOMAINS" == "x" ]; then
  if [ "x$BACKUP_SHUTOFF" == "xy" ]; then
    export DEFAULT_DOMAINS=$(/usr/bin/virsh list --all --name | tr '\n' ' ')
  else
    export DEFAULT_DOMAINS=$(/usr/bin/virsh list --name | tr '\n' ' ')
  fi
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
shortrepo=$(echo $BORG_REPO | sed -E 's|/\|:|_|g' | sed -E 's|@|_|g' | sed -E 's|_+|_|g' | sed -E 's|^_||g')
GLOBALSTATUSDIR=/var/spool/borgbackup/$shortrepo
rm -rf /var/spool/borgbackup/*\@*
if [ ! -d "$GLOBALSTATUSDIR" ]; then
  mkdir -p "$GLOBALSTATUSDIR"
fi
if [ -n "$shortrepo" ]; then
  chmod 700 "$GLOBALSTATUSDIR"
fi

STATUSDIR=$GLOBALSTATUSDIR
rm $STATUSDIR/*.log

write_header

phase="Parameterprüfung"
if [ "x$BORG_PASSPHRASE" == "x" ]; then
  write_error $phase "Kein Borg-Passwort angegeben"
  do_exit 1
fi
if [ "x$BORG_REPO" == "x" ]; then
  export BORG_REPO=
  write_error $phase "Kein Borg-Repository angegeben"
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

maybe_break_lock

touch $STATUSDIR/running

if [ "x$PRUNE_FIRST" != "x" ]; then
  borg_prune
fi

# backup VMs
if [ -f /usr/bin/virsh ]; then
  phase="VM-Backup"
  for domain in $domains; do
    if [ $domain != "" ]; then
      STATUSDIR=$GLOBALSTATUSDIR/$domain
      if [ ! -d "$STATUSDIR" ]; then
        mkdir "$STATUSDIR"
      fi
      chmod 700 "$STATUSDIR"
      touch $STATUSDIR/running
      rm $STATUSDIR/*.log
      result=`qemu-borg-backup.sh $domain 2>&1`
      exitCode=$?
      rm $STATUSDIR/running
      if [ $exitCode -eq 1 ]; then 
        write_error ""$phase" $domain" "$result"
      elif [ $exitCode -eq 2 ]; then 
        write_warning ""$phase" $domain" "$result"
      else 
        touch $STATUSDIR/timestamp
        write_success ""$phase" $domain" "$result"
      fi
    fi
  done
fi

# backup LXC
if [ "x$LXC_BACKUP" == "xy" ]; then
  phase="LXC-Backup"
  for container in $LXC_CONTAINERS; do
    STATUSDIR=$GLOBALSTATUSDIR/$container
    if [ ! -d "$STATUSDIR" ]; then
      mkdir "$STATUSDIR"
    fi
    chmod 700 "$STATUSDIR"
    rm $STATUSDIR/*.log
    touch $STATUSDIR/running
    result=`lxc-borg-backup.sh $container 2>&1`
    exitCode=$?
    rm $STATUSDIR/running
    if [ $exitCode -eq 1 ]; then 
      write_error ""$phase" $container" "$result"
    elif [ $exitCode -eq 2 ]; then 
      write_warning ""$phase" $container" "$result"
    else 
      touch $STATUSDIR/timestamp
      write_success ""$phase" $container" "$result"
    fi
  done
fi

maybe_break_lock

# Dateibackup
phase="Dateibackup"
load_borg_excludes
backup_borg_dirs() {
  local repo=$1 dirs=$2 result exitCode
  STATUSDIR=$GLOBALSTATUSDIR/$repo
  if [ ! -d "$STATUSDIR" ]; then
    mkdir "$STATUSDIR"
  fi
  chmod 700 "$STATUSDIR"
  rm $STATUSDIR/*.log
  touch $STATUSDIR/running
  set -f
  result=$(borg create -v -C zstd --stats "${borg_excludes[@]}" "$BORG_REPO::$repo-{now}" -- $dirs 2>&1)
  exitCode=$?
  set +f
  rm $STATUSDIR/running
  if [ $exitCode -eq 1 ]; then
    write_error "$phase $repo" "$result"
  elif [ $exitCode -eq 2 ]; then
    write_warning "$phase $repo" "$result"
  else
    touch $STATUSDIR/timestamp
    write_success "$phase $repo" "$result"
  fi
}
each_borg_dirs backup_borg_dirs

STATUSDIR=$GLOBALSTATUSDIR

# prune
if [ "x$PRUNE_FIRST" == "x" ]; then
  borg_prune
fi

borg info $BORG_REPO > $STATUSDIR/info

if [ -n "$mounted_by_us" ]; then
  umount "$MOUNTPOINT"
  mounted_by_us=
fi

if [ $retval -eq 0 ]; then
  touch $STATUSDIR/timestamp
  write_success "backup" "erfolgreich"
fi

rm $STATUSDIR/running

do_exit $retval
