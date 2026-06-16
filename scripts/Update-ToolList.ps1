[CmdletBinding()]
param(
    [string]$ToolShedUrl = "https://toolshed.g2.bx.psu.edu",
    [string]$SelectionPath,
    [string]$OutputPath,
    [string]$MetadataPath,
    [switch]$ForceResolve
)

$ErrorActionPreference = "Stop"

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "..\tool_list.yml"
}
if (-not $MetadataPath) {
    $MetadataPath = Join-Path $PSScriptRoot "..\tool_list.metadata.json"
}
if (-not $SelectionPath) {
    $SelectionPath = Join-Path $PSScriptRoot "..\tools.selected.json"
}

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

function Get-Repository {
    param(
        [string]$Name,
        [string]$Owner
    )

    $uri = "{0}/api/repositories?name={1}" -f $ToolShedUrl.TrimEnd("/"), [uri]::EscapeDataString($Name)
    $result = Invoke-RestMethod -Uri $uri -UseBasicParsing
    $matches = ConvertTo-Array $result | Where-Object {
        ($_.name -eq $Name) -and (($_.owner -eq $Owner) -or ($_.repo_owner_username -eq $Owner))
    }

    if (-not $matches) {
        throw "Tool Shed repository not found: $Owner/$Name"
    }

    return $matches | Select-Object -First 1
}

function Get-LatestMetadata {
    param([string]$RepositoryId)

    $uri = "{0}/api/repositories/{1}/metadata" -f $ToolShedUrl.TrimEnd("/"), $RepositoryId
    $metadata = Invoke-RestMethod -Uri $uri -UseBasicParsing
    $entries = foreach ($property in $metadata.PSObject.Properties) {
        $entry = $property.Value
        if ($entry.downloadable -and -not $entry.malicious) {
            [pscustomobject]@{
                NumericRevision = [int]$entry.numeric_revision
                Revision = [string]$entry.changeset_revision
                Tools = (ConvertTo-Array $entry.tools)
            }
        }
    }

    $latest = $entries | Sort-Object NumericRevision -Descending | Select-Object -First 1
    if (-not $latest) {
        throw "No downloadable revision found for repository id $RepositoryId"
    }
    return $latest
}

function Get-ToolVersions {
    param([object[]]$Tools)

    $versions = $Tools |
        ForEach-Object { $_.version } |
        Where-Object { $_ } |
        Sort-Object -Unique

    if ($versions) {
        return ($versions -join ", ")
    }
    return ""
}

function Read-SelectedRepositories {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path $fullPath)) {
        Write-Host "Tool selection file not found. Starting with an empty selection: $fullPath"
        return @()
    }

    $items = ConvertTo-Array ((Get-Content -Raw -Encoding UTF8 $fullPath) | ConvertFrom-Json)
    $deduped = @{}
    foreach ($item in $items) {
        if (-not $item.name -or -not $item.owner) {
            continue
        }
        $key = ("{0}/{1}" -f $item.owner, $item.name).ToLowerInvariant()
        if (-not $deduped.ContainsKey($key)) {
            $section = if ($item.section) { [string]$item.section } else { "Tools" }
            $deduped[$key] = [pscustomobject]@{
                Name = [string]$item.name
                Owner = [string]$item.owner
                Section = $section
            }
        }
    }

    $repositories = $deduped.Values | Sort-Object Owner, Name
    if (-not $repositories) {
        return @()
    }
    return $repositories
}

function Get-RepositoryKey {
    param(
        [string]$Owner,
        [string]$Name
    )
    return ("{0}/{1}" -f $Owner, $Name).ToLowerInvariant()
}

function Get-CachedMetadataByKey {
    param([string]$Path)

    $cache = @{}
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path $fullPath)) {
        return $cache
    }

    foreach ($item in (ConvertTo-Array ((Get-Content -Raw -Encoding UTF8 $fullPath) | ConvertFrom-Json))) {
        if (-not $item.Name -or -not $item.Owner -or -not $item.Revision) {
            continue
        }
        $key = Get-RepositoryKey -Owner ([string]$item.Owner) -Name ([string]$item.Name)
        $cache[$key] = $item
    }
    return $cache
}

$generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
$resolved = @()
$repositories = Read-SelectedRepositories -Path $SelectionPath
$metadataFullPath = [System.IO.Path]::GetFullPath($MetadataPath)
$cachedMetadata = Get-CachedMetadataByKey -Path $metadataFullPath

foreach ($repo in $repositories) {
    $key = Get-RepositoryKey -Owner $repo.Owner -Name $repo.Name
    if (-not $ForceResolve -and $cachedMetadata.ContainsKey($key)) {
        $cached = $cachedMetadata[$key]
        Write-Host ("Using cached metadata, skipping resolve: {0}/{1}" -f $repo.Owner, $repo.Name)
        $resolved += [pscustomobject]@{
            Name = $repo.Name
            Owner = $repo.Owner
            Section = $repo.Section
            RepositoryId = if ($cached.RepositoryId) { [string]$cached.RepositoryId } else { "" }
            Revision = [string]$cached.Revision
            NumericRevision = if ($cached.NumericRevision) { [int]$cached.NumericRevision } else { 0 }
            ToolVersions = if ($cached.ToolVersions) { [string]$cached.ToolVersions } else { "" }
            ToolShedUrl = if ($cached.ToolShedUrl) { [string]$cached.ToolShedUrl } else { $ToolShedUrl.TrimEnd("/") }
            RepositoryUpdated = if ($cached.RepositoryUpdated) { [string]$cached.RepositoryUpdated } else { "" }
            Description = if ($cached.Description) { [string]$cached.Description } else { "" }
        }
    } else {
        Write-Host ("Resolving {0}/{1}" -f $repo.Owner, $repo.Name)
        $repository = Get-Repository -Name $repo.Name -Owner $repo.Owner
        $latest = Get-LatestMetadata -RepositoryId $repository.id
        $resolved += [pscustomobject]@{
            Name = $repo.Name
            Owner = $repo.Owner
            Section = $repo.Section
            RepositoryId = $repository.id
            Revision = $latest.Revision
            NumericRevision = $latest.NumericRevision
            ToolVersions = Get-ToolVersions -Tools $latest.Tools
            ToolShedUrl = $ToolShedUrl.TrimEnd("/")
            RepositoryUpdated = $repository.update_time
            Description = $repository.description
        }
    }
}

$builder = [System.Text.StringBuilder]::new()
[void]$builder.AppendLine("# Generated by scripts/Update-ToolList.ps1")
[void]$builder.AppendLine("# Generated at: $generatedAt")
[void]$builder.AppendLine("# Tool Shed: $($ToolShedUrl.TrimEnd('/'))")
[void]$builder.AppendLine("install_resolver_dependencies: true")
[void]$builder.AppendLine("install_tool_dependencies: false")
[void]$builder.AppendLine("install_repository_dependencies: true")

if ($resolved) {
    [void]$builder.AppendLine("tools:")
    foreach ($repo in $resolved) {
        [void]$builder.AppendLine("  - name: $($repo.Name)")
        [void]$builder.AppendLine("    owner: $($repo.Owner)")
        [void]$builder.AppendLine("    tool_shed_url: $($repo.ToolShedUrl)")
        [void]$builder.AppendLine("    revisions:")
        [void]$builder.AppendLine("      - '$($repo.Revision)'")
        [void]$builder.AppendLine("    tool_panel_section_label: '$($repo.Section)'")
    }
} else {
    [void]$builder.AppendLine("tools: []")
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)

$outputDirectory = Split-Path -Parent $outputFullPath
if ($outputDirectory -and -not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

[System.IO.File]::WriteAllText($outputFullPath, (($builder.ToString() -replace "`r`n", "`n") -replace "`r", "`n"), [System.Text.UTF8Encoding]::new($false))
$metadataJson = if ($resolved) { $resolved | ConvertTo-Json -Depth 8 } else { "[]" }
[System.IO.File]::WriteAllText($metadataFullPath, (($metadataJson -replace "`r`n", "`n") -replace "`r", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))

Write-Host "Wrote $outputFullPath"
Write-Host "Wrote $metadataFullPath"
