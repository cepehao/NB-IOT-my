function Invoke-BoundedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string]$Arguments,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][string]$OutputFolder,
        [Parameter(Mandatory=$true)][ValidateRange(0.1,864000)][double]$TimeoutSeconds,
        [scriptblock]$OnSample = $null
    )
    $ErrorActionPreference = 'Stop'
    if (Test-Path -LiteralPath $OutputFolder) {
        if (@(Get-ChildItem -LiteralPath $OutputFolder -Force).Count -gt 0) { throw 'Output folder must be empty.' }
    }
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    $outputRoot = (Resolve-Path -LiteralPath $OutputFolder).Path
    $stdoutPath = Join-Path $outputRoot 'stdout.log'
    $stderrPath = Join-Path $outputRoot 'stderr.log'
    if (-not ('Nbiot.Runtime.OwnedProcessJob' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'OwnedProcessJob.cs')
    }
    $job = [Nbiot.Runtime.OwnedProcessJob]::new($Executable,$Arguments,$WorkingDirectory,$stdoutPath,$stderrPath)
    $tracked = [System.Collections.Generic.HashSet[uint32]]::new()
    [void]$tracked.Add($job.RootProcessId)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try {
        while ($true) {
            $ids = @($job.ProcessIds())
            foreach ($ownedId in $ids) { [void]$tracked.Add($ownedId) }
            if ($null -ne $OnSample) { & $OnSample $ids }
            if ($job.RootExited -and $ids.Count -eq 0) { break }
            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true; $job.Stop(); break
            }
            Start-Sleep -Milliseconds 100
        }
        $exitCode = $job.ExitCode
        $rootProcessId = $job.RootProcessId
    }
    finally {
        # KILL_ON_JOB_CLOSE also handles exceptions and children whose parent exited.
        $job.Dispose()
    }
    if ($timedOut) { $exitCode = 124; $status = 'timed-out' }
    elseif ($exitCode -eq 0) { $status = 'completed' }
    else { $status = 'failed' }
    $report = [pscustomobject]@{
        status = $status; exitCode = $exitCode; elapsedSeconds = $stopwatch.Elapsed.TotalSeconds
        timeoutSeconds = $TimeoutSeconds; rootProcessId = $rootProcessId
        processIds = @($tracked | Sort-Object); stdout = $stdoutPath; stderr = $stderrPath
    }
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputRoot 'process-report.json') -Encoding UTF8
    return $report
}
