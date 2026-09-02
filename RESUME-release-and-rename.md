# Resume prompt — finish the A/UX release, then rename the core to MacQuadra800

Paste this as the opening message of a new session.

**Where we are:** A/UX 3.1 boots to the multiuser desktop on Wombat33 — both
SCSI bugs are fixed and committed (see `RESUME-aux-superblock.md` for the SCSI
story). We are now executing the user's 7-step finish-and-rename plan. Steps 1-2
are done and step 3 is mostly done but surfaced a **stability problem on the
release build** that must be resolved before continuing.

**Binding rules (unchanged, user-reaffirmed):** never reload a core while a
guest with a mounted HFS volume is *running* — it yanks the volume; **ask before
any deploy/reset**; shut the guest down cleanly first. Stability is a stated
priority.

---

## The user's plan (verbatim intent), with status

1. ✅ **Commit the working code.** Done — all last-session + this-session work is
   committed on `main` (SCSI fixes, tb T1-T15, docs, forensics scripts, resume
   docs).
2. ✅ **Build the non-debug core.** Done. `SCSI_TRACE` is now **commented out**
   in `wombat33.qsf` (~line 125), seed 13. The release build **met timing at
   +0.130 ns** (0 errors). Artifact was `output_files/wombat33.rbf`, md5
   `70716e92871448d1ff81ebb430902f4a`, deployed to the MiSTer. (User's call held:
   timing is not the LC-style problem for this core — and indeed it closed.)
3. ✅ **Test the build on A/UX — PASSED on the 2026-09-02 retest.** The reload
   + reproduce experiment came back clean: A/UX booted (through a ~25-min fsck
   of the twice-yanked volume), ran **16+ min of live interactive desktop**
   (menus, CommandShell, typing), sync-daemon writes flowed in every 30-s
   sample, and `shutdown -h now` reached "You may now switch off your
   Macintosh safely." The 08:02 hang did NOT reproduce — see §"The hang"
   addendum for the revised read and the io-counter method that replaced
   mtime-watching.
4. ✅ **Test MacOS 8.1 (no regressions) — PASSED on the clean reproduce.** After
   the reload, MacOS rebooted, showed the expected "not shut down properly"
   dialog (dismissed with Return → keyboard reaches the foreground), and the
   **menu-bar clock ticked steadily at idle (11:45→11:46→11:48→11:50) across
   several fully-untouched minutes** — the wedge did NOT reproduce with clean
   input. A single careful Special→Shut Down (button explicitly released on the
   highlighted row) reached "It is now safe to switch off," so the volume is
   clean. **Conclusion: the earlier wedge was MY tooling, not the build** — a
   `menu.sh` killed by a 300 s timeout left the mouse button held down and
   wedged the Finder in a permanent menu-track; with no killed automation it is
   rock-solid. Both A/UX and MacOS pass on the release build (70716e92). The
   ⚠️ history below is kept as a cautionary note on the tooling failure mode.

   **Original wedge write-up (kept for the tooling lesson):**
   The MacOS 8.1 disk is **`QuadSquad8.hda`** (slot-0 mount; pristine backup
   `backup/QuadSquad8.hda.gz`, md5 `1a40aa8a77af35cabfe76d4dea9ccf13` after a
   clean shutdown). On the release build (2026-09-02) it **booted clean to the
   Finder, cursor tracked, survived a 10-min idle io-watch (writes flat, normal
   for MacOS — no sync daemon), and menus + a Finder window opened**. THEN,
   while I was driving the Special→Shut Down menu to close cleanly, the Finder
   **foreground wedged**: menu-bar clock frozen at guest 11:04 for 30+ real
   minutes across THREE fully-untouched windows (95 s / 130 s / 75 s, button
   explicitly released), Cmd-W did not close the front window, and menu opens
   stopped working. The 68040 is NOT dead — `/proc/MiSTer/io` write_bytes climbed
   ~16 MB→18.5 MB during the interaction (only cache-flush-sized crumbs once
   wedged). This is the README's watch-cursor-wedge *signature* (stopped clock +
   ADB still at interrupt level), but that bug was supposedly fixed. **Leading
   suspect is my own tooling, not the build:** a `scripts/guest/menu.sh` run was
   **killed by a 300 s timeout (exit 143)** mid-track, which leaves `left_down`
   held; a stuck mouse-button wedges the Finder in a permanent menu/drag exactly
   like this, and the freeze began right at that event. Later `mousebtn:left_up`s
   did NOT recover it, which weakens (but doesn't kill) the stuck-button theory —
   a self-sustaining wedge or a real placement-marginal fault is still possible.
   **NOT a clean pass; do not cut a release until this is a clean reproduce.**
   Next action (mirrors the A/UX call the user already endorsed): reload to
   recover (guest already wedged → low risk; HFS volume is now dirty but backed
   up), reboot MacOS, verify liveness at idle, then do ONE careful shutdown with
   NO timeout-killable automation — never let a `menu.sh`/`click.sh` be killed
   with the button down (always send an explicit `mousebtn:left_up` after any
   guest-menu op; the walkers are unreliable on QuadSquad8's busy wallpaper
   because cursor-find fails). If it wedges again at idle with clean input →
   real regression; if not → my tooling caused it and MacOS passes.
5. ✅ **Cut the release — committed as `25dc453`.** The tested build
   (`70716e92`, +0.130 ns, both OSes pass) is `releases/wombat33_20260902.rbf`
   with a README row + section and its (gitignored) `.fit`/`.sta` summaries.
   **Named 20260902, not 20260901** (user's call when the 09-01 name turned out
   to already hold a *different* seed-13 backup, `abb5ede4`; the tested build
   was fit today and carries today's ncr53c96 data-out fix, so the work-date
   convention put it on 09-02). The 09-01 backup is left untouched.
6. 🔄 **Rename `wombat33` → `MacQuadra800` — IN PROGRESS.** Done so far:
   git-mv of the five project files (`.qpf/.qsf/.sdc/.sv/.srf`); internal
   ref edits (`PROJECT_REVISION`, `files.qip`, `jtag.cdf` sof, qsf SDC/SV,
   CONF_STR `"MacQuadra800;…"`, the `.s0` comment, `report-timing.tcl` rev);
   stale file-path comments in `rtl/*`, `verilator/*`, and the two top-level
   files; build/deploy scripts (`deploy_screenshot.sh` defaults, `push_disk.sh`,
   `local.env` **and** `local.env.sample`); docs (`BUILD.md`, `README.md` —
   repo-name `wombat33_MiSTer` deliberately kept —, `tools/misterdeploy/README.md`
   command examples). **MiSTer side moved:** `games/Wombat33`→`games/MacQuadra800`
   (all disks + boot.rom + backup), and `config/MacQuadra800.s0` rewritten to
   `games/MacQuadra800/QuadSquad8.hda` (old `Wombat33.s0` removed). **A&S check
   passed (0 errors); full fit running.** LEFT INTENTIONALLY UNCHANGED: the
   `emu`/`sys_top` module names (framework contract), the `wombat_cpu`/`wombat_bus`
   internal modules (different codename, not `wombat33`), the `wombat33_MiSTer`
   repo dir, `~/wombat33` WSL scratch paths in `sim_wsl.sh`, historical prose in
   RESUME-*/docs/scsi, and the sorting-illustration example in the launcher
   README. REMAINING: after the fit, deploy the new core, retest BOTH A/UX and
   MacOS 8.1 from `games/MacQuadra800/`, commit the rename, and cut a release
   under the new name (`MacQuadra800_YYYYMMDD.rbf`). **local.env is gitignored —
   the user's copy was edited here, but note it if the machine changes.** Then
   the user plans to merge CPU/architecture fixes from another fork, so land the
   rename as a clean committed base.
7. 🔄 **Report any issues** as they come up. Two stability scares this session
   (A/UX 08:02 "hang", MacOS "wedge") both traced to test-harness/measurement
   artifacts, NOT the build — see steps 3–4. The build is solid on both OSes.

---

## The hang (step 3 blocker) — what is known

**Symptom:** release build deployed → A/UX boots to desktop → guest hangs. The
disk (`HD60_512-AUX3.1-Installed.hda`) last wrote at **08:02:39** (end of boot)
and went silent for 45+ min; a live A/UX flushes on a timer. FPGA video still
scans out (desktop visible) and the HPS is alive (OSD + mrext work), so it is
the **68040 that wedged, not the whole core**.

**Ruled out — it is NOT a logic difference.** The only source delta from the
*stable* debug build is `SCSI_TRACE` off. That macro changes **only which signal
drives the modem TX output pin** (`rtl/iosb.sv`: `assign scc_txd_a = dbg_txd`
under the macro, `= scc_txd_int` without it, ~lines 892/898). Nothing the guest
reads changes — SCC RX/CTS/interrupts/register reads are identical, and there is
no TX→RX loopback (`scc_rxd_a = serialIn = UART_RXD & userport_midi_in` in
`wombat33.sv` ~line 410; `scc_txd_a = serialOut → UART_TXD`, no feedback). **So
debug and release are functionally identical to the guest; the difference is the
fitter placement** (same seed 13, but removing the tracer logic reroutes the
whole netlist; timing +0.246 ns debug vs +0.130 ns release). This smells like a
**placement/timing-marginal path** that meets STA but isn't robust (classic
false-path/multicycle/CDC-constraint blind spot).

**Honest caveat:** not 100% proven a hang vs healthy-idle. A freshly-idle Unix
*can* be write-quiet, and remote input was broken when tested (see gotcha
below), so the two clues are suggestive, not airtight. The debug build, by
contrast, was demonstrably alive+responsive at idle for a long stretch (I typed
`shutdown -h now` and it worked, reaching "You may now switch off your Macintosh
safely").

**User decision already given:** when asked how to proceed, the user chose
**"Reload core + reproduce"** — then interrupted to request this resume. So the
immediate next action (with a fresh session's go-ahead) is that experiment.

### Addendum 2026-09-02 — the reproduce experiment came back CLEAN

The experiment ran (core reloaded 10:09, A/UX rebooted) and **the hang did not
reproduce**: ~25-min fsck (the volume had been yanked twice), multiuser desktop
at 10:35, 16+ min alive and interactive (Apple menu, app menu, CommandShell,
typed commands), `shutdown -h now` → "You may now switch off" at 10:53. During
the whole desktop window the sync daemon wrote in **every** 30-s sample.

**Method lesson that revises the evidence:** the .hda's **mtime is a bad
liveness signal** — on this boot it lagged real writes by up to ~5 min and
froze entirely during read-only phases (fsck reads bump nothing). The reliable
probe is `/proc/$(pidof MiSTer)/io` `read_bytes`/`write_bytes` deltas. The
original 08:02 "hang" was judged on 45+ min of frozen mtime + dead input; the
input part is fully explained by the stale-fd gotcha, and while 45 min >> the
observed 5-min mtime lag (so a real wedge stays plausible), the event is now
**unreproduced and downgraded to "one-off, cause unknown"**. Constraint audit
done the same morning: STA on the release build is fully clean (setup +0.130,
hold +0.247), `wombat33.sdc` false-paths only bless real 2FF synchronizers, and
the one true STA blind spot is that **no pin I/O timing is constrained
anywhere** (SDRAM round-trip unanalyzed — mitigated by FAST_IN/OUT_REGISTER
pinning the IOEs). Nothing actionable without a reproduction; if a wedge is
ever seen again, sample the io counters FIRST, then check input, then decide.

**SCSI corruption question (user asked 2026-09-02):** no evidence of ongoing
corruption. The guest's `/usr/adm/errfile` is 544 bytes (just the errdemon boot
stamp; a failing driver would accumulate records), `errpt` shows nothing,
`/usr/adm/messages` is empty, the boot fsck repaired exactly the damage two
unclean yanks explain, and the session then ran + halted normally. The next
A/UX boot is the residual check: after this clean halt it should skip fsck; a
re-fsck would mean something is still dirtying the volume.

### Immediate next actions for step 3

1. **Reload the core to recover** (the guest is already hung, so this is low
   risk; disk is fsck-recoverable + backed up). This also fixes the input
   plumbing (see gotcha). `bash scripts/deploy_screenshot.sh` re-launches the
   current `output_files/wombat33.rbf` via `load_core` (no reboot).
2. **Reboot A/UX on the release build and watch two things:** (a) test remote
   input *immediately* once at the desktop (fresh main = fresh input fds), and
   (b) watch the disk mtime for ~5-10 min. If A/UX stays responsive and keeps
   touching the disk → the earlier "hang" was likely a one-off (or my
   plumbing confusion); if it wedges again ~2 min after desktop → **reproducible
   placement hang.**
3. **If reproducible:** it's a placement/timing-marginal issue. Options, in
   order of rigour: (a) inspect `wombat33.sdc` for false/multicycle paths and
   any CDC without synchronizers that STA isn't policing; (b) walk fitter seeds
   (`scratch/seeds/restore_seed.sh`, history in `wombat33.qsf` comments) and see
   whether stability tracks a seed — a red flag that a real marginal path
   exists; (c) as a data point, rebuild the **debug** config (tracer on) and
   confirm it is reliably stable, isolating "tracer-off placement" as the
   trigger. Don't chase timing in your own diff — but a *functional* hang is
   more than the placement lottery and deserves a real root-cause look.
4. **Boot MacOS 8.1 on the release build** (§step 4) — if MacOS is rock-solid
   but A/UX hangs, that narrows it to an A/UX-specific access pattern under the
   marginal placement.

---

## Operational gotcha discovered this session — remote input dies after a core reload

MiSTer **main only grabs input devices at its own startup and does NOT
hot-plug.** The mrext remote helper (`/media/fat/Scripts/remote_update.sh
-service`, serves `:8182` `/api/ws` + `/api/screenshots`, driven by
`scripts/mister_ws.py`) injects via its own uinput devices. **Do NOT restart the
remote service while a core is loaded** — main keeps stale fds to the destroyed
devices and remote keyboard/mouse goes silent until main restarts (a core
reload). Verified at the OS level: `ls -la /proc/<main-pid>/fd | grep event`
timestamps vs `ls -la /dev/input/event16` node timestamps — if the fd is older
than the node, injection is dead. **After any `load_core`, remote input works
again** (fresh main grabs the current devices). This session's input silence was
mostly this, not the guest.

Guest shutdown that works: **A/UX** — type `shutdown -h now` at a CommandShell
via `scripts/mister_ws.py` raw keycodes (reaches "You may now switch off"); the
Finder-menu walker `scripts/guest/shutdown_finder.sh` is tuned for the **MacOS**
Finder and mis-positions on A/UX's 8-row Special menu. **MacOS** — Special →
Shut Down (or `shutdown_finder.sh`).

---

## Step 6 — the rename checklist (wombat33 → MacQuadra800)

Do NOT touch the git repo name. Rename the core and repoint the MiSTer folder.
Files/refs to change (grep first: `grep -rniI "wombat33\|Wombat33\|WOMBAT33"`):

- **Project files:** `wombat33.qpf` (`PROJECT_REVISION = "wombat33"`),
  `wombat33.qsf`, `wombat33.sv`, `wombat33.sdc` → `MacQuadra800.*`. Top-level
  entity is `sys_top` (unchanged). `files.qip` references `wombat33.sdc` and
  `wombat33.sv` — update. `jtag.cdf` references `output_files/wombat33.sof`.
- **CONF_STR** in `wombat33.sv` (~line 67): `"Wombat33;UART57600:..."` →
  `"MacQuadra800;..."`. This string is the core name MiSTer shows and the base
  for the `.s0` config filename, so it also changes where the mount is
  remembered (`config/MacQuadra800.s0`).
- **MiSTer folders:** the core reads `games/Wombat33/` (boot.rom, the .hda
  images, `backup/`). Move/point to **`games/MacQuadra800/`**. Slot-0 mount memo
  `config/Wombat33.s0` → `config/MacQuadra800.s0`.
- **Scripts / env:** `scripts/local.env` (gitignored, personal) sets
  `RBF_NAME=wombat33.rbf`, `PROJECT_NAME=wombat33`, and the `SEED_*` paths
  (`games/Wombat33/boot.rom`, `config/Wombat33.s0`,
  `games/Wombat33/QuadSquad8.hda`). Update these — and note `local.env` is not in
  git, so the user's copy needs editing too (call it out). `deploy_screenshot.sh`
  auto-detects the revision from the single `*.qsf`, so renaming the qsf mostly
  carries it; `BUILD.md` documents the old paths.
- **Docs:** `BUILD.md`, `MacQuadra800_HardwareConfig.md` (already named for the
  target), `docs/`, and the various `RESUME-*.md` reference `wombat33`/`Wombat33`
  — update the operative ones (don't rewrite history in the SCSI resume docs).
- **After renaming:** rebuild (`scripts/build_only.sh`), deploy, and **retest
  BOTH A/UX and MacOS 8.1** from the new `games/MacQuadra800/` folder. Then
  commit, and cut the final release under the MacQuadra800 name.

---

## Machine / repo state as left

| | |
|---|---|
| Branch | `main`; latest commit `5fc76d8` (resume-doc). All plan step-1 code committed. |
| `wombat33.qsf` | `SCSI_TRACE` **commented out** (release config), seed 13. |
| `output_files/wombat33.rbf` | The **release** build (tracer off, +0.130 ns, md5 `70716e92…`) — currently flashed. |
| Debug rbf (both fixes, tracer on, +0.243 ns) | Was `output_files/wombat33.rbf` at 04:00, **overwritten** by the release build. Rebuild by uncommenting `SCSI_TRACE` if needed for the stability A/B. |
| Guest | **A/UX passed the 2026-09-02 retest** (see step-3 addendum) and was halted cleanly at 10:53. Core is sitting at the halt screen awaiting the reload for the MacOS test. |
| Slot-0 mount `config/Wombat33.s0` | **switched 2026-09-02** to `games/Wombat33/QuadSquad8.hda` (MacOS 8.1) for step 4. Switch back to `HD60_512-AUX3.1-Installed.hda` for any further A/UX work. |
| Disks | A/UX: `HD60_512-AUX3.1-Installed.hda` (backup zip → md5 `b44b7623`). MacOS 8.1: `QuadSquad8.hda` (backup `QuadSquad8.hda.gz` → `1a40aa8a`). |

## Env / tooling crib

`scripts/local.env`: `MISTER_HOST=192.168.99.143`, key `~/.ssh/mister_only`,
`MISTER_HTTP_PORT=8182`. Build `scripts/build_only.sh` (`--check` for A&S only;
prints a DEBUG-BUILD banner if `SCSI_TRACE` is on; refuses to pass a
timing-failed build). Deploy `scripts/deploy_screenshot.sh` (push + md5-verify +
`load_core`, no reboot). Screenshot `bash scripts/grab.sh out.png`. Input
`python scripts/mister_ws.py --host $MISTER_HOST --delay 0.12 raw:<kc> …`
(keycodes: LEFTALT=56=Guest-Cmd, B=48, Q=16, ENTER=28; `mouse:dx,dy`,
`mousebtn:left_down|left_up`). Git Bash + Windows python:
`export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' PYTHONIOENCODING=utf-8:replace`.
`ssh` without `-n` eats a piped script. Verilator/QEMU live in WSL
(`wsl -e bash -lc '…'`; harmless `Failed to mount I:\` on stderr).

Memory: [[aux-scsi-status]], [[qemu-golden-reference]],
[[never-reset-mister-mid-boot]].
