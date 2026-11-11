# program.tcl - load a bitstream onto the board over USB-JTAG
#   vivado -mode batch -source synth/program.tcl -tclargs build/vivado/fpga_top.bit
set bit [expr {[llength $argv] > 0 ? [lindex $argv 0] : "build/vivado/fpga_top.bit"}]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
close_hw_manager
