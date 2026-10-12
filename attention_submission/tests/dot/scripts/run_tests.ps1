param(
    [string]$Python = 'python',
    [string]$IcarusBin = (Join-Path $env:LOCALAPPDATA 'attention-tools\iverilog-13.0\ucrt64\bin')
)
$ErrorActionPreference = 'Stop'
$extensionRoot = Split-Path $PSScriptRoot -Parent
# 首次运行时创建结果目录。
New-Item -ItemType Directory -Force -Path (Join-Path $extensionRoot 'build') | Out-Null
# 基础对照源码随测试包附带，因此不依赖原仓库路径。
$runRoot = Join-Path $env:TEMP ('attention_parallel_dot_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
& $Python (Join-Path $extensionRoot 'model\generate_mask_vectors.py') $runRoot
if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
$caseCount = (Get-Content (Join-Path $runRoot 'coverage.json') -Raw | ConvertFrom-Json).cases
Copy-Item (Join-Path $extensionRoot 'rtl\*.v') -Destination $runRoot
Copy-Item (Join-Path $extensionRoot 'tb\tb_attention_parallel_dot.sv') -Destination $runRoot
# 既有九十三拍的 AB 版仅作对照，不修改其源文件。
Copy-Item (Join-Path $extensionRoot 'reference_rtl\attention_ip_parallel.v') -Destination $runRoot
Push-Location $runRoot
try {
    & (Join-Path $IcarusBin 'iverilog.exe') -g2012 -Wall -s tb_attention_parallel_dot -o mask.vvp exp_lut.v round_div_signed.v attention_ip_parallel.v attention_ip_parallel_dot.v tb_attention_parallel_dot.sv 2>&1 | Tee-Object compile.log
    if ($LASTEXITCODE -ne 0) { throw 'Mask compilation failed' }
    & (Join-Path $IcarusBin 'vvp.exe') -N mask.vvp 2>&1 | Tee-Object simulation.log
    $simExit = $LASTEXITCODE
    $passed = (Get-Content simulation.log -Raw).Contains("PASS: $caseCount cases,")
    # 第二遍不等待较慢的对照模块，检查优化版完成后的连续任务。
    & (Join-Path $IcarusBin 'vvp.exe') -N mask.vvp +FAST_RESTART 2>&1 | Tee-Object fast_restart.log
    $fastExit = $LASTEXITCODE
    $fastPassed = (Get-Content fast_restart.log -Raw).Contains("PASS: $caseCount cases,")
    $hashes = @{}
    foreach ($name in @('attention_ip_parallel.v','attention_ip_parallel_dot.v','exp_lut.v','round_div_signed.v','tb_attention_parallel_dot.sv')) {
        $hashes[$name] = (Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash
    }
    [ordered]@{cases=$caseCount; passed=$passed; simulator_exit_code=$simExit; fast_restart_passed=$fastPassed; fast_restart_exit_code=$fastExit; source_sha256=$hashes} |
        ConvertTo-Json -Depth 4 | Set-Content validation.json -Encoding utf8
    if (!$passed -or $simExit -ne 0 -or !$fastPassed -or $fastExit -ne 0) { throw 'Parallel tests failed' }
} finally {
    Pop-Location
    Get-ChildItem -LiteralPath $runRoot -File | Copy-Item -Destination (Join-Path $extensionRoot 'build') -Force
    Write-Host "Results: $extensionRoot\build"
}
