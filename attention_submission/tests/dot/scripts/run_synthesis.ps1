param(
    [string]$VivadoBin = 'D:\Xilinx_Vitis_2022\Vivado\2022.2\bin',
    [string]$RuntimeRoot = '',
    [string]$Part = 'xc7z010iclg225-1L'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$runRoot = Join-Path $env:TEMP ('attention_parallel_dot_synth_' + [guid]::NewGuid().ToString('N'))
# 使用纯英文临时目录，避免部分工具子进程误解中文路径。
foreach ($name in @('rtl','reference_rtl','scripts','evidence')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $runRoot $name) | Out-Null
}
Copy-Item (Join-Path $root 'rtl\*.v') (Join-Path $runRoot 'rtl')
Copy-Item (Join-Path $root 'reference_rtl\*.v') (Join-Path $runRoot 'reference_rtl')
Copy-Item (Join-Path $PSScriptRoot 'compare_synthesis.tcl') (Join-Path $runRoot 'scripts')
$savedRuntime = $env:XILINX_PATH
try {
    # 可选隔离运行库只对当前进程有效，不修改安装目录或系统环境。
    if ($RuntimeRoot) { $env:XILINX_PATH = $RuntimeRoot }
    Push-Location (Join-Path $runRoot 'evidence')
    try {
        & (Join-Path $VivadoBin 'vivado.bat') -mode batch -notrace -source (Join-Path $runRoot 'scripts\compare_synthesis.tcl') -log synthesis.log -journal synthesis.jou -tclargs $Part 10.0 2>&1 | Tee-Object synthesis_console.log
        $exitCode = $LASTEXITCODE
        $log = Get-Content synthesis_console.log -Raw
        $completed = $log.Contains('SYNTHESIS_COMPLETED_OLD') -and $log.Contains('SYNTHESIS_COMPLETED_DOT')
        [ordered]@{ reports_completed=$completed; vivado_exit_code=$exitCode; runtime_override=([bool]$RuntimeRoot); part=$Part; period_ns=10; scope='post_synthesis_internal_paths_only' } | ConvertTo-Json | Set-Content synthesis_status.json -Encoding utf8
        if (!$completed -or $exitCode -ne 0) { throw 'Inspect reports and synthesis_status.json; Vivado did not complete cleanly.' }
    } finally {
        Pop-Location
        Copy-Item (Join-Path $runRoot 'evidence\*') (Join-Path $root 'evidence') -Recurse -Force
        Write-Host "Synthesis run: $runRoot"
    }
} finally { $env:XILINX_PATH = $savedRuntime }
