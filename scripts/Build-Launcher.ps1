[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$SourcePath = Join-Path $ProjectRoot "src\LocalGalaxyLauncher\Program.cs"

if (-not $OutputPath) {
    $OutputPath = Join-Path $ProjectRoot "Start-Galaxy.exe"
}

$compilerCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $compilerCandidates) {
    throw "Could not find the .NET Framework C# compiler."
}

$compiler = $compilerCandidates | Select-Object -First 1
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)

& $compiler `
    /nologo `
    /target:winexe `
    /platform:anycpu `
    /optimize+ `
    /reference:System.Windows.Forms.dll `
    /out:$outputFullPath `
    $SourcePath

if ($LASTEXITCODE -ne 0) {
    throw "Launcher compilation failed."
}

Write-Host "Built $outputFullPath"
