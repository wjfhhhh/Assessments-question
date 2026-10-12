param(
    [string]$Python = 'python',
    [string]$IcarusBin = (Join-Path $env:LOCALAPPDATA 'attention-tools\iverilog-13.0\ucrt64\bin'),
    [string]$InputJson = ''
)
$ErrorActionPreference = 'Stop'
$attentionRoot = Split-Path $PSScriptRoot -Parent
$buildName = if ($InputJson) { 'demo' } else { 'iverilog' }
$buildRoot = Join-Path $attentionRoot ('build\' + $buildName)
$runRoot = Join-Path $env:TEMP ('attention_icarus_' + [guid]::NewGuid().ToString('N'))
if ($runRoot -match '[^\x00-\x7F]') { throw 'Use an ASCII TEMP directory.' }
foreach ($tool in @('iverilog.exe','vvp.exe')) {
    if (!(Test-Path (Join-Path $IcarusBin $tool))) { throw 'Run attention/scripts/setup_iverilog.ps1 first, or pass -IcarusBin.' }
}
New-Item -ItemType Directory -Force -Path $runRoot,$buildRoot | Out-Null
$generatorArgs = @((Join-Path $attentionRoot 'model\generate_attention_vectors.py'), $runRoot)
if ($InputJson) { $generatorArgs += @('--input', (Resolve-Path -LiteralPath $InputJson).Path) }
& $Python @generatorArgs
if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
$caseCount = (Get-Content (Join-Path $runRoot 'vectors.json') -Raw | ConvertFrom-Json).inputs.Count
foreach ($name in @('attention_ip.v','exp_lut.v','round_div_signed.v')) {
    Copy-Item -LiteralPath (Join-Path $attentionRoot "rtl\$name") -Destination $runRoot
}
Copy-Item -LiteralPath (Join-Path $attentionRoot 'tb\tb_attention_ip.sv') -Destination $runRoot
Copy-Item -LiteralPath (Join-Path $attentionRoot 'tb\trace_capture.sv') -Destination $runRoot
$savedPath = $env:PATH
Push-Location $runRoot
try {
    $env:PATH = "$IcarusBin;$savedPath"
    $compileOutput = & (Join-Path $IcarusBin 'iverilog.exe') -g2012 -Wall -s tb_attention_ip -s trace_capture -o attention.vvp exp_lut.v round_div_signed.v attention_ip.v tb_attention_ip.sv trace_capture.sv 2>&1
    $compileExit = $LASTEXITCODE
    $compileOutput | Tee-Object -FilePath compile.log | Out-Host
    if ($compileExit -ne 0) { throw 'Icarus compilation failed' }
    $simOutput = & (Join-Path $IcarusBin 'vvp.exe') -N attention.vvp 2>&1
    $simExit = $LASTEXITCODE
    $simOutput | Tee-Object -FilePath simulation.log | Out-Host
    $simText = $simOutput -join "`n"
    $marker = "PASS: $caseCount cases, $($caseCount*8) scores, $($caseCount*8) weights, $($caseCount*4) outputs, 2074793 division inputs"
    $passed = $simText.Contains($marker) -and ($simText -notmatch 'FATAL:|ERROR:')
    $hashes = [ordered]@{}
    foreach ($name in @('attention_ip.v','exp_lut.v','round_div_signed.v','tb_attention_ip.sv','trace_capture.sv')) {
        $hashes[$name] = (Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash.ToLower()
    }
    [ordered]@{
        simulator = 'Icarus Verilog 13.0'
        functional_checks_passed = $passed
        compiler_exit_code = $compileExit
        simulator_exit_code = $simExit
        process_completed_cleanly = ($simExit -eq 0)
        cases = $caseCount
        outputs_checked = $caseCount*4
        division_inputs_checked = 2074793
        source_sha256 = $hashes
    } | ConvertTo-Json -Depth 4 | Set-Content validation.json -Encoding utf8
    if (!$passed -or $simExit -ne 0) { throw 'Icarus regression failed; inspect simulation.log and validation.json.' }
} finally {
    Pop-Location
    $env:PATH = $savedPath
    Get-ChildItem -LiteralPath $runRoot -File | Copy-Item -Destination $buildRoot -Force
    Write-Host "Run directory: $runRoot"
    Write-Host "Results: $buildRoot"
}
