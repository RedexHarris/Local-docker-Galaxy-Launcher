[CmdletBinding()]
param(
    [string]$GalaxyUrl = "http://localhost:8080",
    [string]$ApiKey = "local-usegalaxy-admin-key",
    [string]$SelectionPath,
    [string]$MetadataPath,
    [string]$RemovedPath,
    [string]$ToolShedUrl = "https://toolshed.g2.bx.psu.edu",
    [switch]$KeepPendingOnMissing
)

$ErrorActionPreference = "Stop"

if (-not $SelectionPath) {
    $SelectionPath = Join-Path $PSScriptRoot "..\tools.selected.json"
}
if (-not $MetadataPath) {
    $MetadataPath = Join-Path $PSScriptRoot "..\tool_list.metadata.json"
}
if (-not $RemovedPath) {
    $RemovedPath = Join-Path $PSScriptRoot "..\tools.removed.json"
}

$SelectionPath = [System.IO.Path]::GetFullPath($SelectionPath)
$MetadataPath = [System.IO.Path]::GetFullPath($MetadataPath)
$RemovedPath = [System.IO.Path]::GetFullPath($RemovedPath)
$GalaxyUrl = $GalaxyUrl.TrimEnd("/")
$ToolShedUrl = $ToolShedUrl.TrimEnd("/")

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

function Get-ToolKey {
    param(
        [string]$Owner,
        [string]$Name
    )
    return ("{0}/{1}" -f $Owner, $Name).ToLowerInvariant()
}

function Read-JsonArray {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return @()
    }
    return ConvertTo-Array ((Get-Content -Raw -Encoding UTF8 $Path) | ConvertFrom-Json)
}

function Write-JsonArray {
    param(
        [string]$Path,
        [object[]]$Items
    )

    $itemsArray = ConvertTo-Array $Items
    if (-not $itemsArray) {
        if (Test-Path $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        return
    }

    $json = $itemsArray | ConvertTo-Json -Depth 8
    if (-not $json) {
        $json = "[]"
    }
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Get-InstalledRepositories {
    param([switch]$Quiet)

    $key = [uri]::EscapeDataString($ApiKey)
    $installedUri = "$GalaxyUrl/api/tool_shed_repositories?key=$key"
    if (-not $Quiet) {
        Write-Host "Loading installed Galaxy Tool Shed repositories..."
    }
    return ConvertTo-Array (Invoke-RestMethod -Uri $installedUri -UseBasicParsing -TimeoutSec 30)
}

function Get-RepositoryStatusText {
    param([object]$Repository)

    $values = @()
    foreach ($propertyName in @("status", "tool_shed_status", "installation_status", "status_message", "error_message")) {
        if ($Repository.PSObject.Properties.Name -contains $propertyName -and $Repository.$propertyName) {
            $values += [string]$Repository.$propertyName
        }
    }
    return ($values -join " ").Trim()
}

function Test-RepositoryFailed {
    param([object]$Repository)

    $status = Get-RepositoryStatusText -Repository $Repository
    return [bool]($status -match "(?i)error|fail|failed")
}

function Test-RepositoryInstalled {
    param([object]$Repository)

    if ($Repository.uninstalled -or $Repository.deleted) {
        return $false
    }

    if (Test-RepositoryFailed -Repository $Repository) {
        return $false
    }

    if ($Repository.PSObject.Properties.Name -contains "status" -and $Repository.status) {
        return ([string]$Repository.status) -match "(?i)^installed$|^ok$"
    }

    return $true
}

function Get-ActiveInstalledMap {
    param([object[]]$Installed)

    $map = @{}
    foreach ($repository in (ConvertTo-Array $Installed)) {
        if (-not $repository.name -or -not $repository.owner) {
            continue
        }
        if (-not (Test-RepositoryInstalled -Repository $repository)) {
            continue
        }
        $key = Get-ToolKey -Owner ([string]$repository.owner) -Name ([string]$repository.name)
        if (-not $map.ContainsKey($key)) {
            $map[$key] = @()
        }
        $map[$key] += $repository
    }
    return $map
}

function Wait-RepositoryInstalled {
    param(
        [object]$Tool,
        [int]$TimeoutSec = 600,
        [int]$PollSec = 5
    )

    $name = [string]$Tool.name
    $owner = [string]$Tool.owner
    $toolKey = Get-ToolKey -Owner $owner -Name $name
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $installed = Get-InstalledRepositories -Quiet
        $matches = ConvertTo-Array $installed | Where-Object {
            $_.name -and $_.owner -and
            (Get-ToolKey -Owner ([string]$_.owner) -Name ([string]$_.name)) -eq $toolKey
        }

        foreach ($repository in (ConvertTo-Array $matches)) {
            if (Test-RepositoryFailed -Repository $repository) {
                $status = Get-RepositoryStatusText -Repository $repository
                throw "Galaxy reported a Tool Shed install failure for ${owner}/${name}: $status"
            }
        }

        $ready = ConvertTo-Array $matches | Where-Object { Test-RepositoryInstalled -Repository $_ }
        if ($ready) {
            Write-Host "Repository installed and active: $owner/$name"
            return $installed
        }

        $attempt++
        if (($attempt % 6) -eq 1) {
            Write-Host "Waiting for Galaxy to finish installing: $owner/$name"
        }
        Start-Sleep -Seconds $PollSec
    }

    throw "Timed out waiting for Galaxy to finish installing ${owner}/${name}."
}

function Get-MetadataByKey {
    $metadataByKey = @{}
    foreach ($item in (Read-JsonArray -Path $MetadataPath)) {
        if (-not $item.Name -or -not $item.Owner) {
            continue
        }
        $key = Get-ToolKey -Owner ([string]$item.Owner) -Name ([string]$item.Name)
        $metadataByKey[$key] = $item
    }
    return $metadataByKey
}

function Invoke-InstallRepository {
    param(
        [object]$Tool,
        [object]$Metadata
    )

    $name = [string]$Tool.name
    $owner = [string]$Tool.owner
    $section = if ($Tool.section) { [string]$Tool.section } else { "Tools" }
    $revision = if ($Metadata -and $Metadata.Revision) { [string]$Metadata.Revision } else { "" }

    if (-not $revision) {
        throw "No changeset revision was found for $owner/$name. Regenerate tool_list.yml first."
    }

    $payload = @{
        tool_shed_url = $ToolShedUrl
        name = $name
        owner = $owner
        changeset_revision = $revision
        new_tool_panel_section_label = $section
        tool_panel_section_id = ""
        install_repository_dependencies = $true
        install_resolver_dependencies = $true
        install_tool_dependencies = $false
    }

    $body = $payload | ConvertTo-Json -Depth 8
    $apiKey = [uri]::EscapeDataString($ApiKey)
    $uris = @(
        "$GalaxyUrl/api/tool_shed_repositories/install_repository_revision?key=$apiKey",
        "$GalaxyUrl/api/tool_shed_repositories/new/install_repository_revision?key=$apiKey"
    )

    $lastError = $null
    foreach ($uri in $uris) {
        try {
            Write-Host "Installing missing repository: $owner/$name"
            Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -UseBasicParsing -TimeoutSec 600 | Out-Null
            return
        } catch {
            $lastError = $_
        }
    }

    throw "Could not install ${owner}/${name}: $($lastError.Exception.Message)"
}

function Invoke-RemoveRepositories {
    param(
        [object[]]$RemovedTools,
        [object[]]$Installed
    )

    $remaining = @()
    $hadFailures = $false
    $apiKey = [uri]::EscapeDataString($ApiKey)

    foreach ($tool in (ConvertTo-Array $RemovedTools)) {
        $name = [string]$tool.name
        $owner = [string]$tool.owner
        if (-not $name -or -not $owner) {
            continue
        }

        $toolKey = Get-ToolKey -Owner $owner -Name $name
        $matches = $Installed | Where-Object {
            (Get-ToolKey -Owner ([string]$_.owner) -Name ([string]$_.name)) -eq $toolKey -and
            -not $_.uninstalled -and
            -not $_.deleted
        }

        if (-not $matches) {
            Write-Host "Not installed or already removed: $owner/$name"
            if ($KeepPendingOnMissing) {
                $remaining += $tool
            }
            continue
        }

        foreach ($repository in $matches) {
            try {
                $id = [uri]::EscapeDataString([string]$repository.id)
                $deleteUri = "$GalaxyUrl/api/tool_shed_repositories/$id?key=$apiKey&remove_from_disk=true"
                Write-Host "Removing installed repository: $owner/$name"
                Invoke-RestMethod -Uri $deleteUri -Method Delete -UseBasicParsing -TimeoutSec 120 | Out-Null
            } catch {
                $hadFailures = $true
                $remaining += $tool
                Write-Warning "Could not remove ${owner}/${name}: $($_.Exception.Message)"
            }
        }
    }

    Write-JsonArray -Path $RemovedPath -Items $remaining
    if ($hadFailures) {
        throw "Some tools could not be removed. Pending removals were kept in $RemovedPath"
    }
}

$selectedTools = Read-JsonArray -Path $SelectionPath
$removedTools = Read-JsonArray -Path $RemovedPath
$metadataByKey = Get-MetadataByKey

$installed = Get-InstalledRepositories
Invoke-RemoveRepositories -RemovedTools $removedTools -Installed $installed

$installed = Get-InstalledRepositories
$activeInstalledMap = Get-ActiveInstalledMap -Installed $installed

$installedCount = 0
$skippedCount = 0
foreach ($tool in (ConvertTo-Array $selectedTools)) {
    $name = [string]$tool.name
    $owner = [string]$tool.owner
    if (-not $name -or -not $owner) {
        continue
    }

    $toolKey = Get-ToolKey -Owner $owner -Name $name
    if ($activeInstalledMap.ContainsKey($toolKey)) {
        Write-Host "Already installed, skipping: $owner/$name"
        $skippedCount++
        continue
    }

    $metadata = if ($metadataByKey.ContainsKey($toolKey)) { $metadataByKey[$toolKey] } else { $null }
    Invoke-InstallRepository -Tool $tool -Metadata $metadata
    $installed = Wait-RepositoryInstalled -Tool $tool
    $activeInstalledMap = Get-ActiveInstalledMap -Installed $installed
    $installedCount++
}

Write-Host "Tool sync complete. Installed missing: $installedCount. Already present: $skippedCount."
