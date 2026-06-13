[CmdletBinding()]
param(
    [switch]$RefreshTools,
    [switch]$NoAutoClose
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$EnvFile = Join-Path $ProjectRoot ".env"
$ExampleEnvFile = Join-Path $ProjectRoot ".env.example"
$ToolListFile = Join-Path $ProjectRoot "tool_list.yml"
$RemovedToolsFile = Join-Path $ProjectRoot "tools.removed.json"
$LogFile = Join-Path $ProjectRoot "launcher.log"
$LauncherWindowTitle = "Local Galaxy Launcher"

function Get-SingleInstanceName {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant())
        $hash = [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace("-", "").Substring(0, 16)
        return "Local\LocalGalaxyLauncher-$hash"
    } finally {
        $sha256.Dispose()
    }
}

function Show-ExistingLauncherWindow {
    param([string]$Title)

    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class LocalGalaxyLauncherWindowApi
{
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const UInt32 SWP_NOSIZE = 0x0001;
    public const UInt32 SWP_NOMOVE = 0x0002;
    public const UInt32 SWP_SHOWWINDOW = 0x0040;

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, UInt32 uFlags);
}
"@ -ErrorAction SilentlyContinue

        $handle = [IntPtr]::Zero
        for ($i = 0; $i -lt 50; $i++) {
            $handle = [LocalGalaxyLauncherWindowApi]::FindWindow($null, $Title)
            if ($handle -ne [IntPtr]::Zero) {
                break
            }
            Start-Sleep -Milliseconds 100
        }

        if ($handle -eq [IntPtr]::Zero) {
            return
        }

        [void][LocalGalaxyLauncherWindowApi]::ShowWindowAsync($handle, 9)
        [void][LocalGalaxyLauncherWindowApi]::SetForegroundWindow($handle)
        [void][LocalGalaxyLauncherWindowApi]::SetWindowPos(
            $handle,
            [LocalGalaxyLauncherWindowApi]::HWND_TOPMOST,
            0,
            0,
            0,
            0,
            [LocalGalaxyLauncherWindowApi]::SWP_NOMOVE -bor [LocalGalaxyLauncherWindowApi]::SWP_NOSIZE -bor [LocalGalaxyLauncherWindowApi]::SWP_SHOWWINDOW
        )
        [void][LocalGalaxyLauncherWindowApi]::SetWindowPos(
            $handle,
            [LocalGalaxyLauncherWindowApi]::HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            [LocalGalaxyLauncherWindowApi]::SWP_NOMOVE -bor [LocalGalaxyLauncherWindowApi]::SWP_NOSIZE -bor [LocalGalaxyLauncherWindowApi]::SWP_SHOWWINDOW
        )
    } catch {
    }
}

$createdLauncherInstance = $false
$script:SingleInstanceMutex = [System.Threading.Mutex]::new($true, (Get-SingleInstanceName), [ref]$createdLauncherInstance)
if (-not $createdLauncherInstance) {
    Show-ExistingLauncherWindow -Title $LauncherWindowTitle
    return
}

function Initialize-EnvFile {
    if (-not (Test-Path $EnvFile) -and (Test-Path $ExampleEnvFile)) {
        Copy-Item -Path $ExampleEnvFile -Destination $EnvFile
    }
}

function Read-DotEnv {
    Initialize-EnvFile
    $values = @{}
    if (Test-Path $EnvFile) {
        Get-Content $EnvFile | ForEach-Object {
            $line = $_.Trim()
            if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) {
                return
            }
            $parts = $line.Split("=", 2)
            $values[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
        }
    }
    return $values
}

$Config = Read-DotEnv
$GalaxyPort = if ($Config.GALAXY_PORT) { $Config.GALAXY_PORT } else { "8080" }
$GalaxyUrl = "http://localhost:$GalaxyPort"
$GalaxyLoginUrl = "$GalaxyUrl/login/start?redirect=%2F"
$AdminEmail = if ($Config.GALAXY_ADMIN_EMAIL) { $Config.GALAXY_ADMIN_EMAIL } else { "admin@example.org" }
$AdminPassword = if ($Config.GALAXY_ADMIN_PASSWORD) { $Config.GALAXY_ADMIN_PASSWORD } else { "password" }
$AdminApiKey = if ($Config.GALAXY_ADMIN_API_KEY) { $Config.GALAXY_ADMIN_API_KEY } else { "local-usegalaxy-admin-key" }
$GalaxyImage = if ($Config.GALAXY_IMAGE) { $Config.GALAXY_IMAGE } else { "local-usegalaxy:latest" }
$GalaxyContainerName = if ($Config.GALAXY_CONTAINER_NAME) { $Config.GALAXY_CONTAINER_NAME } else { "local-usegalaxy" }
$DockerInstallUrl = "https://www.docker.com/get-started/"

$script:LogBox = $null
$script:StatusLabel = $null
$script:ContainerStatusLabel = $null
$script:ProgressBar = $null
$script:Form = $null
$script:ToolManagerProcess = $null

function Add-Log {
    param([string]$Message)
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        Write-Host $line
    }
}

function Set-Status {
    param([string]$Message)
    Add-Log $Message
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Message
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function ConvertTo-ProcessArgument {
    param([string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '\s|"') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append([string]::new([char]92, ($backslashes * 2 + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([string]::new([char]92, $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([string]::new([char]92, ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-LoggedCommand {
    param(
        [string]$File,
        [string[]]$Arguments
    )

    Add-Log ("> {0} {1}" -f $File, ($Arguments -join " "))

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $File
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join " ")
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["BUILDKIT_PROGRESS"] = "plain"
    $startInfo.EnvironmentVariables["NO_COLOR"] = "1"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start command: $File"
        }

        $outputDone = $false
        $errorDone = $false
        $startedAt = Get-Date
        $lastOutputAt = $startedAt
        $lastHeartbeatAt = $startedAt
        $outputTask = $process.StandardOutput.ReadLineAsync()
        $errorTask = $process.StandardError.ReadLineAsync()
        while (-not ($process.HasExited -and $outputDone -and $errorDone)) {
            if (-not $outputDone -and $outputTask.IsCompleted) {
                $line = $outputTask.Result
                if ($null -eq $line) {
                    $outputDone = $true
                } else {
                    Add-Log $line
                    $lastOutputAt = Get-Date
                    $outputTask = $process.StandardOutput.ReadLineAsync()
                }
            }
            if (-not $errorDone -and $errorTask.IsCompleted) {
                $line = $errorTask.Result
                if ($null -eq $line) {
                    $errorDone = $true
                } else {
                    Add-Log $line
                    $lastOutputAt = Get-Date
                    $errorTask = $process.StandardError.ReadLineAsync()
                }
            }
            $now = Get-Date
            if (($now - $lastOutputAt).TotalSeconds -ge 30 -and ($now - $lastHeartbeatAt).TotalSeconds -ge 30) {
                $elapsedMinutes = [math]::Round(($now - $startedAt).TotalMinutes, 1)
                $heartbeat = "Command is still running... elapsed $elapsedMinutes min."
                Add-Log $heartbeat
                if ($script:StatusLabel) {
                    $script:StatusLabel.Text = $heartbeat
                }
                $lastHeartbeatAt = $now
            }
            if ($script:Form) {
                [System.Windows.Forms.Application]::DoEvents()
            }
            Start-Sleep -Milliseconds 50
        }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $File $($Arguments -join ' ')"
    }
    Update-ContainerStatus
}

function Test-Executable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-NativeCommand {
    param(
        [string]$File,
        [string[]]$Arguments = @()
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $File @Arguments *> $null
        $exitCode = $LASTEXITCODE
    } catch {
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return ($exitCode -eq 0)
}

function Test-DockerComposePlugin {
    if (-not (Test-Executable "docker")) {
        return $false
    }
    return Test-NativeCommand -File "docker" -Arguments @("compose", "version")
}

function Test-DockerDaemon {
    if (-not (Test-Executable "docker")) {
        return $false
    }
    return Test-NativeCommand -File "docker" -Arguments @("info")
}

function Get-GalaxyContainerStatus {
    if (-not (Test-Executable "docker")) {
        return "Container: Docker not installed"
    }
    if (-not (Test-DockerDaemon)) {
        return "Container: Docker not running"
    }

    $json = & docker inspect $GalaxyContainerName 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        return "Container: not created"
    }

    try {
        $container = ($json | ConvertFrom-Json | Select-Object -First 1)
        if (-not $container) {
            return "Container: unknown"
        }

        $state = if ($container.State.Status) { [string]$container.State.Status } else { "unknown" }
        $health = ""
        if ($container.State.Health -and $container.State.Health.Status) {
            $health = " / health: $($container.State.Health.Status)"
        }
        return "Container: $state$health"
    } catch {
        return "Container: unknown"
    }
}

function Update-ContainerStatus {
    if (-not $script:ContainerStatusLabel) {
        return
    }
    try {
        $script:ContainerStatusLabel.Text = Get-GalaxyContainerStatus
    } catch {
        $script:ContainerStatusLabel.Text = "Container: unknown"
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-Compose {
    param([string[]]$Arguments)

    Push-Location $ProjectRoot
    try {
        if (Test-DockerComposePlugin) {
            $composeArguments = @("compose")
            if ($Arguments.Count -gt 0 -and $Arguments[0] -eq "build") {
                $composeArguments += @("--progress", "plain")
            }
            Invoke-LoggedCommand -File "docker" -Arguments ($composeArguments + $Arguments)
        } elseif (Test-Executable "docker-compose") {
            Invoke-LoggedCommand -File "docker-compose" -Arguments $Arguments
        } else {
            throw "Docker Compose is not available. Install the Docker Compose plugin."
        }
    } finally {
        Pop-Location
    }
}

function Test-DockerImage {
    param([string]$ImageName)

    return Test-NativeCommand -File "docker" -Arguments @("image", "inspect", $ImageName)
}

function Ensure-GalaxyImage {
    Ensure-DockerReady
    if (Test-DockerImage -ImageName $GalaxyImage) {
        Set-Status "Galaxy image exists. Skipping Docker rebuild."
        return
    }

    Set-Status "Galaxy image is missing. First build is running; live progress appears below..."
    Invoke-Compose @("build", "galaxy")
    if (-not (Test-DockerImage -ImageName $GalaxyImage)) {
        throw "Docker build completed, but the expected Galaxy image '$GalaxyImage' was not created. Check launcher.log for the build output."
    }
    Set-Status "Galaxy image build complete."
}

function Start-DockerDesktopIfAvailable {
    $paths = @()
    foreach ($basePath in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, ${env:LOCALAPPDATA})) {
        if (-not $basePath) {
            continue
        }
        $candidatePaths = @(
            (Join-Path $basePath "Docker\Docker\Docker Desktop.exe"),
            (Join-Path $basePath "Docker\Docker Desktop.exe")
        )
        foreach ($candidatePath in $candidatePaths) {
            if (Test-Path $candidatePath) {
                $paths += $candidatePath
            }
        }
    }

    if ($paths) {
        Set-Status "Docker daemon is not running. Starting Docker Desktop..."
        Start-Process -FilePath ($paths | Select-Object -First 1) -WindowStyle Hidden
    }
}

function Prompt-DockerInstall {
    $message = "Docker was not found on this computer. Open $DockerInstallUrl now?"
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $result = [System.Windows.Forms.MessageBox]::Show(
            $message,
            "Docker not found",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process $DockerInstallUrl
            Add-Log "Opened Docker download page: $DockerInstallUrl"
        }
    } catch {
        Add-Log "Docker is not installed. Download page: $DockerInstallUrl"
    }
}

function Ensure-DockerReady {
    if (-not (Test-Executable "docker")) {
        Prompt-DockerInstall
        throw "Docker CLI was not found. Install Docker Desktop or Docker Engine, then reopen this launcher."
    }

    if (Test-DockerDaemon) {
        Set-Status "Docker is ready."
        return
    }

    Start-DockerDesktopIfAvailable
    for ($i = 1; $i -le 120; $i++) {
        if (Test-DockerDaemon) {
            Set-Status "Docker is ready."
            return
        }
        if (($i % 6) -eq 0) {
            Set-Status "Waiting for Docker daemon... ($([int]($i / 2))s)"
        }
        Start-Sleep -Milliseconds 500
        if ($script:Form) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    throw "Docker is installed, but the Docker daemon did not start in time."
}

function Update-ToolListIfNeeded {
    if ($RefreshTools -or -not (Test-Path $ToolListFile)) {
        Set-Status "Refreshing Tool Shed tool list..."
        $scriptPath = Join-Path $PSScriptRoot "Update-ToolList.ps1"
        Invoke-LoggedCommand -File "powershell" -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath)
    }
}

function Wait-GalaxyReady {
    Set-Status "Waiting for Galaxy to become ready..."
    for ($i = 1; $i -le 180; $i++) {
        Update-ContainerStatus
        try {
            $response = Invoke-WebRequest -Uri "$GalaxyUrl/api/version" -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                Set-Status "Galaxy is ready."
                Update-ContainerStatus
                return
            }
        } catch {
            if (($i % 6) -eq 0) {
                Set-Status "Galaxy is starting... ($([int]($i * 5 / 60)) min)"
            }
        }
        Start-Sleep -Seconds 5
        if ($script:Form) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    Add-Log "Galaxy did not become ready in time. Recent logs follow."
    try {
        Invoke-Compose @("logs", "--tail", "80", "galaxy")
    } catch {
        Add-Log $_.Exception.Message
    }
    throw "Galaxy did not become ready in time."
}

function Open-Galaxy {
    Update-ContainerStatus
    Set-Status "Opening Galaxy login page..."
    try {
        if ($script:Form) {
            [System.Windows.Forms.Clipboard]::SetText("Galaxy login`r`nEmail: $AdminEmail`r`nPassword: $AdminPassword")
        }
    } catch {
        Add-Log "Could not copy credentials to the clipboard: $($_.Exception.Message)"
    }
    Start-Process $GalaxyLoginUrl
}

function Sync-RemovedToolsIfNeeded {
    if (-not (Test-Path $RemovedToolsFile)) {
        return
    }

    Set-Status "Removing unchecked tools from running Galaxy..."
    $scriptPath = Join-Path $PSScriptRoot "Sync-GalaxyTools.ps1"
    try {
        Invoke-LoggedCommand -File "powershell" -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $scriptPath,
            "-GalaxyUrl",
            $GalaxyUrl,
            "-ApiKey",
            $AdminApiKey,
            "-RemovedPath",
            $RemovedToolsFile
        )
    } catch {
        Add-Log "Tool removal sync failed and will be retried later: $($_.Exception.Message)"
    }
}

function Sync-SelectedToolsIfNeeded {
    Set-Status "Synchronizing selected Galaxy tools..."
    $scriptPath = Join-Path $PSScriptRoot "Sync-GalaxyTools.ps1"
    try {
        Invoke-LoggedCommand -File "powershell" -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $scriptPath,
            "-GalaxyUrl",
            $GalaxyUrl,
            "-ApiKey",
            $AdminApiKey,
            "-SelectionPath",
            (Join-Path $ProjectRoot "tools.selected.json"),
            "-MetadataPath",
            (Join-Path $ProjectRoot "tool_list.metadata.json"),
            "-RemovedPath",
            $RemovedToolsFile,
            "-ReconcileInstalledWithSelection"
        )
    } catch {
        Add-Log "Tool sync failed and can be retried from Tools: $($_.Exception.Message)"
    }
}

function Start-Galaxy {
    if ($script:ProgressBar) {
        $script:ProgressBar.Style = "Marquee"
    }
    try {
        Ensure-DockerReady
        Update-ToolListIfNeeded
        Ensure-GalaxyImage
        Set-Status "Starting Galaxy without rebuilding the image..."
        Invoke-Compose @("up", "-d", "--no-build")
        Update-ContainerStatus
        Wait-GalaxyReady
        Sync-SelectedToolsIfNeeded
        Open-Galaxy
        Set-Status "Galaxy opened. Launcher will remain open."
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Local Galaxy Launcher", "OK", "Error") | Out-Null
    } finally {
        if ($script:ProgressBar) {
            $script:ProgressBar.Style = "Blocks"
        }
    }
}

function Stop-Galaxy {
    if ($script:ProgressBar) {
        $script:ProgressBar.Style = "Marquee"
    }
    try {
        Ensure-DockerReady
        Set-Status "Stopping Galaxy container. The persistent volume is kept."
        Invoke-Compose @("stop")
        Update-ContainerStatus
        Set-Status "Galaxy container stopped."
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Local Galaxy Launcher", "OK", "Error") | Out-Null
    } finally {
        if ($script:ProgressBar) {
            $script:ProgressBar.Style = "Blocks"
        }
    }
}

function Clear-GalaxyData {
    $message = "This will delete and purge Galaxy histories, datasets, outputs, active jobs, and generated files in the Docker volume. Installed tools will be kept. Continue?"
    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        "Clear Galaxy Data",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
        Set-Status "Galaxy data cleanup cancelled."
        return
    }

    if ($script:ProgressBar) {
        $script:ProgressBar.Style = "Marquee"
    }
    try {
        Ensure-DockerReady
        if (-not (Test-DockerImage -ImageName $GalaxyImage)) {
            throw "Galaxy image was not found. Start Galaxy once before clearing data."
        }

        Set-Status "Starting Galaxy for data cleanup..."
        Invoke-Compose @("up", "-d", "--no-build")
        Update-ContainerStatus
        Wait-GalaxyReady

        Set-Status "Clearing Galaxy histories, jobs, and files..."
        $scriptPath = Join-Path $PSScriptRoot "Clear-GalaxyData.ps1"
        Invoke-LoggedCommand -File "powershell" -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $scriptPath,
            "-GalaxyUrl",
            $GalaxyUrl,
            "-ApiKey",
            $AdminApiKey,
            "-ContainerName",
            $GalaxyContainerName
        )

        Set-Status "Galaxy data cleanup complete. Installed tools were kept."
        [System.Windows.Forms.MessageBox]::Show(
            "Galaxy histories, job outputs, generated files, and temporary files were cleaned. Installed tools were kept.",
            "Local Galaxy Launcher",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Local Galaxy Launcher", "OK", "Error") | Out-Null
    } finally {
        if ($script:ProgressBar) {
            $script:ProgressBar.Style = "Blocks"
        }
    }
}

function Compact-DockerDisk {
    $message = @"
This will stop the Galaxy container, close Docker Desktop/WSL, and compact Docker Desktop virtual disk files.

It will not delete Docker images, containers, volumes, Galaxy data, or installed tools. Docker will be stopped after compaction; use Start and open login when you want to run Galaxy again.

Continue?
"@
    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        "Compact Docker Disk",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
        Set-Status "Docker disk compaction cancelled."
        return
    }

    if ($script:ProgressBar) {
        $script:ProgressBar.Style = "Marquee"
    }
    try {
        $scriptPath = Join-Path $PSScriptRoot "Compact-DockerDisk.ps1"
        Set-Status "Compacting Docker Desktop virtual disk. Administrator permission may be requested..."
        Invoke-LoggedCommand -File "powershell" -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $scriptPath,
            "-ProjectRoot",
            $ProjectRoot,
            "-HelperImage",
            $GalaxyImage
        )

        Update-ContainerStatus
        Set-Status "Docker disk compaction complete. Start Galaxy again when needed."
        [System.Windows.Forms.MessageBox]::Show(
            "Docker Desktop virtual disk compaction is complete. Docker is stopped; start Galaxy again when you want to use the container.",
            "Local Galaxy Launcher",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Local Galaxy Launcher", "OK", "Error") | Out-Null
    } finally {
        if ($script:ProgressBar) {
            $script:ProgressBar.Style = "Blocks"
        }
    }
}

function Start-HiddenPowerShellScript {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $powerShellPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $powerShellPath)) {
        $powerShellPath = "powershell.exe"
    }

    $argumentList = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-STA",
        "-WindowStyle",
        "Hidden",
        "-File",
        $ScriptPath
    ) + $Arguments

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = ($argumentList | ForEach-Object {
        $value = [string]$_
        if ($value -match '\s|["]') {
            '"' + ($value -replace '"', '\"') + '"'
        } else {
            $value
        }
    }) -join " "
    $startInfo.WorkingDirectory = $ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($startInfo)
}

function Get-LocalLogPaths {
    return @(
        $LogFile,
        (Join-Path $ProjectRoot "tool-manager.log"),
        (Join-Path $ProjectRoot "compact-docker-disk.log")
    )
}

function Get-CombinedLogText {
    $builder = [System.Text.StringBuilder]::new()
    foreach ($path in (Get-LocalLogPaths)) {
        [void]$builder.AppendLine("==== $([System.IO.Path]::GetFileName($path)) ====")
        if (Test-Path $path) {
            [void]$builder.AppendLine((Get-Content -Raw -Encoding UTF8 $path))
        } else {
            [void]$builder.AppendLine("Log file does not exist yet.")
        }
        [void]$builder.AppendLine()
    }
    return $builder.ToString()
}

function Clear-LocalLogFiles {
    $cleared = 0
    $errors = @()
    foreach ($path in (Get-LocalLogPaths)) {
        try {
            if (Test-Path $path) {
                [System.IO.File]::WriteAllText($path, "", [System.Text.UTF8Encoding]::new($false))
                $cleared++
            }
        } catch {
            $errors += [pscustomobject]@{
                Path = $path
                Message = $_.Exception.Message
            }
        }
    }

    return [pscustomobject]@{
        Cleared = $cleared
        Errors = $errors
    }
}

function Clear-LocalLogs {
    $message = "This will clear local launcher logs in the project folder. Galaxy data, installed tools, Docker images, containers, and volumes will not be changed. Continue?"
    $result = [System.Windows.Forms.MessageBox]::Show(
        $message,
        "Clear Local Logs",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
        if ($script:StatusLabel) {
            $script:StatusLabel.Text = "Log cleanup cancelled."
        }
        return
    }

    $result = Clear-LocalLogFiles
    foreach ($errorItem in @($result.Errors)) {
        if ($errorItem.Path) {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not clear $([System.IO.Path]::GetFileName([string]$errorItem.Path)): $($errorItem.Message)",
                "Clear Local Logs",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }

    if ($script:LogBox) {
        $script:LogBox.Clear()
    }
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = "Cleared $($result.Cleared) local log file(s)."
    }
}

function Open-LogsWindow {
    $viewer = [System.Windows.Forms.Form]::new()
    $viewer.Text = "Local Galaxy Logs"
    $viewer.StartPosition = "CenterParent"
    $viewer.ClientSize = [System.Drawing.Size]::new(760, 460)
    $viewer.FormBorderStyle = "FixedSingle"
    $viewer.MaximizeBox = $false

    $logViewerBox = [System.Windows.Forms.TextBox]::new()
    $logViewerBox.Location = [System.Drawing.Point]::new(16, 16)
    $logViewerBox.Size = [System.Drawing.Size]::new(728, 380)
    $logViewerBox.Multiline = $true
    $logViewerBox.ScrollBars = "Both"
    $logViewerBox.ReadOnly = $true
    $logViewerBox.WordWrap = $false
    $logViewerBox.Font = [System.Drawing.Font]::new("Consolas", 9)
    $viewer.Controls.Add($logViewerBox)

    $refreshLogButton = [System.Windows.Forms.Button]::new()
    $refreshLogButton.Text = "Refresh"
    $refreshLogButton.Location = [System.Drawing.Point]::new(554, 410)
    $refreshLogButton.Size = [System.Drawing.Size]::new(90, 30)
    $refreshLogButton.Add_Click({
        $logViewerBox.Text = Get-CombinedLogText
        $logViewerBox.SelectionStart = $logViewerBox.TextLength
        $logViewerBox.ScrollToCaret()
    })
    $viewer.Controls.Add($refreshLogButton)

    $clearLogButton = [System.Windows.Forms.Button]::new()
    $clearLogButton.Text = "Clear logs"
    $clearLogButton.Location = [System.Drawing.Point]::new(424, 410)
    $clearLogButton.Size = [System.Drawing.Size]::new(120, 30)
    $clearLogButton.Add_Click({
        Clear-LocalLogs
        $logViewerBox.Text = Get-CombinedLogText
        $logViewerBox.SelectionStart = $logViewerBox.TextLength
        $logViewerBox.ScrollToCaret()
    })
    $viewer.Controls.Add($clearLogButton)

    $closeLogButton = [System.Windows.Forms.Button]::new()
    $closeLogButton.Text = "Close"
    $closeLogButton.Location = [System.Drawing.Point]::new(654, 410)
    $closeLogButton.Size = [System.Drawing.Size]::new(90, 30)
    $closeLogButton.Add_Click({ $viewer.Close() })
    $viewer.Controls.Add($closeLogButton)

    $logViewerBox.Text = Get-CombinedLogText
    $logViewerBox.SelectionStart = $logViewerBox.TextLength
    $logViewerBox.ScrollToCaret()
    [void]$viewer.ShowDialog($script:Form)
}

function Open-ToolManager {
    $scriptPath = Join-Path $PSScriptRoot "Manage-Tools.ps1"
    if ($script:ToolManagerProcess -and -not $script:ToolManagerProcess.HasExited) {
        Set-Status "Tool manager is already open."
        return
    }

    $script:ToolManagerProcess = Start-HiddenPowerShellScript -ScriptPath $scriptPath -Arguments @("-ParentProcessId", [string]$PID)
    Set-Status "Tool manager opened."
}

function Close-ToolManagerProcess {
    if (-not $script:ToolManagerProcess -or $script:ToolManagerProcess.HasExited) {
        return
    }

    try {
        [void]$script:ToolManagerProcess.CloseMainWindow()
        if (-not $script:ToolManagerProcess.WaitForExit(2500)) {
            $script:ToolManagerProcess.Kill()
        }
    } catch {
        try {
            $script:ToolManagerProcess.Kill()
        } catch {
        }
    }
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Host "Windows Forms is not available. Starting Galaxy from the console."
    Start-Galaxy
    return
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = [System.Windows.Forms.Form]::new()
$script:Form = $form
$form.Text = $LauncherWindowTitle
$form.StartPosition = "CenterScreen"
$form.ClientSize = [System.Drawing.Size]::new(760, 520)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$title = [System.Windows.Forms.Label]::new()
$title.Text = "Local Galaxy Bioinformatics"
$title.Font = [System.Drawing.Font]::new("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = [System.Drawing.Point]::new(20, 18)
$form.Controls.Add($title)

$details = [System.Windows.Forms.Label]::new()
$details.Text = "URL: $GalaxyUrl    Login: $AdminEmail / $AdminPassword"
$details.Font = [System.Drawing.Font]::new("Segoe UI", 9)
$details.AutoSize = $false
$details.Location = [System.Drawing.Point]::new(22, 54)
$details.Size = [System.Drawing.Size]::new(700, 22)
$form.Controls.Add($details)

$status = [System.Windows.Forms.Label]::new()
$script:StatusLabel = $status
$status.Text = "Ready."
$status.Font = [System.Drawing.Font]::new("Segoe UI", 10)
$status.AutoSize = $false
$status.Location = [System.Drawing.Point]::new(22, 84)
$status.Size = [System.Drawing.Size]::new(700, 24)
$form.Controls.Add($status)

$progress = [System.Windows.Forms.ProgressBar]::new()
$script:ProgressBar = $progress
$progress.Location = [System.Drawing.Point]::new(24, 114)
$progress.Size = [System.Drawing.Size]::new(700, 18)
$progress.Style = "Blocks"
$form.Controls.Add($progress)

$containerStatus = [System.Windows.Forms.Label]::new()
$script:ContainerStatusLabel = $containerStatus
$containerStatus.Text = "Container: checking..."
$containerStatus.Font = [System.Drawing.Font]::new("Segoe UI", 9)
$containerStatus.AutoSize = $false
$containerStatus.Location = [System.Drawing.Point]::new(24, 136)
$containerStatus.Size = [System.Drawing.Size]::new(700, 20)
$form.Controls.Add($containerStatus)

$startButton = [System.Windows.Forms.Button]::new()
$startButton.Text = "Start and open login"
$startButton.Location = [System.Drawing.Point]::new(24, 166)
$startButton.Size = [System.Drawing.Size]::new(160, 34)
$startButton.Add_Click({ Start-Galaxy })
$form.Controls.Add($startButton)

$openButton = [System.Windows.Forms.Button]::new()
$openButton.Text = "Open Galaxy"
$openButton.Location = [System.Drawing.Point]::new(196, 166)
$openButton.Size = [System.Drawing.Size]::new(120, 34)
$openButton.Add_Click({ Open-Galaxy })
$form.Controls.Add($openButton)

$stopButton = [System.Windows.Forms.Button]::new()
$stopButton.Text = "Stop"
$stopButton.Location = [System.Drawing.Point]::new(328, 166)
$stopButton.Size = [System.Drawing.Size]::new(80, 34)
$stopButton.Add_Click({ Stop-Galaxy })
$form.Controls.Add($stopButton)

$clearDataButton = [System.Windows.Forms.Button]::new()
$clearDataButton.Text = "Clear data"
$clearDataButton.Location = [System.Drawing.Point]::new(420, 166)
$clearDataButton.Size = [System.Drawing.Size]::new(130, 34)
$clearDataButton.Add_Click({ Clear-GalaxyData })
$form.Controls.Add($clearDataButton)

$compactDiskButton = [System.Windows.Forms.Button]::new()
$compactDiskButton.Text = "Compact disk"
$compactDiskButton.Location = [System.Drawing.Point]::new(562, 166)
$compactDiskButton.Size = [System.Drawing.Size]::new(160, 34)
$compactDiskButton.Add_Click({ Compact-DockerDisk })
$form.Controls.Add($compactDiskButton)

$toolsButton = [System.Windows.Forms.Button]::new()
$toolsButton.Text = "Tools"
$toolsButton.Location = [System.Drawing.Point]::new(24, 210)
$toolsButton.Size = [System.Drawing.Size]::new(90, 34)
$toolsButton.Add_Click({ Open-ToolManager })
$form.Controls.Add($toolsButton)

$logsButton = [System.Windows.Forms.Button]::new()
$logsButton.Text = "Logs"
$logsButton.Location = [System.Drawing.Point]::new(126, 210)
$logsButton.Size = [System.Drawing.Size]::new(90, 34)
$logsButton.Add_Click({ Open-LogsWindow })
$form.Controls.Add($logsButton)

$clearLogsButton = [System.Windows.Forms.Button]::new()
$clearLogsButton.Text = "Clear logs"
$clearLogsButton.Location = [System.Drawing.Point]::new(228, 210)
$clearLogsButton.Size = [System.Drawing.Size]::new(120, 34)
$clearLogsButton.Add_Click({ Clear-LocalLogs })
$form.Controls.Add($clearLogsButton)

$logBox = [System.Windows.Forms.TextBox]::new()
$script:LogBox = $logBox
$logBox.Location = [System.Drawing.Point]::new(24, 260)
$logBox.Size = [System.Drawing.Size]::new(700, 195)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = [System.Drawing.Font]::new("Consolas", 9)
$form.Controls.Add($logBox)

$footer = [System.Windows.Forms.Label]::new()
$footer.Text = "Persistent Docker volume: local-usegalaxy_galaxy-export. Do not remove it if you want to keep state."
$footer.Font = [System.Drawing.Font]::new("Segoe UI", 8)
$footer.AutoSize = $false
$footer.Location = [System.Drawing.Point]::new(24, 474)
$footer.Size = [System.Drawing.Size]::new(700, 20)
$form.Controls.Add($footer)

$containerTimer = [System.Windows.Forms.Timer]::new()
$containerTimer.Interval = 5000
$containerTimer.Add_Tick({ Update-ContainerStatus })
$containerTimer.Start()

$form.Add_FormClosing({
    Close-ToolManagerProcess
})

$form.Add_FormClosed({
    if ($script:SingleInstanceMutex) {
        try {
            $script:SingleInstanceMutex.ReleaseMutex()
        } catch {
        }
        $script:SingleInstanceMutex.Dispose()
        $script:SingleInstanceMutex = $null
    }
})

$form.Add_Shown({
    try {
        if (-not (Test-Executable "docker")) {
            Set-Status "Docker CLI was not found."
            Prompt-DockerInstall
        } elseif (Test-DockerDaemon) {
            Set-Status "Docker is ready."
        } else {
            Set-Status "Docker is installed. Click Start and open login to start Docker and Galaxy."
        }
        Update-ContainerStatus
    } catch {
        Add-Log "Docker startup check failed: $($_.Exception.Message)"
    }
})

Add-Log "Project root: $ProjectRoot"
Add-Log "Galaxy URL: $GalaxyUrl"
[void][System.Windows.Forms.Application]::Run($form)
