# 对 A 与 B 使用同一器件、同一综合时钟约束，报告真实资源与寄存器内部路径。
set root [file normalize [file join [file dirname [info script]] ..]]
set target_part xc7z010iclg225-1L
set period 10.0
if {[llength $argv]>0} {set target_part [lindex $argv 0]}
if {[llength $argv]>1} {set period [lindex $argv 1]}
foreach {label top source} [list A attention_ip_causal_mask [file join $root reference_rtl attention_ip_causal_mask.v] B attention_ip_parallel [file join $root rtl attention_ip_parallel.v]] {
    create_project -in_memory -part $target_part
    set folder [file join $root evidence synthesis_$label]
    file mkdir $folder
    read_verilog [list [file join $root rtl exp_lut.v] [file join $root rtl round_div_signed.v] $source]
    set fh [open [file join $folder clock.xdc] w]
    puts $fh "create_clock -name clk -period $period \[get_ports clk\]"
    close $fh
    read_xdc [file join $folder clock.xdc]
    synth_design -top $top -part $target_part -mode out_of_context
    report_utilization -file [file join $folder utilization.rpt]
    report_timing_summary -file [file join $folder timing.rpt]
    report_timing -max_paths 3 -file [file join $folder critical_paths.rpt]
    set latches [get_cells -quiet -hierarchical -filter {REF_NAME =~ LD*}]
    set paths [get_timing_paths -max_paths 1]
    set fh [open [file join $folder summary.txt] w]
    puts $fh "part=$target_part"
    puts $fh "period_ns=$period"
    puts $fh "latches=[llength $latches]"
    puts $fh "worst_slack_ns=[get_property SLACK $paths]"
    puts $fh "source=$source"
    close $fh
    if {[llength $latches]!=0} {error "Unexpected latches in $label"}
    close_project
    puts "SYNTHESIS_COMPLETED_$label"
}
