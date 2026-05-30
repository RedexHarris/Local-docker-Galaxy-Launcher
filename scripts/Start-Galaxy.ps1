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

$script:LogBox = $null
$script:StatusLabel = $null
$script:ProgressBar = $null
$script:Form = $null
$script:RegistryBox = $null
$script:RegistryUserBox = $null
$script:RegistryPasswordBox = $null

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

function Invoke-LoggedCommand {
    param(
        [string]$File,
        [string[]]$Arguments
    )

    Add-Log ("> {0} {1}" -f $File, ($Arguments -join " "))
    $output = & $File @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($item in $output) {
        Add-Log ($item.ToString())
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $File $($Arguments -join ' ')"
    }
}

function Test-Executable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-DockerComposePlugin {
    if (-not (Test-Executable "docker")) {
        return $false
    }
    & docker compose version *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-DockerDaemon {
    if (-not (Test-Executable "docker")) {
        return $false
    }
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Compose {
    param([string[]]$Arguments)

    Push-Location $ProjectRoot
    try {
        if (Test-DockerComposePlugin) {
            Invoke-LoggedCommand -File "docker" -Arguments (@("compose") + $Arguments)
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

    & docker image inspect $ImageName *> $null
    return ($LASTEXITCODE -eq 0)
}

function Ensure-GalaxyImage {
    Ensure-DockerReady
    if (Test-DockerImage -ImageName $GalaxyImage) {
        Set-Status "Galaxy image exists. Skipping Docker rebuild."
        return
    }

    Set-Status "Galaxy image is missing. Building it once..."
    Invoke-Compose @("build")
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

function Ensure-DockerReady {
    if (-not (Test-Executable "docker")) {
        throw "Docker CLI was not found. Install Docker Desktop or Docker Engine first."
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
        try {
            $response = Invoke-WebRequest -Uri "$GalaxyUrl/api/version" -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                Set-Status "Galaxy is ready."
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
            $RemovedToolsFile
        )
    } catch {
        Add-Log "Tool sync failed and can be retried from Tools: $($_.Exception.Message)"
    }
}

function Invoke-DockerRegistryLogin {
    if (-not $script:RegistryUserBox -or -not $script:RegistryPasswordBox) {
        throw "Docker login fields are not available."
    }

    $registry = if ($script:RegistryBox.Text.Trim()) { $script:RegistryBox.Text.Trim() } else { "docker.io" }
    $username = $script:RegistryUserBox.Text.Trim()
    $password = $script:RegistryPasswordBox.Text

    if (-not $username -or -not $password) {
        throw "Enter a Docker registry username and password or token."
    }

    Ensure-DockerReady
    Set-Status "Logging in to Docker registry..."

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "docker"
    $psi.Arguments = "login $registry --username $username --password-stdin"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.WriteLine($password)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($stdout) {
        $stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Add-Log $_ }
    }
    if ($stderr) {
        $stderr -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Add-Log $_ }
    }

    if ($process.ExitCode -ne 0) {
        throw "Docker login failed with exit code $($process.ExitCode)."
    }

    Set-Status "Docker login succeeded. Closing launcher."
    if ($script:Form) {
        Start-Sleep -Seconds 1
        $script:Form.Close()
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
        Wait-GalaxyReady
        Sync-SelectedToolsIfNeeded
        Open-Galaxy
        Set-Status "Galaxy opened. This launcher will close automatically."
        if (-not $NoAutoClose -and $script:Form) {
            Start-Sleep -Seconds 2
            $script:Form.Close()
        }
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
    [System.Diagnostics.Process]::Start($startInfo) | Out-Null
}

function Get-CombinedLogText {
    $builder = [System.Text.StringBuilder]::new()
    foreach ($path in @($LogFile, (Join-Path $ProjectRoot "tool-manager.log"))) {
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
    Start-HiddenPowerShellScript -ScriptPath $scriptPath
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
$form.Text = "Local Galaxy Launcher"
$form.StartPosition = "CenterScreen"
$form.ClientSize = [System.Drawing.Size]::new(760, 540)
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
$status.Size = [System.Drawing.Size]::new(660, 24)
$form.Controls.Add($status)

$progress = [System.Windows.Forms.ProgressBar]::new()
$script:ProgressBar = $progress
$progress.Location = [System.Drawing.Point]::new(24, 114)
$progress.Size = [System.Drawing.Size]::new(660, 18)
$progress.Style = "Blocks"
$form.Controls.Add($progress)

$registryLabel = [System.Windows.Forms.Label]::new()
$registryLabel.Text = "Optional Docker registry login: registry, username, password/token"
$registryLabel.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$registryLabel.AutoSize = $true
$registryLabel.Location = [System.Drawing.Point]::new(24, 148)
$form.Controls.Add($registryLabel)

$registryBox = [System.Windows.Forms.TextBox]::new()
$script:RegistryBox = $registryBox
$registryBox.Text = "docker.io"
$registryBox.Location = [System.Drawing.Point]::new(24, 174)
$registryBox.Size = [System.Drawing.Size]::new(150, 24)
$form.Controls.Add($registryBox)

$registryUserBox = [System.Windows.Forms.TextBox]::new()
$script:RegistryUserBox = $registryUserBox
$registryUserBox.Location = [System.Drawing.Point]::new(186, 174)
$registryUserBox.Size = [System.Drawing.Size]::new(160, 24)
$form.Controls.Add($registryUserBox)

$registryPasswordBox = [System.Windows.Forms.TextBox]::new()
$script:RegistryPasswordBox = $registryPasswordBox
$registryPasswordBox.Location = [System.Drawing.Point]::new(358, 174)
$registryPasswordBox.Size = [System.Drawing.Size]::new(160, 24)
$registryPasswordBox.UseSystemPasswordChar = $true
$form.Controls.Add($registryPasswordBox)

$dockerLoginButton = [System.Windows.Forms.Button]::new()
$dockerLoginButton.Text = "Docker login"
$dockerLoginButton.Location = [System.Drawing.Point]::new(530, 171)
$dockerLoginButton.Size = [System.Drawing.Size]::new(112, 30)
$dockerLoginButton.Add_Click({
    try {
        Invoke-DockerRegistryLogin
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Local Galaxy Launcher", "OK", "Error") | Out-Null
    }
})
$form.Controls.Add($dockerLoginButton)

$startButton = [System.Windows.Forms.Button]::new()
$startButton.Text = "Start and open login"
$startButton.Location = [System.Drawing.Point]::new(24, 218)
$startButton.Size = [System.Drawing.Size]::new(150, 34)
$startButton.Add_Click({ Start-Galaxy })
$form.Controls.Add($startButton)

$openButton = [System.Windows.Forms.Button]::new()
$openButton.Text = "Open Galaxy"
$openButton.Location = [System.Drawing.Point]::new(186, 218)
$openButton.Size = [System.Drawing.Size]::new(120, 34)
$openButton.Add_Click({ Open-Galaxy })
$form.Controls.Add($openButton)

$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Text = "Refresh tools"
$refreshButton.Location = [System.Drawing.Point]::new(318, 218)
$refreshButton.Size = [System.Drawing.Size]::new(120, 34)
$refreshButton.Add_Click({
    $script:RefreshTools = $true
    try {
        Update-ToolListIfNeeded
        Set-Status "Tool list refreshed. Use Tools to apply changes incrementally."
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Local Galaxy Launcher", "OK", "Error") | Out-Null
    } finally {
        $script:RefreshTools = $false
    }
})
$form.Controls.Add($refreshButton)

$stopButton = [System.Windows.Forms.Button]::new()
$stopButton.Text = "Stop"
$stopButton.Location = [System.Drawing.Point]::new(450, 218)
$stopButton.Size = [System.Drawing.Size]::new(90, 34)
$stopButton.Add_Click({ Stop-Galaxy })
$form.Controls.Add($stopButton)

$logsButton = [System.Windows.Forms.Button]::new()
$logsButton.Text = "Logs"
$logsButton.Location = [System.Drawing.Point]::new(552, 218)
$logsButton.Size = [System.Drawing.Size]::new(90, 34)
$logsButton.Add_Click({ Open-LogsWindow })
$form.Controls.Add($logsButton)

$toolsButton = [System.Windows.Forms.Button]::new()
$toolsButton.Text = "Tools"
$toolsButton.Location = [System.Drawing.Point]::new(648, 218)
$toolsButton.Size = [System.Drawing.Size]::new(70, 34)
$toolsButton.Add_Click({ Open-ToolManager })
$form.Controls.Add($toolsButton)

$logBox = [System.Windows.Forms.TextBox]::new()
$script:LogBox = $logBox
$logBox.Location = [System.Drawing.Point]::new(24, 268)
$logBox.Size = [System.Drawing.Size]::new(660, 220)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = [System.Drawing.Font]::new("Consolas", 9)
$form.Controls.Add($logBox)

$footer = [System.Windows.Forms.Label]::new()
$footer.Text = "Persistent Docker volume: local-usegalaxy_galaxy-export. Do not remove it if you want to keep state."
$footer.Font = [System.Drawing.Font]::new("Segoe UI", 8)
$footer.AutoSize = $false
$footer.Location = [System.Drawing.Point]::new(24, 500)
$footer.Size = [System.Drawing.Size]::new(660, 20)
$form.Controls.Add($footer)

Add-Log "Project root: $ProjectRoot"
Add-Log "Galaxy URL: $GalaxyUrl"
[void][System.Windows.Forms.Application]::Run($form)
