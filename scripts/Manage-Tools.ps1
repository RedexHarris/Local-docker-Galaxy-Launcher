[CmdletBinding()]
param(
    [string]$ToolShedUrl = "https://toolshed.g2.bx.psu.edu",
    [string]$SelectionPath,
    [string]$ProjectRoot,
    [int]$ParentProcessId = 0
)

$ErrorActionPreference = "Stop"

if (-not $ProjectRoot) {
    $ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
}
if (-not $SelectionPath) {
    $SelectionPath = Join-Path $ProjectRoot "tools.selected.json"
}

$ToolShedUrl = $ToolShedUrl.TrimEnd("/")
$SelectionPath = [System.IO.Path]::GetFullPath($SelectionPath)
$LogFile = Join-Path $ProjectRoot "tool-manager.log"
$RemovedPath = Join-Path $ProjectRoot "tools.removed.json"
$EnvFile = Join-Path $ProjectRoot ".env"

$script:SelectedGrid = $null
$script:SearchGrid = $null
$script:StatusLabel = $null
$script:SearchBox = $null
$script:SelectedRowKeys = @{}
$script:SearchRowKeys = @{}
$script:ApplyProgressBar = $null
$script:ApplyButton = $null
$script:SearchButton = $null
$script:CurrentCommandProcess = $null
$script:SuppressGridEvents = $false
$script:SearchPlaceholderActive = $false
$SearchPlaceholder = "Enter tool name to search"

function ConvertTo-Array {
    param([object]$Value)
    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return $Value
    }
    return @($Value)
}

function Set-ApplyProgress {
    param(
        [int]$Percent,
        [string]$Message,
        [switch]$Marquee
    )

    if ($script:ApplyProgressBar) {
        if ($Marquee) {
            $script:ApplyProgressBar.Style = "Marquee"
        } else {
            $script:ApplyProgressBar.Style = "Blocks"
            $script:ApplyProgressBar.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
        }
    }
    if ($script:StatusLabel -and $Message) {
        $script:StatusLabel.Text = $Message
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-Log {
    param([string]$Message)
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$stamp] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if ($Message -match '^Progress\s+(\d+)/(\d+):\s*(.*)$') {
        $current = [int]$Matches[1]
        $total = [int]$Matches[2]
        $progressMessage = $Matches[3]
        $percent = if ($total -gt 0) { [int][Math]::Round(($current / $total) * 100) } else { 100 }
        Set-ApplyProgress -Percent $percent -Message ("{0} ({1}/{2})" -f $progressMessage, $current, $total)
        return
    }
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Message
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Get-Owner {
    param([object]$Repository)
    if ($Repository.owner) {
        return [string]$Repository.owner
    }
    if ($Repository.repo_owner_username) {
        return [string]$Repository.repo_owner_username
    }
    return ""
}

function Get-Updated {
    param([object]$Repository)
    if ($Repository.update_time) {
        return [string]$Repository.update_time
    }
    if ($Repository.full_last_updated) {
        return [string]$Repository.full_last_updated
    }
    if ($Repository.last_update) {
        return [string]$Repository.last_update
    }
    return ""
}

function Get-Key {
    param(
        [string]$Owner,
        [string]$Name
    )
    return ("{0}/{1}" -f $Owner, $Name).ToLowerInvariant()
}

function Read-SelectedTools {
    if (-not (Test-Path $SelectionPath)) {
        return @()
    }
    return ConvertTo-Array ((Get-Content -Raw -Encoding UTF8 $SelectionPath) | ConvertFrom-Json)
}

function Read-PendingRemovedTools {
    if (-not (Test-Path $RemovedPath)) {
        return @()
    }
    return ConvertTo-Array ((Get-Content -Raw -Encoding UTF8 $RemovedPath) | ConvertFrom-Json)
}

function Read-DotEnv {
    $values = @{}
    if (-not (Test-Path $EnvFile)) {
        return $values
    }

    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) {
            return
        }
        $parts = $line.Split("=", 2)
        $values[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
    }
    return $values
}

function Write-PendingRemovedTools {
    param([object[]]$Tools)

    $deduped = @{}
    foreach ($tool in (ConvertTo-Array $Tools)) {
        if (-not $tool.name -or -not $tool.owner) {
            continue
        }
        $key = Get-Key -Owner ([string]$tool.owner) -Name ([string]$tool.name)
        if (-not $deduped.ContainsKey($key)) {
            $deduped[$key] = [pscustomobject]@{
                name = [string]$tool.name
                owner = [string]$tool.owner
                section = if ($tool.section) { [string]$tool.section } else { "Tools" }
            }
        }
    }

    $items = $deduped.Values | Sort-Object owner, name
    if (-not $items) {
        if (Test-Path $RemovedPath) {
            Remove-Item -LiteralPath $RemovedPath -Force
        }
        return
    }

    $json = $items | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($RemovedPath, (($json -replace "`r`n", "`n") -replace "`r", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Add-GridRow {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [hashtable]$RowKeys,
        [string]$Name,
        [string]$Owner,
        [string]$Section = "Tools",
        [string]$Description = "",
        [string]$Updated = "",
        [string]$Downloads = ""
    )

    if (-not $Name -or -not $Owner) {
        return
    }

    $key = Get-Key -Owner $Owner -Name $Name
    if ($RowKeys.ContainsKey($key)) {
        $row = $Grid.Rows[$RowKeys[$key]]
        $row.Cells["Section"].Value = if ($Section) { $Section } else { "Tools" }
        if ($Description) {
            $row.Cells["Description"].Value = $Description
        }
        if ($Updated) {
            $row.Cells["Updated"].Value = $Updated
        }
        if ($Downloads) {
            $row.Cells["Downloads"].Value = $Downloads
        }
        return
    }

    $index = $Grid.Rows.Add()
    $RowKeys[$key] = $index
    $row = $Grid.Rows[$index]
    $row.Cells["Owner"].Value = $Owner
    $row.Cells["Name"].Value = $Name
    $row.Cells["Section"].Value = if ($Section) { $Section } else { "Tools" }
    $row.Cells["Updated"].Value = $Updated
    $row.Cells["Downloads"].Value = $Downloads
    $row.Cells["Description"].Value = $Description
    $row.Cells["Key"].Value = $key
}

function Add-SelectedToolRow {
    param(
        [string]$Name,
        [string]$Owner,
        [string]$Section = "Tools",
        [string]$Description = "",
        [string]$Updated = "",
        [string]$Downloads = ""
    )

    Add-GridRow `
        -Grid $script:SelectedGrid `
        -RowKeys $script:SelectedRowKeys `
        -Name $Name `
        -Owner $Owner `
        -Section $Section `
        -Description $Description `
        -Updated $Updated `
        -Downloads $Downloads
}

function Add-SearchResultRow {
    param(
        [string]$Name,
        [string]$Owner,
        [string]$Section = "Tools",
        [string]$Description = "",
        [string]$Updated = "",
        [string]$Downloads = ""
    )

    Add-GridRow `
        -Grid $script:SearchGrid `
        -RowKeys $script:SearchRowKeys `
        -Name $Name `
        -Owner $Owner `
        -Section $Section `
        -Description $Description `
        -Updated $Updated `
        -Downloads $Downloads
}

function Rebuild-GridRowKeys {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [hashtable]$RowKeys
    )

    $RowKeys.Clear()
    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        $name = [string]$row.Cells["Name"].Value
        $owner = [string]$row.Cells["Owner"].Value
        if (-not $name -or -not $owner) {
            continue
        }
        $RowKeys[(Get-Key -Owner $owner -Name $name)] = $row.Index
    }
}

function Load-SelectedTools {
    $tools = Read-SelectedTools
    foreach ($tool in $tools) {
        Add-SelectedToolRow `
            -Name ([string]$tool.name) `
            -Owner ([string]$tool.owner) `
            -Section ([string]$tool.section)
    }
    Add-Log ("Loaded {0} selected tools." -f (ConvertTo-Array $tools).Count)
}

function Refresh-GridSelectionFromSavedSelection {
    $selectedByKey = @{}
    $savedTools = @(ConvertTo-Array (Read-SelectedTools))
    foreach ($tool in $savedTools) {
        if (-not $tool.name -or -not $tool.owner) {
            continue
        }
        $selectedByKey[(Get-Key -Owner ([string]$tool.owner) -Name ([string]$tool.name))] = $true
    }

    $script:SuppressGridEvents = $true
    try {
        $script:SelectedGrid.Rows.Clear()
        $script:SelectedRowKeys.Clear()
        foreach ($tool in $savedTools) {
            Add-SelectedToolRow `
                -Name ([string]$tool.name) `
                -Owner ([string]$tool.owner) `
                -Section ([string]$tool.section)
        }
    } finally {
        $script:SuppressGridEvents = $false
    }

    Add-Log ("Synced selected tools with {0} saved selected tools." -f $selectedByKey.Count)
}

function Search-OfficialTools {
    param([string]$Query)

    if (-not $Query.Trim()) {
        throw "Enter a Tool Shed search term first."
    }

    Add-Log "Searching Galaxy Tool Shed..."
    $script:SuppressGridEvents = $true
    try {
        $script:SearchGrid.Rows.Clear()
        $script:SearchRowKeys.Clear()
    } finally {
        $script:SuppressGridEvents = $false
    }

    $escaped = [uri]::EscapeDataString($Query.Trim())
    $uri = "$ToolShedUrl/api/repositories?q=$escaped&page_size=100"
    $result = Invoke-RestMethod -Uri $uri -UseBasicParsing

    $repositories = @()
    if ($result.hits) {
        $repositories = ConvertTo-Array $result.hits | ForEach-Object { $_.repository }
    } else {
        $repositories = ConvertTo-Array $result
    }

    $count = 0
    foreach ($repository in $repositories) {
        $owner = Get-Owner -Repository $repository
        if (-not $repository.name -or -not $owner) {
            continue
        }
        $key = Get-Key -Owner $owner -Name ([string]$repository.name)
        if ($script:SelectedRowKeys.ContainsKey($key)) {
            continue
        }
        Add-SearchResultRow `
            -Name ([string]$repository.name) `
            -Owner $owner `
            -Section "Tools" `
            -Description ([string]$repository.description) `
            -Updated (Get-Updated -Repository $repository) `
            -Downloads ([string]$repository.times_downloaded)
        $count++
    }
    Add-Log ("Loaded {0} Tool Shed search results." -f $count)
}

function Get-ToolFromRow {
    param([System.Windows.Forms.DataGridViewRow]$Row)

    if (-not $Row -or $Row.IsNewRow) {
        return $null
    }

    $name = [string]$Row.Cells["Name"].Value
    $owner = [string]$Row.Cells["Owner"].Value
    if (-not $name -or -not $owner) {
        return $null
    }

    return [pscustomobject]@{
        name = $name
        owner = $owner
        section = if ($Row.Cells["Section"].Value) { [string]$Row.Cells["Section"].Value } else { "Tools" }
        description = if ($Row.Cells["Description"].Value) { [string]$Row.Cells["Description"].Value } else { "" }
        updated = if ($Row.Cells["Updated"].Value) { [string]$Row.Cells["Updated"].Value } else { "" }
        downloads = if ($Row.Cells["Downloads"].Value) { [string]$Row.Cells["Downloads"].Value } else { "" }
    }
}

function Add-SearchRowToSelectedTools {
    param([System.Windows.Forms.DataGridViewRow]$Row)

    $tool = Get-ToolFromRow -Row $Row
    if (-not $tool) {
        return
    }

    Add-SelectedToolRow `
        -Name ([string]$tool.name) `
        -Owner ([string]$tool.owner) `
        -Section ([string]$tool.section) `
        -Description ([string]$tool.description) `
        -Updated ([string]$tool.updated) `
        -Downloads ([string]$tool.downloads)
}

function Select-GridRowByKey {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [hashtable]$RowKeys,
        [string]$Owner,
        [string]$Name
    )

    if (-not $Grid -or -not $Owner -or -not $Name) {
        return
    }

    $key = Get-Key -Owner $Owner -Name $Name
    if (-not $RowKeys.ContainsKey($key)) {
        return
    }

    $row = $Grid.Rows[$RowKeys[$key]]
    $Grid.ClearSelection()
    $row.Selected = $true
    if ($Grid.Columns.Contains("Name")) {
        $Grid.CurrentCell = $row.Cells["Name"]
    }
    if ($row.Index -ge 0) {
        $Grid.FirstDisplayedScrollingRowIndex = $row.Index
    }
}

function MoveSelectedSearchToolRight {
    if (-not $script:SearchGrid -or -not $script:SearchGrid.CurrentRow) {
        Add-Log "Select a search result first."
        return
    }

    $row = $script:SearchGrid.CurrentRow
    $tool = Get-ToolFromRow -Row $row
    if (-not $tool) {
        Add-Log "Select a valid search result first."
        return
    }

    Add-SearchRowToSelectedTools -Row $row
    $script:SearchGrid.Rows.Remove($row)
    Rebuild-GridRowKeys -Grid $script:SearchGrid -RowKeys $script:SearchRowKeys
    Select-GridRowByKey -Grid $script:SelectedGrid -RowKeys $script:SelectedRowKeys -Owner ([string]$tool.owner) -Name ([string]$tool.name)
    Add-Log ("Moved right to selected tools: {0}/{1}" -f $tool.owner, $tool.name)
}

function MoveSelectedToolLeft {
    if (-not $script:SelectedGrid -or -not $script:SelectedGrid.CurrentRow) {
        Add-Log "Select a selected tool first."
        return
    }

    $row = $script:SelectedGrid.CurrentRow
    $tool = Get-ToolFromRow -Row $row
    if (-not $tool) {
        Add-Log "Select a valid selected tool first."
        return
    }

    $script:SuppressGridEvents = $true
    try {
        $script:SelectedGrid.Rows.Remove($row)
        Rebuild-GridRowKeys -Grid $script:SelectedGrid -RowKeys $script:SelectedRowKeys
        Add-SearchResultRow `
            -Name ([string]$tool.name) `
            -Owner ([string]$tool.owner) `
            -Section ([string]$tool.section) `
            -Description ([string]$tool.description) `
            -Updated ([string]$tool.updated) `
            -Downloads ([string]$tool.downloads)
        Select-GridRowByKey -Grid $script:SearchGrid -RowKeys $script:SearchRowKeys -Owner ([string]$tool.owner) -Name ([string]$tool.name)
    } finally {
        $script:SuppressGridEvents = $false
    }
    Add-Log ("Moved left out of selected tools: {0}/{1}" -f $tool.owner, $tool.name)
}

function Save-Selection {
    $script:SelectedGrid.EndEdit()
    $script:SearchGrid.EndEdit()
    $previousSelection = @(ConvertTo-Array (Read-SelectedTools))
    $previousByKey = @{}
    foreach ($tool in $previousSelection) {
        if ($tool.name -and $tool.owner) {
            $previousByKey[(Get-Key -Owner ([string]$tool.owner) -Name ([string]$tool.name))] = $tool
        }
    }

    $selected = @()
    $selectedByKey = @{}
    foreach ($row in $script:SelectedGrid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        $name = [string]$row.Cells["Name"].Value
        $owner = [string]$row.Cells["Owner"].Value
        $section = [string]$row.Cells["Section"].Value
        if (-not $name -or -not $owner) {
            continue
        }
        $tool = [pscustomobject]@{
            name = $name
            owner = $owner
            section = if ($section) { $section } else { "Tools" }
        }
        $selected += $tool
        $selectedByKey[(Get-Key -Owner $owner -Name $name)] = $tool
    }

    $pendingRemoved = @(ConvertTo-Array (Read-PendingRemovedTools))
    foreach ($key in $previousByKey.Keys) {
        if (-not $selectedByKey.ContainsKey($key)) {
            $pendingRemoved += @($previousByKey[$key])
        }
    }
    $pendingRemoved = @($pendingRemoved | Where-Object {
        $_.name -and $_.owner -and -not $selectedByKey.ContainsKey((Get-Key -Owner ([string]$_.owner) -Name ([string]$_.name)))
    })
    Write-PendingRemovedTools -Tools $pendingRemoved

    $selected = $selected | Sort-Object owner, name -Unique
    $json = $selected | ConvertTo-Json -Depth 6
    if (-not $json) {
        $json = "[]"
    }
    [System.IO.File]::WriteAllText($SelectionPath, (($json -replace "`r`n", "`n") -replace "`r", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    Add-Log ("Saved {0} selected tools." -f (ConvertTo-Array $selected).Count)

    $scriptPath = Join-Path $PSScriptRoot "Update-ToolList.ps1"
    Add-Log "Regenerating tool_list.yml..."
    Invoke-LoggedCommand -File "powershell" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $scriptPath,
        "-SelectionPath",
        $SelectionPath
    )
    Add-Log "tool_list.yml regenerated."
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
        $script:CurrentCommandProcess = $process

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
                Add-Log "Command is still running... elapsed $elapsedMinutes min."
                $lastHeartbeatAt = $now
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        if ($script:CurrentCommandProcess -eq $process) {
            $script:CurrentCommandProcess = $null
        }
        $process.Dispose()
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $File $($Arguments -join ' ')"
    }
}

function Invoke-Compose {
    param([string[]]$Arguments)

    Push-Location $ProjectRoot
    try {
        if (Test-Executable "docker") {
            if (Test-NativeCommand -File "docker" -Arguments @("compose", "version")) {
                $composeArguments = @("compose")
                if ($Arguments.Count -gt 0 -and $Arguments[0] -eq "build") {
                    $composeArguments += @("--progress", "plain")
                }
                Invoke-LoggedCommand -File "docker" -Arguments ($composeArguments + $Arguments)
                return
            }
        }
        if (Test-Executable "docker-compose") {
            Invoke-LoggedCommand -File "docker-compose" -Arguments $Arguments
            return
        }
        throw "Docker Compose was not found."
    } finally {
        Pop-Location
    }
}

function Test-DockerImage {
    param([string]$ImageName)

    return Test-NativeCommand -File "docker" -Arguments @("image", "inspect", $ImageName)
}

function Ensure-GalaxyImage {
    $config = Read-DotEnv
    $imageName = if ($config.GALAXY_IMAGE) { $config.GALAXY_IMAGE } else { "local-usegalaxy:latest" }
    if (Test-DockerImage -ImageName $imageName) {
        Add-Log "Galaxy image exists. Skipping Docker rebuild."
        return
    }

    Add-Log "Galaxy image is missing. First build is running; live progress is being logged..."
    Invoke-Compose @("build", "galaxy")
    if (-not (Test-DockerImage -ImageName $imageName)) {
        throw "Docker build completed, but the expected Galaxy image '$imageName' was not created. Check tool-manager.log for the build output."
    }
    Add-Log "Galaxy image build complete."
}

function Wait-GalaxyReady {
    $config = Read-DotEnv
    $port = if ($config.GALAXY_PORT) { $config.GALAXY_PORT } else { "8080" }
    $galaxyUrl = "http://localhost:$port"

    Add-Log "Waiting for Galaxy to become ready..."
    for ($i = 1; $i -le 180; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "$galaxyUrl/api/version" -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                Add-Log "Galaxy is ready."
                return
            }
        } catch {
            if (($i % 6) -eq 0) {
                Add-Log "Galaxy is starting..."
            }
        }
        Start-Sleep -Seconds 5
        [System.Windows.Forms.Application]::DoEvents()
    }

    throw "Galaxy did not become ready in time."
}

function Apply-ToolChanges {
    if ($script:ApplyButton) {
        $script:ApplyButton.Enabled = $false
    }
    if ($script:SearchButton) {
        $script:SearchButton.Enabled = $false
    }

    try {
        Set-ApplyProgress -Percent 0 -Message "Saving tool selection..."
        Save-Selection
        Set-ApplyProgress -Percent 15 -Message "Checking Galaxy Docker image..."
        Ensure-GalaxyImage
        Set-ApplyProgress -Percent 30 -Message "Starting Galaxy without rebuilding the image..."
        Add-Log "Starting Galaxy without rebuilding the image..."
        Invoke-Compose @("up", "-d", "--no-build")
        Set-ApplyProgress -Percent 40 -Message "Waiting for Galaxy to become ready..."
        Wait-GalaxyReady
        Set-ApplyProgress -Percent 45 -Message "Applying selected tool changes..."
        $syncScript = Join-Path $PSScriptRoot "Sync-GalaxyTools.ps1"
        $config = Read-DotEnv
        $port = if ($config.GALAXY_PORT) { $config.GALAXY_PORT } else { "8080" }
        $apiKey = if ($config.GALAXY_ADMIN_API_KEY) { $config.GALAXY_ADMIN_API_KEY } else { "local-usegalaxy-admin-key" }
        $galaxyUrl = "http://localhost:$port"
        $metadataPath = Join-Path $ProjectRoot "tool_list.metadata.json"
        Invoke-LoggedCommand -File "powershell" -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $syncScript,
            "-GalaxyUrl",
            $galaxyUrl,
            "-ApiKey",
            $apiKey,
            "-SelectionPath",
            $SelectionPath,
            "-MetadataPath",
            $metadataPath,
            "-RemovedPath",
            $RemovedPath,
            "-ReconcileInstalledWithSelection"
        )
        Refresh-GridSelectionFromSavedSelection
        Set-ApplyProgress -Percent 100 -Message "Tool changes were applied. Refresh the Galaxy browser tab if it was already open."
        Add-Log "Tool changes were applied. Refresh the Galaxy browser tab if it was already open."
    } catch {
        try {
            Refresh-GridSelectionFromSavedSelection
        } catch {
            Add-Log "Could not refresh visible checkboxes after failed apply: $($_.Exception.Message)"
        }
        Set-ApplyProgress -Percent 0 -Message "Tool changes were not fully applied. Failed installs were removed from selection if Galaxy did not complete them."
        throw
    } finally {
        if ($script:ApplyButton) {
            $script:ApplyButton.Enabled = $true
        }
        if ($script:SearchButton) {
            $script:SearchButton.Enabled = $true
        }
    }
}

function Set-SearchPlaceholder {
    if (-not $script:SearchBox) {
        return
    }
    $script:SearchPlaceholderActive = $true
    $script:SearchBox.Text = $SearchPlaceholder
    $script:SearchBox.ForeColor = [System.Drawing.Color]::Gray
}

function Clear-SearchPlaceholder {
    if (-not $script:SearchBox -or -not $script:SearchPlaceholderActive) {
        return
    }
    $script:SearchPlaceholderActive = $false
    $script:SearchBox.Text = ""
    $script:SearchBox.ForeColor = [System.Drawing.SystemColors]::WindowText
}

function Restore-SearchPlaceholderIfEmpty {
    if (-not $script:SearchBox) {
        return
    }
    if (-not $script:SearchBox.Text.Trim()) {
        Set-SearchPlaceholder
    }
}

function Get-SearchQuery {
    if (-not $script:SearchBox -or $script:SearchPlaceholderActive) {
        return ""
    }
    return $script:SearchBox.Text.Trim()
}

function New-ToolGrid {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    $grid = [System.Windows.Forms.DataGridView]::new()
    $grid.Location = [System.Drawing.Point]::new($X, $Y)
    $grid.Size = [System.Drawing.Size]::new($Width, $Height)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AutoSizeColumnsMode = "None"
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.RowHeadersVisible = $false

    foreach ($columnInfo in @(
        @{ Name = "Owner"; Header = "Owner"; Width = 110; ReadOnly = $true },
        @{ Name = "Name"; Header = "Name"; Width = 165; ReadOnly = $true },
        @{ Name = "Section"; Header = "Section"; Width = 130; ReadOnly = $false },
        @{ Name = "Updated"; Header = "Updated"; Width = 130; ReadOnly = $true },
        @{ Name = "Downloads"; Header = "Downloads"; Width = 85; ReadOnly = $true },
        @{ Name = "Description"; Header = "Description"; Width = 345; ReadOnly = $true },
        @{ Name = "Key"; Header = "Key"; Width = 80; ReadOnly = $true }
    )) {
        $column = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $column.Name = $columnInfo.Name
        $column.HeaderText = $columnInfo.Header
        $column.Width = $columnInfo.Width
        $column.ReadOnly = [bool]$columnInfo.ReadOnly
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        if ($columnInfo.Name -eq "Key") {
            $column.Visible = $false
        }
        $grid.Columns.Add($column) | Out-Null
    }

    return $grid
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    throw "Windows Forms is not available."
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = [System.Windows.Forms.Form]::new()
$form.Text = "Galaxy Tool Manager"
$form.StartPosition = "CenterScreen"
$form.ClientSize = [System.Drawing.Size]::new(980, 610)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.Font = [System.Drawing.Font]::new("Segoe UI", 9)

$title = [System.Windows.Forms.Label]::new()
$title.Text = "Galaxy Tool Shed Manager"
$title.Font = [System.Drawing.Font]::new("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = [System.Drawing.Point]::new(18, 16)
$form.Controls.Add($title)

$hint = [System.Windows.Forms.Label]::new()
$hint.Text = "Search Tool Shed, move results right to use them, move selected tools left to uninstall them, then apply changes."
$hint.Font = [System.Drawing.Font]::new("Segoe UI", 9)
$hint.AutoSize = $false
$hint.Location = [System.Drawing.Point]::new(20, 50)
$hint.Size = [System.Drawing.Size]::new(920, 24)
$form.Controls.Add($hint)

$searchBox = [System.Windows.Forms.TextBox]::new()
$script:SearchBox = $searchBox
$searchBox.Location = [System.Drawing.Point]::new(22, 82)
$searchBox.Size = [System.Drawing.Size]::new(320, 24)
$searchBox.Add_Enter({ Clear-SearchPlaceholder })
$searchBox.Add_Leave({ Restore-SearchPlaceholderIfEmpty })
$form.Controls.Add($searchBox)
Set-SearchPlaceholder

$searchButton = [System.Windows.Forms.Button]::new()
$script:SearchButton = $searchButton
$searchButton.Text = "Search Tool Shed"
$searchButton.Location = [System.Drawing.Point]::new(354, 80)
$searchButton.Size = [System.Drawing.Size]::new(140, 30)
$searchButton.Add_Click({
    try {
        Search-OfficialTools -Query (Get-SearchQuery)
    } catch {
        Add-Log "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Galaxy Tool Manager", "OK", "Error") | Out-Null
    }
})
$form.Controls.Add($searchButton)
$form.AcceptButton = $searchButton

$applyButton = [System.Windows.Forms.Button]::new()
$script:ApplyButton = $applyButton
$applyButton.Text = "Apply changes"
$applyButton.Location = [System.Drawing.Point]::new(506, 80)
$applyButton.Size = [System.Drawing.Size]::new(150, 30)
$applyButton.Add_Click({
    try {
        Apply-ToolChanges
    } catch {
        Add-Log "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Galaxy Tool Manager", "OK", "Error") | Out-Null
    }
})
$form.Controls.Add($applyButton)

$closeButton = [System.Windows.Forms.Button]::new()
$closeButton.Text = "Close"
$closeButton.Location = [System.Drawing.Point]::new(668, 80)
$closeButton.Size = [System.Drawing.Size]::new(110, 30)
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$searchLabel = [System.Windows.Forms.Label]::new()
$searchLabel.Text = "Search results"
$searchLabel.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$searchLabel.AutoSize = $false
$searchLabel.Location = [System.Drawing.Point]::new(22, 122)
$searchLabel.Size = [System.Drawing.Size]::new(420, 20)
$form.Controls.Add($searchLabel)

$searchGrid = New-ToolGrid -X 22 -Y 144 -Width 420 -Height 390
$script:SearchGrid = $searchGrid
$form.Controls.Add($searchGrid)

$moveToolTip = [System.Windows.Forms.ToolTip]::new()

$moveRightButton = [System.Windows.Forms.Button]::new()
$moveRightButton.Text = ">"
$moveRightButton.Font = $form.Font
$moveRightButton.Location = [System.Drawing.Point]::new(457, 304)
$moveRightButton.Size = [System.Drawing.Size]::new(48, 30)
$moveRightButton.Add_Click({ MoveSelectedSearchToolRight })
$moveToolTip.SetToolTip($moveRightButton, "Move selected search result right to selected tools")
$form.Controls.Add($moveRightButton)

$moveLeftButton = [System.Windows.Forms.Button]::new()
$moveLeftButton.Text = "<"
$moveLeftButton.Font = $form.Font
$moveLeftButton.Location = [System.Drawing.Point]::new(457, 344)
$moveLeftButton.Size = [System.Drawing.Size]::new(48, 30)
$moveLeftButton.Add_Click({ MoveSelectedToolLeft })
$moveToolTip.SetToolTip($moveLeftButton, "Move selected tool left to uninstall/remove selection")
$form.Controls.Add($moveLeftButton)

$selectedLabel = [System.Windows.Forms.Label]::new()
$selectedLabel.Text = "Installed / selected tools"
$selectedLabel.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$selectedLabel.AutoSize = $false
$selectedLabel.Location = [System.Drawing.Point]::new(520, 122)
$selectedLabel.Size = [System.Drawing.Size]::new(420, 20)
$form.Controls.Add($selectedLabel)

$selectedGrid = New-ToolGrid -X 520 -Y 144 -Width 420 -Height 390
$script:SelectedGrid = $selectedGrid
$form.Controls.Add($selectedGrid)

$applyProgressBar = [System.Windows.Forms.ProgressBar]::new()
$script:ApplyProgressBar = $applyProgressBar
$applyProgressBar.Location = [System.Drawing.Point]::new(22, 540)
$applyProgressBar.Size = [System.Drawing.Size]::new(918, 14)
$applyProgressBar.Minimum = 0
$applyProgressBar.Maximum = 100
$applyProgressBar.Value = 0
$applyProgressBar.Style = "Blocks"
$form.Controls.Add($applyProgressBar)

$statusLabel = [System.Windows.Forms.Label]::new()
$script:StatusLabel = $statusLabel
$statusLabel.Text = "Ready."
$statusLabel.Font = [System.Drawing.Font]::new("Segoe UI", 9)
$statusLabel.AutoSize = $false
$statusLabel.Location = [System.Drawing.Point]::new(22, 560)
$statusLabel.Size = [System.Drawing.Size]::new(918, 32)
$form.Controls.Add($statusLabel)

$form.Add_FormClosing({
    if ($script:CurrentCommandProcess -and -not $script:CurrentCommandProcess.HasExited) {
        try {
            $script:CurrentCommandProcess.Kill()
        } catch {
        }
    }
})

$form.Add_Shown({
    $form.ActiveControl = $selectedGrid
    $selectedGrid.Focus() | Out-Null
    Restore-SearchPlaceholderIfEmpty
})

if ($ParentProcessId -gt 0) {
    $parentTimer = [System.Windows.Forms.Timer]::new()
    $parentTimer.Interval = 2000
    $parentTimer.Add_Tick({
        if (-not (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
            $parentTimer.Stop()
            $form.Close()
        }
    })
    $parentTimer.Start()
    $form.Add_FormClosed({
        $parentTimer.Stop()
        $parentTimer.Dispose()
    })
}

Load-SelectedTools
[void][System.Windows.Forms.Application]::Run($form)
