#!/bin/bash

export BORG_PASSPHRASE=<PASSWORT>
export BORG_REPO=ssh://<USER>@borg.fdatek.de:222/var/borg/<USER>/repo
export KEEP_DAILY=7
export KEEP_WEEKLY=4
export KEEP_MONTHLY=4

if pidof -x -o $$ $(basename "$0"); then
  echo "Backup already running..."
  exit 1
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
    if ! virsh snapshot-create-as --domain $domain --name backup.qcow2 --no-metadata --atomic --quiesce --disk-only $ds; then
        sleep 10
        if ! virsh snapshot-create-as --domain $domain --name backup.qcow2 --no-metadata --atomic --quiesce --disk-only $ds; then
            return 1
        fi
    fi
    return 0
}

if [ $# -eq 0 ]; then
    export domains="Server"
else
    export domains=$*
fi

# create snapshots
export images=""
for domain in $domains; do
    if [ "$domain" != "" ]; then
        export backup_imgs=$(virsh domblklist $domain --details | grep backup | awk '/disk/ {print $3}')
        if [ "$backup_imgs" != "" ]; then
            echo "error: snapshots still there for domain $domain"
            continue
        fi

        export ds=""
        export myimages=""
        for drive in $(virsh domblklist $domain --details | awk '/disk/ {print $3}'); do
            export ds="--diskspec $drive,snapshot=external $ds"
        done
        for image in $(virsh domblklist $domain --details | awk '/disk/ {print $4}'); do
            export myimages="$image $myimages"
        done
        echo "Sending TRIM command to $domain"
        virsh domfstrim $domain

        # wait a minute to trim
        echo "Waiting for TRIM on $domain"
        sleep 60

        echo "Creating snapshot of $domain"
        if ! create_snapshot $domain $ds; then
            echo "error: snapshot creation failed, returned with $?"
        else
            export myimages=$(trim $myimages)
            echo "Creating backup with borg of $myimages"
            (while ! borg create -v -C zstd --stats $BORG_REPO::$domain-'{now}' $myimages 2>&1; do sleep 60; done) &
            wait
            declare -A imgsbackup
            eval $(virsh domblklist ${domain} --details | awk '/disk/ {print "imgsbackup["$3"]="$4}')
            for drive in $(virsh domblklist $domain --details | grep backup | awk '/disk/ {print $3}'); do
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
for domain in $domains; do
    if [ $domain != "" ]; then
        (borg prune -v --list -P $domain --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY $BORG_REPO) &
        wait
    fi
done
