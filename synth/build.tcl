# ============================================================================
# build.tcl - Vivado batch build of fpga_top for the Nexys A7-100T
# ============================================================================
#   vivado -mode batch -source synth/build.tcl -tclargs [image.line.hex] [clkout_div]
#   (or: make fpga PROG=hello CLKOUT_DIV=20)
# image.line.hex is the program preloaded into main memory (make sw builds
# build/sw/<prog>.line.hex); default build/sw/hello.line.hex.
# clkout_div sets the core clock to 1000 MHz / clkout_div (20 = 50 MHz,
# 25 = 40 MHz, 40 = 25 MHz); the UART baud divider follows it.
# Outputs in build/vivado/: fpga_top.bit, utilization*.rpt, timing.rpt
# ============================================================================
set root [file normalize [file join [file dirname [info script]] ..]]
set hex  [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : "$root/build/sw/hello.line.hex"}]
set div  [expr {[llength $argv] > 1 ? [lindex $argv 1] : 20}]
set part xc7a100tcsg324-1
set out  $root/build/vivado
file mkdir $out
if {![file exists $hex]} { error "program image $hex not found (run: make sw)" }

set srcs {}
foreach dir {core cache coherence memory io top} {
    foreach f [lsort [glob $root/rtl/$dir/*.v]] {
        if {![regexp {cache_controller\.v|mesi_protocol\.v} $f]} { lappend srcs $f }
    }
}
read_verilog $srcs
read_xdc $root/synth/constraints.xdc

synth_design -top fpga_top -part $part \
    -include_dirs [list $root/rtl/core $root/rtl/cache] \
    -verilog_define SYNTHESIS \
    -verilog_define "MEM_INIT_FILE=\"$hex\"" \
    -generic CLKOUT_DIV=$div
report_utilization -file $out/utilization_synth.rpt
opt_design
place_design
phys_opt_design
route_design
report_utilization                -file $out/utilization.rpt
report_utilization -hierarchical  -file $out/utilization_hier.rpt
report_timing_summary -max_paths 20 -file $out/timing.rpt
write_checkpoint -force $out/fpga_top_routed.dcp
write_bitstream  -force $out/fpga_top.bit

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "build.tcl: core clock [expr {1000.0 / $div}] MHz, worst setup slack $wns ns"
if {$wns < 0} { puts "build.tcl: TIMING NOT MET - try a slower clock, e.g. make fpga CLKOUT_DIV=25" }
