# 逐个运行四个现场入口，每次只展开一个顶层，不包含预期答案。
set submission_root [file normalize [file join [file dirname [info script]] ..]]
foreach entry {01_base.tcl 02_mask.tcl 03_ab.tcl 04_dot.tcl} {
    source -encoding utf-8 [file join $submission_root demo $entry]
}
puts "SUBMISSION_ALL_DEMOS_COMPLETED"
exit
