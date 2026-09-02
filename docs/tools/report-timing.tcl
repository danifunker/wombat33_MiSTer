# report-timing.tcl — dump the worst timing paths from an EXISTING compile.
#
# The default compile flow's MacQuadra800.sta.rpt carries only per-clock slack
# summaries; the "Timing Closure Recommendations" panel that would name the
# failing path is HTML-only and does not survive the plain-text export.  This
# re-runs the timing analyzer against the netlist already in db/ — no fit, no
# synthesis, ~1 minute — and writes the full node-by-node path detail.
#
# Usage (from the project root, with quartus_sta on PATH):
#   quartus_sta -t docs/tools/report-timing.tcl
#
# Writes output_files/timing_worst.rpt and echoes the same to the console.

set rev MacQuadra800
if {[llength $quartus(args)] > 0} { set rev [lindex $quartus(args) 0] }

project_open $rev -revision $rev
# No -post_fit: post-fit IS the default, and 17.0's parser mis-reads the flag
# as an operating-condition name ("did not match any valid operating
# conditions").  Plain create_timing_netlist gives the default worst-case slow
# corner, which is the one the compile's own slack numbers came from.
create_timing_netlist
read_sdc
update_timing_netlist

set out output_files/timing_worst.rpt
file delete -force $out

# Worst setup paths across every clock, with the full node-by-node path so the
# offending logic is identifiable by instance name.  This one matters; the
# extras below are wrapped so a version quirk in them cannot discard it.
report_timing -setup -npaths 20 -detail full_path -stdout -file $out

# Same again restricted to the core machine clock, in case a faster framework
# clock's paths crowd out the core's in the list above.
if {[catch {
    set core [get_clocks -nowarn {*emu|pll|pll_inst*divclk}]
    if {[get_collection_size $core] > 0} {
        report_timing -setup -npaths 10 -detail full_path -to_clock $core \
            -stdout -file $out -append
    }
} msg]} { post_message -type warning "core-clock report skipped: $msg" }

# Per-clock Fmax, for context alongside the paths.
if {[catch {
    report_clock_fmax_summary -stdout -file $out -append
} msg]} { post_message -type warning "fmax summary skipped: $msg" }

delete_timing_netlist
project_close
