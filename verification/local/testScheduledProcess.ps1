param(
    [switch]$Controller,
    [string]$ConfigPath = '',
    [string]$EvidenceFolder = ''
)
$ErrorActionPreference = 'Stop'

function Write-JsonFile([string]$Path,[object]$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
}

function Wait-File([string]$Path,[int]$TimeoutSeconds=15) {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    if ($null -ne $script:caseDeadlineUtc -and $script:caseDeadlineUtc -lt $deadline) {
        $deadline=$script:caseDeadlineUtc
    }
    while (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for $Path" }
        Start-Sleep -Milliseconds 100
    }
}

function Start-TestCase([string]$Name) {
    $script:caseName=$Name
    $script:caseStopwatch=[Diagnostics.Stopwatch]::StartNew()
    $script:caseDeadlineUtc=[DateTime]::UtcNow.AddSeconds(30)
}

function Assert-TestCaseWithinLimit {
    if ($null -eq $script:caseStopwatch) { return }
    $script:caseStopwatch.Stop()
    $elapsed=$script:caseStopwatch.Elapsed.TotalSeconds
    $status=if($elapsed -le 30){'completed-within-limit'}else{'exceeded-limit'}
    $script:caseTimings.Add([pscustomobject]@{name=$script:caseName;elapsedSeconds=$elapsed;maxSeconds=30;status=$status})
    if ($elapsed -gt 30) { throw "Scheduled-process case exceeded its measured 30-second limit: $script:caseName ($elapsed seconds)." }
}

function Get-TestCaseTimeout([double]$RequestedSeconds) {
    if ($null -eq $script:caseDeadlineUtc) { return $RequestedSeconds }
    $remaining=($script:caseDeadlineUtc-[DateTime]::UtcNow).TotalSeconds
    if ($remaining -le 0.2) { throw "Scheduled-process case has no bounded time remaining: $script:caseName" }
    return [Math]::Min($RequestedSeconds,$remaining-0.1)
}

function Read-JsonPreservingDateStrings([string]$Path) {
    $raw=[IO.File]::ReadAllText($Path)
    $convertFromJson=Get-Command ConvertFrom-Json
    if ($convertFromJson.Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $raw -DateKind String
    }
    $value=ConvertFrom-Json -InputObject $raw
    $timestamp=[regex]::Match($raw,'"processStartTimeUtc"\s*:\s*"([^"\\]*)"')
    if ($timestamp.Success) {
        $value.processStartTimeUtc=$timestamp.Groups[1].Value
    }
    return $value
}

function Assert-EvidenceFolderAvailable([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $fullPath=[IO.Path]::GetFullPath($Path)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $tempPrefix=$tempRoot+[IO.Path]::DirectorySeparatorChar
    if ($fullPath.Equals($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'EvidenceFolder must be outside the system temporary directory.'
    }
    if (Test-Path -LiteralPath $fullPath) {
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { throw 'EvidenceFolder exists and is not a directory.' }
        if (@(Get-ChildItem -LiteralPath $fullPath -Force).Count -gt 0) { throw 'EvidenceFolder must be empty.' }
    }
}

function Copy-TestEvidence([string]$SourceFolder,[string]$DestinationFolder) {
    if ([string]::IsNullOrWhiteSpace($DestinationFolder)) { return }
    Assert-EvidenceFolderAvailable $DestinationFolder
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

function Add-ScheduledLaunch([string]$Name,[object]$Launch) {
    $root=Get-OwnedProcessHandle ([int]$Launch.rootProcessId) ([string]$Launch.processStartTimeUtc)
    [void]$script:ownedChildren.Add($root)
    Add-FixtureProcess ($Name+'-root') $root
    $worker=Get-OwnedProcessHandle ([int]$Launch.workerProcessId) ([string]$Launch.workerProcessStartTimeUtc)
    [void]$script:ownedChildren.Add($worker)
    Add-FixtureProcess ($Name+'-worker') $worker
    return $root
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

function Get-OwnedProcessHandle([int]$ProcessId,[string]$ExpectedStartTimeUtc) {
    $process=Get-Process -Id $ProcessId -ErrorAction Stop
    try {
        $null=$process.Handle
        $expected=[DateTimeOffset]::Parse($ExpectedStartTimeUtc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $actual=$process.StartTime.ToUniversalTime()
        if ($actual.Ticks -ne $expected.Ticks) { throw "Process identity mismatch for PID $ProcessId." }
        return $process
    } catch {
        $process.Dispose()
        throw
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
            $waitMilliseconds=5000
            if ($null -ne $script:caseDeadlineUtc) {
                $remaining=($script:caseDeadlineUtc-[DateTime]::UtcNow).TotalMilliseconds
                $waitMilliseconds=[int][Math]::Max(0,[Math]::Min($waitMilliseconds,$remaining))
            }
            if ($waitMilliseconds -gt 0) { [void]$Process.WaitForExit($waitMilliseconds) }
        }
    } catch {
        Write-Warning "Owned process handle cleanup failed for PID $($Process.Id): $($_.Exception.Message)"
    }
}

if ($Controller) {
    $controllerConfig=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $launch=& ([string]$controllerConfig.wrapper) `
        -Executable ([string]$controllerConfig.executable) `
        -Arguments ([string]$controllerConfig.arguments) `
        -WorkingDirectory ([string]$controllerConfig.workingDirectory) `
        -OutputFolder ([string]$controllerConfig.outputFolder) `
        -SampleIntervalSeconds 0.1 -HeartbeatSeconds 0.2 `
        -StartupWaitSeconds ([int]$controllerConfig.startupWaitSeconds) `
        -NoProgressWarningSeconds 10
    Write-JsonFile ([string]$controllerConfig.launchResult) $launch
    Start-Sleep -Seconds 30
    exit 0
}

$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$wrapper=Join-Path $PSScriptRoot 'InvokeScheduledProcess.ps1'
$legacyTest=Join-Path $PSScriptRoot 'testBoundedProcess.ps1'
Assert-EvidenceFolderAvailable $EvidenceFolder
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('nbiot-scheduled-test-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
$shellExe=(Get-Process -Id $PID).Path
$controllerProcess=$null
$otherProcess=$null
$testPassed=$false
$evidenceError=$null
$cleanupError=$null
$script:caseDeadlineUtc=$null
$script:caseName=''
$script:caseStopwatch=$null
$script:caseTimings=[System.Collections.Generic.List[object]]::new()
$script:fixtureIdentities=[System.Collections.Generic.List[object]]::new()
$script:ownedChildren=[System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$ownedChildren=$script:ownedChildren
try {
    $sleepScript=Join-Path $testRoot 'sleep.ps1'
    Set-Content -LiteralPath $sleepScript -Value @'
Start-Sleep -Seconds 4
Write-Output 'scheduled-child-done'
exit 0
'@ -Encoding UTF8
    $childArguments="-NoProfile -ExecutionPolicy Bypass -File `"$sleepScript`""
    $progressFile=Join-Path $testRoot 'stale-progress.json'
    Write-JsonFile $progressFile ([ordered]@{
        phase='test-long-step';currentTick=7;lastCheckpoint='';
        updatedAtUtc=[DateTime]::UtcNow.ToString('o')
    })

    $warningFolder=Join-Path $testRoot 'warning-run'
    Start-TestCase 'warning heartbeat'
    $warningLaunch=& $wrapper -Executable $shellExe -Arguments $childArguments `
        -WorkingDirectory $testRoot -OutputFolder $warningFolder `
        -ProgressFile $progressFile -SampleIntervalSeconds 0.1 `
        -HeartbeatSeconds 0.2 -NoProgressWarningSeconds 1 -StartupWaitSeconds 10
    $warningChild=Add-ScheduledLaunch 'warning' $warningLaunch
    if (-not (Test-Path -LiteralPath $warningLaunch.stdout -PathType Leaf) -or
        -not (Test-Path -LiteralPath $warningLaunch.stderr -PathType Leaf) -or
        -not (Test-Path -LiteralPath $warningLaunch.processStarted -PathType Leaf) -or
        [string]::IsNullOrWhiteSpace([string]$warningLaunch.runId) -or
        [string]::IsNullOrWhiteSpace([string]$warningLaunch.processStartTimeUtc)) {
        throw 'Scheduled launch did not record the run identity, PID, creation time and child logs before returning.'
    }
    Wait-File $warningLaunch.processReport 15
    $warningReport=Get-Content -LiteralPath $warningLaunch.processReport -Raw | ConvertFrom-Json
    $heartbeat=Get-Content -LiteralPath $warningLaunch.heartbeat -Raw | ConvertFrom-Json
    if ($warningReport.status -ne 'completed' -or $warningReport.exitCode -ne 0 -or
        -not $warningReport.progressWarningIssued -or
        -not (Test-Path -LiteralPath $warningLaunch.memoryCsv -PathType Leaf) -or
        -not (Test-Path -LiteralPath $warningLaunch.progressFile -PathType Leaf) -or
        $heartbeat.progressPhase -ne 'test-long-step' -or
        -not ($warningReport.maximumDescription -like '*sampled*')) {
        throw ('Warning-threshold run failed or was terminated: '+($warningReport|ConvertTo-Json -Compress))
    }
    $childOutput=Get-Content -LiteralPath $warningLaunch.stdout -Raw
    if ($childOutput -notmatch 'scheduled-child-done') { throw 'Child stdout was not retained.' }
    Assert-TestCaseWithinLimit

    Start-TestCase 'detached controller lifecycle'
    $controllerChild=Join-Path $testRoot 'controller-child.ps1'
    Set-Content -LiteralPath $controllerChild -Value @'
Start-Sleep -Seconds 4
Write-Output 'controller-child-done'
exit 0
'@ -Encoding UTF8
    $controllerChildArguments="-NoProfile -ExecutionPolicy Bypass -File `"$controllerChild`""
    $controllerFolder=Join-Path $testRoot 'controller-run'
    $controllerResult=Join-Path $testRoot 'controller-launch.json'
    $controllerConfig=Join-Path $testRoot 'controller-config.json'
    Write-JsonFile $controllerConfig ([ordered]@{
        wrapper=$wrapper
        executable=$shellExe
        arguments=$controllerChildArguments
        workingDirectory=$testRoot
        outputFolder=$controllerFolder
        launchResult=$controllerResult
        startupWaitSeconds=10
    })
    $controllerArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),
        '-Controller','-ConfigPath',('"{0}"' -f $controllerConfig))
    $controllerProcess=Start-Process -FilePath $shellExe -ArgumentList $controllerArgs `
        -WorkingDirectory $testRoot -WindowStyle Hidden -PassThru
    $null=$controllerProcess.Handle
    Add-FixtureProcess 'detached-controller' $controllerProcess
    Wait-File $controllerResult 15
    $controllerLaunch=Read-JsonPreservingDateStrings $controllerResult
    $controllerChildProcess=Add-ScheduledLaunch 'controller-child' $controllerLaunch
    $otherScript=Join-Path $testRoot 'unrelated.ps1'
    Set-Content -LiteralPath $otherScript -Value 'Start-Sleep -Seconds 20' -Encoding UTF8
    $otherArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $otherScript))
    $otherProcess=Start-Process -FilePath $shellExe -ArgumentList $otherArgs `
        -WorkingDirectory $testRoot -WindowStyle Hidden -PassThru
    $null=$otherProcess.Handle
    Add-FixtureProcess 'unrelated-sentinel' $otherProcess
    $controllerProcess.Kill()
    if (-not $controllerProcess.WaitForExit(5000) -or -not (Test-ProcessHandleAlive $controllerChildProcess)) {
        throw 'The test controller did not exit cleanly or its scheduled child did not survive.'
    }
    if ($otherProcess.HasExited) { throw 'The unrelated process was stopped.' }
    Wait-File $controllerLaunch.processReport 15
    $controllerReport=Get-Content -LiteralPath $controllerLaunch.processReport -Raw | ConvertFrom-Json
    if ($controllerReport.status -ne 'completed' -or $controllerReport.exitCode -ne 0) {
        throw ('The process did not finish after controller exit: '+($controllerReport|ConvertTo-Json -Compress))
    }
    if ((Get-Content -LiteralPath $controllerLaunch.stdout -Raw) -notmatch 'controller-child-done') {
        throw 'Detached child stdout was not retained.'
    }
    Assert-TestCaseWithinLimit

    $blockedSampler=Join-Path $testRoot 'sampler-blocked'
    New-Item -ItemType Directory -Path $blockedSampler | Out-Null
    $samplerFolder=Join-Path $testRoot 'sampler-error-run'
    Start-TestCase 'sampler failure'
    $samplerLaunch=& $wrapper -Executable $shellExe -Arguments $childArguments `
        -WorkingDirectory $testRoot -OutputFolder $samplerFolder `
        -MemoryCsvPath $blockedSampler -SampleIntervalSeconds 0.1 `
        -HeartbeatSeconds 0.2 -NoProgressWarningSeconds 10 -StartupWaitSeconds 10
    $samplerChild=Add-ScheduledLaunch 'sampler' $samplerLaunch
    Wait-File $samplerLaunch.processReport 15
    $samplerReport=Get-Content -LiteralPath $samplerLaunch.processReport -Raw | ConvertFrom-Json
    $workerLog=Get-Content -LiteralPath (Join-Path $samplerFolder 'worker.log') -Raw
    if ($samplerReport.status -ne 'completed' -or $samplerReport.exitCode -ne 0 -or
        [string]::IsNullOrWhiteSpace([string]$samplerReport.samplerError) -or
        $workerLog -notmatch 'SAMPLER_ERROR' -or
        (Get-Content -LiteralPath $samplerLaunch.stdout -Raw) -notmatch 'scheduled-child-done') {
        throw ('Sampler failure terminated or lost the scheduled process: '+($samplerReport|ConvertTo-Json -Compress))
    }
    Assert-TestCaseWithinLimit

    Start-TestCase 'legacy bounded process'
    & $legacyTest -MaxSeconds (Get-TestCaseTimeout 30) -EvidenceFolder (Join-Path $testRoot 'legacy-bounded-evidence')
    Assert-TestCaseWithinLimit
    $testPassed=$true
    Write-Output 'SCHEDULED_PROCESS_TESTS passed=4 detached-lifecycle=1 sampler-failure=1 legacy-bounded=5'
} catch {
    Write-Output ("SCHEDULED_PROCESS_FAILURE="+$_.Exception.ToString())
    throw
} finally {
    if ($null -ne $controllerProcess) {
        Stop-ProcessHandle $controllerProcess
        $controllerProcess.Dispose()
    }
    foreach ($ownedProcess in $ownedChildren) {
        Stop-ProcessHandle $ownedProcess
        $ownedProcess.Dispose()
    }
    if ($null -ne $otherProcess) {
        Stop-ProcessHandle $otherProcess
        $otherProcess.Dispose()
    }
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
    if ($null -ne $script:caseStopwatch -and $script:caseStopwatch.IsRunning) {
        $script:caseStopwatch.Stop()
        $elapsed=$script:caseStopwatch.Elapsed.TotalSeconds
        $status=if($elapsed -le 30){'failed-within-limit'}else{'exceeded-limit'}
        $script:caseTimings.Add([pscustomobject]@{name=$script:caseName;elapsedSeconds=$elapsed;maxSeconds=30;status=$status})
    }
    try {
        Write-JsonFile (Join-Path $testRoot 'scenario-timing.json') ([ordered]@{schemaVersion=1;maxScenarioSeconds=30;scenarios=@($script:caseTimings)})
    } catch { $cleanupError="Scenario timing report could not be written: $($_.Exception.Message)" }
    $resolvedTestRoot=(Resolve-Path -LiteralPath $testRoot).Path
    $tempRoot=[IO.Path]::GetTempPath()
    $evidenceCopied=[string]::IsNullOrWhiteSpace($EvidenceFolder)
    if (-not [string]::IsNullOrWhiteSpace($EvidenceFolder)) {
        try {
            Copy-TestEvidence $resolvedTestRoot $EvidenceFolder
            $evidenceCopied=$true
        } catch {
            $evidenceError=$_.Exception
            Write-Warning "Test evidence copy failed; temp artifacts preserved at $resolvedTestRoot : $($_.Exception.Message)"
        }
    }
    if ($resolvedTestRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and $testPassed -and $evidenceCopied) {
        try { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
        catch { Write-Warning "Test temp cleanup deferred: $($_.Exception.Message)" }
    } elseif ($resolvedTestRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "Test artifacts preserved for diagnosis: $resolvedTestRoot"
    }
}
if ($null -ne $evidenceError) { throw "Test evidence could not be retained: $($evidenceError.Message)" }
if ($null -ne $cleanupError) { throw $cleanupError }
