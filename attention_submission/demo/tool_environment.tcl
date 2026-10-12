# 为本次仿真统一工具、编译器和运行库路径，完成后恢复原进程环境。
proc demo_push_tool_environment {runtime} {
    set candidates [list [file normalize [file join [file dirname [info nameofexecutable]] .. .. ..]]]
    if {[info exists ::env(XILINX_VIVADO)]} {lappend candidates $::env(XILINX_VIVADO)}
    if {[info exists ::env(RDI_DATADIR)]} {
        foreach directory [split $::env(RDI_DATADIR) {;}] {
            lappend candidates [file dirname $directory]
        }
    }
    set installation {}
    foreach candidate $candidates {
        if {[file exists [file join $candidate bin vivado.bat]] &&
            [file exists [file join $candidate tps mingw 6.2.0 win64.o nt bin gcc.exe]]} {
            set installation [file normalize $candidate]
            break
        }
    }
    if {$installation eq {}} {error "Cannot locate a complete Vivado 2022.2 installation and its GCC."}

    set use_runtime [file exists [file join $runtime bin unwrapped win64.o xelab.exe]]
    set roots [list $installation]
    if {$use_runtime} {set roots [linsert $roots 0 $runtime]}
    set libdirs {}
    foreach root $roots {lappend libdirs [file join $root lib win64.o]}
    foreach library {librdi_simulator_kernel.dll librdi_simbridge_kernel.dll} {
        set found 0
        foreach directory $libdirs {
            if {[file exists [file join $directory $library]]} {set found 1; break}
        }
        if {!$found} {error "Missing simulator runtime library: $library"}
    }

    set gcc [file join $installation tps mingw 6.2.0 win64.o nt bin]
    set paths [list [file join $installation bin] $gcc]
    if {$use_runtime} {set paths [linsert $paths 0 [file join $runtime bin unwrapped win64.o]]}
    lappend paths [file join $installation tps mingw 6.2.0 win64.o nt libexec gcc x86_64-w64-mingw32 6.2.0]
    foreach directory $libdirs {lappend paths $directory}

    set saved [dict create]
    foreach key {PATH LIBRARY_PATH XILINX_PATH XILINX_VIVADO RDI_APPROOT RDI_BINROOT RDI_LIBDIR RDI_DATADIR HDI_APPROOT} {
        if {![catch {set ::env($key)} value]} {
            dict set saved $key [list 1 $value]
        } else {
            dict set saved $key [list 0 {}]
        }
    }
    # 仅设置 XILINX_PATH 无法修复已启动 GUI 中缓存或继承的搜索路径。
    # 显式提供库搜索目录，避免链接器报找不到仿真内核。
    set ::env(PATH) "[join $paths {;}];$::env(PATH)"
    set ::env(LIBRARY_PATH) [join $libdirs {;}]
    set ::env(XILINX_VIVADO) $installation
    if {$use_runtime} {set ::env(XILINX_PATH) $runtime} else {unset -nocomplain ::env(XILINX_PATH)}
    set ::env(RDI_APPROOT) [join $roots {;}]
    set ::env(RDI_BINROOT) [file join $installation bin]
    set ::env(RDI_LIBDIR) [join $libdirs {;}]
    set ::env(RDI_DATADIR) [file join $installation data]
    set ::env(HDI_APPROOT) $installation
    puts "DEMO_TOOLCHAIN: $installation"
    puts "DEMO_GCC: $gcc"
    puts "DEMO_LIBRARY_PATH: $::env(LIBRARY_PATH)"
    return $saved
}

proc demo_pop_tool_environment {saved} {
    dict for {key entry} $saved {
        if {[lindex $entry 0]} {
            set ::env($key) [lindex $entry 1]
        } else {
            unset -nocomplain ::env($key)
        }
    }
}
