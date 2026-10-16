#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export PATH=$PATH:$SCRIPT_DIR:/snap/bin
# shellcheck source=backup-common.sh
source "$SCRIPT_DIR/backup-common.sh"
# shellcheck source=backup-restic.sh
source "$SCRIPT_DIR/backup-restic.sh"
resolve_backends

die() {
  echo "$1" >&2
  exit 1
}

backend_label() {
  case "$1" in
    borg) printf 'Borg' ;;
    restic) printf 'Restic' ;;
    rustic) printf 'Rustic' ;;
    *) printf '%s' "$1" ;;
  esac
}

repo_is_absent() {
  printf '%s\n' "$1" | grep -q \
    -e 'does not exist' \
    -e 'DoesNotExist' \
    -e 'Is there a repository at the following location' \
    -e 'unable to open config file' \
    -e 'No repository config file found' \
    -e 'config file does not exist' \
    -e 'file does not exist' \
    -e 'no such file or directory' \
    -e '404'
}

repo_already_initialized() {
  printf '%s\n' "$1" | grep -q -e 'already exists' -e 'already initialized'
}

if [ $# -ne 0 ]; then
  die "repo-init.sh erwartet keine Argumente"
fi
if [ -z "$BACKUP_BORG" ] && [ -z "$BACKUP_RESTIC" ]; then
  die "Kein Backup-Backend ausgewählt"
fi

if [ "$BACKUP_BORG" = "y" ]; then
  if [ -z "$BORG_PASSPHRASE" ]; then
    die "Kein Borg-Passwort angegeben"
  fi
  if [ -z "$BORG_REPO" ]; then
    die "Kein Borg-Repository angegeben"
  fi
  if ! command -v borg >/dev/null 2>&1; then
    die "borg ist nicht installiert"
  fi
  export BORG_PASSPHRASE BORG_REPO
fi

if [ "$BACKUP_RESTIC" = "y" ]; then
  fallback_from_rustic
  if [ -n "$rustic_fallback_warning" ]; then
    echo "$rustic_fallback_warning" >&2
  fi
  if [ -n "$restic_program_error" ]; then
    die "$restic_program_error"
  fi
  if [ -z "$RESTIC_PASSWORD" ]; then
    die "Kein Passwort für $RESTIC_PROGRAM angegeben"
  fi
  if [ -z "$RESTIC_REPOSITORY" ]; then
    die "Kein Repository für $RESTIC_PROGRAM angegeben"
  fi
  if ! command -v "$RESTIC_PROGRAM" >/dev/null 2>&1; then
    die "$RESTIC_PROGRAM ist nicht installiert"
  fi
  export RESTIC_PASSWORD RESTIC_REPOSITORY
fi

if ! apply_ssh_key; then
  die "$ssh_key_error"
fi
trap remove_ssh_wrapper EXIT

init_borg() {
  local label probe probe_rc borg_help borg_major
  local -a init_args=()
  label=$(backend_label borg)
  borg_help=$(borg --help 2>&1) || {
    echo "borg --help ist fehlgeschlagen" >&2
    return 1
  }
  if printf '%s\n' "$borg_help" | grep -q rcreate; then
    borg_major=2
  elif printf '%s\n' "$borg_help" | grep -q init; then
    borg_major=1
  else
    echo "borg init wird von dieser Borg-Version nicht angeboten" >&2
    return 1
  fi
  if [ "$borg_major" = 2 ]; then
    probe=$(borg --repo "$BORG_REPO" rinfo 2>&1)
  else
    probe=$(borg info "$BORG_REPO" 2>&1)
  fi
  probe_rc=$?
  if [ "$probe_rc" -eq 0 ]; then
    echo "$label-Repository existiert bereits"
    return 0
  fi
  if ! printf '%s\n' "$probe" | grep -q -e 'does not exist' -e 'DoesNotExist'; then
    echo "$label-Repository konnte nicht gelesen werden" >&2
    printf '%s\n' "$probe" >&2
    return 1
  fi
  if [ "$borg_major" = 2 ]; then
    if borg rcreate --help 2>&1 | grep -q -- '--make-parent-dirs'; then
      init_args+=(--make-parent-dirs)
    fi
    borg --repo "$BORG_REPO" rcreate --encryption=repokey-blake2-aes-ocb "${init_args[@]}"
  else
    if borg init --help 2>&1 | grep -q -- '--make-parent-dirs'; then
      init_args+=(--make-parent-dirs)
    fi
    borg init --encryption=repokey-blake2 "${init_args[@]}" "$BORG_REPO"
  fi
  if [ $? -ne 0 ]; then
    echo "$label-Repository konnte nicht angelegt werden" >&2
    return 1
  fi
  echo "$label-Repository angelegt"
}

restic_probe() {
  local -a args=()
  if "$RESTIC_PROGRAM" --help 2>&1 | grep -q -- '--no-lock'; then
    args+=(--no-lock)
  fi
  if [ "$RESTIC_PROGRAM" = "rustic" ]; then
    run_restic "${args[@]}" snapshots 2>&1
  else
    run_restic "${args[@]}" cat config 2>&1
  fi
}

init_restic_repo() {
  local label probe probe_rc out init_rc
  label=$(backend_label "$RESTIC_PROGRAM")
  probe=$(restic_probe)
  probe_rc=$?
  if [ "$probe_rc" -eq 0 ]; then
    echo "$label-Repository existiert bereits"
    return 0
  fi
  if repo_is_absent "$probe" || { [ "$RESTIC_PROGRAM" = "restic" ] && printf '%s\n' "$probe" | grep -q 'wrong password or no key found'; }; then
    out=$(run_restic init 2>&1)
    init_rc=$?
    if [ "$init_rc" -eq 0 ]; then
      echo "$label-Repository angelegt"
      return 0
    fi
    if repo_already_initialized "$out"; then
      echo "$label-Repository konnte nicht gelesen werden" >&2
      printf '%s\n' "$probe" >&2
      return 1
    fi
    echo "$label-Repository konnte nicht angelegt werden" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  echo "$label-Repository konnte nicht gelesen werden" >&2
  printf '%s\n' "$probe" >&2
  return 1
}

status=0
if [ "$BACKUP_BORG" = "y" ]; then
  init_borg || status=1
fi
if [ "$BACKUP_RESTIC" = "y" ]; then
  init_restic_repo || status=1
fi
exit "$status"
