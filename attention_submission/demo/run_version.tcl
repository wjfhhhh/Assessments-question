# 四个仿真集共用一个工程，每次只运行所选版本。
source -encoding utf-8 [file join [file dirname [info script]] tool_environment.tcl]
proc run_demo_version {version} {
    global four_demo_root
    set root $four_demo_root
    if {$version ni {base mask ab dot}} {error "Unknown version: $version"}
    set tops [dict create base attention_ip mask attention_ip_causal_mask ab attention_ip_parallel dot attention_ip_parallel_dot]
    # 先检查所选输入，格式有误时不启动仿真。
    set counts {q 4 k 32 v 32}
    if {$version ne "base"} {lappend counts control 2}
    foreach {name count} $counts {
        set fh [open [file join $root input ${version}_${name}.hex] r]
        set tokens [regexp -all -inline {\S+} [read $fh]]
        close $fh
        if {[llength $tokens] != $count} {error "$version/$name requires $count bytes"}
        foreach token $tokens {
            if {![regexp {^[0-9a-fA-F]{2}$} $token]} {error "Invalid byte: $token"}
        }
        if {$name eq "control"} {
            scan [lindex $tokens 0] %x enabled
            scan [lindex $tokens 1] %x position
            if {$enabled>1 || $position>7} {error "Control requires 00/01 and 00..07"}
        }
    }
    if {[llength [get_projects -quiet]] > 0} {
        catch {close_sim}
        # 重新打开工程以清除仿真工具缓存的上一仿真集编译列表。
        close_project
    }
    if {[llength [get_projects -quiet]] == 0} {
        set xpr [file join $root project attention_four_versions.xpr]
        if {[file exists $xpr]} {
            open_project $xpr
        } else {
            create_project attention_four_versions [file join $root project] -part xc7z010iclg225-1L
            set_property source_mgmt_mode None [current_project]
            add_files -norecurse [glob [file join $root rtl *.v]]
            foreach label {base mask ab dot} {
                set fs sim_$label
                create_fileset -simset $fs
                add_files -fileset $fs -norecurse [file join $root tb tb_demo_${label}.sv]
                add_files -fileset $fs -norecurse [glob [file join $root input ${label}_*.hex]]
                set_property top tb_demo_$label [get_filesets $fs]
                set_property xsim.simulate.runtime 0ns [get_filesets $fs]
            }
            set_property file_type {Memory Initialization Files} [get_files *.hex]
        }
    }
    set fs sim_$version
    set top tb_demo_$version
    # 显式编译四个独立测试平台，展开时仅运行选中的顶层。
    # 避免本机自动层次分析失效以及仿真集切换时沿用不完整的编译列表。
    set_property source_mgmt_mode None [current_project]
    foreach label {base mask ab dot} {
        set simset [get_filesets sim_$label]
        foreach tb_file [glob [file join $root tb *.sv]] {
            if {[llength [get_files -quiet -of_objects $simset $tb_file]] == 0} {
                add_files -fileset sim_$label -norecurse $tb_file
            }
        }
    }
    set_property top [dict get $tops $version] [get_filesets sources_1]
    current_fileset -simset [get_filesets $fs]
    set_property top $top [get_filesets $fs]
    set_property xsim.simulate.runtime 0ns [get_filesets $fs]
    # 本机运行库异常时复用已经准备好的隔离副本，仅影响本次工具调用。
    set runtime [file normalize [file join $::env(LOCALAPPDATA) attention-tools vivado-runtime-2022.2-dot]]
    set use_runtime [file exists [file join $runtime bin unwrapped win64.o xelab.exe]]
    set saved_environment [demo_push_tool_environment $runtime]
    set code [catch {
        # 分步执行流程会复用模拟器缓存；切换后清除失效工程对象和源码列表。
        if {[llength [info commands ::tclapp::xilinx::xsim::usf_init_vars]]} {
            ::tclapp::xilinx::xsim::usf_init_vars
        }
        launch_simulation -simset $fs -step compile
        launch_simulation -simset $fs -step elaborate
        if {$use_runtime} {
            set kernel [file join $root project attention_four_versions.sim $fs behav xsim xsim.dir ${top}_behav]
            foreach dll [glob [file join $runtime bin unwrapped win64.o *.dll]] {
                file copy -force $dll $kernel
            }
        }
        launch_simulation -simset $fs -step simulate
        log_wave -r /$top/*
        create_wave_config ${version}_wave
        foreach name {clk rst_n start data_ready q_valid kv_valid score_valid weight_valid out_valid done} {
            add_wave /$top/$name
        }
        if {$version ne "base"} {
            foreach name {mask_enable mask_enable_latched weight_masked} {add_wave /$top/$name}
        }
        set item [add_wave /$top/state_name]
        set_property radix ascii $item
        foreach name {state token_index elem_index score_index weight_index weight_raw l_raw} {
            set item [add_wave /$top/$name]
            set_property radix unsigned $item
        }
        foreach name {q_in k_in v_in score_data x_max delta_data acc0_raw acc1_raw acc2_raw acc3_raw out_data result0 result1 result2 result3} {
            set item [add_wave /$top/$name]
            set_property radix dec $item
        }
        run all
        catch {wave zoom full}
        save_wave_config [file join $root waves ${version}.wcfg]
        puts "FOUR_DEMO_COMPLETED: $version"
    } message]
    demo_pop_tool_environment $saved_environment
    if {$code != 0} {error $message}
}
