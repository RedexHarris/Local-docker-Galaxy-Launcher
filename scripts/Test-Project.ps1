[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Assert-Path {
    param([string]$Path)
    $fullPath = Join-Path $ProjectRoot $Path
    if (-not (Test-Path $fullPath)) {
        throw "Missing required file: $Path"
    }
    Write-Host "OK  $Path"
}

function Test-PowerShellSyntax {
    param([string]$Path)
    $fullPath = Join-Path $ProjectRoot $Path
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $fullPath), [ref]$errors) | Out-Null
    if ($errors) {
        $errors | Format-List *
        throw "PowerShell syntax error: $Path"
    }
    Write-Host "OK  $Path syntax"
}

Assert-Path "Dockerfile"
Assert-Path "docker-compose.yml"
Assert-Path ".env.example"
Assert-Path "tool_list.yml"
Assert-Path "tools.selected.json"
Assert-Path "Start-Galaxy.exe"
Assert-Path "src\LocalGalaxyLauncher\Program.cs"
Assert-Path "scripts\Build-Launcher.ps1"
Assert-Path "scripts\Start-Galaxy.ps1"
Assert-Path "scripts\Update-ToolList.ps1"
Assert-Path "scripts\Manage-Tools.ps1"
Assert-Path "scripts\Sync-GalaxyTools.ps1"
Assert-Path "scripts\Clear-GalaxyData.ps1"

Test-PowerShellSyntax "scripts\Start-Galaxy.ps1"
Test-PowerShellSyntax "scripts\Build-Launcher.ps1"
Test-PowerShellSyntax "scripts\Update-ToolList.ps1"
Test-PowerShellSyntax "scripts\Manage-Tools.ps1"
Test-PowerShellSyntax "scripts\Sync-GalaxyTools.ps1"
Test-PowerShellSyntax "scripts\Clear-GalaxyData.ps1"

if (Get-Command docker -ErrorAction SilentlyContinue) {
    & docker --version
    if ($LASTEXITCODE -ne 0) {
        throw "docker --version failed."
    }

    Push-Location $ProjectRoot
    try {
        & docker compose version *> $null
        if ($LASTEXITCODE -eq 0) {
            & docker compose config *> $null
            if ($LASTEXITCODE -ne 0) {
                throw "docker compose config failed."
            }
            Write-Host "OK  docker compose config"
        } elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
            & docker-compose config *> $null
            if ($LASTEXITCODE -ne 0) {
                throw "docker-compose config failed."
            }
            Write-Host "OK  docker-compose config"
        } else {
            Write-Warning "Docker is installed, but Docker Compose was not found."
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Warning "Docker CLI is not installed on this machine; Docker build/start was not tested."
}

Write-Host "Project checks completed."
