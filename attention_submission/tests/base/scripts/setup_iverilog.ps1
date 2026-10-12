param(
    [string]$ToolsRoot = (Join-Path $env:LOCALAPPDATA 'attention-tools\iverilog-13.0')
)
$ErrorActionPreference = 'Stop'
# 便携目录只用于本项目，不修改注册表、系统环境或既有仿真器安装。
if ($ToolsRoot -match '[^\x00-\x7F]') { throw 'Use an ASCII ToolsRoot for the simulator.' }
$archiveRoot = Join-Path $ToolsRoot 'packages'
New-Item -ItemType Directory -Force -Path $ToolsRoot,$archiveRoot | Out-Null
$packages = Get-Content (Join-Path $PSScriptRoot 'iverilog_packages.json') -Raw | ConvertFrom-Json
foreach ($package in $packages) {
    $archive = Join-Path $archiveRoot ($package.name + '.tar.zst')
    if (!(Test-Path $archive)) { Invoke-WebRequest -Uri $package.url -OutFile $archive }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLower() -ne $package.sha256) {
        throw "Package hash mismatch: $($package.name)"
    }
    # 只解压软件目录，保留其中的许可证文件，不执行包管理器钩子。
    & tar -xf $archive -C $ToolsRoot ucrt64
    if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $($package.name)" }
    Write-Host "Verified and extracted $($package.name)"
}
$bin = Join-Path $ToolsRoot 'ucrt64\bin'
$compilerRoot = Join-Path $ToolsRoot 'ucrt64\lib\ivl'
# 子编译器从自身目录也可找到依赖，避免依赖调用方的环境配置。
Get-ChildItem -LiteralPath $bin -Filter '*.dll' | Copy-Item -Destination $compilerRoot -Force
$savedPath = $env:PATH
try {
    $env:PATH = "$bin;$savedPath"
    & (Join-Path $bin 'iverilog.exe') -V
    if ($LASTEXITCODE -ne 0) { throw 'Icarus compiler startup failed' }
    & (Join-Path $bin 'vvp.exe') -V
    if ($LASTEXITCODE -ne 0) { throw 'Icarus simulator startup failed' }
} finally { $env:PATH = $savedPath }
Write-Host "Portable Icarus ready: $bin"
