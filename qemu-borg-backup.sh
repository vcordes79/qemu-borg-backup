#!/bin/bash

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
    if virsh guestinfo $domain 2>&1 >/dev/null; then
        params="--quiesce $params"
    fi
    if ! virsh snapshot-create-as --domain $domain --name borg.qcow2 $params $ds; then
        if ! virsh shutdown --domain $domain 2>&1; then
            echo "Shutdown failed"
            return 1
        fi
        sleep 120
        numtries=0
        while ! virsh start $domain 2>&1 ; do
            sleep 10
            numtries=$[numtries+1]
            if [ $numtries -gt 60 ]; then
                echo "Waiting for shutdown failed"
                return 1
            fi
        done
        sleep 120
        numtries=0
        while ! virsh guestinfo --domain $domain --hostname; do
            sleep 10
            numtries=$[numtries+1]
            if [ $numtries -gt 60 ]; then
                echo "Waiting for startup failed"
                return 1
            fi
        done
        if ! virsh snapshot-create-as --domain $domain --name borg.qcow2 $params $ds; then
            return 1
        fi
    fi
    return 0
}

blockcommit() {
    domain=$1; retval=1;
    declare -A imgsbackup
    eval $(virsh domblklist ${domain} --details | awk '/disk/ {print "imgsbackup["$3"]="$4}')
    for drive in $(virsh domblklist $domain --details | grep borg | awk '/disk/ {print $3}'); do
        if virsh blockcommit $domain $drive --active --pivot; then
            mv ${imgsbackup["$drive"]} ${imgsbackup["$drive"]}.old
            retval=0
        else
            sleep 10
            if virsh blockcommit $domain $drive --active --pivot; then
                mv ${imgsbackup["$drive"]} ${imgsbackup["$drive"]}.old
                retval=0
            fi
        fi
    done
    unset imgsbackup
    return $retval
}

# create snapshots
export images=""
export domain=$1
if [ "$domain" != "" ]; then
    if ! virsh list --all |grep "$domain" >/dev/null; then
        echo "error: VM nicht gefunden"
        exit 1
    fi

    export backup_imgs=$(virsh domblklist $domain --details | grep borg | awk '/disk/ {print $3}')
    if [ "$backup_imgs" != "" ]; then
        echo "warning: snapshots still there for domain $domain"
        if ! blockcommit $domain; then
            echo "error: blockcommit not successful for domain $domain"
            exit 1
        fi
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
    if [ "$d" != "pfsense" -a "$d" != "opnsense" ]; then
        echo "Sending TRIM command to $domain"
        virsh domfstrim $domain
        # wait a minute to trim
        echo "Waiting for TRIM on $domain"
        sleep 120
    fi

    echo "Creating snapshot of $domain"
    if ! create_snapshot $domain $ds; then
        echo "error: snapshot creation failed, returned with $?"
        exit 1
    fi

    export myimages=$(trim $myimages)
    echo "Creating backup with borg of $myimages"
    numtries=1
    while ! borg create -v -C zstd --stats $BORG_REPO::$domain-'{now}' $myimages 2>&1; do 
        if [ "x$BORG_BREAK_LOCK" == "x" -o "x$BORG_BREAK_LOCK" == "xy" ]; then
            if borg list 2>&1 | grep lock.exclusive; then
                borg break-lock
            fi
        fi
        sleep 60;
        numtries=$[numtries+1]
        if [ $numtries -gt $BORG_TRIES ]; then
            echo "error creating backup"
            blockcommit $domain
            exit 1
        fi
    done

    # blockcommit
    blockcommit $domain

    # set time
    virsh domtime $domain --now
fi

exit 0
