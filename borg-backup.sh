#!/bin/bash
# repository settings
if [ "x$BORG_PASSPHRASE" == "x" ]; then
  export BORG_PASSPHRASE=
fi
if [ "x$BORG_REPO" == "x" ]; then
  export BORG_REPO=
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
if [ "x$LXC_CONTAINERS" == "x" ]; then
  export LXC_CONTAINERS=$(lxc list --format=csv -c n)
fi
if [ "x$LXC_STOP_MYSQL" == "x" ]; then
  export LXC_STOP_MYSQL=
fi
if [ "x$LXC_STORAGE_PATH" == "x" ]; then
  export LXC_STORAGE_PATH=`lxc storage get default source`
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

if pidof -x -o $$ $(basename "$0"); then
  echo "Backup already running..."
  exit 1
fi

if [ "x" != "x$FS_UUID" -o "x" != "x$NFS_PATH" ]; then
    if mountpoint -q $MOUNTPOINT; then
       echo "device already mounted..."
       if ! umount $MOUNTPOINT; then
          exit 1
       fi
       echo "successfully unmounted..."
       if mountpoint -q $MOUNTPOINT; then
          exit 1
       fi
    fi
fi

if [ "x" != "x$FS_UUID" ]; then
    mount UUID="$FS_UUID" $MOUNTPOINT
    if ! mountpoint -q $MOUNTPOINT; then
       echo "unable to mount backup device..."
       exit 1
    fi
elif [ "x" != "x$NFS_PATH" ]; then
    if ! mount.nfs -o rw,tcp,hard,nfsvers=4,rsize=65536,wsize=65536,noatime,intr,_netdev $NFS_PATH $MOUNTPOINT; then
        exit
    fi
    if ! mountpoint -q $MOUNTPOINT; then
       echo "unable to mount backup device..."
       exit 1
    fi
fi

if [ "x$PRUNE_FIRST" != "x" ]; then
    for container in $LXC_CONTAINERS; do
        borg prune -v --list -P $container --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO
    done
    for domain in $domains; do
        if [ $domain != "" ]; then
            borg prune -v --list -P $domain --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO
        fi
    done
    borg compact -v
fi

# backup VMs
for domain in $domains; do
    if [ $domain != "" ]; then
        ./qemu-borg-backup.sh $domain
    fi
done

# backup LXC
for container in $LXC_CONTAINERS; do
    ./lxc-borg-backup.sh $container
done

# prune
if [ "x$PRUNE_FIRST" == "x" ]; then
    for container in $LXC_CONTAINERS; do
        borg prune -v --list -P $container --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO
    done
    for domain in $domains; do
        if [ $domain != "" ]; then
            borg prune -v --list -P $domain --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO
        fi
    done
    borg compact -v
fi

if [ "x" != "x$FS_UUID" -o "x" != "x$NFS_PATH" ]; then
    umount $MOUNTPOINT
fi