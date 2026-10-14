#!/bin/bash
export PATH=/snap/bin:$PATH
export container=$1
retval=0

if [[ -z "$container" ]]; then
    echo "Error: no container name"
    exit 1
fi

export CONTAINER_STORAGE_PATH=$LXC_STORAGE_PATH
POOL=$(lxc config device show "$container" | grep pool | cut -d : -f 2 | sed -z 's/^[[:space:]]*//' | sed -z 's/[[:space:]]*$//')
if [ "x$POOL" != "x" ]; then
  export CONTAINER_STORAGE_PATH=$(lxc storage get $POOL source)
fi

snapshot_prefix="containers-snapshots/${container}/borgbackup"

load_borg_excludes() {
    if [ -z "$BORG_EXCLUDE" ]; then
        borg_excludes=(--exclude '*/.btrfs' --exclude '*/.snapshots')
    else
        set -f
        read -r -a borg_excludes <<< "$BORG_EXCLUDE"
        set +f
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

delete_snapshot_subvols() {
    local root=$1 prefix=$2 nested_only=$3 path rc=0 prev
    [[ -n "$prefix" ]] || return 1
    prev=$(pwd) || return 1
    cd "$root" || return 1
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        btrfs property set -ts "$path" ro false || rc=1
        btrfs subvolume delete "$path" || rc=1
    done < <(
        btrfs subvolume list . | sed -n 's/.* path //p' | awk -v prefix="$prefix" -v nested="$nested_only" '
            {
                n = length(prefix)
                if (index($0, prefix) != 1) next
                if (length($0) != n && substr($0, n + 1, 1) != "/") next
                if (nested == "yes" && $0 !~ /\/\.btrfs(\/|$)/ && $0 !~ /\/\.snapshots(\/|$)/) next
                parts = split($0, unused, "/")
                print parts "\t" $0
            }
        ' | sort -t "$(printf '\t')" -k1,1nr | cut -f2-
    )
    cd "$prev" || return 1
    return $rc
}

if [ -d "$CONTAINER_STORAGE_PATH/containers-snapshots/$container/borgbackup" ]; then
    lxc delete "$container/borgbackup"
fi
if [ "x$LXC_STOP_MYSQL" != "x" ]; then
    lxc exec "$container" -- service mysql stop
fi

lxc_backup_dir="$CONTAINER_STORAGE_PATH/containers-snapshots/$container/borgbackup"

if ! lxc snapshot "$container" borgbackup; then
    echo "Error creating container snapshot"
    if [ "x$LXC_STOP_MYSQL" != "x" ]; then
        lxc exec "$container" -- service mysql start || echo "Error starting mysql"
    fi
    exit 1
fi

if [ "x$LXC_STOP_MYSQL" != "x" ]; then
    lxc exec "$container" -- service mysql start || echo "Error starting mysql"
fi

if [ -d "$CONTAINER_STORAGE_PATH/containers-snapshots/$container/borgbackup" ]; then
    if ! delete_snapshot_subvols "$CONTAINER_STORAGE_PATH" "$snapshot_prefix" yes; then
        echo "Error removing nested subvolumes"
        [[ $retval -eq 0 ]] && retval=2
    fi
fi

numtries=1
load_borg_excludes
while ! borg create -v -C zstd --stats "${borg_excludes[@]}" "$BORG_REPO::$container-{now}" "$lxc_backup_dir" 2>&1; do
    maybe_break_lock
    sleep 60
    numtries=$((numtries + 1))
    if [[ $numtries -gt ${BORG_TRIES:-20} ]]; then
        echo "Error creating backup"
        retval=1
        break
    fi
done

if [ -d "$CONTAINER_STORAGE_PATH/containers-snapshots/$container/borgbackup" ]; then
    if ! lxc delete "$container/borgbackup"; then
        if ! delete_snapshot_subvols "$CONTAINER_STORAGE_PATH" "$snapshot_prefix" no; then
            echo "Error removing snapshot"
            [[ $retval -eq 0 ]] && retval=2
        elif [ -d "$CONTAINER_STORAGE_PATH/containers-snapshots/$container/borgbackup" ]; then
            echo "Error removing snapshot"
            [[ $retval -eq 0 ]] && retval=2
        fi
    fi
fi

exit $retval
