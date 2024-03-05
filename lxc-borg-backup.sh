#!/bin/bash
export PATH=/snap/bin:$PATH
export container=$1
retval=0

if [ -d "$LXC_STORAGE_PATH/containers-snapshots/$container/borgbackup" ]; then
    lxc delete "$container/borgbackup"
fi
if [ "x$LXC_STOP_MYSQL" != "x" ]; then
  lxc exec "$container" -- service mysql stop
fi

lxc_backup_dir="$LXC_STORAGE_PATH/containers-snapshots/$container/borgbackup"

if ! lxc snapshot "$container" borgbackup; then
  echo "Error creating container snapshot"
  lxc_backup_dir="$LXC_STORAGE_PATH/containers/$container"
  retval=1
fi

if [ "x$LXC_STOP_MYSQL" != "x" ]; then
  lxc exec "$container" -- service mysql start
fi

if [ -d "$LXC_STORAGE_PATH/containers-snapshots/$container/borgbackup" ]; then
  cd "$LXC_STORAGE_PATH"
  for i in $(btrfs subvolume list . |grep "containers-snapshots/$container/borgbackup" | grep "/.btrfs" | cut -d ' ' -f 9 | sort -r); do btrfs property set -ts "$i" ro false; done
  for i in $(btrfs subvolume list . |grep "containers-snapshots/$container/borgbackup" | grep "/.btrfs" | cut -d ' ' -f 9 | sort -r); do btrfs subvolume delete "$i"; done
  for i in $(btrfs subvolume list . |grep "containers-snapshots/$container/borgbackup" | grep "/.snapshots" | cut -d ' ' -f 9 | sort -r); do btrfs property set -ts "$i" ro false; done
  for i in $(btrfs subvolume list . |grep "containers-snapshots/$container/borgbackup" | grep "/.snapshots" | cut -d ' ' -f 9 | sort -r); do btrfs subvolume delete "$i"; done
fi

numtries=1
while ! borg create -v -C zstd --stats $BORG_EXCLUDE $BORG_REPO::$container-'{now}' "$lxc_backup_dir" 2>&1; do
  sleep 60; 
  numtries=$[numtries+1]
  if [ $numtries -gt $BORG_TRIES ]; then
    echo "Error creating backup"
    retval=1
    break
  fi
done

if [ -d "$LXC_STORAGE_PATH/containers-snapshots/$container/borgbackup" ]; then
  if ! lxc delete "$container/borgbackup"; then
    cd "$LXC_STORAGE_PATH"
    for i in $(btrfs subvolume list . |grep "containers-snapshots/$container/borgbackup" | cut -d ' ' -f 9 | sort -r); do btrfs property set -ts "$i" ro false; done
    for i in $(btrfs subvolume list . |grep "containers-snapshots/$container/borgbackup" | cut -d ' ' -f 9 | sort -r); do btrfs subvolume delete "$i"; done
    if [ -d "$LXC_STORAGE_PATH/containers-snapshots/$container/borgbackup" ]; then
      echo "Error removing snapshot"
      retval=2
    fi
  fi
fi

exit $retval