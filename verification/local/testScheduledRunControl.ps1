param([string]$OutputFolder='', [string]$ScenarioPattern='.*', [switch]$IsolatedScenario)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/fixtures/scheduledRunStub.ps1" -Mode Library
Initialize-FixtureSuite 'control spaces' $OutputFolder
$script:scenarioPattern=$ScenarioPattern
$script:isolatedScenario=[bool]$IsolatedScenario; $script:testEntry=$PSCommandPath; $script:suiteArtifact='control-scenarios.json'
$control=Join-Path $PSScriptRoot 'ControlScheduledRun.ps1'

function Read-RawIdentityString([string]$Path,[string]$Field) {
    # Read timestamp text before ConvertFrom-Json can coerce ISO strings to DateTime.
    $raw=[IO.File]::ReadAllText($Path)
    $match=[regex]::Match($raw,'"'+[regex]::Escape($Field)+'"\s*:\s*"([^"\\]*)"')
    Assert-True $match.Success "Missing raw identity string $Field in $Path"
    return $match.Groups[1].Value
}

function Read-FixtureTextForAtomicHeartbeat([string]$Path,[double]$TimeoutSeconds=2) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $stream=$null; $reader=$null
        try {
            $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
            $reader=[IO.StreamReader]::new($stream)
            return $reader.ReadToEnd()
        } catch {
            if ($_.Exception.GetBaseException() -isnot [IO.IOException]) { throw }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw }
            Start-Sleep -Milliseconds 25
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            elseif ($null -ne $stream) { $stream.Dispose() }
        }
    }
    throw [TimeoutException]::new('Heartbeat remained unavailable during atomic publication.')
}

function Get-ControlFixtureSourceManifestSha256([string]$ProjectRoot) {
    $root=(Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path.TrimEnd('\')
    $sourceRoot=Join-Path $root 'src'
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw 'Computational source folder is missing.' }
    foreach ($directory in @(Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Force -ErrorAction Stop)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Computational source tree contains a reparse point.' }
    }
    $files=[Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.m' -File -Recurse -Force -ErrorAction Stop)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Computational source file is a reparse point.' }
        $full=[IO.Path]::GetFullPath($file.FullName)
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Computational source escapes the project root.' }
        $relative=$full.Substring($prefix.Length).Replace('\','/')
        $files.Add($relative,(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    foreach ($entryPoint in @('setupProject.m','experiments/runStaticSweep.m','experiments/runStaticSweepParallel.m','experiments/optimizationSourceManifest.m')) {
        $full=Join-Path $root ($entryPoint.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Required source entry point is missing: $entryPoint" }
        $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Source entry point is a reparse point: $entryPoint" }
        $canonical=[IO.Path]::GetFullPath($item.FullName)
        if (-not $canonical.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Source entry point escapes the project root: $entryPoint" }
        $relative=$canonical.Substring($prefix.Length).Replace('\','/')
        $files[$relative]=(Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $canonicalText=[Text.StringBuilder]::new()
    foreach ($relative in $files.Keys) {
        [void]$canonicalText.Append($relative); [void]$canonicalText.Append([char]0)
        [void]$canonicalText.Append($files[$relative]); [void]$canonicalText.Append([char]10)
    }
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($canonicalText.ToString())
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Set-ControlFixtureSourceProof($Fixture) {
    $projectRoot=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..') -ErrorAction Stop).Path
    $sourceManifestSha=Get-ControlFixtureSourceManifestSha256 $projectRoot
    $runnerPath=Join-Path $projectRoot 'experiments\runLoadProbe.m'
    $runnerSha=(Get-FileHash -LiteralPath $runnerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $probe=Join-Path $Fixture.run 'probe'
    $proof=@{runFolder=$probe;sourceManifestSha256=$sourceManifestSha;runnerSha256=$runnerSha}
    Write-FixtureJson (Join-Path $probe 'progress.json') $proof
    Write-FixtureJson (Join-Path $probe 'preflight.json') (@{status='passed';sourceManifestSha256=$sourceManifestSha;runnerSha256=$runnerSha})
}

Invoke-FixtureScenario 'inspect and resume are read only' {
    $fixture=$null
    try {
        $fixture=New-FixtureRun
        Set-ControlFixtureSourceProof $fixture
        $attemptId=[guid]::NewGuid().ToString()
        $caseKey='fractional-inspect-case'
        $attempt=[pscustomobject]@{attemptId=$attemptId;runId=$fixture.launch.runId;caseKey=$caseKey;
            startedAtUtc=$fixture.launch.processStartTimeUtc;finishedAtUtc='';status='active';
            observedSeconds=12.5;chargedSeconds=0;processReportSha256=''}
        $ledger=Read-FixtureJson $fixture.ledger
        $ledger|Add-Member -NotePropertyName accountingVersion -NotePropertyValue 2 -Force
        $ledger.attempts=@($attempt)
        $ledger.activeCase=[pscustomobject]@{attemptId=$attemptId;runId=$fixture.launch.runId;caseKey=$caseKey;startedAtUtc=$fixture.launch.processStartTimeUtc}
        Write-FixtureJson $fixture.ledger $ledger
        $observationPath=Join-Path $fixture.processFolder 'accounting-observation.json'
        Write-FixtureJson $observationPath @{runId=$fixture.launch.runId;attemptId=$attemptId;caseKey=$caseKey;
            observedAtUtc=[DateTime]::UtcNow.ToString('o');observedSeconds=12.5}
        $before=(Get-FileHash -LiteralPath $fixture.ledger).Hash
        $observationHash=(Get-FileHash -LiteralPath $observationPath).Hash
        $launchHash=(Get-FileHash -LiteralPath (Join-Path $fixture.processFolder 'launch.json')).Hash
        $inspect=Invoke-FixtureCli $control "-Action inspect -RunFolder `"$($fixture.run)`""
        Assert-Equal 0 $inspect.exitCode 'Inspect exit.'
        Assert-Equal 100 $inspect.json.committedSeconds 'Inspect persisted committed seconds.'
        Assert-Equal 112.5 $inspect.json.estimatedSeconds 'Inspect must preserve fractional observed seconds.'
        Assert-Equal 'estimated' $inspect.json.estimateLabel 'Inspect must label uncommitted observation as estimated.'
        $resume=Invoke-FixtureCli $control "-Action resume -RunFolder `"$($fixture.run)`""
        Assert-Equal $false $resume.json.resumeAllowed 'Live run must not resume.'
        Assert-True ([string]::IsNullOrWhiteSpace([string]$resume.json.resumeCommand)) 'Unsafe resume command returned.'
        Assert-Equal $before (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Read-only ledger.'
        Assert-Equal $observationHash (Get-FileHash -LiteralPath $observationPath).Hash 'Read-only observation.'
        Assert-Equal $launchHash (Get-FileHash -LiteralPath (Join-Path $fixture.processFolder 'launch.json')).Hash 'Read-only launch.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.processFolder 'control-request.json'))) 'Inspect/resume wrote request.'
    } finally { Close-FixtureRun $fixture }
}

foreach ($corruption in @('start time','run identity')) {
    Invoke-FixtureScenario "reject wrong $corruption" {
        $fixture=$null; $original=$null
        try {
            $fixture=New-FixtureRun
            $started=Join-Path $fixture.processFolder 'process-started.json'
            $original=[IO.File]::ReadAllText($started); $bad=$original|ConvertFrom-Json
            if ($corruption -eq 'start time') { $bad.processStartTimeUtc='2000-01-01T00:00:00.0000000Z' }
            else { $bad.runId=[guid]::NewGuid().ToString('N') }
            Write-FixtureJson $started $bad
            $result=Invoke-FixtureCli $control "-Action cancel -RunFolder `"$($fixture.run)`""
            Assert-True ($result.exitCode -ne 0) 'Identity conflict must fail.'
            Assert-Equal 'rejected' $result.json.status 'Identity conflict status.'
            Assert-True (Test-FixtureAlive $fixture.launch.rootProcessId $fixture.launch.processStartTimeUtc) 'Rejected control stopped root.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.processFolder 'control-request.json'))) 'Rejected identity wrote request.'
        } finally {
            if ($null -ne $original) { [IO.File]::WriteAllText($started,$original) }
            Close-FixtureRun $fixture
        }
    }
}

Invoke-FixtureScenario 'stop during finalizing and replay request' {
    $fixture=$null
    try {
        $fixture=New-FixtureRun -WithTwoCases
        [IO.File]::WriteAllText((Join-Path $fixture.run 'release case.request'),'release')
        Wait-FixtureFile (Join-Path $fixture.run 'finalizing ready.json')
        $result=Invoke-FixtureCli $control "-Action stop-after-case -RunFolder `"$($fixture.run)`""
        Assert-Equal 0 $result.exitCode 'Stop request exit.'
        $marker=Join-Path $fixture.run 'stop-after-case.request.json'
        Wait-FixtureFile $marker
        $requestPath=Join-Path $fixture.processFolder 'control-request.json'
        Wait-FixtureFile $requestPath
        $request=Read-FixtureJson $requestPath
        foreach ($field in @('schemaVersion','requestId','runId','action','requestedAtUtc','rootProcessId','processStartTimeUtc','workerProcessId','workerProcessStartTimeUtc')) {
            Assert-True ($null -ne $request.$field) "Missing request field $field"
        }
        $ackPath=Join-Path $fixture.processFolder 'control-ack.json'
        Wait-Fixture { if (Test-Path -LiteralPath $ackPath) { (Read-FixtureJson $ackPath).requestId -eq $request.requestId } } 'request ack'
        Assert-Equal 'applied' (Read-FixtureJson $ackPath).status 'Stop ack.'
        $markerHash=(Get-FileHash -LiteralPath $marker).Hash
        Write-FixtureJson $requestPath $request
        Start-Sleep -Milliseconds 300
        Assert-Equal $markerHash (Get-FileHash -LiteralPath $marker).Hash 'Replay changed persistent stop marker.'
        Close-FixtureRun $fixture
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.run 'case complete.json')) 'Current finalization was interrupted.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.run 'case 2 started.json'))) 'Next case admitted.'
        Assert-True (Test-Path -LiteralPath $marker) 'Worker removed persistent stop marker.'
    } finally { Close-FixtureRun $fixture }
}

Invoke-FixtureScenario 'cancel owned child leaves sentinel alive' {
    $fixture=$null; $sentinel=$null
    try {
        $sentinel=Start-FixtureOwned "-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode Sentinel -Folder `"$script:scenarioFolder`" -MaxSeconds 25" 'sentinel'
        Wait-FixtureFile (Join-Path $script:scenarioFolder 'Sentinel started.json')
        $fixture=New-FixtureRun -WithChild
        Wait-FixtureFile (Join-Path $fixture.run 'Child started.json')
        $child=Read-FixtureJson (Join-Path $fixture.run 'Child started.json')
        [IO.File]::WriteAllText((Join-Path $fixture.run 'release case.request'),'release')
        Wait-FixtureFile (Join-Path $fixture.run 'finalizing ready.json')
        $result=Invoke-FixtureCli $control "-Action cancel -RunFolder `"$($fixture.run)`""
        Assert-Equal 0 $result.exitCode 'Cancel exit.'
        Wait-FixtureFile $fixture.launch.processReport
        $report=Read-FixtureJson $fixture.launch.processReport
        Assert-Equal 'cancelled' $report.status 'Cancel report status.'
        Assert-Equal 'explicit-request' $report.reason 'Cancel report reason.'
        Assert-True (-not (Test-FixtureAlive $fixture.launch.rootProcessId $fixture.launch.processStartTimeUtc)) 'Root survived cancel.'
        Wait-Fixture { -not (Test-FixtureAlive $child.processId $child.processStartTimeUtc) } 'owned child termination'
        Assert-True (-not $sentinel.RootExited) 'Cancel affected unrelated sentinel.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.run 'case complete.json'))) 'Cancelled finalization created completion marker.'
    } finally {
        Close-FixtureRun $fixture
        if ($null -ne $sentinel) { if (-not $sentinel.RootExited) { $sentinel.Stop() } }
    }
}

Invoke-FixtureScenario 'heartbeat age warns without automatic stop' {
    $fixture=$null
    try {
        $fixture=New-FixtureRun -WarningSeconds 0.4
        $warning=Join-Path $fixture.processFolder 'no-progress-warning.json'
        Wait-FixtureFile $warning
        $value=Read-FixtureJson $warning
        Assert-Equal 'needs-attention' $value.status 'No progress status.'
        $json=$value|ConvertTo-Json -Depth 12
        Assert-True ($json.Contains('-Action inspect') -and $json.Contains('-Action cancel')) 'Warning lacks actionable control commands.'
        Assert-True (Test-FixtureAlive $fixture.launch.rootProcessId $fixture.launch.processStartTimeUtc) 'Warning automatically killed root.'
        # The warning records the interval that triggered it. A later heartbeat
        # can legitimately reset its age when result-finalizing begins.
        Assert-Equal 'simulating' $value.phase 'Canonical phase recorded by warning.'
        Assert-Equal 1 $value.currentTick 'Tick recorded by warning.'
        Assert-True ($value.unchangedSeconds -ge 0.4) 'Warning did not retain the threshold-crossing unchanged interval.'
    } finally { Close-FixtureRun $fixture }
}
Invoke-FixtureScenario 'worker survives natural launcher exit' {
    $launcher=$null; $launch=$null
    $run=Join-Path $script:scenarioFolder 'run folder'; $probe=Join-Path $run 'probe'
    [void][IO.Directory]::CreateDirectory($probe)
    $controlledFolder=Join-Path $run 'controlled progress'
    [void][IO.Directory]::CreateDirectory($controlledFolder)
    $controlledProgress=Join-Path $controlledFolder 'worker-progress.json'
    try {
        Write-FixtureJson (Join-Path $run 'launcher options.json') @{
            wrapper=(Join-Path $script:localFolder 'InvokeScheduledProcess.ps1');executable=$script:shellExe;
            arguments="-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode Case -Folder `"$run`" -MaxSeconds 18";
            outputFolder=(Join-Path $run 'workers/process folder');progressFile=$controlledProgress}
        $launcher=Start-FixtureOwned "-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode Launcher -Folder `"$run`"" 'launcher'
        Wait-FixtureFile (Join-Path $run 'launcher result.json') 8
        $launch=Read-FixtureJson (Join-Path $run 'launcher result.json')
        Wait-Fixture { $launcher.RootExited } 'launcher exits naturally'
        Wait-FixtureFile $launch.heartbeat
        $first=Read-FixtureTextForAtomicHeartbeat $launch.heartbeat
        Wait-Fixture { (Read-FixtureTextForAtomicHeartbeat $launch.heartbeat) -ne $first } 'heartbeat after launcher exit'
        $processFolder=Join-Path $run 'workers/process folder'
        $startedPath=Join-Path $processFolder 'process-started.json'
        $rootStart=Read-RawIdentityString $startedPath 'processStartTimeUtc'
        $workerStart=Read-RawIdentityString $startedPath 'workerProcessStartTimeUtc'
        foreach ($timestamp in @($rootStart,$workerStart)) {
            Assert-True ($timestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') 'Process record must retain exact round-trip UTC ISO identity.'
        }
        Assert-True (Test-FixtureAlive $launch.rootProcessId $rootStart) 'Launcher exit stopped root (exact process-started ISO tuple).'
        Assert-True (Test-FixtureAlive $launch.workerProcessId $workerStart) 'Launcher exit stopped worker (exact process-started ISO tuple).'
        $launchPath=Join-Path $processFolder 'launch.json'
        Assert-Equal $rootStart (Read-RawIdentityString $launchPath 'processStartTimeUtc') 'Launcher lost exact root ISO identity; localized timestamp is unsafe.'
        Assert-Equal $workerStart (Read-RawIdentityString $launchPath 'workerProcessStartTimeUtc') 'Launcher lost exact worker ISO identity; localized timestamp is unsafe.'
        Assert-Equal $controlledProgress $launch.progressFile 'Worker must observe the controlled progress path, separate from the case stub.'
        # The case stub owns probe/worker-progress.json; only this test writes
        # the separate activeCase source consumed by accounting observation.
        $attemptId=[guid]::NewGuid().ToString(); $caseKey='fractional-worker-observation'
        $caseStart=[DateTimeOffset]::UtcNow.AddSeconds(-12.25).UtcDateTime.ToString('o')
        Write-FixtureJson $controlledProgress @{schemaVersion=2;phase='simulating';currentTick=1;updatedAtUtc=[DateTime]::UtcNow.ToString('o')}
        Write-FixtureJson (Join-Path $controlledFolder 'progress.json') @{activeCase=@{
            runId=$launch.runId;attemptId=$attemptId;caseKey=$caseKey;startedAtUtc=$caseStart}}
        $observationPath=Join-Path $processFolder 'accounting-observation.json'
        Wait-FixtureFile $observationPath
        $observation=Read-FixtureJson $observationPath
        Assert-Equal $launch.runId $observation.runId 'Worker observation runId.'
        Assert-Equal $attemptId $observation.attemptId 'Worker observation attemptId.'
        Assert-Equal $caseKey $observation.caseKey 'Worker observation caseKey.'
        $observedSeconds=[double]$observation.observedSeconds
        Assert-True ($observedSeconds -gt 0) 'Worker observation must contain a positive interval.'
        Assert-True (($observedSeconds-[Math]::Truncate($observedSeconds)) -gt 0) 'Worker observation must preserve a nonzero fractional component; integer Math.Max overload truncates elapsed seconds.'
    } finally {
        if ($null -ne $launch) { Close-FixtureRun ([pscustomobject]@{run=$run;launch=$launch}) }
        if ($null -ne $launcher) { $launcher.Stop() }
    }
}
foreach ($corruption in @('worker start','executable','command line','unreadable identity','foreign live tuple')) {
    Invoke-FixtureScenario "identity negative $corruption" {
        $fixture=$null; $lock=$null
        try {
            $fixture=New-FixtureRun
            $startedPath=Join-Path $fixture.processFolder 'process-started.json'
            $launchPath=Join-Path $fixture.processFolder 'launch.json'
            $workerPath=Join-Path $fixture.run 'worker.json'
            $started=Read-FixtureJson $startedPath; $launch=Read-FixtureJson $launchPath; $worker=Read-FixtureJson $workerPath
            $sentinel=Start-FixtureOwned "-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode Sentinel -Folder `"$script:scenarioFolder`" -MaxSeconds 25" 'identity sentinel'
            Wait-FixtureFile (Join-Path $script:scenarioFolder 'Sentinel started.json')
            $foreign=Read-FixtureJson (Join-Path $script:scenarioFolder 'Sentinel started.json')
            switch ($corruption) {
                'worker start' { $started.workerProcessStartTimeUtc='2000-01-01T00:00:00.0000000Z'; $launch.workerProcessStartTimeUtc=$started.workerProcessStartTimeUtc; $worker.workerProcessStartTimeUtc=$started.workerProcessStartTimeUtc }
                'executable' { $started.executable='C:\fixture missing executable.exe'; $launch.executable=$started.executable; $worker.executable=$started.executable }
                'command line' { $started.rootCommandLine='fixture mismatched command line'; $worker.matlabCommandLine=$started.rootCommandLine }
                'foreign live tuple' { $started.rootProcessId=$foreign.processId; $started.processStartTimeUtc=$foreign.processStartTimeUtc; $launch.rootProcessId=$foreign.processId; $launch.processStartTimeUtc=$foreign.processStartTimeUtc; $worker.matlabProcessId=$foreign.processId; $worker.matlabProcessStartTimeUtc=$foreign.processStartTimeUtc }
            }
            Write-FixtureJson $startedPath $started; Write-FixtureJson $launchPath $launch; Write-FixtureJson $workerPath $worker
            if ($corruption -eq 'unreadable identity') { $lock=[IO.File]::Open($startedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None) }
            $result=Invoke-FixtureCli $control "-Action cancel -RunFolder `"$($fixture.run)`""
            Assert-True ($result.exitCode -ne 0) 'Unsafe identity accepted.'
            Assert-Equal 'rejected' $result.json.status 'Identity rejection JSON.'
            Assert-True (Test-FixtureAlive $fixture.launch.rootProcessId $fixture.launch.processStartTimeUtc) 'Real fixture root stopped.'
            Assert-True (Test-FixtureAlive $fixture.launch.workerProcessId $fixture.launch.workerProcessStartTimeUtc) 'Real fixture worker stopped.'
            Assert-True (-not $sentinel.RootExited) 'Foreign sentinel stopped.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.processFolder 'control-request.json'))) 'Rejected control wrote request.'
        } finally { if ($null -ne $lock) { $lock.Dispose() }; Close-FixtureRun $fixture }
    }
}
Invoke-FixtureScenario 'forged request rejected without side effect' {
    $fixture=$null
    try {
        $fixture=New-FixtureRun
        $request=[ordered]@{schemaVersion=1;requestId=[guid]::NewGuid().ToString();runId=$fixture.launch.runId;action='cancel';requestedAtUtc=[DateTime]::UtcNow.ToString('o');rootProcessId=$PID;processStartTimeUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');workerProcessId=$fixture.launch.workerProcessId;workerProcessStartTimeUtc=$fixture.launch.workerProcessStartTimeUtc}
        $path=Join-Path $fixture.processFolder 'control-request.json'
        Write-FixtureJson $path $request
        $ackPath=Join-Path $fixture.processFolder 'control-ack.json'
        Wait-FixtureFile $ackPath
        $ack=Read-FixtureJson $ackPath
        Assert-Equal $request.requestId $ack.requestId 'Forged request ack identity.'
        Assert-Equal 'rejected' $ack.status 'Forged request accepted.'
        Assert-True (Test-FixtureAlive $fixture.launch.rootProcessId $fixture.launch.processStartTimeUtc) 'Forged request killed root.'
        Assert-True (Test-FixtureAlive $fixture.launch.workerProcessId $fixture.launch.workerProcessStartTimeUtc) 'Forged request killed worker.'
        $ackHash=(Get-FileHash -LiteralPath $ackPath).Hash
        Write-FixtureJson $path $request; Start-Sleep -Milliseconds 300
        Assert-Equal $ackHash (Get-FileHash -LiteralPath $ackPath).Hash 'Repeated rejected request changed acknowledgement.'
    } finally { Close-FixtureRun $fixture }
}
Invoke-FixtureScenario 'atomic publications remain readable' {
    $fixture=$null
    try {
        $fixture=New-FixtureRun
        $paths=@((Join-Path $fixture.processFolder 'control-request.json'),$fixture.launch.heartbeat,$fixture.launch.processReport)
        Write-FixtureJson (Join-Path $script:scenarioFolder 'reader options.json') @{paths=$paths;runId=$fixture.launch.runId;rootProcessId=$fixture.launch.rootProcessId}
        $reader=Start-FixtureOwned "-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode Reader -Folder `"$script:scenarioFolder`" -MaxSeconds 15" 'atomic reader'
        Wait-FixtureFile (Join-Path $script:scenarioFolder 'reader ready.json')
        Assert-Equal 0 (Invoke-FixtureCli $control "-Action stop-after-case -RunFolder `"$($fixture.run)`"").exitCode 'Atomic stop request exit.'
        Start-Sleep -Milliseconds 400
        Close-FixtureRun $fixture
        $countsPath=Join-Path $script:scenarioFolder 'reader counts.json'
        Wait-Fixture {
            if (-not (Test-Path -LiteralPath $countsPath)) { return $false }
            $counts=Read-FixtureJson $countsPath
            foreach($path in $paths) { if ([int]$counts.successfulReads.PSObject.Properties[$path].Value -lt 1) { return $false } }
            return $true
        } 'successful JSON read of every published control-request, heartbeat and process-report'
        [IO.File]::WriteAllText((Join-Path $script:scenarioFolder 'release reader.request'),'release')
        Wait-FixtureFile (Join-Path $script:scenarioFolder 'reader result.json')
        $result=Read-FixtureJson (Join-Path $script:scenarioFolder 'reader result.json')
        Assert-True ($result.reads -gt 0) 'Concurrent reader performed no reads.'
        foreach($path in $paths) {
            Assert-True ([int]$result.successfulReads.PSObject.Properties[$path].Value -ge 1) "Concurrent reader never successfully parsed $path"
        }
        Assert-Equal 0 @($result.errors).Count 'Concurrent reader saw malformed/inconsistent publication.'
    } finally { Close-FixtureRun $fixture }
}
Complete-FixtureSuite 'control-scenarios.json'
