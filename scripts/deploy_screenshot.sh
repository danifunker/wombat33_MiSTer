#!/usr/bin/env bash
# Deploy: verify the Quartus build, then hand off to the reusable launcher
# tools/misterdeploy/launch_unstable_core.py, which pushes the rbf (scp, md5-verified)
# and starts it by writing load_core to the MiSTer's /dev/MiSTer_cmd FIFO — no reboot
# and no blind OSD navigation. (The launcher still has --launch osd for hosts with no
# ssh; that path missed on .143, see its docstring.) Machine config: scripts/local.env.
#
# Portable: the Quartus revision is auto-detected from the repo's single *.qsf
# (override with $QUARTUS_REVISION), so this drops into another core repo unedited.
#
# Usage: bash scripts/deploy_screenshot.sh
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
if [ -r scripts/local.env ]; then . scripts/local.env; fi

: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTER_SSH_KEY:?set MISTER_SSH_KEY in scripts/local.env}"
: "${MISTER_HTTP_PORT:=8182}"

# Revision (= .qsf basename) drives both the artifact name and the report names.
if [ -n "${QUARTUS_REVISION:-}" ]; then
    REV="$QUARTUS_REVISION"
else
    shopt -s nullglob; qsf=( *.qsf ); shopt -u nullglob
    case "${#qsf[@]}" in
        1) REV="${qsf[0]%.qsf}" ;;
        *) echo "ERROR: cannot auto-pick a revision from *.qsf — set QUARTUS_REVISION" >&2
           exit 1 ;;
    esac
fi
: "${RBF_NAME:=$REV.rbf}"

# Seeding — `=` (not `:=`) so an explicit empty SEED_FILE in local.env disables it.
# Defaults reproduce the MacQuadra800 layout: the pristine 1 MB Quadra 800 ROM lands as
# games/MacQuadra800/boot.rom, and SD slot 0 is pre-mounted to the main SCSI disk image.
: "${SEED_FILE=releases/quadra800.rom}"
: "${SEED_REMOTE=/media/fat/games/MacQuadra800/boot.rom}"
: "${SEED_MOUNT_CFG=/media/fat/config/MacQuadra800.s0}"
: "${SEED_MOUNT_REL=games/MacQuadra800/QuadSquad8.hda}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "=== Verify build artifact ==="
if [ ! -f "output_files/$RBF_NAME" ]; then
    log "ERROR: output_files/$RBF_NAME does not exist - build failed?"
    exit 1
fi
# Refuse to deploy a stale rbf left by a failed Quartus run: trust the first line of
# <rev>.fit.summary ("Fitter Status : Successful" vs "...: Failed").
FIT_STATUS=$(awk 'NR==1' "output_files/$REV.fit.summary" 2>/dev/null)
case "$FIT_STATUS" in
    *Successful*) ;;
    *Failed*)
        log "ERROR: Quartus Fitter reported Failed in $REV.fit.summary:"
        log "  $FIT_STATUS"
        exit 1 ;;
    *)
        log "WARN: no parseable Fitter Status in $REV.fit.summary. Build state unknown — continuing." ;;
esac

# A Fitter "Successful" says the design PLACED, not that it will WORK. Timing is
# the separate gate, and it is the one that matters for hardware: a violated
# build can boot and then corrupt memory in ways that look like random software
# bugs. Refuse it here rather than leave the judgement to whoever reads the log.
# Override with ALLOW_TIMING_VIOLATION=1 only for a deliberate throwaway probe.
STA="output_files/$REV.sta.summary"
if [ -r "$STA" ]; then
    WORST=$(awk '/[Ss]lack/ { v=""; for (i=1;i<=NF;i++) if ($i ~ /^-?[0-9]+\.[0-9]+$/) v=$i
                 if (v!="") { if (!seen || v+0 < min+0) { min=v; seen=1 } } }
                 END { if (seen) print min }' "$STA")
    if [ -n "${WORST:-}" ] && awk "BEGIN{exit !($WORST < 0)}"; then
        if [ "${ALLOW_TIMING_VIOLATION:-0}" = 1 ]; then
            log "WARN: timing VIOLATED (worst slack $WORST ns) — deploying anyway"
            log "      because ALLOW_TIMING_VIOLATION=1. Do not trust this build."
        else
            log "ERROR: timing NOT met — worst slack $WORST ns in $STA."
            log "       Refusing to deploy. Re-fit until slack is positive, or set"
            log "       ALLOW_TIMING_VIOLATION=1 for a deliberate throwaway probe."
            exit 1
        fi
    else
        log "Timing OK — worst slack +$WORST ns"
    fi
else
    log "WARN: no $STA to check timing against — continuing."
fi

log "=== Push rbf + seed ROM/mount + launch via the reusable launcher ==="
# git-bash/MSYS rewrites bare "/media/fat/..." args into Windows paths; disable that
# so the absolute --seed-remote/--seed-mount-cfg paths reach the MiSTer unmangled.
export MSYS_NO_PATHCONV=1
LAUNCH_ARGS=(
    --host "$MISTER_HOST" --port "$MISTER_HTTP_PORT"
    --ssh-key "$MISTER_SSH_KEY"
    --core "$RBF_NAME"
    --push "output_files/$RBF_NAME"
)
if [ -n "$SEED_FILE" ]; then
    LAUNCH_ARGS+=(
        --seed-file "$SEED_FILE"
        --seed-remote "$SEED_REMOTE"
        --seed-mount-cfg "$SEED_MOUNT_CFG"
        --seed-mount-rel "$SEED_MOUNT_REL"
    )
else
    log "SEED_FILE empty — skipping seed (push + launch only)"
fi
exec python tools/misterdeploy/launch_unstable_core.py "${LAUNCH_ARGS[@]}"
