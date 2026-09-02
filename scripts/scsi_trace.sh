#!/usr/bin/env bash
# scsi_trace.sh — deploy the core, then capture the SCSI protocol trace that
# rtl/iosb.sv streams out the modem port, and decode it.
#
# The tracer emits one record the first time each distinct value appears on a
# channel WITHIN AN EPOCH (~8 s, marked by an "E" record); the tables are wiped
# at every epoch boundary. Session-wide dedup was actively misleading: A/UX
# Startup drives the disk through the ROM's SCSI Manager, so its commands are
# the ROM's commands and were all marked seen during the Mac OS boot -- a whole
# A/UX boot attempt decoded as silence. See docs/scsi/aux-startup-boot-path.md
# and the tracer's header comment in rtl/iosb.sv for the record format.
#
# Usage:
#   bash scripts/scsi_trace.sh [seconds]      # deploy + capture (default 150)
#   bash scripts/scsi_trace.sh --capture-only [seconds]
#
# Leaves the raw stream in scratch/scsi_trace.txt and a decoded listing in
# scratch/scsi_trace.decoded.txt.
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
. scripts/local.env
SSH="ssh -i $MISTER_SSH_KEY -o ConnectTimeout=8 root@$MISTER_HOST"

CAPTURE_ONLY=0
if [ "${1:-}" = "--capture-only" ]; then CAPTURE_ONLY=1; shift; fi
SECS="${1:-150}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [ "$CAPTURE_ONLY" = 0 ]; then
    log "=== deploy ==="
    bash scripts/deploy_screenshot.sh || exit 1
fi

log "=== capturing ${SECS}s from /dev/ttyS1 ==="
# shellcheck disable=SC2086
$SSH "stty -F /dev/ttyS1 115200 raw -echo; timeout $SECS cat /dev/ttyS1 > /tmp/scsi_trace.txt; wc -c /tmp/scsi_trace.txt"
scp -q -i "$MISTER_SSH_KEY" "root@$MISTER_HOST:/tmp/scsi_trace.txt" scratch/scsi_trace.txt || exit 1
log "raw: scratch/scsi_trace.txt ($(wc -c < scratch/scsi_trace.txt) bytes)"

python - scratch/scsi_trace.txt > scratch/scsi_trace.decoded.txt <<'PY'
import sys, re
TAG = {
 "=":"ARMED (first Unix-dialect command seen)",
 "H":"heartbeat", "E":"---- epoch boundary (seen-tables wiped) ----",
 "f":"FIFO flags read (first sighting)", "s":"sequence step read (first sighting)",
 "C":"cmd write (first sighting)", "S":"SELID write (first sighting)",
 "r":"INTR read (first sighting)", "t":"STATUS read (first sighting)",
 "T":"sel/resel timeout write", "P":"sync period write", "O":"sync offset write",
 "1":"CONFIG1 write", "2":"CONFIG2 write", "3":"CONFIG3 write",
 "K":"clock-conversion write", "X":"test-register write",
 "U":"16-byte-strided write outside the SCSI window",
 "u":"16-byte-strided read outside the SCSI window",
 "B":"BUS FAULT addr 31:24", "b":"BUS FAULT addr 23:16",
 "n":"  ...its addr 15:8",
}
CMD = {0x00:"NOP",0x01:"FLUSH",0x02:"RESET CHIP",0x03:"RESET BUS",0x10:"TRANSFER INFO",
       0x11:"ICCS",0x12:"MSG ACCEPT",0x18:"PAD",0x1A:"SET ATN",0x1B:"RST ATN",
       0x41:"SEL no-ATN",0x42:"SEL ATN",0x43:"SEL ATN STOP",0x44:"ENSEL",0x45:"DISSEL",
       0x46:"SEL ATN3"}
PHASE = {0:"DATA OUT",1:"DATA IN",2:"COMMAND",3:"STATUS",6:"MSG OUT",7:"MSG IN"}
INTR = [(0x80,"RST"),(0x40,"ILLEGAL"),(0x20,"DISC"),(0x10,"BS"),(0x08,"FC"),
        (0x04,"RESEL"),(0x02,"SELATN"),(0x01,"SEL")]
data = open(sys.argv[1],"rb").read().decode("latin-1")
recs = re.findall(r"([=HECSrtfsUuBbnTPO123KX])([0-9A-F]{2}) ", data)
hb = 0
for tag, hexv in recs:
    v = int(hexv,16)
    if tag == "H":
        hb += 1
        continue
    if tag == "E":
        hb += 1
        print("   ... %d heartbeat(s)" % hb); hb = 0
        print("=== epoch %d ends -- everything below is sighted afresh ===" % v)
        continue
    if hb:
        print("   ... %d heartbeat(s) (ROM-only activity)" % hb); hb = 0
    d = TAG.get(tag, tag)
    extra = ""
    if tag == "C":
        extra = "  %s%s" % (CMD.get(v & 0x7f, "?"), "  +DMA" if v & 0x80 else "")
    elif tag in "rt":
        if tag == "t":
            extra = "  phase=%s%s%s" % (PHASE.get(v & 7, v & 7),
                                        "  INT" if v & 0x80 else "",
                                        "  TC0" if v & 0x10 else "")
        else:
            bits = [n for m, n in INTR if v & m]
            extra = "  " + ("|".join(bits) if bits else "none")
    elif tag == "f":
        extra = "  count=%d step=%d" % (v & 0x1f, v >> 5)
    elif tag == "s":
        extra = "  step=%d" % (v & 7)
    elif tag in "Iq":
        extra = "  " + ("assert" if v else "deassert")
    elif tag in "Uu":
        extra = "  $5%02X.....  <- a driver is here, and it is NOT our SCSI window" % v
    elif tag == "B":
        extra = "  the CPU faulted on an address starting $%02X......" % v
    elif tag == "b":
        extra = "  ...$..%02X....  (see the B record above)" % v
    elif tag == "n":
        extra = "  ...$..%02X..  (low half of the U/u address above)" % v
    print("%s %02X  %-22s%s" % (tag, v, d, extra))
if hb:
    print("   ... %d heartbeat(s) (ROM-only activity)" % hb)
print()
print("total records: %d" % len(recs))
PY
log "decoded: scratch/scsi_trace.decoded.txt"
tail -60 scratch/scsi_trace.decoded.txt
