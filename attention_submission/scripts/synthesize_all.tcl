# 在同一器件与约束下综合四个版本，报告仅代表综合后模块内部时序。
set submission_root [file normalize [file join [file dirname [info script]] ..]]
# 避免本机工具子进程在中文工作目录下出现异常，建议使用英文提交目录。
set saved_working_directory [pwd]
cd $submission_root
set target_part xc7z010iclg225-1L
set period 10.0
if {[llength $argv] > 0} {set target_part [lindex $argv 0]}
if {[llength $argv] > 1} {set period [lindex $argv 1]}
if {![string is double -strict $period] || $period <= 0} {error "Invalid clock period"}
set code [catch {
    foreach {label top} {base attention_ip mask attention_ip_causal_mask ab attention_ip_parallel dot attention_ip_parallel_dot} {
        create_project -in_memory -part $target_part
        set folder [file join $submission_root evidence synthesis $label]
        file mkdir $folder
        read_verilog [list [file join $submission_root demo rtl exp_lut.v] [file join $submission_root demo rtl round_div_signed.v] [file join $submission_root demo rtl ${top}.v]]
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
        close $fh
        if {[llength $latches] != 0} {error "Unexpected latches in $label"}
        close_project
        puts "SUBMISSION_SYNTHESIS_COMPLETED: $label"
    }
} message]
cd $saved_working_directory
if {$code != 0} {error $message}
puts "SUBMISSION_ALL_SYNTHESIS_COMPLETED"
exit
