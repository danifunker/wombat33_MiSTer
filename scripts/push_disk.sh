#!/usr/bin/env bash
# scripts/push_disk.sh — push a SCSI disk image to the MiSTer, verify it byte-for-byte,
# and take a compressed PRISTINE backup on the MiSTer before the core ever writes to it.
#
# Disk images are multi-gigabyte, so they live outside the repo and are pushed by hand
# (deploy_screenshot.sh only writes the slot-0 mount memory that points at one). This
# script is that "by hand" step, made repeatable.
#
# Order matters: verify BEFORE backing up (a corrupt transfer must not become the
# backup), and back up BEFORE the first boot (once the core mounts it read-write there
# is no pristine copy left).
#
# Usage:
#   bash scripts/push_disk.sh <local-image> [remote-name]
#     <local-image>   path to the .hda/.vhd/.img to push (may contain spaces)
#     [remote-name]   filename on the MiSTer; default: the local basename with
#                     spaces squeezed to none (MiSTer copes with spaces, scripts don't)
#
#   bash scripts/push_disk.sh --no-backup <local-image> [remote-name]
#   bash scripts/push_disk.sh -h
#
# Host/key come from scripts/local.env (MISTER_HOST, MISTER_SSH_KEY). The remote
# directory is the core's games folder, derived from SEED_REMOTE.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
[ -r scripts/local.env ] && . scripts/local.env

BACKUP=1
case "${1:-}" in
    --no-backup) BACKUP=0; shift ;;
    -h|--help) awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/,""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

SRC="${1:?usage: push_disk.sh <local-image> [remote-name]  (try --help)}"
[ -f "$SRC" ] || { echo "ERROR: no such file: $SRC" >&2; exit 1; }

: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_SSH_USER:=root}"
: "${SEED_REMOTE:=/media/fat/games/MacQuadra800/boot.rom}"
GAMES_DIR="$(dirname "$SEED_REMOTE")"

DST_NAME="${2:-$(basename "$SRC" | tr -d ' ')}"
DST="$GAMES_DIR/$DST_NAME"
BAK="$GAMES_DIR/backup/$DST_NAME.gz"

# git-bash/MSYS would rewrite the bare /media/fat/... paths into Windows paths.
export MSYS_NO_PATHCONV=1
SSH=(ssh -i "$MISTER_SSH_KEY" "$MISTER_SSH_USER@$MISTER_HOST")
log() { echo "[$(date +%H:%M:%S)] $*"; }

SZ=$(stat -c %s "$SRC" 2>/dev/null || stat -f %z "$SRC" 2>/dev/null)
log "push  $SRC  ($SZ bytes)"
log "  ->  $MISTER_HOST:$DST"

if "${SSH[@]}" "test -e '$DST'"; then
    echo "REFUSING: $DST already exists on the MiSTer." >&2
    echo "  It may hold a booted system's writes. Move or delete it there first," >&2
    echo "  or pass a different [remote-name]." >&2
    exit 1
fi

"${SSH[@]}" "mkdir -p '$GAMES_DIR' '$GAMES_DIR/backup'" || exit 1
scp -i "$MISTER_SSH_KEY" "$SRC" "$MISTER_SSH_USER@$MISTER_HOST:$DST" || exit 1

log "verify (md5, both ends)"
LOCAL_MD5=$(md5sum "$SRC" | cut -d' ' -f1)
REMOTE_MD5=$("${SSH[@]}" "md5sum '$DST'" | cut -d' ' -f1)
if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
    echo "ERROR: md5 mismatch — local $LOCAL_MD5 != remote $REMOTE_MD5" >&2
    echo "       the copy on the MiSTer is bad; delete $DST and retry." >&2
    exit 1
fi
log "  md5 $LOCAL_MD5  OK"

if [ "$BACKUP" = 1 ]; then
    log "pristine backup -> $BAK  (gzip -1 on the MiSTer's ARM; this takes a few minutes)"
    "${SSH[@]}" "gzip -1 -c '$DST' > '$BAK'" || exit 1
    "${SSH[@]}" "ls -l '$BAK'"
    log "  restore with:  gzip -dc '$BAK' > '$DST'   (run on the MiSTer)"
else
    log "--no-backup: skipping the pristine backup"
fi

log "DONE. Mount it from the OSD (Mount SCSI disk), or point SEED_MOUNT_REL at"
log "      ${DST#/media/fat/} in scripts/local.env so deploy seeds slot 0 with it."
