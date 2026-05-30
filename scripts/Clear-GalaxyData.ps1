[CmdletBinding()]
param(
    [string]$GalaxyUrl = "http://localhost:8080",
    [string]$ApiKey = "local-usegalaxy-admin-key",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$GalaxyUrl = $GalaxyUrl.TrimEnd("/")

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

function Join-QueryString {
    param([hashtable]$Query)

    $parts = @()
    foreach ($key in ($Query.Keys | Sort-Object)) {
        if ($null -eq $Query[$key]) {
            continue
        }
        $parts += ("{0}={1}" -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$Query[$key]))
    }
    return ($parts -join "&")
}

function Invoke-GalaxyApi {
    param(
        [string]$Path,
        [string]$Method = "Get",
        [hashtable]$Query = @{},
        [object]$Body = $null,
        [int]$TimeoutSec = 120
    )

    $uri = if ($Path.StartsWith("http")) { $Path } else { "$GalaxyUrl$Path" }
    $queryWithKey = @{} + $Query
    $queryWithKey["key"] = $ApiKey
    $queryString = Join-QueryString -Query $queryWithKey
    if ($queryString) {
        $separator = if ($uri.Contains("?")) { "&" } else { "?" }
        $uri = "$uri$separator$queryString"
    }

    $parameters = @{
        Uri             = $uri
        Method          = $Method
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = ($Body | ConvertTo-Json -Depth 8)
    }

    return Invoke-RestMethod @parameters
}

function Get-UniqueHistories {
    $byId = @{}

    foreach ($source in @(
        @{ Name = "active"; Path = "/api/histories"; Query = @{ all = "true" } },
        @{ Name = "deleted"; Path = "/api/histories/deleted"; Query = @{ all = "true" } }
    )) {
        try {
            $items = ConvertTo-Array (Invoke-GalaxyApi -Path $source.Path -Query $source.Query)
            foreach ($history in $items) {
                if (-not $history.id -or $history.purged) {
                    continue
                }
                if (-not $byId.ContainsKey([string]$history.id)) {
                    $byId[[string]$history.id] = $history
                }
            }
            Write-Host ("Found {0} {1} histories." -f $items.Count, $source.Name)
        } catch {
            Write-Warning ("Could not list {0} histories: {1}" -f $source.Name, $_.Exception.Message)
        }
    }

    return ConvertTo-Array $byId.Values
}

function Get-HistoryContentCount {
    param([string]$HistoryId)

    try {
        $contents = ConvertTo-Array (Invoke-GalaxyApi -Path "/api/histories/$HistoryId/contents" -TimeoutSec 120)
        return $contents.Count
    } catch {
        Write-Warning "Could not count contents for history ${HistoryId}: $($_.Exception.Message)"
        return 0
    }
}

function Stop-ActiveJobs {
    $jobs = ConvertTo-Array (Invoke-GalaxyApi -Path "/api/jobs" -TimeoutSec 120)
    $activeStates = @("new", "queued", "running", "waiting", "paused", "resubmitted", "upload")
    $activeJobs = $jobs | Where-Object { $_.id -and ($activeStates -contains ([string]$_.state).ToLowerInvariant()) }

    if (-not $activeJobs) {
        Write-Host "No active Galaxy jobs need cancellation."
        return 0
    }

    foreach ($job in $activeJobs) {
        $id = [string]$job.id
        $state = [string]$job.state
        if ($DryRun) {
            Write-Host "Dry run: would cancel job $id ($state)."
            continue
        }

        Write-Host "Cancelling job $id ($state)."
        Invoke-GalaxyApi -Path "/api/jobs/$id" -Method "Delete" -Body @{ message = "Cancelled by Local Galaxy cleanup." } -TimeoutSec 120 | Out-Null
    }

    return (ConvertTo-Array $activeJobs).Count
}

function Remove-Histories {
    param([object[]]$Histories)

    $removed = 0
    foreach ($history in (ConvertTo-Array $Histories)) {
        $id = [string]$history.id
        $name = if ($history.name) { [string]$history.name } else { "(unnamed)" }

        if ($DryRun) {
            Write-Host "Dry run: would delete and purge history $id - $name."
            continue
        }

        Write-Host "Deleting and purging history $id - $name."
        Invoke-GalaxyApi -Path "/api/histories/$id" -Method "Delete" -Query @{ purge = "true" } -TimeoutSec 600 | Out-Null
        $removed++
    }

    return $removed
}

Write-Host "Loading Galaxy histories and jobs from $GalaxyUrl"
Write-Host "Cleanup scope: histories, datasets, dataset collections, and active jobs. Installed Tool Shed repositories are not touched."

$histories = ConvertTo-Array (Get-UniqueHistories)
$contentCount = 0
foreach ($history in $histories) {
    $contentCount += Get-HistoryContentCount -HistoryId ([string]$history.id)
}

Write-Host ("Cleanup preview: {0} histories and {1} history items." -f $histories.Count, $contentCount)
$cancelledJobs = Stop-ActiveJobs
$removedHistories = Remove-Histories -Histories $histories

if ($DryRun) {
    Write-Host ("Dry run complete. Would cancel {0} active jobs and purge {1} histories." -f $cancelledJobs, $histories.Count)
} else {
    Write-Host ("Galaxy data cleanup complete. Cancelled jobs: {0}. Purged histories: {1}." -f $cancelledJobs, $removedHistories)
}
