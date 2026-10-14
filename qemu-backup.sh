#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export PATH=$PATH:$SCRIPT_DIR:/snap/bin
# shellcheck source=backup-common.sh
source "$SCRIPT_DIR/backup-common.sh"
# shellcheck source=backup-borg.sh
source "$SCRIPT_DIR/backup-borg.sh"
# shellcheck source=backup-restic.sh
source "$SCRIPT_DIR/backup-restic.sh"
resolve_backends

wait_for_domstate() {
    local domain=$1 want=$2 tries=0 state
    while true; do
        state=$(virsh domstate "$domain" 2>/dev/null | tr -d '\r')
        [[ "$state" == "$want" ]] && return 0
        tries=$((tries + 1))
        if [[ $tries -gt 300 ]]; then
            echo "timeout: $domain ist ${state:-unbekannt}, erwartet $want"
            return 1
        fi
        sleep 10
    done
}

wait_for_agent() {
    local domain=$1 tries=0
    while ! virsh guestinfo "$domain" --hostname >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [[ $tries -gt 300 ]]; then
            echo "timeout: QEMU-Agent auf $domain antwortet nicht"
            return 1
        fi
        sleep 10
    done
}

dom_state() {
    virsh domstate "$1" 2>/dev/null | tr -d '\r'
}

wake_if_suspended() {
    local domain=$1 state
    state=$(dom_state "$domain")
    case "$state" in
        paused)
            echo "VM $domain ist suspended, wird für den Snapshot fortgesetzt"
            virsh resume "$domain" || return 1
            was_suspended=paused
            wait_for_domstate "$domain" running || return 1
            ;;
        pmsuspended)
            echo "VM $domain ist im Energiesparmodus, wird für den Snapshot aufgeweckt"
            virsh dompmwakeup "$domain" || return 1
            was_suspended=pmsuspended
            wait_for_domstate "$domain" running || return 1
            ;;
    esac
}

restore_suspended() {
    local mode=$was_suspended state
    [ -n "$mode" ] || return 0
    was_suspended=
    state=$(dom_state "$domain")
    [ "$state" = "running" ] || return 0
    case "$mode" in
        paused)
            echo "VM $domain wird wieder suspended"
            virsh suspend "$domain"
            ;;
        pmsuspended)
            echo "VM $domain wird wieder in den Energiesparmodus versetzt"
            virsh dompmsuspend "$domain" mem
            ;;
    esac
}

cleanup_qemu() {
    restore_suspended
    remove_ssh_wrapper
}

set_snapshot_params() {
    snap_params=(--no-metadata --atomic --disk-only)
    if virsh guestinfo "$1" >/dev/null 2>&1; then
        snap_params=(--quiesce "${snap_params[@]}")
    fi
}

create_snapshot() {
    local domain=$1
    shift
    local -a diskspecs=("$@")
    local state
    local -a snap_params=()

    set_snapshot_params "$domain"
    if virsh snapshot-create-as --domain "$domain" --name borg.qcow2 \
        "${snap_params[@]}" "${diskspecs[@]}"; then
        return 0
    fi

    echo "snapshot failed for $domain, restarting guest"
    state=$(virsh domstate "$domain" 2>/dev/null | tr -d '\r')
    if [[ "$state" != "shut off" ]]; then
        if ! virsh shutdown "$domain"; then
            echo "shutdown failed for $domain"
            return 1
        fi
        if ! wait_for_domstate "$domain" "shut off"; then
            return 1
        fi
    fi

    if ! virsh start "$domain"; then
        echo "start failed for $domain"
        return 1
    fi
    if ! wait_for_domstate "$domain" "running"; then
        return 1
    fi
    if ! wait_for_agent "$domain"; then
        return 1
    fi

    set_snapshot_params "$domain"
    if ! virsh snapshot-create-as --domain "$domain" --name borg.qcow2 \
        "${snap_params[@]}" "${diskspecs[@]}"; then
        echo "snapshot failed again for $domain"
        return 1
    fi
}

parse_disks() {
    local domain=$1 line rest disk_type device target source
    declare -gA disk_source=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ "$line" == Type* || "$line" == -* || -z "$line" ]] && continue
        rest=$line
        disk_type=${rest%%[[:space:]]*}
        rest=${rest#"$disk_type"}
        rest=${rest#"${rest%%[![:space:]]*}"}
        device=${rest%%[[:space:]]*}
        rest=${rest#"$device"}
        rest=${rest#"${rest%%[![:space:]]*}"}
        target=${rest%%[[:space:]]*}
        rest=${rest#"$target"}
        source=${rest#"${rest%%[![:space:]]*}"}
        source=${source%"${source##*[![:space:]]}"}
        [[ "$device" == disk && -n "$source" && "$source" != "-" ]] || continue
        disk_source["$target"]=$source
    done < <(virsh domblklist "$domain" --details)
}

is_backup_overlay() {
    [[ "$(basename -- "$1")" == *.borg.qcow2 ]]
}

has_backup_overlay() {
    local target
    for target in "${!disk_source[@]}"; do
        is_backup_overlay "${disk_source[$target]}" && return 0
    done
    return 1
}

blockcommit() {
    local domain=$1 target source failed=0 found=0
    parse_disks "$domain"
    for target in "${!disk_source[@]}"; do
        source=${disk_source[$target]}
        is_backup_overlay "$source" || continue
        found=1
        if virsh blockcommit "$domain" "$target" --active --pivot \
            || { sleep 10; virsh blockcommit "$domain" "$target" --active --pivot; }; then
            mv -- "$source" "$source.old" || failed=1
        else
            echo "error: blockcommit failed for $domain $target"
            failed=1
        fi
    done
    [[ $found -eq 1 && $failed -eq 0 ]]
}

domain=$1
if [[ -n "$domain" ]]; then
    if [ -z "$BACKUP_BORG" ] && [ -z "$BACKUP_RESTIC" ]; then
        echo "error: Kein Backup-Backend ausgewählt"
        exit 1
    fi
    if ! apply_ssh_key; then
        echo "error: $ssh_key_error"
        exit 1
    fi
    was_suspended=
    trap cleanup_qemu EXIT
    if ! virsh list --all --name | grep -Fxq -- "$domain"; then
        echo "error: VM nicht gefunden"
        exit 1
    fi

    if ! wake_if_suspended "$domain"; then
        echo "error: $domain konnte nicht für den Snapshot aufgeweckt werden"
        exit 1
    fi

    parse_disks "$domain"
    if has_backup_overlay; then
        echo "warning: snapshots still there for domain $domain"
        if ! blockcommit "$domain"; then
            echo "error: blockcommit not successful for domain $domain"
            exit 1
        fi
        parse_disks "$domain"
    fi

    images=()
    diskspecs=()
    for target in "${!disk_source[@]}"; do
        diskspecs+=(--diskspec "${target},snapshot=external")
        if ! is_backup_overlay "${disk_source[$target]}" \
            && [[ "${disk_source[$target]}" != *_backup* ]]; then
            images+=("${disk_source[$target]}")
        fi
    done

    d=$(echo "$domain" | tr "[:upper:]" "[:lower:]")
    if [[ "$d" != "pfsense" && "$d" != "opnsense" ]]; then
        echo "Sending TRIM command to $domain"
        virsh domfstrim "$domain"
        echo "Waiting for TRIM on $domain"
        sleep 120
    fi

    echo "Creating snapshot of $domain"
    create_snapshot "$domain" "${diskspecs[@]}"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "error: snapshot creation failed, returned with $rc"
        exit 1
    fi

    if [[ ${#images[@]} -eq 0 ]]; then
        echo "error: no disk images for $domain"
        blockcommit "$domain" || echo "error: blockcommit failed for $domain"
        exit 1
    fi

    run_enabled_backends "$domain" vm n "${BORG_TRIES:-20}" "${images[@]}"
    backends_rc=$?

    if ! blockcommit "$domain"; then
        echo "error: blockcommit failed for $domain"
        exit 1
    fi
    if [[ $backends_rc -ne 0 ]]; then
        exit 1
    fi

    virsh domtime "$domain" --now
    if ! restore_suspended; then
        echo "error: $domain konnte nicht wieder angehalten werden"
        exit 1
    fi
fi

exit 0
