[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$VhdxPath,
    [string]$LogPath,
    [switch]$Elevated,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not $ProjectRoot) {
    $ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}
if (-not $LogPath) {
    $LogPath = Join-Path $ProjectRoot "compact-docker-disk.log"
}

if (-not $Elevated) {
    [System.IO.File]::WriteAllText($LogPath, "", [System.Text.UTF8Encoding]::new($false))
}

function Write-Step {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Format-Size {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return ("{0:N2} GB" -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ("{0:N2} MB" -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ("{0:N2} KB" -f ($Bytes / 1KB))
    }
    return "$Bytes B"
}

function Quote-Argument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
    $powerShellPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $powerShellPath)) {
        $powerShellPath = "powershell.exe"
    }

    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Quote-Argument $PSCommandPath),
        "-ProjectRoot",
        (Quote-Argument $ProjectRoot),
        "-LogPath",
        (Quote-Argument $LogPath),
        "-Elevated"
    )
    if ($VhdxPath) {
        $arguments += @("-VhdxPath", (Quote-Argument $VhdxPath))
    }
    if ($DryRun) {
        $arguments += "-DryRun"
    }

    Write-Step "Requesting administrator permission to compact the Docker Desktop virtual disk."
    $process = Start-Process -FilePath $powerShellPath -ArgumentList ($arguments -join " ") -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        if (Test-Path $LogPath) {
            Get-Content -Path $LogPath -Tail 80 | ForEach-Object { Write-Host $_ }
        }
        throw "Elevated disk compact process failed with exit code $($process.ExitCode)."
    }

    if (Test-Path $LogPath) {
        Get-Content -Path $LogPath -Tail 80 | ForEach-Object { Write-Host $_ }
    }
}

function Invoke-Native {
    param(
        [string]$File,
        [string[]]$Arguments = @()
    )

    Write-Step ("> {0} {1}" -f $File, ($Arguments -join " "))
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $File @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($item in ($output | Where-Object { $_ })) {
        Write-Step ($item.ToString())
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $File $($Arguments -join ' ')"
    }
}

function Test-DockerDaemon {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Stop-GalaxyContainerIfPossible {
    if (-not (Test-DockerDaemon)) {
        Write-Step "Docker daemon is not running; skipping docker compose stop."
        return
    }

    Push-Location $ProjectRoot
    try {
        & docker compose version *> $null
        if ($LASTEXITCODE -eq 0) {
            Invoke-Native -File "docker" -Arguments @("compose", "stop")
        } elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
            Invoke-Native -File "docker-compose" -Arguments @("stop")
        } else {
            Write-Step "Docker Compose is not available; skipping compose stop."
        }
    } finally {
        Pop-Location
    }
}

function Stop-DockerDesktopProcesses {
    $processNames = @(
        "Docker Desktop",
        "com.docker.backend",
        "com.docker.build",
        "com.docker.proxy",
        "com.docker.wsl-distro-proxy",
        "vpnkit",
        "vpnkit-bridge"
    )

    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $processNames -contains $_.ProcessName })
    if (-not $processes) {
        Write-Step "No Docker Desktop user processes were found."
        return
    }

    foreach ($process in $processes) {
        Write-Step "Stopping process $($process.ProcessName) (PID $($process.Id))."
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Get-DockerVhdxPaths {
    $paths = @()
    if ($VhdxPath) {
        $paths += $VhdxPath
    }

    $knownPaths = @(
        (Join-Path $env:LOCALAPPDATA "Docker\wsl\disk\docker_data.vhdx"),
        (Join-Path $env:LOCALAPPDATA "Docker\wsl\data\ext4.vhdx"),
        (Join-Path $env:LOCALAPPDATA "Docker\wsl\main\ext4.vhdx")
    )
    foreach ($path in $knownPaths) {
        if ($path -and (Test-Path $path)) {
            $paths += $path
        }
    }

    $dockerWslRoot = Join-Path $env:LOCALAPPDATA "Docker\wsl"
    if (Test-Path $dockerWslRoot) {
        $paths += Get-ChildItem -Path $dockerWslRoot -Recurse -Force -ErrorAction SilentlyContinue -Include "*.vhdx" |
            Select-Object -ExpandProperty FullName
    }

    return @($paths | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique)
}

function Invoke-DiskpartCompact {
    param([string]$Path)

    $diskpartScript = @"
select vdisk file="$Path"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@

    $tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "compact-docker-disk-$([guid]::NewGuid()).txt")
    [System.IO.File]::WriteAllText($tempFile, $diskpartScript, [System.Text.Encoding]::ASCII)
    try {
        Invoke-Native -File "diskpart.exe" -Arguments @("/s", $tempFile)
    } finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CompactVhdx {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path
    $before = $item.Length
    if ($DryRun) {
        Write-Step "Virtual disk: $Path"
    } else {
        Write-Step "Compacting $Path"
    }
    Write-Step "Size before: $(Format-Size $before)"

    if ($DryRun) {
        Write-Step "Dry run: would compact this virtual disk."
        return
    }

    if (Get-Command Optimize-VHD -ErrorAction SilentlyContinue) {
        Write-Step "Using Optimize-VHD."
        Optimize-VHD -Path $Path -Mode Full
    } else {
        Write-Step "Optimize-VHD is not available; using diskpart compact vdisk."
        Invoke-DiskpartCompact -Path $Path
    }

    $after = (Get-Item -LiteralPath $Path).Length
    Write-Step "Size after: $(Format-Size $after)"
    Write-Step "Reclaimed: $(Format-Size ($before - $after))"
}

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq "Core") {
    throw "Docker Desktop virtual disk compaction is only supported by this script on Windows."
}

if (-not $DryRun -and -not (Test-Administrator)) {
    if ($Elevated) {
        throw "Administrator permission is required to compact Docker Desktop VHDX files."
    }
    Invoke-ElevatedSelf
    return
}

Write-Step "Starting Docker Desktop virtual disk compaction."
Write-Step "Project root: $ProjectRoot"

if ($DryRun) {
    Write-Step "Dry run: would stop the Galaxy container, close Docker Desktop, and run wsl.exe --shutdown before compacting."
} else {
    Stop-GalaxyContainerIfPossible
    Stop-DockerDesktopProcesses

    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        Invoke-Native -File "wsl.exe" -Arguments @("--shutdown")
        Start-Sleep -Seconds 5
    } else {
        Write-Step "wsl.exe was not found. Docker Desktop VHDX may still be mounted."
    }
}

$vhdxPaths = @(Get-DockerVhdxPaths)
if (-not $vhdxPaths) {
    throw "No Docker Desktop VHDX file was found under $env:LOCALAPPDATA\Docker\wsl."
}

foreach ($path in $vhdxPaths) {
    Invoke-CompactVhdx -Path $path
}

if ($DryRun) {
    Write-Step "Dry run complete. No containers, Docker processes, WSL sessions, or VHDX files were changed."
} else {
    Write-Step "Docker Desktop virtual disk compaction complete. Docker is stopped; start Galaxy again when you want to use it."
}
