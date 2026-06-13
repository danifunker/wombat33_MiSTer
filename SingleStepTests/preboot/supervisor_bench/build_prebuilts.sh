#!/bin/bash
# build_prebuilts.sh — build every prebuilt test image for the
# Macintosh IIvi / LC II hardware campaign and package them as one
# tgz per fixture under SingleStepTests/prebuilt/.
#
# Fixtures (2 files each: SCSI .hda + 800K floppy .dsk):
#   cpu-mdc824           CPU corpus, fixed 80-byte display stride
#   cpu-autovideo        CPU corpus, runtime ScrnRow stride (mdc824/V8/VASP)
#   mmu-safe-mdc824     MMU hw-safe rows, fixed stride
#   mmu-safe-autovideo  MMU hw-safe rows, auto stride
#   mmu-full-mdc824     MMU all rows incl. live MMU + faults, fixed stride
#   mmu-full-autovideo  MMU all rows incl. live MMU + faults, auto stride
#
# Inputs:
#   TEMPLATE  — APM template .hda (default ~/testdisk.hda)
#   RB        — rb-cli binary
#   OUTDIR    — final tgz directory (default ../../prebuilt)
set -euo pipefail

RB="${RB:-$HOME/repos/rusty-backup/target/release/rb-cli}"
TEMPLATE="${TEMPLATE:-$HOME/testdisk.hda}"
OUTDIR="${OUTDIR:-../../prebuilt}"
STAGE="${STAGE:-/tmp/quadra800_prebuilt}"
BUILD=build
BOOT="$BUILD/boot_stub_patch.bin"
RESULTS_SIZE=409600

[[ -x "$RB" ]]       || { echo "rb-cli not found at $RB"; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "missing template $TEMPLATE"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }

make prebuilt_payloads
[[ -f "$BOOT" ]] || { echo "missing $BOOT"; exit 1; }

patch_markers() {  # image payload_off_hex results_off_hex
    python3 - "$1" "0x$2" "0x$3" <<'PY'
import struct, sys
image, payload_off, results_off = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
with open(image, "r+b") as f:
    data = f.read()
    p = data.find(b"PAYLDOFF")
    if p < 0: sys.exit("PAYLDOFF marker not found in boot stub")
    f.seek(p + 8); f.write(struct.pack(">I", payload_off))
    r = data.find(b"RJSNLTAG")
    if r < 0: sys.exit("RJSNLTAG marker not found in payload")
    f.seek(r + 8); f.write(struct.pack(">I", results_off))
PY
}

put_rel() {  # img host dst -> partition-relative hex offset
    "$RB" put --print-offset --quiet "$1" "$2" "$3" |
        jq -r '.result.offset - .result.partition_offset' | xargs printf '%x'
}
locate_rel() {  # img path -> partition-relative hex offset
    "$RB" locate --quiet "$1" "$2" |
        jq -r '.result.offset - .result.partition_offset' | xargs printf '%x'
}

build_hda() {  # payload out
    local payload="$1" out="$2" img poff roff
    img="${out}@1"
    cp -f "$TEMPLATE" "$out"
    "$RB" put --boot "$BOOT" --quiet "$img" >/dev/null
    poff=$(put_rel "$img" "$payload" /Payload)
    "$RB" put --zero "$RESULTS_SIZE" --dst /Results.jsonl --quiet "$img" >/dev/null
    roff=$(locate_rel "$img" /Results.jsonl)
    "$RB" fsck --quiet "$img" >/dev/null
    patch_markers "$out" "$poff" "$roff"
    echo "  $out  (payload@0x$poff results@0x$roff)"
}

build_dsk() {  # payload out volname
    local payload="$1" out="$2" vol="$3" poff roff
    rm -f "$out"
    "$RB" new --quiet --fs hfs --size 800K --name "$vol" "$out" >/dev/null
    "$RB" put --boot "$BOOT" --quiet "$out" >/dev/null
    poff=$(put_rel "$out" "$payload" /Payload)
    "$RB" put --zero "$RESULTS_SIZE" --dst /Results.jsonl --quiet "$out" >/dev/null
    roff=$(locate_rel "$out" /Results.jsonl)
    "$RB" fsck --quiet "$out" >/dev/null
    patch_markers "$out" "$poff" "$roff"
    echo "  $out  (payload@0x$poff results@0x$roff)"
}

rm -rf "$STAGE"; mkdir -p "$STAGE" "$OUTDIR"

declare -A PAYLOADS=(
    [cpu-mdc824]="$BUILD/payload_cpu_scsi.bin"
    [cpu-autovideo]="$BUILD/payload_cpu_scsi_auto.bin"
    [mmu-safe-mdc824]="$BUILD/payload_mmu_scsi.bin"
    [mmu-safe-autovideo]="$BUILD/payload_mmu_scsi_auto.bin"
    [mmu-full-mdc824]="$BUILD/payload_mmu_full_scsi.bin"
    [mmu-full-autovideo]="$BUILD/payload_mmu_full_scsi_auto.bin"
)
declare -A VOLNAME=(
    [cpu-mdc824]="CPUBench"      [cpu-autovideo]="CPUBench"
    [mmu-safe-mdc824]="MMUSafe" [mmu-safe-autovideo]="MMUSafe"
    [mmu-full-mdc824]="MMUFull" [mmu-full-autovideo]="MMUFull"
)

FIXTURES="cpu-mdc824 cpu-autovideo mmu-safe-mdc824 mmu-safe-autovideo mmu-full-mdc824 mmu-full-autovideo"

for fx in $FIXTURES; do
    payload="${PAYLOADS[$fx]}"
    [[ -f "$payload" ]] || { echo "missing payload $payload"; exit 1; }
    echo "== $fx =="
    build_hda "$payload" "$STAGE/quadra800-$fx.hda"
    build_dsk "$payload" "$STAGE/quadra800-$fx.dsk" "${VOLNAME[$fx]}"
done

echo
echo "== packaging =="
STAMP=$(date +%F)
( cd "$STAGE"
  for fx in $FIXTURES; do
      tar czf "quadra800-$fx-$STAMP.tgz" "quadra800-$fx.hda" "quadra800-$fx.dsk"
  done
  sha256sum quadra800-*.tgz quadra800-*.hda quadra800-*.dsk > SHA256SUMS
)
cp -f "$STAGE"/quadra800-*-"$STAMP".tgz "$STAGE/SHA256SUMS" "$OUTDIR/"
echo "tgz files + SHA256SUMS -> $OUTDIR/"
ls -la "$OUTDIR"
