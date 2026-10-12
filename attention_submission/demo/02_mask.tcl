# 单独运行 mask 版本，无需修改仿真顶层。
set four_demo_root [file normalize [file dirname [info script]]]
source -encoding utf-8 [file join $four_demo_root run_version.tcl]
run_demo_version mask
