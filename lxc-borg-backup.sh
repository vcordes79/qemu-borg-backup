#!/bin/bash

if [ "x$BORG_PASSPHRASE" == "x" ]; then
  export BORG_PASSPHRASE=
fi
if [ "x$BORG_REPO" == "x" ]; then
  export BORG_REPO=
fi
if [ "x$BORG_EXCLUDE" == "x" ]; then
  export BORG_EXCLUDE=
fi
if [ "x$MOUNTPOINT" == "x" ]; then
  export MOUNTPOINT=
fi
if [ "x$FS_UUID" == "x" ]; then
  export FS_UUID=
fi
if [ "x$NFS_PATH" == "x" ]; then
  export NFS_PATH=
fi
if [ "x$LXC_CONTAINERS" == "x" ]; then
  export LXC_CONTAINERS=$(lxc list --format=csv -c n)
fi
if [ "x$LXC_STORAGE_PATH" == "x" ]; then
  export LXC_STORAGE_PATH=`lxc storage list --format=csv | cut -d\, -f3`
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

if pidof -x -o $$ $(basename "$0"); then
  echo "Backup already running..."
  exit 1
fi

if [ "x" != "x$FS_UUID" ]; then
    if mountpoint -q $MOUNTPOINT; then
       echo "device already mounted..."
       exit 1
    fi
    mount UUID="$FS_UUID" $MOUNTPOINT
    if ! mountpoint -q $MOUNTPOINT; then
       echo "unable to mount backup device..."
       exit 1
    fi
elif [ "x" != "x$NFS_PATH" ]; then
    if mountpoint -q $MOUNTPOINT; then
       echo "device already mounted..."
       exit 1
    fi
    if ! mount.nfs -o rw,tcp,hard,nfsvers=4,rsize=65536,wsize=65536,noatime,intr,_netdev $NFS_PATH $MOUNTPOINT; then
        exit
    fi
    if ! mountpoint -q $MOUNTPOINT; then
       echo "unable to mount backup device..."
       exit 1
    fi
fi

export PATH=/snap/bin:$PATH
for container in $LXC_CONTAINERS; do
    lxc snapshot "$container" backup
    borg create -v -C zstd --stats $BORG_EXCLUDE $BORG_REPO::$container-'{now}' "$LXC_STORAGE_PATH/containers-snapshots/$container/backup" 2>&1
    lxc delete "$container/backup"
    borg prune -v --list -P $container --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO
done

if [ "x" != "x$FS_UUID" -o "x" != "x$NFS_PATH" ]; then
    umount $MOUNTPOINT
fi
