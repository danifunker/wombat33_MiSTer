#!/usr/bin/env bash
# shutdown_finder.sh — Finder: Special -> Shut Down, verified before release.
#
# Why this exists alongside shutdown.sh: that one was tuned for a Finder whose
# Special menu has five items, and it aims at an absolute y=104 while trusting
# menuitem_probe.py to find the panel. On the A/UX disk's MacPartition (System
# 7.1) the menu has EIGHT rows --
#
#     Clean Up Desktop / Empty Trash... / --- / Eject Disk / Erase Disk... /
#     --- / Restart / Shut Down
#
# -- so y=104 lands between "Erase Disk..." and the separator below it, and the
# probe kept reporting NOPANEL and giving up. "Erase Disk..." being two rows
# above the target is reason enough not to aim by a hardcoded offset ever again.
#
# So this walks down in small steps and, before releasing, CONFIRMS from the
# screenshot that the highlighted band is the LAST row of the panel. If that
# check fails it slides back to the title and releases on nothing.
#
# Usage: bash scripts/guest/shutdown_finder.sh
# Exit:  0 shut down issued, 3 could not confirm (nothing selected)
set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
. scripts/local.env
WS="python scripts/mister_ws.py --host $MISTER_HOST --delay 0.02"
P=scratch/guest
mkdir -p "$P"

SPECIAL_X=${SPECIAL_X:-229}
steps() { local n=$1 dy=$2 out=""; while [ "$n" -gt 0 ]; do out="$out mouse:0,$dy"; n=$((n-1)); done; echo "$out"; }
log()   { echo "[$(date +%H:%M:%S)] $*"; }

# Reports "BAND <y0> <y1> <panel_bottom>" for the highlighted row of an open
# pull-down, or "NONE". A menu row is a near-solid dark horizontal run inside
# the panel's x-range; the panel bottom is the lowest row with a frame pixel.
probe() {
python - "$1" <<'PY'
import sys
try:
    from PIL import Image
except ImportError:
    print("NOPIL"); sys.exit(0)
im = Image.open(sys.argv[1]).convert("L")
w, h = im.size
px = im.load()
# Sample to the RIGHT of the item text (x 295..335): inside the panel, past
# "Shut Down"/"Clean Up Desktop", so a hovered row is SOLID black there. The
# first version sampled x 210..330, which straddles the white-on-black text --
# a highlighted row never reached the darkness threshold and the walk stepped
# past every row without ever seeing one.
BX0, BX1 = 295, 335
# The panel's frame is found over the full width; its bottom border is what
# "last row" is measured against.
PX0, PX1 = 210, 330
rows = []
bottom = 0
for y in range(20, min(h, 220)):
    b = sum(1 for x in range(BX0, BX1) if px[x, y] < 96)
    if b > (BX1 - BX0) * 0.90:
        rows.append(y)
    if sum(1 for x in range(PX0, PX1) if px[x, y] < 96) > 3:
        bottom = y
if not rows:
    print("NONE %d" % bottom); sys.exit(0)
runs, cur = [], [rows[0]]
for y in rows[1:]:
    if y == cur[-1] + 1: cur.append(y)
    else: runs.append(cur); cur = [y]
runs.append(cur)
# a real menu row is a dozen px tall; the panel's own 1-2 px bottom border is
# also a solid dark run and must not be mistaken for the hovered row
runs = [r for r in runs if len(r) >= 8]
if not runs:
    print("NONE %d" % bottom); sys.exit(0)
best = max(runs, key=len)
print("BAND %d %d %d" % (best[0], best[-1], bottom))
PY
}

log "positioning on Special (x=$SPECIAL_X)"
bash scripts/guest/click.sh "$SPECIAL_X" 7 move >/dev/null 2>&1 || { log "could not position"; exit 3; }
$WS mousebtn:left_down sleep:0.4 >/dev/null 2>&1

bash scripts/grab_fresh.sh "$P/sf_open.png" >/dev/null 2>&1
read -r st y0 y1 bot <<<"$(probe "$P/sf_open.png")"
if [ "$st" = "NOPIL" ]; then
    log "Pillow not available - cannot verify the row, refusing to click"
    $WS $(steps 60 -1) mousebtn:left_up >/dev/null 2>&1
    exit 3
fi
log "menu opened (probe: $st ${y0:-} ${y1:-} ${bot:-})"

ok=0
for attempt in $(seq 1 40); do
    bash scripts/grab_fresh.sh "$P/sf_hover.png" >/dev/null 2>&1
    read -r st a b c <<<"$(probe "$P/sf_hover.png")"
    if [ "$st" != "BAND" ]; then
        log "no row highlighted (panel_bottom=${a:-?}) - down 6"
        $WS $(steps 6 1) >/dev/null 2>&1
        continue
    fi
    y0=$a; y1=$b; bot=$c
    # Shut Down is the LAST row, so its TOP sits about one row-height above the
    # panel's bottom border. Measuring against the panel instead of a hardcoded
    # y is what keeps this correct on a menu with a different number of items.
    depth=$(( bot - y0 ))
    log "row [$y0,$y1] panel_bottom=$bot depth=$depth"
    if [ "$depth" -ge 10 ] && [ "$depth" -le 22 ]; then
        ok=1; break
    fi
    if [ "$depth" -gt 22 ]; then
        n=$(( (depth - 16) / 3 )); [ "$n" -lt 1 ] && n=1; [ "$n" -gt 12 ] && n=12
        $WS $(steps "$n" 1) >/dev/null 2>&1
    else
        $WS $(steps 2 -1) >/dev/null 2>&1
    fi
done

if [ "$ok" != 1 ]; then
    log "could not confirm the last row - releasing on the title, nothing selected"
    $WS $(steps 60 -1) mousebtn:left_up >/dev/null 2>&1
    exit 3
fi

log "last row highlighted (Shut Down) - releasing"
$WS mousebtn:left_up >/dev/null 2>&1
sleep 12
bash scripts/grab_fresh.sh "$P/sf_done.png" >/dev/null 2>&1
log "final shot: $P/sf_done.png"
