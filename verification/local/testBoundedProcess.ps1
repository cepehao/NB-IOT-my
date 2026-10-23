param([ValidateRange(0.1,30)][double]$MaxSeconds=30,[string]$EvidenceFolder='')
$ErrorActionPreference = 'Stop'
$script:testStopwatch=[Diagnostics.Stopwatch]::StartNew()
$script:testDeadlineUtc=[DateTime]::UtcNow.AddSeconds($MaxSeconds)

function Get-TestProcessTimeout([double]$RequestedSeconds) {
    $remaining=($script:testDeadlineUtc-[DateTime]::UtcNow).TotalSeconds
    if ($remaining -le 0.2) { throw 'Legacy bounded-process case has no bounded time remaining.' }
    return [Math]::Min($RequestedSeconds,$remaining-0.1)
}

function Assert-EvidenceFolderAvailable([string]$Path,[string]$SourceFolder) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $fullPath=[IO.Path]::GetFullPath($Path)
    $source=[IO.Path]::GetFullPath($SourceFolder).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $sourcePrefix=$source+[IO.Path]::DirectorySeparatorChar
    if ($fullPath.Equals($source,[StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'EvidenceFolder cannot overlap the legacy test temporary folder.'
    }
    if (Test-Path -LiteralPath $fullPath) {
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { throw 'EvidenceFolder exists and is not a directory.' }
        if (@(Get-ChildItem -LiteralPath $fullPath -Force).Count -gt 0) { throw 'EvidenceFolder must be empty.' }
    }
}

function Copy-TestEvidence([string]$SourceFolder,[string]$DestinationFolder) {
    if ([string]::IsNullOrWhiteSpace($DestinationFolder)) { return }
    Assert-EvidenceFolderAvailable $DestinationFolder $SourceFolder
    $destination=[IO.Path]::GetFullPath($DestinationFolder)
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $SourceFolder -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
    }
}

function Add-FixtureIdentity([string]$Name,[int]$ProcessId,[string]$StartTimeUtc) {
    $expected=[DateTimeOffset]::Parse($StartTimeUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    $script:fixtureIdentities.Add([pscustomobject]@{
        name=$Name;processId=$ProcessId;processStartTimeUtc=$expected.ToString('o')
    })
}

function Add-FixtureProcess([string]$Name,[Diagnostics.Process]$Process) {
    if ($null -eq $Process) { throw "Missing owned process handle for fixture $Name." }
    $null=$Process.Handle
    Add-FixtureIdentity $Name $Process.Id $Process.StartTime.ToUniversalTime().ToString('o')
}

function Test-FixtureIdentityAlive([object]$Identity) {
    try { $process=[Diagnostics.Process]::GetProcessById([int]$Identity.processId) }
    catch [ArgumentException] { return $false }
    try {
        $null=$process.Handle
        $expected=[DateTimeOffset]::Parse([string]$Identity.processStartTimeUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $actual=$process.StartTime.ToUniversalTime()
        if ($actual.Ticks -ne $expected.Ticks) { return $false }
        return -not $process.HasExited
    } finally { $process.Dispose() }
}

function Write-JsonFile([string]$Path,[object]$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
}
function Get-OwnedProcessHandle([int]$ProcessId,[string]$ExpectedStartTimeUtc) {
    try { $process=[Diagnostics.Process]::GetProcessById($ProcessId) }
    catch [ArgumentException] { return $null }
    try {
        $null=$process.Handle
        $expected=[DateTimeOffset]::Parse($ExpectedStartTimeUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $actual=$process.StartTime.ToUniversalTime()
        if ($actual.Ticks -ne $expected.Ticks) {
            $process.Dispose()
            return $null
        }
        return $process
    } catch {
        $process.Dispose()
        throw "Cannot verify owned-process identity for PID ${ProcessId}: $($_.Exception.Message)"
    }
}

function Test-ProcessHandleAlive([Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return $false }
    try { return -not $Process.HasExited } catch { return $false }
}

function Stop-ProcessHandle([Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
            $remaining=($script:testDeadlineUtc-[DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -gt 0) { [void]$Process.WaitForExit([int][Math]::Min(5000,$remaining)) }
        }
    } catch {
        Write-Warning "Owned process handle cleanup failed for PID $($Process.Id): $($_.Exception.Message)"
    }
}
. (Join-Path $PSScriptRoot 'InvokeBoundedProcess.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nbiot-budget-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
$shellExe = (Get-Process -Id $PID).Path
$other = $null
$ownedChildProcess = $null
$ownedOrphanProcess = $null
$testPassed=$false
$evidenceError=$null
$cleanupError=$null
$script:fixtureIdentities=[System.Collections.Generic.List[object]]::new()
try {
    Assert-EvidenceFolderAvailable $EvidenceFolder $testRoot
    $successScript = Join-Path $testRoot 'success.ps1'
    Set-Content -LiteralPath $successScript -Value "Write-Output 'child-output'; exit 0" -Encoding UTF8
    $ok = Invoke-BoundedProcess -Executable $shellExe -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$successScript`"" -WorkingDirectory $testRoot -OutputFolder (Join-Path $testRoot 'success') -TimeoutSeconds (Get-TestProcessTimeout 10)
    if ($ok.status -ne 'completed' -or $ok.exitCode -ne 0) { throw ('Successful process was not recorded: ' + ($ok | ConvertTo-Json -Compress) + ' stderr=' + (Get-Content -LiteralPath $ok.stderr -Raw)) }
    if ((Get-Content -LiteralPath $ok.stdout -Raw) -notmatch 'child-output') { throw 'stdout missing.' }
    $failScript = Join-Path $testRoot 'fail.ps1'
    Set-Content -LiteralPath $failScript -Value "[Console]::Error.WriteLine('child-error'); exit 7" -Encoding UTF8
    $failed = Invoke-BoundedProcess -Executable $shellExe -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$failScript`"" -WorkingDirectory $testRoot -OutputFolder (Join-Path $testRoot 'failed') -TimeoutSeconds (Get-TestProcessTimeout 10)
    if ($failed.status -ne 'failed' -or $failed.exitCode -ne 7) { throw 'Nonzero exit was hidden.' }
    $sleepScript = Join-Path $testRoot 'sleep.ps1'
    Set-Content -LiteralPath $sleepScript -Value 'Start-Sleep -Seconds 30' -Encoding UTF8
    $other = Start-Process -FilePath $shellExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$sleepScript`"" -WindowStyle Hidden -PassThru
    $null=$other.Handle
    Add-FixtureProcess 'unrelated-sentinel' $other
    $childPidFile = Join-Path $testRoot 'child.pid'
    $childStartTimeFile = Join-Path $testRoot 'child-start-time.txt'
    $treeScript = Join-Path $testRoot 'tree.ps1'
    $treeText = @'
param($ShellExe,$SleepScript,$PidFile,$StartTimeFile)
$child = Start-Process -FilePath $ShellExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$SleepScript`"" -WindowStyle Hidden -PassThru
$child.Id | Set-Content -LiteralPath $PidFile
$child.StartTime.ToUniversalTime().ToString('o') | Set-Content -LiteralPath $StartTimeFile
Start-Sleep -Seconds 30
'@
    Set-Content -LiteralPath $treeScript -Value $treeText -Encoding UTF8
    $timed = Invoke-BoundedProcess -Executable $shellExe -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$treeScript`" -ShellExe `"$shellExe`" -SleepScript `"$sleepScript`" -PidFile `"$childPidFile`" -StartTimeFile `"$childStartTimeFile`"" -WorkingDirectory $testRoot -OutputFolder (Join-Path $testRoot 'timed') -TimeoutSeconds (Get-TestProcessTimeout 3)
    if ($timed.status -ne 'timed-out' -or $timed.exitCode -ne 124) { throw 'Timeout was not reported.' }
    $childId=[int](Get-Content -LiteralPath $childPidFile)
    $childStart=[string](Get-Content -LiteralPath $childStartTimeFile)
    Add-FixtureIdentity 'timed-descendant' $childId $childStart
    $ownedChildProcess=Get-OwnedProcessHandle $childId $childStart
    if (Test-ProcessHandleAlive $ownedChildProcess) { throw 'Owned descendant survived timeout.' }
    if ($other.HasExited) { throw 'Unrelated process was stopped.' }
    $orphanPidFile = Join-Path $testRoot 'orphan.pid'
    $orphanStartTimeFile = Join-Path $testRoot 'orphan-start-time.txt'
    $orphanScript = Join-Path $testRoot 'orphan.ps1'
    Set-Content -LiteralPath $orphanScript -Value ($treeText.Replace('Start-Sleep -Seconds 30','exit 0')) -Encoding UTF8
    $orphan = Invoke-BoundedProcess -Executable $shellExe -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$orphanScript`" -ShellExe `"$shellExe`" -SleepScript `"$sleepScript`" -PidFile `"$orphanPidFile`" -StartTimeFile `"$orphanStartTimeFile`"" -WorkingDirectory $testRoot -OutputFolder (Join-Path $testRoot 'orphan') -TimeoutSeconds (Get-TestProcessTimeout 3)
    $orphanId=[int](Get-Content -LiteralPath $orphanPidFile)
    $orphanStart=[string](Get-Content -LiteralPath $orphanStartTimeFile)
    Add-FixtureIdentity 'orphan-descendant' $orphanId $orphanStart
    $ownedOrphanProcess=Get-OwnedProcessHandle $orphanId $orphanStart
    if ($orphan.status -ne 'timed-out' -or (Test-ProcessHandleAlive $ownedOrphanProcess)) { throw 'A child escaped after its parent exited.' }
    $pilotScript = Join-Path $PSScriptRoot '..\completion\stage-3\runLoadPilot.ps1'
    $blocked = $false
    try { & $pilotScript -MatlabCommand 'deliberately-missing' } catch { $blocked = $_.Exception.Message -like 'ExecutionBudget:*' }
    if (-not $blocked) { throw 'Pilot default was not blocked before MATLAB startup.' }
    if ($script:testStopwatch.Elapsed.TotalSeconds -gt $MaxSeconds) { throw 'Legacy bounded-process case exceeded its measured time limit.' }
    $testPassed=$true
    Write-Output 'BOUNDED_PROCESS_TESTS passed=5 failed=0'
}
finally {
    Stop-ProcessHandle $ownedOrphanProcess
    if ($null -ne $ownedOrphanProcess) { $ownedOrphanProcess.Dispose() }
    Stop-ProcessHandle $ownedChildProcess
    if ($null -ne $ownedChildProcess) { $ownedChildProcess.Dispose() }
    Stop-ProcessHandle $other
    if ($null -ne $other) { $other.Dispose() }
    $fixtureChecks=@()
    foreach ($identity in $script:fixtureIdentities) {
        try {
            $alive=Test-FixtureIdentityAlive $identity
            $status=if($alive){'alive-after-cleanup'}else{'absent'}
            if ($alive) { $cleanupError="Fixture $($identity.name) remains alive after cleanup." }
        } catch {
            $status='unverified'
            $cleanupError="Fixture $($identity.name) could not be checked: $($_.Exception.Message)"
        }
        $fixtureChecks+=@([ordered]@{
            name=$identity.name;processId=$identity.processId;processStartTimeUtc=$identity.processStartTimeUtc;status=$status
        })
    }
    try { Write-JsonFile (Join-Path $testRoot 'fixture-processes.json') ([ordered]@{schemaVersion=1;processes=$fixtureChecks}) }
    catch { $cleanupError="Fixture identity report could not be written: $($_.Exception.Message)" }
    $script:testStopwatch.Stop()
    $elapsed=$script:testStopwatch.Elapsed.TotalSeconds
    $timingStatus=if($elapsed -le $MaxSeconds -and $testPassed){'completed-within-limit'}elseif($elapsed -gt $MaxSeconds){'exceeded-limit'}else{'failed-within-limit'}
    try {
        Write-JsonFile (Join-Path $testRoot 'scenario-timing.json') ([ordered]@{schemaVersion=1;maxScenarioSeconds=$MaxSeconds;elapsedSeconds=$elapsed;status=$timingStatus})
    } catch { $cleanupError="Scenario timing report could not be written: $($_.Exception.Message)" }
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    $evidenceCopied=[string]::IsNullOrWhiteSpace($EvidenceFolder)
    if (-not [string]::IsNullOrWhiteSpace($EvidenceFolder)) {
        try {
            Copy-TestEvidence $resolvedTestRoot $EvidenceFolder
            $evidenceCopied=$true
        } catch {
            $evidenceError=$_.Exception
            Write-Warning "Legacy test evidence copy failed; temp artifacts preserved at $resolvedTestRoot : $($_.Exception.Message)"
        }
    }
    if ($resolvedTestRoot.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and $testPassed -and $evidenceCopied) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    } elseif ($resolvedTestRoot.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "Legacy test artifacts preserved for diagnosis: $resolvedTestRoot"
    }
}
if ($null -ne $evidenceError) { throw "Legacy test evidence could not be retained: $($evidenceError.Message)" }
if ($null -ne $cleanupError) { throw $cleanupError }
