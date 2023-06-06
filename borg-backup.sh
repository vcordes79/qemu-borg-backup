#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export PATH=$PATH:$SCRIPT_DIR
export BORG_DIRS_SYSTEM="/usr/local /etc"

write_header() {
  echo "<html><body><table>"
}

write_warning() {
  echo "<tr style='background-color:yellow;color:black'><th>$1</th></tr><tr><td>$2</td></tr>";
  retval=2
}

write_info() {
  echo "<tr style='background-color:lightblue;color:black'><th>$1</th></tr><tr><td>$2</td></tr>";
}

write_success() {
  echo "<tr style='background-color:lightgreen;color:black'><th>$1</th></tr><tr><td>$2</td></tr>";
}

write_error() {
  echo "<tr style='background-color:red;color:white'><th>$1</th></tr><tr><td>$2</td></tr>";
}

do_exit() {
  echo '</table></body></html>'
  exit $1
}

borg_prune() {
    phase="alte Backups löschen"
    if [ "x$LXC_BACKUP" == "xy" ]; then
      for container in $LXC_CONTAINERS; do
        if [ $container != "" ]; then
          result=`borg prune -v --list -P $container --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO 2>&1`
          if [ $? -gt 0 ]; then
            write_warning "$phase $container" "Backups für $container konnten nicht aufgeräumt werden"
            write_warning "$phase $container" "<pre>$result</pre>"
          else
            write_success "$phase $container" "<pre>$result</pre>" 
          fi
        fi
      done
    fi
    for domain in $domains; do
        if [ $domain != "" ]; then
            result=`borg prune -v --list -P $domain --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO 2>&1`
            if [ $? -gt 0 ]; then
                write_warning "$phase $domain" "Backups für $domain konnten nicht aufgeräumt werden"
                write_warning "$phase $domain" "<pre>$result</pre>"
            else
                write_success "$phase $domain" "<pre>$result</pre>" 
            fi
        fi
    done
    OLDIFS=$IFS
    IFS=$'\n'
    for v in $(env |grep BORG_DIRS); do 
      v=`echo $v | cut -d\_ -f3`
      repo=`echo $v | cut -d\= -f1`
      if [ $repo != "" ]; then
        result=`borg prune -v --list -P $repo --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO 2>&1`
        if [ $? -gt 0 ]; then
          write_warning "$phase $repo" "Backups für $repo konnten nicht aufgeräumt werden"
          write_warning "$phase $repo" "<pre>$result</pre>"
        else
          write_success "$phase $repo" "<pre>$result</pre>" 
        fi
      fi
    done
    IFS=$OLDIFS

    phase="Speicherplatz freigeben"
    if borg --help |grep compact >/dev/null; then
      result=`borg compact -v 2>&1`
      if [ $? -gt 0 ]; then
          write_warning "$phase" "Repository konnte nicht komprimiert werden"
          write_warning "$phase" "<pre>$result</pre>"
      else
          write_success "$phase" "<pre>$result</pre>" 
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
  export DEFAULT_DOMAINS="pfsense"
fi
if [ $# -eq 0 ]; then
    export domains=$DEFAULT_DOMAINS
else
    export domains=$*
fi

# other settings
if [ "x$BORG_EXCLUDE" == "x" ]; then
  export BORG_EXCLUDE="--exclude 'sh:**/.btrfs' --exclude 'sh:**/.snapshots'"
fi
if [ "x$BORG_TRIES" == "x" ]; then 
  export BORG_TRIES=5
fi

retval=0

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


if pidof -x -o $$ $(basename "$0"); then
  write_error "Vorbereitung" "Backup läuft bereits..."
  do_exit 1
fi

phase="Backupziel vorbereiten"
if [ "x" != "x$FS_UUID" -o "x" != "x$NFS_PATH" ]; then
    if mountpoint -q $MOUNTPOINT; then
       write_warning "$phase" "Mountpunkt nicht leer..."
       if ! umount $MOUNTPOINT; then
          write_error "$phase" "Konnte nicht ausgehängt werden..."
          do_exit 1
       fi
       write_info "$phase" "Erfolgreich ausgehängt..."
       if mountpoint -q $MOUNTPOINT; then
          do_exit 1
       fi
    fi
fi

if [ "x" != "x$FS_UUID" ]; then
    mount UUID="$FS_UUID" $MOUNTPOINT
    if ! mountpoint -q $MOUNTPOINT; then
       write_error "$phase" "Backupziel konnte nicht eingehängt werden..."
       do_exit 1
    fi
elif [ "x" != "x$NFS_PATH" ]; then
    if ! mount.nfs -o rw,tcp,hard,nfsvers=4.0,rsize=65536,wsize=65536,noatime,intr,_netdev $NFS_PATH $MOUNTPOINT; then
       write_error "$phase" "Backupziel konnte nicht eingehängt werden..."
       do_exit 1
    fi
    if ! mountpoint -q $MOUNTPOINT; then
       write_error "$phase" "Backupziel konnte nicht eingehängt werden..."
       do_exit 1
    fi
fi

if [ "x$PRUNE_FIRST" != "x" ]; then
  borg_prune  
fi

# backup VMs
if [ -f /usr/bin/virsh ]; then
  phase="VM-Backup"
  for domain in $domains; do
    if [ $domain != "" ]; then
      result=`qemu-borg-backup.sh $domain 2>&1`
      exitCode=$?
      result="<pre>$result</pre>"
      if [ $exitCode -eq 1 ]; then 
        write_error ""$phase" $domain" "<pre>$result</pre>"
      elif [ $exitCode -eq 2 ]; then 
        write_warning ""$phase" $domain" "<pre>$result</pre>"
      else 
        write_success ""$phase" $domain" "<pre>$result</pre>"
      fi
    fi
  done
fi

# backup LXC
if [ "x$LXC_BACKUP" == "xy" ]; then
  phase="LXC-Backup"
  for container in $LXC_CONTAINERS; do
    result=`lxc-borg-backup.sh $container 2>&1`
    exitCode=$?
    result="<pre>$result</pre>"
    if [ $exitCode -eq 1 ]; then 
      write_error ""$phase" $container" "<pre>$result</pre>"
    elif [ $exitCode -eq 2 ]; then 
      write_warning ""$phase" $container" "<pre>$result</pre>"
    else 
      write_success ""$phase" $container" "<pre>$result</pre>"
    fi
  done
fi

# Dateibackup
phase="Dateibackup"
OLDIFS=$IFS
IFS=$'\n'
for v in $(env |grep BORG_DIRS); do 
  v=`echo $v | cut -d\_ -f3`
  repo=`echo $v | cut -d\= -f1`
  dirs=`echo $v | cut -d\= -f2`
  IFS=$OLDIFS
  result=$(borg create -v -C zstd --stats $BORG_EXCLUDE $BORG_REPO::$repo-'{now}' $dirs 2>&1)
  IFS=$'\n'
  exitCode=$?
  result="<pre>$result</pre>"
  if [ $exitCode -eq 1 ]; then 
    write_error ""$phase" $repo" "<pre>$result</pre>"
  elif [ $exitCode -eq 2 ]; then 
    write_warning ""$phase" $repo" "<pre>$result</pre>"
  else 
    write_success ""$phase" $repo" "<pre>$result</pre>"
  fi
done
IFS=$OLDIFS

# prune
if [ "x$PRUNE_FIRST" == "x" ]; then
  borg_prune
fi

if [ "x" != "x$FS_UUID" -o "x" != "x$NFS_PATH" ]; then
  umount $MOUNTPOINT
fi

do_exit $retval
