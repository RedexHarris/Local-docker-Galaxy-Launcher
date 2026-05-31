[CmdletBinding()]
param(
    [string]$GalaxyUrl = "http://localhost:8080",
    [string]$ApiKey = "local-usegalaxy-admin-key",
    [string]$ContainerName = "local-usegalaxy",
    [switch]$SkipFilesystemCleanup,
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

function Invoke-DockerExec {
    param([string]$Command)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $normalizedCommand = ($Command -replace "`r`n", "`n") -replace "`r", "`n"
        $output = $normalizedCommand | & docker exec -i $ContainerName bash -c "tr -d '\r' | bash -s" 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        $message = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        if (-not $message) {
            $message = "docker exec failed with exit code $exitCode."
        }
        throw $message
    }

    return $output
}

function Show-GeneratedFileSizes {
    param([string]$Title)

    $script = @'
paths="
/export/galaxy/database/files
/export/galaxy/database/job_working_directory
/export/galaxy/database/tmp
/export/galaxy/database/object_store_cache
/export/galaxy/database/objects
/export/galaxy/database/short_term_storage
"
for path in $paths; do
    if [ -e "$path" ]; then
        du -sh "$path"
    fi
done
count=$(find /export/galaxy/database/files /export/galaxy/database/job_working_directory /export/galaxy/database/tmp /export/galaxy/database/object_store_cache /export/galaxy/database/objects /export/galaxy/database/short_term_storage -type f 2>/dev/null | wc -l)
echo "generated_file_count ${count}"
'@

    Write-Host $Title
    Invoke-DockerExec -Command $script | ForEach-Object { Write-Host $_.ToString() }
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

    return @($byId.Values | ForEach-Object { $_ })
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

function Clear-GeneratedFiles {
    if ($SkipFilesystemCleanup) {
        Write-Host "Skipping Docker volume file cleanup."
        return
    }

    Show-GeneratedFileSizes -Title "Generated file sizes before filesystem cleanup:"

    if ($DryRun) {
        Write-Host "Dry run: would remove generated files from Galaxy object store, job working directory, temp directory, and object-store cache."
        return
    }

    $cleanupScript = @'
set -eu

cleanup_dir() {
    path="$1"
    case "$path" in
        /export/galaxy/database/files|\
        /export/galaxy/database/job_working_directory|\
        /export/galaxy/database/tmp|\
        /export/galaxy/database/object_store_cache|\
        /export/galaxy/database/objects|\
        /export/galaxy/database/short_term_storage)
            ;;
        *)
            echo "Refusing to clean unsafe path: $path" >&2
            exit 2
            ;;
    esac

    if [ -d "$path" ]; then
        if command -v shred >/dev/null 2>&1; then
            find "$path" -type f -exec shred -n 0 -z -u -- {} +
        else
            find "$path" -type f -exec rm -f -- {} +
        fi
        find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
}

cleanup_dir /export/galaxy/database/files
cleanup_dir /export/galaxy/database/job_working_directory
cleanup_dir /export/galaxy/database/tmp
cleanup_dir /export/galaxy/database/object_store_cache
cleanup_dir /export/galaxy/database/objects
cleanup_dir /export/galaxy/database/short_term_storage

install -d /export/galaxy/database/files
install -d /export/galaxy/database/files/000
install -d /export/galaxy/database/files/_metadata_files
install -d /export/galaxy/database/job_working_directory
install -d /export/galaxy/database/job_working_directory/000
install -d /export/galaxy/database/tmp
install -d /export/galaxy/database/object_store_cache

if id galaxy >/dev/null 2>&1; then
    chown -R galaxy:galaxy \
        /export/galaxy/database/files \
        /export/galaxy/database/job_working_directory \
        /export/galaxy/database/tmp \
        /export/galaxy/database/object_store_cache
fi

sync
'@

    Write-Host "Zeroing and removing generated files from Docker volume path /export/galaxy/database. Installed tools are not touched."
    Invoke-DockerExec -Command $cleanupScript | ForEach-Object { Write-Host $_.ToString() }
    Show-GeneratedFileSizes -Title "Generated file sizes after filesystem cleanup:"
}

Write-Host "Loading Galaxy histories and jobs from $GalaxyUrl"
Write-Host "Cleanup scope: histories, datasets, dataset collections, active jobs, object-store files, job working files, temp files, and object-store cache. Installed Tool Shed repositories are not touched."

$histories = @(Get-UniqueHistories)
$contentCount = 0
foreach ($history in $histories) {
    $contentCount += Get-HistoryContentCount -HistoryId ([string]$history.id)
}

Write-Host ("Cleanup preview: {0} histories and {1} history items." -f $histories.Count, $contentCount)
$cancelledJobs = Stop-ActiveJobs
$removedHistories = Remove-Histories -Histories $histories
Clear-GeneratedFiles

if ($DryRun) {
    Write-Host ("Dry run complete. Would cancel {0} active jobs, purge {1} histories, and remove generated files from the Docker volume." -f $cancelledJobs, $histories.Count)
} else {
    Write-Host ("Galaxy data cleanup complete. Cancelled jobs: {0}. Purged histories: {1}. Generated files were removed from the Docker volume." -f $cancelledJobs, $removedHistories)
}
