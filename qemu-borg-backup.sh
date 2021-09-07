#!/bin/bash

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
if [ "x$DEFAULT_DOMAINS" == "x" ]; then
  export DEFAULT_DOMAINS="pfsense"
fi
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


trim() {
    local var="$*"
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

create_snapshot() {
    domain=$1; shift; ds=$*
    d=$(echo $domain | tr "[:upper:]" "[:lower:]")
    params="--no-metadata --atomic --disk-only"
    if [ "$d" != "pfsense" ]; then
        params="--quiesce $params"
    fi
    if ! virsh snapshot-create-as --domain $domain --name borg.qcow2 $params $ds; then
        virsh reboot --domain $domain --mode agent
        while ! virsh guestinfo --domain $domain --hostname; do
            sleep 10
        done
        if ! virsh snapshot-create-as --domain $domain --name borg.qcow2 $params $ds; then
            return 1
        fi
    fi
    return 0
}

if [ $# -eq 0 ]; then
    export domains=$DEFAULT_DOMAINS
else
    export domains=$*
fi

if [ "x$PRUNE_FIRST" != "x" ]; then
    for domain in $domains; do
        if [ $domain != "" ]; then
            borg prune -v --list -P $domain --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO
        fi
    done
fi

# create snapshots
export images=""
for domain in $domains; do
    if [ "$domain" != "" ]; then
        export backup_imgs=$(virsh domblklist $domain --details | grep borg | awk '/disk/ {print $3}')
        if [ "$backup_imgs" != "" ]; then
            echo "error: snapshots still there for domain $domain"
            continue
        fi

        export ds=""
        export myimages=""
        for drive in $(virsh domblklist $domain --details | awk '/disk/ {print $3}'); do
            export ds="--diskspec $drive,snapshot=external $ds"
        done
        for image in $(virsh domblklist $domain --details | grep -v "_backup" | awk '/disk/ {print $4}'); do
            export myimages="$image $myimages"
        done

        d=$(echo $domain | tr "[:upper:]" "[:lower:]")
        params="--no-metadata --atomic --disk-only"
        if [ "$d" != "pfsense" ]; then
            echo "Sending TRIM command to $domain"
            virsh domfstrim $domain
            # wait a minute to trim
            echo "Waiting for TRIM on $domain"
            sleep 120
        fi

        echo "Creating snapshot of $domain"
        if ! create_snapshot $domain $ds; then
            echo "error: snapshot creation failed, returned with $?"
        else
            export myimages=$(trim $myimages)
            echo "Creating backup with borg of $myimages"
            while ! borg create -v -C zstd --stats $BORG_REPO::$domain-'{now}' $myimages 2>&1; do sleep 60; done
            declare -A imgsbackup
            eval $(virsh domblklist ${domain} --details | awk '/disk/ {print "imgsbackup["$3"]="$4}')
            for drive in $(virsh domblklist $domain --details | grep borg | awk '/disk/ {print $3}'); do
                if virsh blockcommit $domain $drive --active --pivot; then
                    mv ${imgsbackup["$drive"]} ${imgsbackup["$drive"]}.old
                else
                    sleep 10
                    if virsh blockcommit $domain $drive --active --pivot; then
                        mv ${imgsbackup["$drive"]} ${imgsbackup["$drive"]}.old
                    fi
                fi
            done
            unset imgsbackup
        fi
    fi
done

# prune
if [ "x$PRUNE_FIRST" == "x" ]; then
    for domain in $domains; do
        if [ $domain != "" ]; then
            borg prune -v --list -P $domain --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO
        fi
    done
fi

if [ "x" != "x$FS_UUID" -o "x" != "x$NFS_PATH" ]; then
    umount $MOUNTPOINT
fi
