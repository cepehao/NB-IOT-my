param([string]$OutputFolder='', [string]$ScenarioPattern='.*', [switch]$IsolatedScenario)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/fixtures/scheduledRunStub.ps1" -Mode Library
Initialize-FixtureSuite 'reconcile spaces' $OutputFolder
$script:scenarioPattern=$ScenarioPattern
$script:isolatedScenario=[bool]$IsolatedScenario; $script:testEntry=$PSCommandPath; $script:suiteArtifact='accounting-fixtures.json'
$reconcile=Join-Path $PSScriptRoot 'ReconcileScheduledRun.ps1'

function New-AccountingFixture([double]$WorkerLeadSeconds=0,[double]$ChargedSeconds=0) {
    $run=Join-Path $script:scenarioFolder 'run folder'
    $processFolder=Join-Path $run 'workers/process folder'; $probe=Join-Path $run 'probe'
    [void][IO.Directory]::CreateDirectory($processFolder); [void][IO.Directory]::CreateDirectory($probe)
    # Select absent identities at runtime; never borrow historical process IDs.
    $absent=@(); $candidate=2000000000
    while ($absent.Count -lt 2) {
        if ($null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { $absent+= $candidate }
        $candidate--
    }
    $start='2026-01-01T00:00:00.0000000Z'; $finish='2026-01-01T00:00:12.5000000Z'
    $workerStart=[DateTimeOffset]::Parse($start).AddSeconds(-$WorkerLeadSeconds).UtcDateTime.ToString('o')
    $runId=[guid]::NewGuid().ToString('N'); $ledger=Join-Path $run 'budget ledger.json'
    $active=@{attemptId='a1';runId=$runId;caseKey='fixture-case';startedAtUtc=$start;
        rootProcessId=$absent[0];processStartTimeUtc=$workerStart;workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart}
    $attempt=@{attemptId='a1';runId=$runId;caseKey='fixture-case';startedAtUtc=$start;finishedAtUtc='';
        status='active';observedSeconds=$ChargedSeconds;chargedSeconds=$ChargedSeconds;processReportSha256=''}
    Write-FixtureJson $ledger @{schemaVersion=1;budgetSeconds=57600;elapsedSeconds=100;accountingVersion=2;
        attempts=@($attempt);activeCase=$active;pendingCases=@(500,1000,2500);
        phaseTimes=@(@{phase='prior';elapsedSeconds=100;startedAtUtc='2025-12-31T23:58:20Z';finishedAtUtc=$start;case='previous'})}
    $progress=Join-Path $probe 'progress.json'
    Write-FixtureJson $progress @{status='running';runId=$runId;activeCase=$active;pendingCounts=@(500,1000,2500);budgetElapsedSeconds=100;
        completedCases=@(@{count=100;realizationId=77;marker='fixture-only'})}
    Write-FixtureJson (Join-Path $run 'run-manifest.json') @{runId=$runId;runFolder=$run;probeFolder=$probe;sharedBudgetLedger=$ledger;status='running'}
    Write-FixtureJson (Join-Path $run 'worker-options.json') @{budgetLedgerFile=$ledger;outputFolder=$probe}
    $report=Join-Path $processFolder 'process-report.json'
    $identity=@{runId=$runId;rootProcessId=$absent[0];processStartTimeUtc=$workerStart;workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart;
        executable=$script:shellExe;arguments='fixture-only never executed';workingDirectory=$run}
    Write-FixtureJson (Join-Path $processFolder 'launch.json') $identity
    Write-FixtureJson (Join-Path $processFolder 'process-started.json') $identity
    Write-FixtureJson $report ($identity+@{status='failed';exitCode=24;startedAtUtc=$workerStart;finishedAtUtc=$finish;elapsedSeconds=(12.5+$WorkerLeadSeconds);
        attemptId='a1';caseKey='fixture-case';sampledPeakWorkingSetBytes=1})
    Write-FixtureJson (Join-Path $run 'worker.json') @{status='running';runId=$runId;runFolder=$run;workerFolder=$processFolder;
        workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart;matlabProcessId=$absent[0];matlabProcessStartTimeUtc=$workerStart;
        executable=$script:shellExe;arguments='fixture-only never executed';processReport=$report;
        progressFile=(Join-Path $probe 'worker-progress.json');heartbeat=(Join-Path $processFolder 'heartbeat.json')}
    $protected=Join-Path $run 'scientific fixture.bin'; [IO.File]::WriteAllText($protected,'immutable fixture content')
    $registry=Join-Path $run 'registry fixture.json'; Write-FixtureJson $registry @{reserved=@(77,78);completed=@(77)}
    $summary=Join-Path $probe 'load-probe.json'
    Write-FixtureJson $summary @{status='running';completedCounts=@(100);pendingCounts=@(500,1000,2500);budgetElapsedSeconds=100}
    [pscustomobject]@{run=$run;ledger=$ledger;progress=$progress;report=$report;processFolder=$processFolder;
        protected=$protected;registry=$registry;runId=$runId;summary=$summary}
}
function Invoke-ReconcileFixture($Fixture,[switch]$Apply) {
    $arguments="-RunFolder `"$($Fixture.run)`""; if ($Apply) { $arguments+=' -Apply' }
    Invoke-FixtureCli $reconcile $arguments
}
function New-HistoricalPreviewFixture {
    $run=Join-Path $script:scenarioFolder 'historical run folder'
    $processFolder=Join-Path $run 'workers/restored worker'
    $staleProcessFolder=Join-Path $run 'workers/stale worker'
    $probe=Join-Path $run 'probe'
    [void][IO.Directory]::CreateDirectory($processFolder)
    [void][IO.Directory]::CreateDirectory($staleProcessFolder)
    [void][IO.Directory]::CreateDirectory($probe)

    $runId=[guid]::NewGuid().ToString('N')
    $reportRunId=[guid]::NewGuid().ToString('N')
    $ledgerPath=Join-Path $run 'budget ledger.json'
    $progressPath=Join-Path $probe 'progress.json'
    $workerStart='2026-02-01T00:00:00.0000000Z'
    $reportFinish=[DateTimeOffset]::Parse($workerStart).AddSeconds(987.5).UtcDateTime.ToString('o')
    $activeCase=@{caseKey='historical-case-500';numUE=500;startedAtUtc='2026-02-01T00:00:00.0000000Z';
        lastProgressAtUtc='2026-02-01T00:16:27.5000000Z';runFolder=(Join-Path $run 'workers/ambiguous worker')}
    $phaseTimes=@(
        @{phase='stage-2-physical';startedAtUtc='2026-01-31T23:54:38.7500000Z';finishedAtUtc=$workerStart;
            elapsedSeconds=321.25;caseKey='closed-fixture-case'},
        @{phase='stage-3-load-probe';startedAtUtc=$workerStart;finishedAtUtc='';elapsedSeconds=0;
            caseKey='historical-case-500'}
    )
    $ledger=@{schemaVersion=1;budgetSeconds=57600;elapsedSeconds=321.25;
        startedAtUtc='2026-01-31T23:54:38.7500000Z';updatedAtUtc='2026-02-01T00:16:27.5000000Z';
        phaseTimes=$phaseTimes;warnings=@();pendingCases=@(500,1000,2500);
        activeCase=$activeCase;lastCaseStatus='interrupted'}
    Write-FixtureJson $ledgerPath $ledger

    $progress=@{runId=$runId;status='owner-stopped';phase='load-500-running';currentTick=4454;
        lastCheckpoint='synthetic-checkpoint.mat';updatedAtUtc='2026-02-01T00:16:27.5000000Z';
        budgetElapsedSeconds=321.25;completedCases=@(@{count=100;realizationId=901;marker='synthetic'});
        pendingCounts=@(500,1000,2500);activeCase=$activeCase}
    Write-FixtureJson $progressPath $progress

    $identity=@{runId=$runId;rootProcessId=9101001;processStartTimeUtc=$workerStart;
        workerProcessId=9101002;workerProcessStartTimeUtc=$workerStart;
        executable='synthetic-powershell.exe';workerExecutable='synthetic-powershell.exe';
        rootCommandLine='synthetic historical root';workerCommandLine='synthetic historical worker'}
    Write-FixtureJson (Join-Path $processFolder 'launch.json') $identity
    Write-FixtureJson (Join-Path $processFolder 'process-started.json') $identity

    $reportPath=Join-Path $processFolder 'process-report.json'
    $report=@{runId=$reportRunId;status='failed';exitCode=-1;
        rootProcessId=9102001;processStartTimeUtc='2026-02-01T00:00:00.0000000Z';
        workerProcessId=9102002;workerProcessStartTimeUtc='2026-02-01T00:00:00.0000000Z';
        startedAtUtc=$workerStart;finishedAtUtc=$reportFinish;elapsedSeconds=987.5;
        attemptId='synthetic-other-attempt';caseKey='synthetic-other-case'}
    Write-FixtureJson $reportPath $report

    $staleReportPath=Join-Path $staleProcessFolder 'process-report.json'
    Write-FixtureJson $staleReportPath @{runId=$runId;status='failed';elapsedSeconds=12.5}
    $worker=@{status='running';runId=$runId;runFolder=$run;workerFolder=$processFolder;
        workerProcessId=9101002;workerProcessStartTimeUtc=$workerStart;
        matlabProcessId=9101001;matlabProcessStartTimeUtc=$workerStart;
        workerCommandLine='synthetic historical worker';matlabCommandLine='synthetic historical root';
        executable='synthetic-powershell.exe';arguments='synthetic only';
        processReport=$staleReportPath;progressFile=$progressPath;heartbeat=(Join-Path $processFolder 'heartbeat.json')}
    Write-FixtureJson (Join-Path $run 'worker.json') $worker

    $manifest=@{runId=$runId;runFolder=$run;probeFolder=$probe;sharedBudgetLedger=$ledgerPath;status='owner-stopped'}
    Write-FixtureJson (Join-Path $run 'run-manifest.json') $manifest
    Write-FixtureJson (Join-Path $run 'worker-options.json') @{budgetLedgerFile=$ledgerPath;outputFolder=$probe}
    Write-FixtureJson (Join-Path $run 'owner-stop.json') @{
        stoppedProcessId=9101003;stoppedAtUtc='2026-02-01T00:16:28.0000000Z';filesDeleted=@()
    }
    Write-FixtureJson (Join-Path $run 'before-owner-stop.json') @{
        capturedAtUtc='2026-02-01T00:16:27.9000000Z';reason='synthetic ambiguous historical evidence';
        process=$identity;progress=$progress;worker=$worker;ledger=$ledger
    }

    [pscustomobject]@{run=$run;ledger=$ledgerPath;progress=$progressPath;report=$reportPath;
        reportRunId=$reportRunId;runId=$runId;workerFolder=$processFolder;
        workerReportReference=$staleReportPath;activeCaseRunFolder=$activeCase.runFolder;
        confirmedCommittedSeconds=321.25;candidateProcessDurationSeconds=987.5}
}
function Invoke-HistoricalPreviewFixture($Fixture,[switch]$Apply) {
    $harness=Join-Path $script:scenarioFolder 'historical preview process tripwire.ps1'
    $harnessSource=@'
param([string]$ReconcilePath,[string]$RunFolder,[switch]$Apply)
function Get-Process {
    param([int]$Id,[string]$Name,[string]$ErrorAction)
    throw 'HISTORICAL_PREVIEW_FORBIDDEN_LIVE_PROCESS_LOOKUP'
}
function Get-CimInstance {
    param([string]$ClassName,[string]$Filter,[string]$ErrorAction)
    throw 'HISTORICAL_PREVIEW_FORBIDDEN_LIVE_CIM_LOOKUP'
}
if ($Apply) { & $ReconcilePath -RunFolder $RunFolder -Apply }
else { & $ReconcilePath -RunFolder $RunFolder }
'@
    [IO.File]::WriteAllText($harness,$harnessSource,[Text.UTF8Encoding]::new($false))
    $arguments='-ReconcilePath "'+$reconcile+'" -RunFolder "'+[string]$Fixture.run+'"'
    if ($Apply) { $arguments+=' -Apply' }
    Invoke-FixtureCli $harness $arguments
}
function New-ExternalOwnerStopEvidenceFixture {
    $run=Join-Path $script:scenarioFolder 'external evidence run folder'
    $processFolder=Join-Path $run 'workers/synthetic worker'
    $probe=Join-Path $run 'probe'
    $evidence=Join-Path $script:scenarioFolder 'external audit evidence'
    [void][IO.Directory]::CreateDirectory($processFolder)
    [void][IO.Directory]::CreateDirectory($probe)
    [void][IO.Directory]::CreateDirectory($evidence)

    $runId=[guid]::NewGuid().ToString('N')
    $caseKey='synthetic-external-evidence-case'
    $start='2026-02-03T00:00:00.0000000Z'
    $approvedLedger=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\completion\stage-2\budget-ledger.json'))
    $finish='2026-02-03T00:16:27.5000000Z'
    $committed=144.25
    $ledgerPath=Join-Path $run 'budget ledger.json'
    $progressPath=Join-Path $probe 'progress.json'
    $reportPath=Join-Path $processFolder 'process-report.json'
    $activeCase=@{caseKey=$caseKey;numUE=500;startedAtUtc=$start;lastProgressAtUtc=$finish;runFolder=$run}
    $ledger=@{schemaVersion=1;budgetSeconds=57600;elapsedSeconds=$committed;startedAtUtc=$start;updatedAtUtc=$finish;
        attempts=@();phaseTimes=@(@{phase='stage-2-physical';startedAtUtc='2026-02-02T23:57:36.7500000Z';finishedAtUtc=$start;
            elapsedSeconds=$committed;caseKey='synthetic-closed-case'});pendingCases=@(500,1000,2500);activeCase=$activeCase;lastCaseStatus='interrupted'}
    $progress=@{status='running';phase='load-500-running';currentTick=4454;updatedAtUtc=$finish;
        budgetElapsedSeconds=$committed;completedCases=@(@{count=100;realizationId=901;marker='synthetic-external'});
        pendingCounts=@(500,1000,2500);activeCase=$activeCase}
    $identity=@{runId=$runId;rootProcessId=9313001;processStartTimeUtc=$start;
        workerProcessId=9313002;workerProcessStartTimeUtc=$start;executable='synthetic-powershell.exe';
        workerExecutable='synthetic-powershell.exe';rootCommandLine='synthetic external-evidence root';
        workerCommandLine='synthetic external-evidence worker'}
    $worker=@{status='running';runId=$runId;runFolder=$run;workerFolder=$processFolder;
        workerProcessId=9313002;workerProcessStartTimeUtc=$start;matlabProcessId=9313001;matlabProcessStartTimeUtc=$start;
        executable='synthetic-powershell.exe';arguments='synthetic fixture only';processReport=$reportPath;
        progressFile=$progressPath;heartbeat=(Join-Path $processFolder 'heartbeat.json')}
    $report=@{runId='foreign-synthetic-report-run-id';status='failed';exitCode=24;rootProcessId=9313001;processStartTimeUtc=$start;
        workerProcessId=9313002;workerProcessStartTimeUtc=$start;startedAtUtc=$start;finishedAtUtc='2026-02-03T00:16:27.5000000Z';
        elapsedSeconds=987.5;attemptId='synthetic-external-attempt';caseKey=$caseKey}
    $manifest=@{runFolder=$run;probeFolder=$probe;sharedBudgetLedger=$approvedLedger;status='running'}

    Write-FixtureJson $ledgerPath $ledger
    Write-FixtureJson $progressPath $progress
    Write-FixtureJson $reportPath $report
    Write-FixtureJson (Join-Path $processFolder 'launch.json') $identity
    Write-FixtureJson (Join-Path $processFolder 'process-started.json') $identity
    Write-FixtureJson (Join-Path $run 'worker.json') $worker
    Write-FixtureJson (Join-Path $run 'run-manifest.json') $manifest
    Write-FixtureJson (Join-Path $run 'worker-options.json') @{budgetLedgerFile=$approvedLedger;outputFolder=$probe}
    $snapshot=@{capturedAtUtc='2026-02-03T00:16:27.7500000Z';reason='synthetic external owner-stop audit evidence';
        process=$identity;progress=$progress;worker=$worker;ledger=$ledger}
    Write-FixtureJson (Join-Path $evidence 'owner-stop.json') @{
        stoppedProcessId=9313003;stoppedAtUtc='2026-02-03T00:16:28.0000000Z';filesDeleted=@()
    }
    Write-FixtureJson (Join-Path $evidence 'before-owner-stop.json') $snapshot
    [pscustomobject]@{run=$run;evidence=$evidence;ledger=$ledgerPath;progress=$progressPath;report=$reportPath;
        processFolder=$processFolder;probe=$probe;runId=$runId;caseKey=$caseKey;committedSeconds=$committed;
        candidateSeconds=987.5;approvedLedger=$approvedLedger;manifestPath=(Join-Path $run 'run-manifest.json');
        snapshotPath=(Join-Path $evidence 'before-owner-stop.json')}
}
function Test-ExternalEvidencePathWithinRun([string]$Run,[string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $root=[IO.Path]::GetFullPath($Run); $full=[IO.Path]::GetFullPath($Path)
        $prefix=$root
        if (-not $prefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)) { $prefix+=[IO.Path]::DirectorySeparatorChar }
        return $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
function Get-FixtureFileSha256([string]$Path) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    $stream=$null
    try {
        $stream=[IO.File]::OpenRead($Path)
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $algorithm.Dispose()
    }
}
function Get-FixtureTreeHashes([string]$Folder,[string]$ExcludedPath) {
    $folderFullPath=[IO.Path]::GetFullPath($Folder)
    $excludedFullPath=$null
    if (-not [string]::IsNullOrWhiteSpace($ExcludedPath)) {
        $excludedFullPath=[IO.Path]::GetFullPath($ExcludedPath)
    }
    $files=@(Get-ChildItem -LiteralPath $folderFullPath -File -Recurse)
    if ($null -ne $excludedFullPath) {
        $files=@($files | Where-Object {
            -not [string]::Equals([IO.Path]::GetFullPath($_.FullName),$excludedFullPath,[StringComparison]::OrdinalIgnoreCase)
        })
    }
    @($files | Sort-Object FullName |
        ForEach-Object { $_.FullName.Substring($folderFullPath.Length).TrimStart([char]92)+'|'+(Get-FixtureFileSha256 -Path $_.FullName) })
}
function Get-FixtureReconcileProtectedState([string]$RunFolder) {
    $relativePaths=@('budget ledger.json','budget ledger.json.before','reconcile-intent.json','reconcile-commit.json',
        'probe\progress.json','probe\progress.json.before','probe\load-probe.json','probe\load-probe.json.before')
    @(foreach($relative in $relativePaths) {
        $path=Join-Path $RunFolder $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $relative+'|present|'+(Get-FixtureFileSha256 -Path $path)
        } else { $relative+'|absent' }
    })
}
function Invoke-ExternalOwnerStopEvidencePreview($Fixture,[switch]$Apply) {
    $harness=Join-Path $script:scenarioFolder 'external evidence preview tripwire.ps1'
    $harnessSource=@'
param([string]$ReconcilePath,[string]$RunFolder,[string]$EvidenceFolder,[switch]$Apply)
$ErrorActionPreference='Stop'
function Get-Process {
    param([int]$Id,[string]$Name,[string]$ErrorAction)
    throw 'HISTORICAL_EXTERNAL_PREVIEW_FORBIDDEN_LIVE_PROCESS_LOOKUP'
}
function Get-CimInstance {
    param([string]$ClassName,[string]$Filter,[string]$ErrorAction)
    throw 'HISTORICAL_EXTERNAL_PREVIEW_FORBIDDEN_LIVE_CIM_LOOKUP'
}
try {
    if ($Apply) { & $ReconcilePath -RunFolder $RunFolder -OwnerStopEvidenceFolder $EvidenceFolder -Apply }
    else { & $ReconcilePath -RunFolder $RunFolder -OwnerStopEvidenceFolder $EvidenceFolder }
} catch {
    $message=$_.Exception.Message
    $reason='EXTERNAL_PREVIEW_INVOCATION_ERROR'
    if ($message -match 'OwnerStopEvidenceFolder') { $reason='EXTERNAL_OWNER_STOP_EVIDENCE_UNSUPPORTED' }
    elseif ($message -match 'HISTORICAL_EXTERNAL_PREVIEW_FORBIDDEN_LIVE_') { $reason=$message }
    [ordered]@{status='invocation-error';reason=$reason;detail=$message}|ConvertTo-Json -Depth 8 -Compress
    exit 0
}
'@
    [IO.File]::WriteAllText($harness,$harnessSource,[Text.UTF8Encoding]::new($false))
    $arguments='-ReconcilePath "'+$reconcile+'" -RunFolder "'+[string]$Fixture.run+'" -EvidenceFolder "'+[string]$Fixture.evidence+'"'
    if ($Apply) { $arguments+=' -Apply' }
    Invoke-FixtureCli $harness $arguments
}
function Initialize-SecondAttemptFixture($Fixture) {
    $caseKey='fixture-case-a2'; $caseStart='2026-01-02T00:00:00.0000000Z'
    $workerStart=$caseStart
    $workerFinish=[DateTimeOffset]::Parse($workerStart).AddSeconds(7.25).UtcDateTime.ToString('o')
    $previousIdentity=Read-FixtureJson (Join-Path $Fixture.processFolder 'process-started.json')
    $previousIds=@([int]$previousIdentity.rootProcessId,[int]$previousIdentity.workerProcessId)
    $absent=@(); $candidate=1900000000
    while ($absent.Count -lt 2) {
        if ($candidate -notin $previousIds -and $null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { $absent+= [int]$candidate }
        $candidate--
    }
    $identity=@{runId=$Fixture.runId;rootProcessId=$absent[0];processStartTimeUtc=$workerStart;
        workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart;executable=$script:shellExe;
        arguments='fixture-only never executed';workingDirectory=$Fixture.run}
    $active=@{attemptId='a2';runId=$Fixture.runId;caseKey=$caseKey;startedAtUtc=$caseStart;
        rootProcessId=$absent[0];processStartTimeUtc=$workerStart;workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart}
    $nextAttempt=@{attemptId='a2';runId=$Fixture.runId;caseKey=$caseKey;startedAtUtc=$caseStart;finishedAtUtc='';
        status='active';observedSeconds=0;chargedSeconds=0;processReportSha256=''}
    $ledger=Read-FixtureJson $Fixture.ledger
    $ledger.attempts=@($ledger.attempts)+@($nextAttempt); $ledger.activeCase=$active
    $ledger.phaseTimes=@($ledger.phaseTimes)+@(@{phase='stage-3-load-probe';startedAtUtc=$caseStart;finishedAtUtc='';elapsedSeconds=0;caseKey=$caseKey})
    Write-FixtureJson $Fixture.ledger $ledger
    $progress=Read-FixtureJson $Fixture.progress
    $progress.activeCase=$active; $progress.status='running'; $progress.phase='running'
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'currentTick' -Value 0 -Force
    $progress.updatedAtUtc=$caseStart
    $owner=@{processId=[int]$identity.rootProcessId;matlabRelease='R2025b';startedAtUtc=$caseStart;
        processStartTimeUtc=$identity.processStartTimeUtc;commandLine=$identity.arguments}
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'owner' -Value $owner -Force
    Write-FixtureJson $Fixture.progress $progress
    Write-FixtureJson (Join-Path $Fixture.processFolder 'launch.json') $identity
    Write-FixtureJson (Join-Path $Fixture.processFolder 'process-started.json') $identity
    $worker=Read-FixtureJson (Join-Path $Fixture.run 'worker.json')
    $worker.workerProcessId=$absent[1]; $worker.workerProcessStartTimeUtc=$workerStart
    $worker.matlabProcessId=$absent[0]; $worker.matlabProcessStartTimeUtc=$workerStart
    $worker.executable=$script:shellExe; $worker.arguments='fixture-only never executed'
    Write-FixtureJson (Join-Path $Fixture.run 'worker.json') $worker
    Write-FixtureJson $Fixture.report ($identity+@{status='failed';exitCode=24;startedAtUtc=$workerStart;finishedAtUtc=$workerFinish;
        elapsedSeconds=7.25;attemptId='a2';caseKey=$caseKey;sampledPeakWorkingSetBytes=1})
    [pscustomobject]@{identity=$identity;active=$active;caseKey=$caseKey;caseStart=$caseStart}
}

function Initialize-CleanPauseAccountingFixture($Fixture,[double]$ElapsedSeconds) {
    $finishedAt='2026-01-01T00:00:12.5000000Z'
    $ledger=Read-FixtureJson $Fixture.ledger
    $ledger.elapsedSeconds=$ElapsedSeconds
    $ledger.attempts[0].status='completed'
    $ledger.attempts[0].observedSeconds=12.5
    $ledger.attempts[0].chargedSeconds=12.5
    $ledger.attempts[0].finishedAtUtc=$finishedAt
    $ledger.attempts[0].processReportSha256=''
    $ledger.activeCase=@{}
    $ledger.pendingCases=@(500,1000,2500)
    $ledger.phaseTimes=@($ledger.phaseTimes)+@(@{phase='stage-3-load-probe';startedAtUtc='2026-01-01T00:00:00.0000000Z';
        finishedAtUtc=$finishedAt;elapsedSeconds=12.5;caseKey='fixture-case'})
    Add-Member -InputObject $ledger -MemberType NoteProperty -Name 'updatedAtUtc' -Value $finishedAt -Force
    Write-FixtureJson $Fixture.ledger $ledger

    $progress=Read-FixtureJson $Fixture.progress
    $progress.runId=$Fixture.runId
    $progress.status='paused'; $progress.activeCase=@{}
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'phase' -Value 'paused' -Force
    $progress.pendingCounts=@(500,1000,2500); $progress.budgetElapsedSeconds=$ElapsedSeconds
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'updatedAtUtc' -Value $finishedAt -Force
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'currentTick' -Value 5000 -Force
    Write-FixtureJson $Fixture.progress $progress

    $summary=Read-FixtureJson $Fixture.summary
    $summary.status='paused'; $summary.budgetElapsedSeconds=$ElapsedSeconds
    Write-FixtureJson $Fixture.summary $summary
    $report=Read-FixtureJson $Fixture.report
    $report.status='completed'; $report.exitCode=0; $report.elapsedSeconds=12.5
    $report.finishedAtUtc=$finishedAt; $report.attemptId='a1'; $report.caseKey='fixture-case'
    Write-FixtureJson $Fixture.report $report
    return [pscustomobject]@{reportSha=(Get-FileHash -LiteralPath $Fixture.report -Algorithm SHA256).Hash.ToLowerInvariant();finishedAt=$finishedAt}
}

function Get-FixtureSourceManifestSha256([string]$ProjectRoot) {
    $root=(Resolve-Path -LiteralPath $ProjectRoot).Path.TrimEnd('\')
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    $files=[Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.m' -File -Recurse -Force)) {
        $full=[IO.Path]::GetFullPath($file.FullName)
        $relative=$full.Substring($prefix.Length).Replace('\','/')
        $files.Add($relative,(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    foreach($entryPoint in @('setupProject.m','experiments/runStaticSweep.m','experiments/runStaticSweepParallel.m','experiments/optimizationSourceManifest.m')) {
        $full=[IO.Path]::GetFullPath((Join-Path $root $entryPoint.Replace('/',[IO.Path]::DirectorySeparatorChar)))
        $relative=$full.Substring($prefix.Length).Replace('\','/')
        $files[$relative]=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $text=[Text.StringBuilder]::new()
    foreach($relative in $files.Keys) {
        [void]$text.Append($relative); [void]$text.Append([char]0)
        [void]$text.Append($files[$relative]); [void]$text.Append([char]10)
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($text.ToString())))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-BudgetResumeFixture($Fixture,[switch]$MismatchRunIdentity,[switch]$MismatchLedgerPath,[switch]$HoldWriterLease) {
    $runner=Join-Path $PSScriptRoot '..\completion\stage-3\runVariant2.ps1'
    $harness=Join-Path $script:scenarioFolder 'budget resume process tripwire.ps1'
    $harnessSource=@'
param([string]$RunnerPath,[string]$RunFolder)
$script:liveLookups=0
function Get-Process { $script:liveLookups++; throw 'BUDGET_RESUME_FORBIDDEN_LIVE_PROCESS_LOOKUP' }
function Get-CimInstance { $script:liveLookups++; throw 'BUDGET_RESUME_FORBIDDEN_LIVE_CIM_LOOKUP' }
try {
    $result=& $RunnerPath -Resume -RunFolder $RunFolder -MatlabCommand 'NBIOT_SYNTHETIC_MATLAB_MUST_NOT_RUN'
    [ordered]@{status='returned';result=$result;liveLookups=$script:liveLookups}|ConvertTo-Json -Depth 12 -Compress
    exit 0
} catch {
    [ordered]@{status='error';reason=$_.Exception.Message;liveLookups=$script:liveLookups}|ConvertTo-Json -Depth 8 -Compress
    exit 0
}
'@
    [IO.File]::WriteAllText($harness,$harnessSource,[Text.UTF8Encoding]::new($false))
    $arguments='-RunnerPath "'+$runner+'" -RunFolder "'+[string]$Fixture.run+'"'
    if ($MismatchRunIdentity -or $MismatchLedgerPath) {
        $manifest=Read-FixtureJson (Join-Path $Fixture.run 'run-manifest.json')
        $manifest.runId=$Fixture.runId
        if ($MismatchRunIdentity) { $manifest.runId=[guid]::NewGuid().ToString('N') }
        if ($MismatchLedgerPath) { $manifest.sharedBudgetLedger=Join-Path $Fixture.run 'unapproved ledger.json' }
        Write-FixtureJson (Join-Path $Fixture.run 'run-manifest.json') $manifest
    }
    $manifestPath=Join-Path $Fixture.run 'run-manifest.json'
    $manifestHashBefore=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $heldWriterLease=$null
    try {
        if ($HoldWriterLease) {
            # Model another run-folder writer holding the exact shared ledger lease.
            $heldWriterLease=[IO.File]::Open(([string]$Fixture.ledger+'.writer.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        }
        $result=Invoke-FixtureCli $harness $arguments
    } finally {
        if ($null -ne $heldWriterLease) { $heldWriterLease.Dispose() }
    }
    Add-Member -InputObject $result -MemberType NoteProperty -Name 'manifestHashBefore' -Value $manifestHashBefore -Force
    return $result
}

function Record-FixtureAssertion($Failures,[scriptblock]$Assertion) {
    try { & $Assertion } catch { [void]$Failures.Add($_.Exception.Message) }
}

Invoke-FixtureScenario 'historical owner-stop preview remains incomplete and offline' {
    $fixture=New-HistoricalPreviewFixture
    Assert-True ($fixture.reportRunId -cne $fixture.runId) 'Synthetic report/run linkage must be mismatched.'
    Assert-True ($fixture.workerReportReference -cne $fixture.report) 'Synthetic worker/report path linkage must be mismatched.'
    Assert-True ($fixture.activeCaseRunFolder -cne $fixture.workerFolder) 'Synthetic activeCase/worker linkage must be mismatched.'

    $beforeFiles=@(Get-ChildItem -LiteralPath $fixture.run -File -Recurse | Sort-Object FullName |
        ForEach-Object { $_.FullName.Substring($fixture.run.Length).TrimStart([char]92)+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
    # Even an explicit Apply request must stay a read-only historical preview.
    $result=Invoke-HistoricalPreviewFixture $fixture -Apply
    Assert-True ($result.json.reason -notmatch 'HISTORICAL_PREVIEW_FORBIDDEN_LIVE_(PROCESS|CIM)_LOOKUP') 'Historical preview attempted forbidden live process/PID lookup.'
    Assert-Equal 0 $result.exitCode 'Historical preview exit.'
    Assert-Equal 'accounting-incomplete' $result.json.status 'Ambiguous historical linkage must remain accounting-incomplete.'
    Assert-Equal $fixture.confirmedCommittedSeconds $result.json.committedSeconds 'Preview changed confirmed committed seconds.'
    Assert-Equal $fixture.confirmedCommittedSeconds $result.json.elapsedSeconds 'Unconfirmed process duration was charged.'
    Assert-Equal 0 $result.json.chargedCandidateSeconds 'Candidate process duration must not be charged.'
    Assert-Equal $fixture.candidateProcessDurationSeconds $result.json.candidateProcessDurationSeconds 'Candidate duration missing.'
    Assert-Equal 'unconfirmed' $result.json.candidateProcessDurationStatus 'Candidate duration must be labeled unconfirmed.'
    Assert-Equal $false $result.json.applied 'Historical preview must never Apply.'
    Assert-Equal $false $result.json.applyAllowed 'Historical preview must not offer Apply.'
    Assert-Equal $false $result.json.resumeAllowed 'Owner-stopped historical run must not offer resume.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$result.json.applyCommand)) 'Historical preview returned an Apply command.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$result.json.resumeCommand)) 'Historical preview returned a resume command.'


    $previewTokens=$null; $previewParseErrors=$null
    $previewAst=[System.Management.Automation.Language.Parser]::ParseFile($reconcile,[ref]$previewTokens,[ref]$previewParseErrors)
    Assert-Equal 0 @($previewParseErrors).Count 'Reconcile parser errors during historical-preview isolation check.'
    $previewFunctions=@($previewAst.FindAll({
        param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-HistoricalReconcilePreview'
    },$true))
    Assert-Equal 1 $previewFunctions.Count 'Missing isolated historical-preview function.'
    $forbiddenCalls=@($previewFunctions[0].Body.FindAll({
        param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in @('Get-RunStates','Get-RunProcessState','Get-Process','Get-CimInstance')
    },$true))
    Assert-Equal 0 $forbiddenCalls.Count 'Historical preview function contains a live process/PID lookup call.'

    $afterFiles=@(Get-ChildItem -LiteralPath $fixture.run -File -Recurse | Sort-Object FullName |
        ForEach-Object { $_.FullName.Substring($fixture.run.Length).TrimStart([char]92)+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
    Assert-Equal ($beforeFiles -join [Environment]::NewLine) ($afterFiles -join [Environment]::NewLine) 'Historical preview changed or added a run artifact.'
    foreach($name in @('reconcile-intent.json','reconcile-commit.json','budget ledger.json.before','probe\progress.json.before','budget ledger.json.writer.lock')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.run $name))) "Historical preview created transaction artifact $name."
    }
}
Invoke-FixtureScenario 'external owner-stop evidence preview remains incomplete and offline' {
    $fixture=New-ExternalOwnerStopEvidenceFixture
    $manifest=Read-FixtureJson $fixture.manifestPath
    $snapshot=Read-FixtureJson $fixture.snapshotPath
    $runOwnerStop=Join-Path $fixture.run 'owner-stop.json'
    $runBeforeOwnerStop=Join-Path $fixture.run 'before-owner-stop.json'
    $evidenceOwnerStop=Join-Path $fixture.evidence 'owner-stop.json'
    $evidenceBeforeOwnerStop=Join-Path $fixture.evidence 'before-owner-stop.json'

    Assert-Equal 'running' $manifest.status 'Synthetic run must remain running without root owner-stop evidence.'
    Assert-True (-not (Test-Path -LiteralPath $runOwnerStop)) 'Synthetic run root must not contain owner-stop.json.'
    Assert-True (-not (Test-Path -LiteralPath $runBeforeOwnerStop)) 'Synthetic run root must not contain before-owner-stop.json.'
    Assert-True (Test-Path -LiteralPath $evidenceOwnerStop -PathType Leaf) 'External audit owner-stop.json is missing.'
    Assert-True (Test-Path -LiteralPath $evidenceBeforeOwnerStop -PathType Leaf) 'External audit before-owner-stop.json is missing.'
    Assert-True (-not (Test-ExternalEvidencePathWithinRun $fixture.run $fixture.evidence)) 'External evidence folder must be outside the synthetic run.'
    Assert-Equal $fixture.run $manifest.runFolder 'Synthetic manifest must name the exact run folder.'
    Assert-Equal $fixture.run $snapshot.worker.runFolder 'Saved worker runFolder must identify the exact synthetic run.'
    Assert-True (@($manifest.PSObject.Properties.Name) -notcontains 'runId') 'Legacy run manifest should leave the optional runId property absent.'
    Assert-True (@($snapshot.PSObject.Properties.Name) -notcontains 'runId') 'Legacy saved snapshot should leave the optional runId property absent.'
    Assert-True (@($snapshot.progress.PSObject.Properties.Name) -notcontains 'runId') 'Legacy saved progress should leave the optional runId property absent.'
    Assert-True (@($snapshot.ledger.PSObject.Properties.Name) -notcontains 'runId') 'Legacy saved ledger should leave the optional runId property absent.'
    Assert-True (@($snapshot.PSObject.Properties.Name) -notcontains 'ledgerPath') 'Legacy snapshot should leave optional ledgerPath absent.'
    Assert-True (@($snapshot.PSObject.Properties.Name) -notcontains 'progressPath') 'Legacy snapshot should leave optional progressPath absent.'
    $ownerStop=Read-FixtureJson $evidenceOwnerStop
    Assert-True (@($ownerStop.PSObject.Properties.Name) -notcontains 'runId') 'Legacy owner-stop evidence should not invent an optional runId field.'
    Assert-Equal $fixture.approvedLedger ([IO.Path]::GetFullPath([string]$manifest.sharedBudgetLedger)) 'Manifest must reference only the declared stage-2 ledger path.'
    Assert-True (-not (Test-ExternalEvidencePathWithinRun $fixture.run $manifest.sharedBudgetLedger)) 'Approved stage-2 ledger must remain outside the run.'
    foreach($path in @($manifest.probeFolder,$snapshot.worker.workerFolder)) {
        Assert-True (Test-ExternalEvidencePathWithinRun $fixture.run ([string]$path)) "Saved evidence directory must remain inside the synthetic run: $path"
        Assert-True (Test-Path -LiteralPath ([string]$path) -PathType Container) "Saved evidence directory is missing: $path"
    }
    foreach($path in @($snapshot.worker.processReport,$snapshot.worker.progressFile)) {
        Assert-True (Test-ExternalEvidencePathWithinRun $fixture.run ([string]$path)) "Saved evidence path must remain inside the synthetic run: $path"
        Assert-True (Test-Path -LiteralPath ([string]$path) -PathType Leaf) "Saved evidence path is missing: $path"
    }
    $savedReport=Read-FixtureJson $snapshot.worker.processReport
    Assert-True ($savedReport.runId -cne $snapshot.worker.runId) 'Synthetic report identity mismatch must remain an unconfirmed candidate.'

    $tokens=$null; $parseErrors=$null
    $reconcileAst=[System.Management.Automation.Language.Parser]::ParseFile($reconcile,[ref]$tokens,[ref]$parseErrors)
    Assert-Equal 0 @($parseErrors).Count 'Reconcile parser errors.'
    $reconcileSource=[IO.File]::ReadAllText($reconcile)
    $externalRouteOffset=$reconcileSource.IndexOf('if ($ownerStopEvidenceSpecified)',[StringComparison]::Ordinal)
    $liveLookupOffset=$reconcileSource.IndexOf('$states=Get-RunStates',[StringComparison]::Ordinal)
    Assert-True ($externalRouteOffset -ge 0 -and $liveLookupOffset -gt $externalRouteOffset) 'External evidence route must appear before every live-run process lookup.'
    foreach($functionName in @('Get-ExternalOwnerStopPreview','Resolve-ExternalPreviewCanonicalPath','Test-ExternalPreviewCanonicalContainment')) {
        $isolatedFunctions=@($reconcileAst.FindAll({
            param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $functionName
        },$true))
        Assert-Equal 1 $isolatedFunctions.Count "Missing isolated external preview function $functionName."
        $liveCalls=@($isolatedFunctions[0].Body.FindAll({
            param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Get-RunStates','Get-RunProcessState','Get-Process','Get-CimInstance')
        },$true))
        Assert-Equal 0 $liveCalls.Count "$functionName contains a live process/PID lookup call."
    }

    $runBefore=Get-FixtureTreeHashes $fixture.run
    $evidenceBefore=Get-FixtureTreeHashes $fixture.evidence
    # The external evidence path is deliberately explicit. Even with -Apply,
    # this historical preview must not mutate either input tree.
    $result=Invoke-ExternalOwnerStopEvidencePreview $fixture -Apply
    Assert-True ($result.json.reason -notmatch 'HISTORICAL_EXTERNAL_PREVIEW_FORBIDDEN_LIVE_(PROCESS|CIM)_LOOKUP') 'External evidence preview attempted forbidden live process/PID lookup.'
    Assert-Equal 0 $result.exitCode 'External evidence preview exit.'
    $runAfter=Get-FixtureTreeHashes $fixture.run
    $evidenceAfter=Get-FixtureTreeHashes $fixture.evidence
    Assert-Equal ($runBefore -join [Environment]::NewLine) ($runAfter -join [Environment]::NewLine) 'External evidence preview changed or added a run artifact.'
    Assert-Equal ($evidenceBefore -join [Environment]::NewLine) ($evidenceAfter -join [Environment]::NewLine) 'External evidence preview changed its saved audit inputs.'
    foreach($name in @('reconcile-intent.json','reconcile-commit.json','budget ledger.json.before','probe\progress.json.before','budget ledger.json.writer.lock')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.run $name))) "External evidence preview created transaction artifact $name."
    }

    # GREEN contract: even a legacy snapshot with optional runId/path fields absent stays read-only and incomplete.
    Assert-Equal 'accounting-incomplete' $result.json.status 'Ambiguous external historical linkage must remain accounting-incomplete.'
    Assert-Equal $fixture.runId $result.json.runId 'Preview runId must come from the saved worker identity.'
    Assert-Equal $fixture.committedSeconds $result.json.committedSeconds 'Preview changed snapshot ledger committed seconds.'
    Assert-Equal $fixture.committedSeconds $result.json.elapsedSeconds 'Unconfirmed report duration was charged.'
    Assert-Equal 0 $result.json.chargedCandidateSeconds 'Candidate report duration must not be charged.'
    Assert-Equal $fixture.candidateSeconds $result.json.candidateProcessDurationSeconds 'Candidate report duration missing.'
    Assert-Equal 'unconfirmed' $result.json.candidateProcessDurationStatus 'Candidate report duration must be labeled unconfirmed.'
    Assert-Equal $false $result.json.applied 'External historical preview must never Apply.'
    Assert-Equal $false $result.json.applyAllowed 'External historical preview must not offer Apply.'
    Assert-Equal $false $result.json.resumeAllowed 'External owner-stopped preview must not offer resume.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$result.json.applyCommand)) 'External historical preview returned an Apply command.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$result.json.resumeCommand)) 'External historical preview returned a resume command.'

    # A mismatching optional owner-stop runId must fail closed through the same offline route.
    $mismatchedEvidence=Join-Path $script:scenarioFolder 'mismatched external audit evidence'
    [void][IO.Directory]::CreateDirectory($mismatchedEvidence)
    Copy-Item -LiteralPath $evidenceOwnerStop -Destination (Join-Path $mismatchedEvidence 'owner-stop.json')
    Copy-Item -LiteralPath $evidenceBeforeOwnerStop -Destination (Join-Path $mismatchedEvidence 'before-owner-stop.json')
    $mismatchedOwnerStop=Read-FixtureJson (Join-Path $mismatchedEvidence 'owner-stop.json')
    Add-Member -InputObject $mismatchedOwnerStop -MemberType NoteProperty -Name 'runId' -Value 'foreign-synthetic-owner-stop-run' -Force
    Write-FixtureJson (Join-Path $mismatchedEvidence 'owner-stop.json') $mismatchedOwnerStop
    $mismatchedFixture=[pscustomobject]@{run=$fixture.run;evidence=$mismatchedEvidence}
    $mismatchRunBefore=Get-FixtureTreeHashes $fixture.run
    $mismatchEvidenceBefore=Get-FixtureTreeHashes $mismatchedEvidence
    $mismatch=Invoke-ExternalOwnerStopEvidencePreview $mismatchedFixture -Apply
    Assert-True ($mismatch.json.reason -notmatch 'HISTORICAL_EXTERNAL_PREVIEW_FORBIDDEN_LIVE_(PROCESS|CIM)_LOOKUP') 'Mismatching external evidence attempted forbidden live process/PID lookup.'
    Assert-Equal 0 $mismatch.exitCode 'Mismatching external evidence preview exit.'
    Assert-Equal 'accounting-incomplete' $mismatch.json.status 'Mismatching evidence must fail closed as incomplete.'
    Assert-Equal $fixture.committedSeconds $mismatch.json.committedSeconds 'Mismatching owner-stop evidence changed confirmed snapshot committed seconds.'
    Assert-Equal $fixture.committedSeconds $mismatch.json.elapsedSeconds 'Mismatching evidence charged candidate seconds.'
    Assert-Equal 0 $mismatch.json.chargedCandidateSeconds 'Mismatching evidence charged candidate seconds.'
    Assert-Equal $false $mismatch.json.applied 'Mismatching evidence must never Apply.'
    Assert-Equal $false $mismatch.json.applyAllowed 'Mismatching evidence must not offer Apply.'
    Assert-Equal $false $mismatch.json.resumeAllowed 'Mismatching evidence must not offer resume.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$mismatch.json.applyCommand)) 'Mismatching evidence returned an Apply command.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$mismatch.json.resumeCommand)) 'Mismatching evidence returned a resume command.'
    Assert-True ($mismatch.json.reason -match 'owner-stop runId conflicts') 'Mismatching owner-stop runId was not rejected.'
    Assert-Equal ($mismatchRunBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $fixture.run) -join [Environment]::NewLine) 'Mismatching preview changed the run tree.'
    Assert-Equal ($mismatchEvidenceBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $mismatchedEvidence) -join [Environment]::NewLine) 'Mismatching preview changed its audit evidence.'

    $timestampOwnerStop=Read-FixtureJson (Join-Path $mismatchedEvidence 'owner-stop.json')
    $timestampOwnerStop.runId=$fixture.runId
    $timestampOwnerStop.stoppedAtUtc='2026-02-03T00:16:27.7000000Z'
    Write-FixtureJson (Join-Path $mismatchedEvidence 'owner-stop.json') $timestampOwnerStop
    $timestampEvidenceBefore=Get-FixtureTreeHashes $mismatchedEvidence
    $timestampMismatch=Invoke-ExternalOwnerStopEvidencePreview $mismatchedFixture -Apply
    Assert-True ($timestampMismatch.json.reason -notmatch 'HISTORICAL_EXTERNAL_PREVIEW_FORBIDDEN_LIVE_(PROCESS|CIM)_LOOKUP') 'Timestamp mismatch attempted forbidden live process/PID lookup.'
    Assert-Equal 0 $timestampMismatch.exitCode 'Timestamp-mismatched evidence preview exit.'
    Assert-Equal 'accounting-incomplete' $timestampMismatch.json.status 'Timestamp-mismatched evidence must remain incomplete.'
    Assert-Equal $fixture.committedSeconds $timestampMismatch.json.committedSeconds 'Timestamp mismatch lost confirmed snapshot committed seconds.'
    Assert-Equal $fixture.committedSeconds $timestampMismatch.json.elapsedSeconds 'Timestamp mismatch charged candidate seconds.'
    Assert-Equal 0 $timestampMismatch.json.chargedCandidateSeconds 'Timestamp mismatch charged candidate seconds.'
    Assert-Equal $null $timestampMismatch.json.candidateProcessDurationSeconds 'Timestamp-mismatched evidence exposed report duration as a candidate.'
    Assert-Equal $false $timestampMismatch.json.applied 'Timestamp-mismatched evidence must never Apply.'
    Assert-Equal $false $timestampMismatch.json.applyAllowed 'Timestamp-mismatched evidence must not offer Apply.'
    Assert-Equal $false $timestampMismatch.json.resumeAllowed 'Timestamp-mismatched evidence must not offer resume.'
    Assert-True ($timestampMismatch.json.reason -match 'timestamp predates') 'Owner-stop timestamp predating snapshot was not rejected.'
    Assert-Equal ($timestampEvidenceBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $mismatchedEvidence) -join [Environment]::NewLine) 'Timestamp-mismatch preview changed its audit evidence.'
    Assert-Equal ($mismatchRunBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $fixture.run) -join [Environment]::NewLine) 'Timestamp-mismatch preview changed the run tree.'

    # A present but empty manifest runId is invalid; only an absent property is optional.
    $originalManifest=Read-FixtureJson $fixture.manifestPath
    $emptyManifest=Read-FixtureJson $fixture.manifestPath
    Add-Member -InputObject $emptyManifest -MemberType NoteProperty -Name 'runId' -Value '' -Force
    Write-FixtureJson $fixture.manifestPath $emptyManifest
    $emptyManifestRunBefore=Get-FixtureTreeHashes $fixture.run
    $emptyManifestResult=Invoke-ExternalOwnerStopEvidencePreview $fixture -Apply
    Assert-Equal 0 $emptyManifestResult.exitCode 'Empty manifest runId preview exit.'
    Assert-Equal 'accounting-incomplete' $emptyManifestResult.json.status 'Present empty manifest runId must fail closed.'
    Assert-Equal $fixture.committedSeconds $emptyManifestResult.json.committedSeconds 'Empty manifest runId lost confirmed snapshot committed seconds.'
    Assert-Equal $fixture.committedSeconds $emptyManifestResult.json.elapsedSeconds 'Empty manifest runId charged candidate seconds.'
    Assert-Equal 0 $emptyManifestResult.json.chargedCandidateSeconds 'Empty manifest runId charged candidate seconds.'
    Assert-Equal $false $emptyManifestResult.json.applied 'Empty manifest runId must never Apply.'
    Assert-Equal $false $emptyManifestResult.json.applyAllowed 'Empty manifest runId must not offer Apply.'
    Assert-Equal $false $emptyManifestResult.json.resumeAllowed 'Empty manifest runId must not offer resume.'
    Assert-True ($emptyManifestResult.json.reason -match 'Manifest runId conflicts') 'Present empty manifest runId was treated as absent.'
    Assert-Equal ($emptyManifestRunBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $fixture.run) -join [Environment]::NewLine) 'Empty manifest runId preview changed its run tree.'
    Write-FixtureJson $fixture.manifestPath $originalManifest
    Assert-Equal ($runBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $fixture.run) -join [Environment]::NewLine) 'Restoring the optional manifest field changed the synthetic run tree.'

    # A present null runId in the owner-stop source is invalid, unlike a truly absent property.
    $nullOwnerEvidence=Join-Path $script:scenarioFolder 'null owner-stop runId evidence'
    [void][IO.Directory]::CreateDirectory($nullOwnerEvidence)
    Copy-Item -LiteralPath $evidenceOwnerStop -Destination (Join-Path $nullOwnerEvidence 'owner-stop.json')
    Copy-Item -LiteralPath $evidenceBeforeOwnerStop -Destination (Join-Path $nullOwnerEvidence 'before-owner-stop.json')
    $nullOwnerStop=Read-FixtureJson (Join-Path $nullOwnerEvidence 'owner-stop.json')
    Add-Member -InputObject $nullOwnerStop -MemberType NoteProperty -Name 'runId' -Value $null -Force
    Write-FixtureJson (Join-Path $nullOwnerEvidence 'owner-stop.json') $nullOwnerStop
    $nullOwnerFixture=[pscustomobject]@{run=$fixture.run;evidence=$nullOwnerEvidence}
    $nullOwnerEvidenceBefore=Get-FixtureTreeHashes $nullOwnerEvidence
    $nullOwnerResult=Invoke-ExternalOwnerStopEvidencePreview $nullOwnerFixture -Apply
    Assert-Equal 0 $nullOwnerResult.exitCode 'Null owner-stop runId preview exit.'
    Assert-Equal 'accounting-incomplete' $nullOwnerResult.json.status 'Present null owner-stop runId must fail closed.'
    Assert-Equal $fixture.committedSeconds $nullOwnerResult.json.committedSeconds 'Null owner-stop runId lost confirmed snapshot committed seconds.'
    Assert-Equal 0 $nullOwnerResult.json.chargedCandidateSeconds 'Null owner-stop runId charged candidate seconds.'
    Assert-Equal $false $nullOwnerResult.json.applied 'Null owner-stop runId must never Apply.'
    Assert-Equal $false $nullOwnerResult.json.applyAllowed 'Null owner-stop runId must not offer Apply.'
    Assert-Equal $false $nullOwnerResult.json.resumeAllowed 'Null owner-stop runId must not offer resume.'
    Assert-True ($nullOwnerResult.json.reason -match 'owner-stop runId conflicts') 'Present null owner-stop runId was treated as absent.'
    Assert-Equal ($nullOwnerEvidenceBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $nullOwnerEvidence) -join [Environment]::NewLine) 'Null owner-stop runId preview changed its audit evidence.'
    Assert-Equal ($runBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $fixture.run) -join [Environment]::NewLine) 'Null owner-stop runId preview changed the run tree.'

    # A present empty nested snapshot runId is also invalid; preserve absent legacy fields above.
    $emptySnapshotEvidence=Join-Path $script:scenarioFolder 'empty snapshot runId evidence'
    [void][IO.Directory]::CreateDirectory($emptySnapshotEvidence)
    Copy-Item -LiteralPath $evidenceOwnerStop -Destination (Join-Path $emptySnapshotEvidence 'owner-stop.json')
    Copy-Item -LiteralPath $evidenceBeforeOwnerStop -Destination (Join-Path $emptySnapshotEvidence 'before-owner-stop.json')
    $emptySnapshot=Read-FixtureJson (Join-Path $emptySnapshotEvidence 'before-owner-stop.json')
    Add-Member -InputObject $emptySnapshot.progress -MemberType NoteProperty -Name 'runId' -Value '' -Force
    Write-FixtureJson (Join-Path $emptySnapshotEvidence 'before-owner-stop.json') $emptySnapshot
    $emptySnapshotFixture=[pscustomobject]@{run=$fixture.run;evidence=$emptySnapshotEvidence}
    $emptySnapshotEvidenceBefore=Get-FixtureTreeHashes $emptySnapshotEvidence
    $emptySnapshotResult=Invoke-ExternalOwnerStopEvidencePreview $emptySnapshotFixture -Apply
    Assert-Equal 0 $emptySnapshotResult.exitCode 'Empty snapshot runId preview exit.'
    Assert-Equal 'accounting-incomplete' $emptySnapshotResult.json.status 'Present empty snapshot runId must fail closed.'
    Assert-Equal $fixture.committedSeconds $emptySnapshotResult.json.committedSeconds 'Empty snapshot runId lost confirmed snapshot committed seconds.'
    Assert-Equal 0 $emptySnapshotResult.json.chargedCandidateSeconds 'Empty snapshot runId charged candidate seconds.'
    Assert-Equal $false $emptySnapshotResult.json.applied 'Empty snapshot runId must never Apply.'
    Assert-Equal $false $emptySnapshotResult.json.applyAllowed 'Empty snapshot runId must not offer Apply.'
    Assert-Equal $false $emptySnapshotResult.json.resumeAllowed 'Empty snapshot runId must not offer resume.'
    Assert-True ($emptySnapshotResult.json.reason -match 'snapshot progress runId conflicts') 'Present empty snapshot runId was treated as absent.'
    Assert-Equal ($emptySnapshotEvidenceBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $emptySnapshotEvidence) -join [Environment]::NewLine) 'Empty snapshot runId preview changed its audit evidence.'
    Assert-Equal ($runBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes $fixture.run) -join [Environment]::NewLine) 'Empty snapshot runId preview changed the run tree.'
}
Invoke-FixtureScenario 'preview leaves persisted files unchanged' {
    $fixture=New-AccountingFixture
    $beforeLedger=(Get-FileHash -LiteralPath $fixture.ledger).Hash
    $beforeProgress=(Get-FileHash -LiteralPath $fixture.progress).Hash
    $result=Invoke-ReconcileFixture $fixture
    Assert-Equal 0 $result.exitCode 'Preview exit.'
    Assert-Equal $beforeLedger (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Preview changed ledger.'
    Assert-Equal $beforeProgress (Get-FileHash -LiteralPath $fixture.progress).Hash 'Preview changed progress.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.run 'reconcile-intent.json'))) 'Preview wrote intent.'
}
Invoke-FixtureScenario 'charge twelve point five exactly once' {
    $fixture=New-AccountingFixture
    $science=(Get-FileHash -LiteralPath $fixture.protected).Hash; $registry=(Get-FileHash -LiteralPath $fixture.registry).Hash
    $completed=(Read-FixtureJson $fixture.progress).completedCases|ConvertTo-Json -Compress
    $first=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $first.exitCode 'First Apply exit.'
    Assert-Equal 112.5 (Read-FixtureJson $fixture.ledger).elapsedSeconds 'First charge.'
    $second=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $second.exitCode 'Repeat Apply exit.'
    $ledger=Read-FixtureJson $fixture.ledger
    Assert-Equal 112.5 $ledger.elapsedSeconds 'Repeated charge.'
    Assert-Equal 12.5 $ledger.attempts[0].chargedSeconds 'Attempt charged seconds.'
    Assert-Equal 1 @($ledger.attempts).Count 'Duplicate attempt.'
    Assert-Equal 1 $ledger.schemaVersion 'Ledger schema changed.'
    Assert-Equal 57600 $ledger.budgetSeconds 'Budget changed.'
    Assert-Equal $science (Get-FileHash -LiteralPath $fixture.protected).Hash 'Scientific fixture changed.'
    Assert-Equal $registry (Get-FileHash -LiteralPath $fixture.registry).Hash 'Registry fixture changed.'
    Assert-Equal $completed ((Read-FixtureJson $fixture.progress).completedCases|ConvertTo-Json -Compress) 'Completed records changed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.run 'reconcile-intent.json')) 'Missing transaction intent.'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.run 'reconcile-commit.json')) 'Missing transaction commit.'
}
Invoke-FixtureScenario 'reconcile preserves a second distinct attempt' {
    $fixture=New-AccountingFixture
    $protectedBefore=(Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash.ToLowerInvariant()
    $registryBefore=(Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash.ToLowerInvariant()
    $firstReportSha=(Get-FileHash -LiteralPath $fixture.report -Algorithm SHA256).Hash.ToLowerInvariant()
    $first=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $first.exitCode 'First attempt Apply exit.'
    Assert-Equal 'reconciled' $first.json.status 'First attempt status.'
    $firstLedger=Read-FixtureJson $fixture.ledger
    Assert-Equal 112.5 $firstLedger.elapsedSeconds 'First attempt charge.'
    Assert-Equal 1 @($firstLedger.attempts).Count 'First attempt row count.'
    Assert-Equal 'a1' $firstLedger.attempts[0].attemptId 'First attempt ID.'
    Assert-Equal 12.5 $firstLedger.attempts[0].chargedSeconds 'First attempt charged seconds.'
    Assert-Equal $firstReportSha ([string]$firstLedger.attempts[0].processReportSha256).ToLowerInvariant() 'First attempt report SHA.'
    $firstIntent=Read-FixtureJson (Join-Path $fixture.run 'reconcile-intent.json')
    $firstCommit=Read-FixtureJson (Join-Path $fixture.run 'reconcile-commit.json')
    Assert-Equal 'a1' $firstIntent.attemptId 'First transaction attempt ID.'
    Assert-Equal $firstReportSha ([string]$firstIntent.processReportSha256).ToLowerInvariant() 'First transaction report SHA.'
    Assert-Equal 'a1' $firstCommit.attemptId 'First commit attempt ID.'
    Assert-Equal $firstReportSha ([string]$firstCommit.processReportSha256).ToLowerInvariant() 'First commit report SHA.'
    $protectedAfterFirst=(Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash.ToLowerInvariant()
    $registryAfterFirst=(Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $protectedBefore $protectedAfterFirst 'First Apply changed scientific fixture.'
    Assert-Equal $registryBefore $registryAfterFirst 'First Apply changed registry fixture.'

    # Model a later case in the same run with a fresh, dynamically checked absent PID pair.
    $caseKey='fixture-case-a2'; $caseStart='2026-01-02T00:00:00.0000000Z'
    $workerStart=$caseStart
    $workerFinish=[DateTimeOffset]::Parse($workerStart).AddSeconds(7.25).UtcDateTime.ToString('o')
    $previousIdentity=Read-FixtureJson (Join-Path $fixture.processFolder 'process-started.json')
    $previousIds=@([int]$previousIdentity.rootProcessId,[int]$previousIdentity.workerProcessId)
    $absent=@(); $candidate=1900000000
    while ($absent.Count -lt 2) {
        if ($candidate -notin $previousIds -and $null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { $absent+= [int]$candidate }
        $candidate--
    }
    $identity=@{runId=$fixture.runId;rootProcessId=$absent[0];processStartTimeUtc=$workerStart;
        workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart;executable=$script:shellExe;
        arguments='fixture-only never executed';workingDirectory=$fixture.run}
    $active=@{attemptId='a2';runId=$fixture.runId;caseKey=$caseKey;startedAtUtc=$caseStart;
        rootProcessId=$absent[0];processStartTimeUtc=$workerStart;workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart}
    $nextAttempt=@{attemptId='a2';runId=$fixture.runId;caseKey=$caseKey;startedAtUtc=$caseStart;finishedAtUtc='';
        status='active';observedSeconds=0;chargedSeconds=0;processReportSha256=''}
    $ledger=Read-FixtureJson $fixture.ledger
    $ledger.attempts=@($ledger.attempts)+@($nextAttempt)
    $ledger.activeCase=$active
    Write-FixtureJson $fixture.ledger $ledger
    $progress=Read-FixtureJson $fixture.progress
    $progress.activeCase=$active; $progress.status='running'; $progress.phase='running'
    Write-FixtureJson $fixture.progress $progress
    Write-FixtureJson (Join-Path $fixture.processFolder 'launch.json') $identity
    Write-FixtureJson (Join-Path $fixture.processFolder 'process-started.json') $identity
    $worker=Read-FixtureJson (Join-Path $fixture.run 'worker.json')
    $worker.workerProcessId=$absent[1]; $worker.workerProcessStartTimeUtc=$workerStart
    $worker.matlabProcessId=$absent[0]; $worker.matlabProcessStartTimeUtc=$workerStart
    $worker.executable=$script:shellExe; $worker.arguments='fixture-only never executed'
    Write-FixtureJson (Join-Path $fixture.run 'worker.json') $worker
    Write-FixtureJson $fixture.report ($identity+@{status='failed';exitCode=24;startedAtUtc=$workerStart;finishedAtUtc=$workerFinish;
        elapsedSeconds=7.25;attemptId='a2';caseKey=$caseKey;sampledPeakWorkingSetBytes=1})
    $secondReportSha=(Get-FileHash -LiteralPath $fixture.report -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($secondReportSha -cne $firstReportSha) 'Second attempt report SHA must differ.'

    $second=Invoke-ReconcileFixture $fixture -Apply
    $protectedAfterSecond=(Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash.ToLowerInvariant()
    $registryAfterSecond=(Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-FixtureJson (Join-Path $script:scenarioFolder 'protected-registry hash evidence.json') ([ordered]@{
        protectedFixturePath=$fixture.protected;protectedFixtureBeforeSha256=$protectedBefore;protectedFixtureAfterFirstApplySha256=$protectedAfterFirst;protectedFixtureAfterSecondApplySha256=$protectedAfterSecond
        registryPath=$fixture.registry;registryBeforeSha256=$registryBefore;registryAfterFirstApplySha256=$registryAfterFirst;registryAfterSecondApplySha256=$registryAfterSecond
        unchangedThroughSecondApply=($protectedBefore -ceq $protectedAfterFirst -and $protectedBefore -ceq $protectedAfterSecond -and $registryBefore -ceq $registryAfterFirst -and $registryBefore -ceq $registryAfterSecond)
        firstAttemptId='a1';firstProcessReportSha256=$firstReportSha;secondAttemptId='a2';secondProcessReportSha256=$secondReportSha
        secondApplyExitCode=$second.exitCode;secondApplyStatus=$second.json.status})
    Assert-Equal $protectedBefore $protectedAfterSecond 'Second Apply changed scientific fixture.'
    Assert-Equal $registryBefore $registryAfterSecond 'Second Apply changed registry fixture.'
    Assert-Equal 'reconciled' $second.json.status 'Second distinct attempt must reconcile.'
    Assert-Equal 0 $second.exitCode 'Second distinct attempt Apply exit.'
    $secondLedger=Read-FixtureJson $fixture.ledger
    Assert-Equal 119.75 $secondLedger.elapsedSeconds 'Second attempt total charge.'
    Assert-Equal 2 @($secondLedger.attempts).Count 'Second attempt row count.'
    Assert-Equal 'a1' $secondLedger.attempts[0].attemptId 'First attempt row was replaced.'
    Assert-Equal 'a2' $secondLedger.attempts[1].attemptId 'Second attempt row ID.'
    Assert-Equal 12.5 $secondLedger.attempts[0].chargedSeconds 'First attempt charge changed.'
    Assert-Equal 7.25 $secondLedger.attempts[1].chargedSeconds 'Second attempt charge.'
    Assert-Equal $firstReportSha ([string]$secondLedger.attempts[0].processReportSha256).ToLowerInvariant() 'First attempt report SHA changed.'
    Assert-Equal $secondReportSha ([string]$secondLedger.attempts[1].processReportSha256).ToLowerInvariant() 'Second attempt report SHA linkage.'
    $secondIntent=Read-FixtureJson (Join-Path $fixture.run 'reconcile-intent.json')
    $secondCommit=Read-FixtureJson (Join-Path $fixture.run 'reconcile-commit.json')
    Assert-Equal 'a2' $secondIntent.attemptId 'Second transaction attempt ID.'
    Assert-Equal $secondReportSha ([string]$secondIntent.processReportSha256).ToLowerInvariant() 'Second transaction report SHA.'
    Assert-Equal 'a2' $secondCommit.attemptId 'Second commit attempt ID.'
    Assert-Equal $secondReportSha ([string]$secondCommit.processReportSha256).ToLowerInvariant() 'Second commit report SHA.'

    $repeat=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $repeat.exitCode 'Repeat second attempt Apply exit.'
    Assert-Equal 'reconciled' $repeat.json.status 'Repeat second attempt status.'
    $finalLedger=Read-FixtureJson $fixture.ledger
    Assert-Equal 119.75 $finalLedger.elapsedSeconds 'Repeated second attempt charge.'
    Assert-Equal 2 @($finalLedger.attempts).Count 'Repeated second attempt duplicated a row.'
    Assert-Equal $firstReportSha ([string]$finalLedger.attempts[0].processReportSha256).ToLowerInvariant() 'Repeated Apply changed first report SHA.'
    Assert-Equal $secondReportSha ([string]$finalLedger.attempts[1].processReportSha256).ToLowerInvariant() 'Repeated Apply changed second report SHA.'
    $protectedAfterRepeat=(Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash.ToLowerInvariant()
    $registryAfterRepeat=(Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $protectedBefore $protectedAfterRepeat 'Repeated Apply changed scientific fixture.'
    Assert-Equal $registryBefore $registryAfterRepeat 'Repeated Apply changed registry fixture.'
    $hashEvidence=Read-FixtureJson (Join-Path $script:scenarioFolder 'protected-registry hash evidence.json')
    $hashEvidence|Add-Member -NotePropertyName protectedFixtureAfterRepeatSha256 -NotePropertyValue $protectedAfterRepeat -Force
    $hashEvidence|Add-Member -NotePropertyName registryAfterRepeatSha256 -NotePropertyValue $registryAfterRepeat -Force
    $hashEvidence|Add-Member -NotePropertyName unchangedThroughRepeat -NotePropertyValue ($protectedBefore -ceq $protectedAfterRepeat -and $registryBefore -ceq $registryAfterRepeat) -Force
    Write-FixtureJson (Join-Path $script:scenarioFolder 'protected-registry hash evidence.json') $hashEvidence
}
Invoke-FixtureScenario 'rejects foreign ledger pendingCases change before second attempt reconcile' {
    $fixture=New-AccountingFixture
    $firstReportSha=(Get-FileHash -LiteralPath $fixture.report -Algorithm SHA256).Hash.ToLowerInvariant()
    $first=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $first.exitCode 'First attempt Apply exit.'
    Assert-Equal 'reconciled' $first.json.status 'First attempt status.'
    $firstLedger=Read-FixtureJson $fixture.ledger
    Assert-Equal 112.5 $firstLedger.elapsedSeconds 'First attempt charge.'
    Assert-Equal $firstReportSha ([string]$firstLedger.attempts[0].processReportSha256).ToLowerInvariant() 'First attempt report SHA.'

    # Build the same legal scheduler delta as the passing multi-attempt scenario.
    $caseKey='fixture-case-a2'; $caseStart='2026-01-02T00:00:00.0000000Z'
    $workerStart=$caseStart
    $workerFinish=[DateTimeOffset]::Parse($workerStart).AddSeconds(7.25).UtcDateTime.ToString('o')
    $previousIdentity=Read-FixtureJson (Join-Path $fixture.processFolder 'process-started.json')
    $previousIds=@([int]$previousIdentity.rootProcessId,[int]$previousIdentity.workerProcessId)
    $absent=@(); $candidate=1800000000
    while ($absent.Count -lt 2) {
        if ($candidate -notin $previousIds -and $null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { $absent+= [int]$candidate }
        $candidate--
    }
    $identity=@{runId=$fixture.runId;rootProcessId=$absent[0];processStartTimeUtc=$workerStart;
        workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart;executable=$script:shellExe;
        arguments='fixture-only never executed';workingDirectory=$fixture.run}
    $active=@{attemptId='a2';runId=$fixture.runId;caseKey=$caseKey;startedAtUtc=$caseStart;
        rootProcessId=$absent[0];processStartTimeUtc=$workerStart;workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart}
    $nextAttempt=@{attemptId='a2';runId=$fixture.runId;caseKey=$caseKey;startedAtUtc=$caseStart;finishedAtUtc='';
        status='active';observedSeconds=0;chargedSeconds=0;processReportSha256=''}
    $ledger=Read-FixtureJson $fixture.ledger
    $ledger.attempts=@($ledger.attempts)+@($nextAttempt)
    $ledger.activeCase=$active
    Write-FixtureJson $fixture.ledger $ledger
    $progress=Read-FixtureJson $fixture.progress
    $progress.activeCase=$active; $progress.status='running'; $progress.phase='running'
    Write-FixtureJson $fixture.progress $progress
    Write-FixtureJson (Join-Path $fixture.processFolder 'launch.json') $identity
    Write-FixtureJson (Join-Path $fixture.processFolder 'process-started.json') $identity
    $worker=Read-FixtureJson (Join-Path $fixture.run 'worker.json')
    $worker.workerProcessId=$absent[1]; $worker.workerProcessStartTimeUtc=$workerStart
    $worker.matlabProcessId=$absent[0]; $worker.matlabProcessStartTimeUtc=$workerStart
    $worker.executable=$script:shellExe; $worker.arguments='fixture-only never executed'
    Write-FixtureJson (Join-Path $fixture.run 'worker.json') $worker
    Write-FixtureJson $fixture.report ($identity+@{status='failed';exitCode=24;startedAtUtc=$workerStart;finishedAtUtc=$workerFinish;
        elapsedSeconds=7.25;attemptId='a2';caseKey=$caseKey;sampledPeakWorkingSetBytes=1})
    $secondReportSha=(Get-FileHash -LiteralPath $fixture.report -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ($secondReportSha -cne $firstReportSha) 'Second attempt report SHA must differ.'

    # pendingCases is a real shared-ledger field; reorder the same planned values
    # after a2 is active to simulate an uncommitted foreign scheduler edit.
    $ledger=Read-FixtureJson $fixture.ledger
    $ledger.pendingCases=@(1000,500,2500)
    Write-FixtureJson $fixture.ledger $ledger
    $foreignLedgerSha=(Get-FileHash -LiteralPath $fixture.ledger -Algorithm SHA256).Hash
    $progressSha=(Get-FileHash -LiteralPath $fixture.progress -Algorithm SHA256).Hash
    $intentPath=Join-Path $fixture.run 'reconcile-intent.json'
    $commitPath=Join-Path $fixture.run 'reconcile-commit.json'
    $intentSha=(Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash
    $commitSha=(Get-FileHash -LiteralPath $commitPath -Algorithm SHA256).Hash
    $protectedSha=(Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash
    $registrySha=(Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash

    $result=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 'conflict' $result.json.status 'Foreign ledger pendingCases change must conflict.'
    Assert-True ($result.exitCode -ne 0) 'Foreign ledger pendingCases change returned success.'
    Assert-Equal $foreignLedgerSha (Get-FileHash -LiteralPath $fixture.ledger -Algorithm SHA256).Hash 'Conflict changed the foreign ledger state.'
    Assert-Equal $progressSha (Get-FileHash -LiteralPath $fixture.progress -Algorithm SHA256).Hash 'Conflict changed progress.'
    Assert-Equal $intentSha (Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash 'Conflict replaced the predecessor intent.'
    Assert-Equal $commitSha (Get-FileHash -LiteralPath $commitPath -Algorithm SHA256).Hash 'Conflict replaced the predecessor commit.'
    Assert-Equal $protectedSha (Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash 'Conflict changed scientific fixture.'
    Assert-Equal $registrySha (Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash 'Conflict changed registry fixture.'
    $after=Read-FixtureJson $fixture.ledger
    Assert-Equal 112.5 $after.elapsedSeconds 'Rejected second attempt was charged.'
    Assert-Equal 2 @($after.attempts).Count 'Rejected second attempt changed history length.'
    Assert-Equal 'a1' $after.attempts[0].attemptId 'Rejected second attempt changed a1 history.'
    Assert-Equal 'a2' $after.attempts[1].attemptId 'Rejected second attempt row missing.'
    Assert-Equal 'active' $after.attempts[1].status 'Rejected second attempt row closed.'
    Assert-Equal 0 $after.attempts[1].chargedSeconds 'Rejected second attempt received a charge.'
    Assert-Equal '' ([string]$after.attempts[1].processReportSha256) 'Rejected second attempt report SHA was committed.'
}
Invoke-FixtureScenario 'recover ledger published before progress' {
    $fixture=New-AccountingFixture
    $fixtureLedger=Read-FixtureJson $fixture.ledger; $fixtureProgress=Read-FixtureJson $fixture.progress
    Assert-Equal 100 $fixtureLedger.elapsedSeconds 'Recovery fixture initial ledger baseline.'
    Assert-Equal $fixtureLedger.elapsedSeconds $fixtureProgress.budgetElapsedSeconds 'Recovery fixture progress budget must match ledger elapsedSeconds.'
    $oldProgress=[IO.File]::ReadAllBytes($fixture.progress)
    $oldSummary=[IO.File]::ReadAllBytes($fixture.summary)
    $beforeLedger=(Get-FileHash -LiteralPath $fixture.ledger).Hash.ToLowerInvariant()
    $beforeProgress=(Get-FileHash -LiteralPath $fixture.progress).Hash.ToLowerInvariant()
    $beforeSummary=(Get-FileHash -LiteralPath $fixture.summary).Hash.ToLowerInvariant()
    Assert-Equal 0 (Invoke-ReconcileFixture $fixture -Apply).exitCode 'Fixture Apply exit.'
    $newProgress=(Get-FileHash -LiteralPath $fixture.progress).Hash
    $newSummary=(Get-FileHash -LiteralPath $fixture.summary).Hash
    Assert-Equal $beforeLedger (Get-FileHash -LiteralPath ($fixture.ledger+'.before')).Hash.ToLowerInvariant() 'Ledger backup SHA.'
    Assert-Equal $beforeProgress (Get-FileHash -LiteralPath ($fixture.progress+'.before')).Hash.ToLowerInvariant() 'Progress backup SHA.'
    Assert-Equal $beforeSummary (Get-FileHash -LiteralPath ($fixture.summary+'.before')).Hash.ToLowerInvariant() 'Summary backup SHA.'
    $intent=Read-FixtureJson (Join-Path $fixture.run 'reconcile-intent.json')
    foreach ($entry in $intent.entries) {
        Assert-Equal $entry.oldSha256 (Get-FileHash -LiteralPath $entry.beforePath).Hash.ToLowerInvariant() 'Intent old digest.'
        Assert-Equal $entry.newSha256 (Get-FileHash -LiteralPath $entry.path).Hash.ToLowerInvariant() 'Intent new digest.'
    }
    # Emulate only a private temp fixture crash, preserving the actual emitted intent/new ledger.
    Remove-Item -LiteralPath (Join-Path $fixture.run 'reconcile-commit.json')
    [IO.File]::WriteAllBytes($fixture.progress,$oldProgress)
    [IO.File]::WriteAllBytes($fixture.summary,$oldSummary)
    Assert-Equal 0 (Invoke-ReconcileFixture $fixture -Apply).exitCode 'Recovery Apply exit.'
    Assert-Equal 112.5 (Read-FixtureJson $fixture.ledger).elapsedSeconds 'Recovery charged twice.'
    Assert-Equal $newProgress (Get-FileHash -LiteralPath $fixture.progress).Hash 'Recovery did not finish same progress transaction.'
    Assert-Equal $newSummary (Get-FileHash -LiteralPath $fixture.summary).Hash 'Recovery did not finish same summary transaction.'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.run 'reconcile-commit.json')) 'Recovery omitted commit.'
}
Invoke-FixtureScenario 'changed report on closed attempt conflicts' {
    $fixture=New-AccountingFixture
    Assert-Equal 0 (Invoke-ReconcileFixture $fixture -Apply).exitCode 'Fixture Apply exit.'
    $before=(Get-FileHash -LiteralPath $fixture.ledger).Hash
    $report=Read-FixtureJson $fixture.report; $report.elapsedSeconds=13; $report.finishedAtUtc='2026-01-01T00:00:13.0000000Z'
    Write-FixtureJson $fixture.report $report
    $result=Invoke-ReconcileFixture $fixture -Apply
    Assert-True ($result.exitCode -ne 0) 'Changed report accepted.'
    Assert-Equal $before (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Conflict changed ledger.'
}
Invoke-FixtureScenario 'exclusive lease excludes another process' {
    $fixture=New-AccountingFixture; $holder=$null
    try {
        $holder=Start-FixtureOwned "-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode Lease -Folder `"$($fixture.run)`" -MaxSeconds 20" 'lease'
        Wait-FixtureFile (Join-Path $fixture.run 'lease held.json')
        $before=(Get-FileHash -LiteralPath $fixture.ledger).Hash
        $result=Invoke-ReconcileFixture $fixture -Apply
        Assert-True ($result.exitCode -ne 0) 'Apply ignored OS lease.'
        Assert-Equal $before (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Lease conflict changed ledger.'
    } finally {
        [IO.File]::WriteAllText((Join-Path $fixture.run 'release lease.request'),'release')
        if ($null -ne $holder) { if (-not $holder.RootExited) { $holder.Stop() } }
    }
}
Invoke-FixtureScenario 'Java FileChannel writer lease blocks Apply' {
    $fixture=New-AccountingFixture; $holder=$null
    $lockPath=$fixture.ledger+'.writer.lock'
    $leaseSeed=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    $leaseSeed.Dispose()
    $jjsPath=Get-FixtureMatlabR2025bJjsPath
    $readyPath=Join-Path $script:scenarioFolder 'Java lease ready.json'
    $releasePath=Join-Path $script:scenarioFolder 'release Java lease.request'
    $resultPath=Join-Path $script:scenarioFolder 'Java lease result.json'
    $probeConfig=@{mode='hold';target=$lockPath;ready=$readyPath;release=$releasePath;result=$resultPath;timeoutMilliseconds=15000}
    $sourcePath=New-FixtureNashornLockProbeSource $script:scenarioFolder $probeConfig
    try {
        $holder=Start-FixtureNashornOwned $jjsPath $sourcePath 'java lease holder'
        Wait-FixtureFile $readyPath 10
        $ready=Read-FixtureJson $readyPath
        Assert-Equal 'tryLock' $ready.stage 'Java holder stage.'
        Assert-Equal 'acquired' $ready.outcome 'Java did not acquire the writer lease.'
        Assert-Equal $true $ready.attemptedTryLock 'Java holder did not attempt FileChannel.tryLock.'
        Assert-Equal ([IO.Path]::GetFullPath($lockPath)) ([IO.Path]::GetFullPath([string]$ready.target)) 'Java holder used a different lock path.'
        Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'Java writer lock file must exist before Apply.'
        $runBefore=Get-FixtureTreeHashes -Folder $fixture.run -ExcludedPath $lockPath
        $protectedBefore=Get-FixtureReconcileProtectedState $fixture.run
        $ledgerBefore=Get-FixtureFileSha256 -Path $fixture.ledger
        $apply=Invoke-ReconcileFixture $fixture -Apply
        Assert-Equal 1 $apply.exitCode 'Apply under Java lease must exit with conflict.'
        Assert-Equal 'conflict' $apply.json.status 'Apply under Java lease must return structured conflict.'
        Assert-True ([string]$apply.json.reason -match 'Ledger writer lease is held by another process') 'Java lease conflict reason was not preserved.'
        Assert-Equal $ledgerBefore (Get-FixtureFileSha256 -Path $fixture.ledger) 'Java lease conflict changed ledger.'
        Assert-Equal ($protectedBefore -join [Environment]::NewLine) ((Get-FixtureReconcileProtectedState $fixture.run) -join [Environment]::NewLine) 'Java lease conflict changed ledger/progress/transaction files.'
        Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'Java writer lock file must still exist after Apply.'
        Assert-Equal ($runBefore -join [Environment]::NewLine) ((Get-FixtureTreeHashes -Folder $fixture.run -ExcludedPath $lockPath) -join [Environment]::NewLine) 'Java lease conflict changed the synthetic run tree.'
    } finally {
        [IO.File]::WriteAllText($releasePath,'release')
        if ($null -ne $holder -and -not $holder.RootExited) { Wait-Fixture { $holder.RootExited } 'Java lease holder exit' 5 }
    }
    Assert-Equal 0 $holder.ExitCode 'Java lease holder exit code.'
    Assert-Equal 'release' (Read-FixtureJson $resultPath).stage 'Java holder did not release through its bounded fixture path.'
}
Invoke-FixtureScenario '.NET FileShare.None blocks Java tryLock' {
    $fixture=New-AccountingFixture; $holder=$null; $probe=$null
    $lockPath=$fixture.ledger+'.writer.lock'
    $jjsPath=Get-FixtureMatlabR2025bJjsPath
    $readyPath=Join-Path $script:scenarioFolder 'unused Java ready.json'
    $releasePath=Join-Path $script:scenarioFolder 'unused Java release.request'
    $resultPath=Join-Path $script:scenarioFolder 'Java tryLock result.json'
    $probeConfig=@{mode='try';target=$lockPath;ready=$readyPath;release=$releasePath;result=$resultPath;timeoutMilliseconds=10000}
    $sourcePath=New-FixtureNashornLockProbeSource $script:scenarioFolder $probeConfig
    try {
        $holder=Start-FixtureOwned "-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode Lease -Folder `"$($fixture.run)`" -MaxSeconds 20" '.NET exclusive lease holder'
        Wait-FixtureFile (Join-Path $fixture.run 'lease held.json') 5
        $probe=Start-FixtureNashornOwned $jjsPath $sourcePath 'java tryLock probe'
        Wait-Fixture { $probe.RootExited } 'bounded Java tryLock probe' 10
        Assert-Equal 0 $probe.ExitCode 'Java tryLock probe process exit.'
        $result=Read-FixtureJson $resultPath
        $targetMatches=([IO.Path]::GetFullPath([string]$result.target)).Equals([IO.Path]::GetFullPath($lockPath),[StringComparison]::OrdinalIgnoreCase)
        Assert-True $targetMatches 'Java contention result refers to a different lock path.'
        $tryLockContention=($result.stage -eq 'tryLock' -and $result.outcome -eq 'contention' -and $result.attemptedTryLock -and
            $result.exceptionClass -in @($null,'java.nio.channels.OverlappingFileLockException'))
        $specificSharingReason=([string]$result.reason -match '(?i)(sharing violation|used by another process|being used by another process|locked by another process|\u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u0435\u0442\u0441\u044f \u0434\u0440\u0443\u0433\u0438\u043c \u043f\u0440\u043e\u0446\u0435\u0441\u0441\u043e\u043c|\u0437\u0430\u043d\u044f\u0442 \u0434\u0440\u0443\u0433\u0438\u043c \u043f\u0440\u043e\u0446\u0435\u0441\u0441\u043e\u043c)')
        $openShareDenial=($result.stage -eq 'open' -and $result.outcome -eq 'open-sharing-denied' -and -not $result.attemptedTryLock -and
            (($result.exceptionClass -eq 'java.nio.file.AccessDeniedException') -or
                ($result.exceptionClass -eq 'java.nio.file.FileSystemException' -and $specificSharingReason)))
        Assert-True ($tryLockContention -or $openShareDenial) "Java did not report a specific bounded lease conflict at tryLock/open: stage=$($result.stage), outcome=$($result.outcome), exception=$($result.exceptionClass), reason=$($result.reason)."
    } finally {
        [IO.File]::WriteAllText((Join-Path $fixture.run 'release lease.request'),'release')
        if ($null -ne $holder -and -not $holder.RootExited) { Wait-Fixture { $holder.RootExited } '.NET lease holder exit' 5 }
        if ($null -ne $probe -and -not $probe.RootExited) { $probe.Stop() }
    }
}
Invoke-FixtureScenario 'malformed final report cannot charge' {
    $fixture=New-AccountingFixture
    [IO.File]::WriteAllText($fixture.report,'{"malformed":')
    $before=(Get-FileHash -LiteralPath $fixture.ledger).Hash
    $result=Invoke-ReconcileFixture $fixture -Apply
    Assert-True ($result.exitCode -ne 0) 'Malformed report accepted.'
    Assert-Equal $before (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Malformed report changed ledger.'
}
Invoke-FixtureScenario 'foreign digest blocks crash recovery' {
    $fixture=New-AccountingFixture
    Assert-Equal 0 (Invoke-ReconcileFixture $fixture -Apply).exitCode 'Fixture Apply exit.'
    Remove-Item -LiteralPath (Join-Path $fixture.run 'reconcile-commit.json')
    $progress=Read-FixtureJson $fixture.progress; $progress.status='foreign-writer'
    Write-FixtureJson $fixture.progress $progress
    $ledgerHash=(Get-FileHash -LiteralPath $fixture.ledger).Hash; $progressHash=(Get-FileHash -LiteralPath $fixture.progress).Hash
    Assert-True ((Invoke-ReconcileFixture $fixture -Apply).exitCode -ne 0) 'Foreign digest recovery accepted.'
    Assert-Equal $ledgerHash (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Foreign digest changed ledger.'
    Assert-Equal $progressHash (Get-FileHash -LiteralPath $fixture.progress).Hash 'Foreign digest overwritten.'
}
foreach ($charged in @(3,20)) {
    Invoke-FixtureScenario "intersection accounting charged $charged" {
        $fixture=New-AccountingFixture -WorkerLeadSeconds 40 -ChargedSeconds $charged
        Assert-Equal 0 (Invoke-ReconcileFixture $fixture -Apply).exitCode 'Intersection Apply exit.'
        $ledger=Read-FixtureJson $fixture.ledger
        Assert-Equal (100+[Math]::Max([double]0,[double](12.5-$charged))) $ledger.elapsedSeconds 'Must charge case interval delta, not complete process interval.'
        Assert-Equal ([Math]::Max([double]$charged,[double]12.5)) $ledger.attempts[0].chargedSeconds 'Charged amount must never decrease.'
    }
}
foreach ($liveRole in @('worker','root')) {
    Invoke-FixtureScenario "partial live $liveRole" {
        $fixture=New-AccountingFixture
        $sentinel=Start-FixtureOwned "-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode Sentinel -Folder `"$script:scenarioFolder`" -MaxSeconds 25" 'live tuple'
        Wait-FixtureFile (Join-Path $script:scenarioFolder 'Sentinel started.json')
        $live=Read-FixtureJson (Join-Path $script:scenarioFolder 'Sentinel started.json')
        $startedPath=Join-Path $fixture.processFolder 'process-started.json'; $launchPath=Join-Path $fixture.processFolder 'launch.json'; $workerPath=Join-Path $fixture.run 'worker.json'
        $started=Read-FixtureJson $startedPath; $launch=Read-FixtureJson $launchPath; $worker=Read-FixtureJson $workerPath
        $cmd=[string](Get-CimInstance Win32_Process -Filter "ProcessId=$($live.processId)").CommandLine
        if ($liveRole -eq 'worker') {
            foreach($record in @($started,$launch,$worker)) { $record.workerProcessId=$live.processId; $record.workerProcessStartTimeUtc=$live.processStartTimeUtc; $record|Add-Member -NotePropertyName workerCommandLine -NotePropertyValue $cmd -Force }
            $started|Add-Member -NotePropertyName workerExecutable -NotePropertyValue $script:shellExe -Force
        } else {
            foreach($record in @($started,$launch)) { $record.rootProcessId=$live.processId; $record.processStartTimeUtc=$live.processStartTimeUtc }
            $started|Add-Member -NotePropertyName rootCommandLine -NotePropertyValue $cmd -Force; $worker.matlabProcessId=$live.processId; $worker.matlabProcessStartTimeUtc=$live.processStartTimeUtc; $worker|Add-Member -NotePropertyName matlabCommandLine -NotePropertyValue $cmd -Force
        }
        Write-FixtureJson $startedPath $started; Write-FixtureJson $launchPath $launch; Write-FixtureJson $workerPath $worker
        $before=(Get-FileHash -LiteralPath $fixture.ledger).Hash
        $result=Invoke-ReconcileFixture $fixture -Apply
        Assert-Equal $(if($liveRole -eq 'worker'){'wait-for-report'}else{'needs-attention'}) $result.json.status 'Partial live state.'
        Assert-Equal $false $result.json.resumeAllowed 'Partial live resume.'
        Assert-Equal $before (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Partial live ledger edit.'
        Assert-True (-not $sentinel.RootExited) 'Reconcile stopped live process.'
    }
}
Invoke-FixtureScenario 'orphan without report remains incomplete' {
    $fixture=New-AccountingFixture; Remove-Item -LiteralPath $fixture.report
    $before=(Get-FileHash -LiteralPath $fixture.ledger).Hash
    $result=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 'interrupted-accounting-incomplete' $result.json.status 'Missing report status.'
    Assert-Equal $false $result.json.resumeAllowed 'Orphan resume.'
    Assert-Equal $before (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Orphan charged guessed time.'
}
foreach($invalid in @('run mismatch','attempt mismatch','negative','nonfinite','reversed')) {
    Invoke-FixtureScenario "semantic invalid $invalid" {
        $fixture=New-AccountingFixture; $report=Read-FixtureJson $fixture.report
        switch($invalid) {
            'run mismatch' {$report.runId='foreign'}
            'attempt mismatch' {$report.attemptId='foreign'}
            'negative' {$report.elapsedSeconds=-1}
            'nonfinite' {$report.elapsedSeconds='NaN'}
            'reversed' {$report.finishedAtUtc='2025-12-31T23:59:59.0000000Z'}
        }
        Write-FixtureJson $fixture.report $report
        $before=(Get-FileHash -LiteralPath $fixture.ledger).Hash; $progressHash=(Get-FileHash -LiteralPath $fixture.progress).Hash
        Assert-True ((Invoke-ReconcileFixture $fixture -Apply).exitCode -ne 0) 'Semantic-invalid report accepted.'
        Assert-Equal $before (Get-FileHash -LiteralPath $fixture.ledger).Hash 'Invalid report changed ledger.'
        Assert-Equal $progressHash (Get-FileHash -LiteralPath $fixture.progress).Hash 'Invalid report changed progress.'
    }
}
Invoke-FixtureScenario 'concurrent Apply charges one attempt' {
    $fixture=New-AccountingFixture
    Write-FixtureJson (Join-Path $script:scenarioFolder 'concurrent options.json') @{script=$reconcile;runFolder=$fixture.run}
    $arguments="-NoProfile -ExecutionPolicy Bypass -File `"$script:stubFile`" -Mode ReconcileClient -Folder `"$script:scenarioFolder`" -MaxSeconds 20"
    $one=Start-FixtureOwned $arguments 'apply one'; $two=Start-FixtureOwned $arguments 'apply two'
    Wait-Fixture { @(Get-ChildItem -LiteralPath $script:scenarioFolder -Filter 'apply ready *.json').Count -eq 2 } 'two Apply clients at common barrier'
    [IO.File]::WriteAllText((Join-Path $script:scenarioFolder 'release apply.request'),'release')
    Wait-Fixture { $one.RootExited -and $two.RootExited } 'concurrent Apply clients' 8
    $first=Read-FixtureJson (Join-Path $script:scenarioFolder 'apply one.stdout.log')
    $second=Read-FixtureJson (Join-Path $script:scenarioFolder 'apply two.stdout.log')
    Assert-True ($one.ExitCode -eq 0 -or $two.ExitCode -eq 0) 'Both Apply clients failed.'
    foreach($result in @($first,$second)) { Assert-True ($result.status -in @('reconciled','conflict')) 'Concurrent Apply must serialize or reject.' }
    Assert-True ($first.status -eq 'reconciled' -or $second.status -eq 'reconciled') 'Neither Apply client reported a parsed reconciled status.'
    $ledger=Read-FixtureJson $fixture.ledger
    Assert-Equal 112.5 $ledger.elapsedSeconds 'Concurrent Apply charged twice.'
    Assert-Equal 1 @($ledger.attempts).Count 'Concurrent Apply duplicated attempt.'
    Assert-Equal 12.5 $ledger.attempts[0].chargedSeconds 'Concurrent charged seconds.'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.run 'reconcile-commit.json')) 'No committed transaction.'
}
Invoke-FixtureScenario 'rejects foreign owner process tuple on second attempt' {
    $fixture=New-AccountingFixture
    Assert-Equal 0 (Invoke-ReconcileFixture $fixture -Apply).exitCode 'Predecessor a1 Apply exit.'
    Assert-Equal 112.5 (Read-FixtureJson $fixture.ledger).elapsedSeconds 'Predecessor a1 charge.'
    $second=Initialize-SecondAttemptFixture $fixture
    $progress=Read-FixtureJson $fixture.progress
    $foreignOwnerStart=[DateTimeOffset]::Parse($second.caseStart).AddSeconds(-10).UtcDateTime.ToString('o')
    $progress.owner=@{processId=([int]$second.identity.rootProcessId+11);matlabRelease='R2025b';startedAtUtc=$second.caseStart;
        processStartTimeUtc=$foreignOwnerStart;commandLine='fixture-only never executed'}
    Write-FixtureJson $fixture.progress $progress
    $ledgerBefore=(Get-FileHash -LiteralPath $fixture.ledger -Algorithm SHA256).Hash
    $progressBefore=(Get-FileHash -LiteralPath $fixture.progress -Algorithm SHA256).Hash
    $intentPath=Join-Path $fixture.run 'reconcile-intent.json'; $commitPath=Join-Path $fixture.run 'reconcile-commit.json'
    $intentBefore=(Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash
    $commitBefore=(Get-FileHash -LiteralPath $commitPath -Algorithm SHA256).Hash
    $protectedBefore=(Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash
    $registryBefore=(Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash
    $result=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 'conflict' $result.json.status 'Foreign owner process tuple must conflict.'
    Assert-Equal 1 $result.exitCode 'Foreign owner process tuple conflict exit.'
    Assert-Equal $ledgerBefore (Get-FileHash -LiteralPath $fixture.ledger -Algorithm SHA256).Hash 'Foreign owner conflict changed ledger.'
    Assert-Equal $progressBefore (Get-FileHash -LiteralPath $fixture.progress -Algorithm SHA256).Hash 'Foreign owner conflict changed progress.'
    Assert-Equal $intentBefore (Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash 'Foreign owner conflict replaced predecessor intent.'
    Assert-Equal $commitBefore (Get-FileHash -LiteralPath $commitPath -Algorithm SHA256).Hash 'Foreign owner conflict replaced predecessor commit.'
    Assert-Equal $protectedBefore (Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash 'Foreign owner conflict changed protected fixture.'
    Assert-Equal $registryBefore (Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash 'Foreign owner conflict changed registry.'
    $after=Read-FixtureJson $fixture.ledger
    Assert-Equal 112.5 $after.elapsedSeconds 'Foreign owner conflict charged a2.'
    Assert-Equal 'active' $after.attempts[1].status 'Foreign owner conflict closed a2.'
    Assert-Equal 0 $after.attempts[1].chargedSeconds 'Foreign owner conflict charged a2.'
}
Invoke-FixtureScenario 'rejects synchronized activeCase root tuple substitution' {
    $fixture=New-AccountingFixture
    Assert-Equal 0 (Invoke-ReconcileFixture $fixture -Apply).exitCode 'Predecessor a1 Apply exit.'
    Assert-Equal 112.5 (Read-FixtureJson $fixture.ledger).elapsedSeconds 'Predecessor a1 charge.'
    $second=Initialize-SecondAttemptFixture $fixture
    $started=Read-FixtureJson (Join-Path $fixture.processFolder 'process-started.json')
    $report=Read-FixtureJson $fixture.report
    foreach($field in @('runId','rootProcessId','processStartTimeUtc','workerProcessId','workerProcessStartTimeUtc')) {
        Assert-Equal ([string]$started.$field) ([string]$report.$field) "Fixture report identity mismatch: $field."
    }
    $foreignRootStart=[DateTimeOffset]::Parse($second.caseStart).AddSeconds(-10).UtcDateTime.ToString('o')
    $active=Read-FixtureJson $fixture.ledger
    $active=$active.activeCase
    $active.rootProcessId=[int]$second.identity.rootProcessId+11
    $active.processStartTimeUtc=$foreignRootStart
    $ledger=Read-FixtureJson $fixture.ledger; $ledger.activeCase=$active
    Write-FixtureJson $fixture.ledger $ledger
    $progress=Read-FixtureJson $fixture.progress; $progress.activeCase=$active
    Write-FixtureJson $fixture.progress $progress
    $ledgerBefore=(Get-FileHash -LiteralPath $fixture.ledger -Algorithm SHA256).Hash
    $progressBefore=(Get-FileHash -LiteralPath $fixture.progress -Algorithm SHA256).Hash
    $intentPath=Join-Path $fixture.run 'reconcile-intent.json'; $commitPath=Join-Path $fixture.run 'reconcile-commit.json'
    $intentBefore=(Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash
    $commitBefore=(Get-FileHash -LiteralPath $commitPath -Algorithm SHA256).Hash
    $protectedBefore=(Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash
    $registryBefore=(Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash
    $result=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 'conflict' $result.json.status 'Synchronized activeCase root tuple substitution must conflict.'
    Assert-Equal 1 $result.exitCode 'Synchronized activeCase root tuple conflict exit.'
    Assert-Equal $ledgerBefore (Get-FileHash -LiteralPath $fixture.ledger -Algorithm SHA256).Hash 'ActiveCase tuple conflict changed ledger.'
    Assert-Equal $progressBefore (Get-FileHash -LiteralPath $fixture.progress -Algorithm SHA256).Hash 'ActiveCase tuple conflict changed progress.'
    Assert-Equal $intentBefore (Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash 'ActiveCase tuple conflict replaced predecessor intent.'
    Assert-Equal $commitBefore (Get-FileHash -LiteralPath $commitPath -Algorithm SHA256).Hash 'ActiveCase tuple conflict replaced predecessor commit.'
    Assert-Equal $protectedBefore (Get-FileHash -LiteralPath $fixture.protected -Algorithm SHA256).Hash 'ActiveCase tuple conflict changed protected fixture.'
    Assert-Equal $registryBefore (Get-FileHash -LiteralPath $fixture.registry -Algorithm SHA256).Hash 'ActiveCase tuple conflict changed registry.'
    $after=Read-FixtureJson $fixture.ledger
    Assert-Equal 112.5 $after.elapsedSeconds 'ActiveCase tuple conflict charged a2.'
    Assert-Equal 'active' $after.attempts[1].status 'ActiveCase tuple conflict closed a2.'
    Assert-Equal 0 $after.attempts[1].chargedSeconds 'ActiveCase tuple conflict charged a2.'
}
Invoke-FixtureScenario 'R4.4 clean pause authorizes resume across worker IDs' {
    $fixture=New-AccountingFixture
    $completedAt='2026-01-01T00:00:12.5000000Z'
    $ledger=Read-FixtureJson $fixture.ledger
    $ledger.elapsedSeconds=112.5
    $ledger.attempts[0].status='completed'
    $ledger.attempts[0].observedSeconds=12.5
    $ledger.attempts[0].chargedSeconds=12.5
    $ledger.attempts[0].finishedAtUtc=$completedAt
    $ledger.attempts[0].processReportSha256=''
    $ledger.activeCase=@{}
    $ledger.pendingCases=@(500,1000,2500)
    $ledger.phaseTimes=@($ledger.phaseTimes)+@(@{phase='stage-3-load-probe';startedAtUtc='2026-01-01T00:00:00.0000000Z';
        finishedAtUtc=$completedAt;elapsedSeconds=12.5;caseKey='fixture-case'})
    Add-Member -InputObject $ledger -MemberType NoteProperty -Name 'updatedAtUtc' -Value $completedAt -Force
    Write-FixtureJson $fixture.ledger $ledger

    $progress=Read-FixtureJson $fixture.progress
    $progress.runId=$fixture.runId
    $progress.status='paused'; $progress.activeCase=@{}
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'phase' -Value 'paused' -Force
    $progress.pendingCounts=@(500,1000,2500); $progress.budgetElapsedSeconds=112.5
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'updatedAtUtc' -Value $completedAt -Force
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'currentTick' -Value 5000 -Force
    Write-FixtureJson $fixture.progress $progress
    $summary=Read-FixtureJson $fixture.summary
    $summary.status='paused'; $summary.budgetElapsedSeconds=112.5
    Write-FixtureJson $fixture.summary $summary

    $report=Read-FixtureJson $fixture.report
    $report.status='completed'; $report.exitCode=0; $report.elapsedSeconds=12.5
    $report.finishedAtUtc=$completedAt; $report.attemptId='a1'; $report.caseKey='fixture-case'
    Write-FixtureJson $fixture.report $report
    $cleanReportSha=(Get-FileHash -LiteralPath $fixture.report -Algorithm SHA256).Hash.ToLowerInvariant()
    $firstWorkerId=$fixture.runId

    $clean=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $clean.exitCode "Clean paused reconcile exit. reason=$($clean.json.reason)"
    Assert-Equal 'reconciled' $clean.json.status 'Clean paused worker must reconcile.'
    Assert-Equal $true $clean.json.resumeAllowed 'Clean paused worker must receive resume authorization.'
    Assert-Equal 112.5 $clean.json.elapsedSeconds 'Clean paused reconcile charged elapsed a second time.'
    $cleanLedger=Read-FixtureJson $fixture.ledger
    Assert-Equal 1 @($cleanLedger.attempts).Count 'Clean pause changed attempt history length.'
    Assert-Equal $firstWorkerId $cleanLedger.attempts[0].runId 'Clean pause changed its completed attempt worker ID.'
    Assert-Equal '' ([string]$cleanLedger.attempts[0].processReportSha256) 'Worker report was attributed to a completed case attempt.'
    Assert-Equal 12.5 $cleanLedger.attempts[0].chargedSeconds 'Clean pause changed completed attempt charge.'
    $cleanIntent=Read-FixtureJson (Join-Path $fixture.run 'reconcile-intent.json')
    $cleanCommit=Read-FixtureJson (Join-Path $fixture.run 'reconcile-commit.json')
    Assert-Equal 'clean-paused-worker' $cleanIntent.accountingKind 'Clean pause transaction kind.'
    Assert-Equal $firstWorkerId $cleanIntent.runId 'Clean pause intent worker ID.'
    Assert-Equal $cleanReportSha $cleanIntent.processReportSha256 'Clean pause report SHA linkage.'
    Assert-Equal $true $cleanCommit.resumeAllowed 'Clean pause commit must authorize explicit resume.'
    Assert-Equal $firstWorkerId $cleanCommit.runId 'Clean pause commit worker ID.'

    # A resumed worker gets a new run ID and appends its own case attempt.
    $secondWorkerId=[guid]::NewGuid().ToString('N')
    $caseKey2='fixture-case-worker-2'
    $caseStart2='2026-01-02T00:00:00.0000000Z'
    $workerStart2=[DateTimeOffset]::Parse($caseStart2).AddSeconds(-1).UtcDateTime.ToString('o')
    $workerEnd2=[DateTimeOffset]::Parse($caseStart2).AddSeconds(8).UtcDateTime.ToString('o')
    $absent=@(); $candidate=1900000000
    while ($absent.Count -lt 2) {
        if ($null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { $absent+= [int]$candidate }
        $candidate--
    }
    $workerFolder2=Join-Path $fixture.run ('workers/worker-'+$secondWorkerId)
    [void][IO.Directory]::CreateDirectory($workerFolder2)
    $identity2=@{runId=$secondWorkerId;rootProcessId=$absent[0];processStartTimeUtc=$workerStart2;
        workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart2;executable=$script:shellExe;
        arguments='fixture-only second worker never executed';workingDirectory=$fixture.run}
    $active2=@{attemptId='a2';runId=$secondWorkerId;caseKey=$caseKey2;numUE=500;startedAtUtc=$caseStart2;
        lastProgressAtUtc=$caseStart2;runFolder=$fixture.run;rootProcessId=$absent[0];processStartTimeUtc=$workerStart2;
        workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart2}
    $attempt2=@{attemptId='a2';runId=$secondWorkerId;caseKey=$caseKey2;startedAtUtc=$caseStart2;finishedAtUtc='';
        status='active';observedSeconds=0;chargedSeconds=0;processReportSha256=''}
    $ledger=Read-FixtureJson $fixture.ledger
    $ledger.attempts=@($ledger.attempts)+@($attempt2)
    $ledger.activeCase=$active2
    $ledger.phaseTimes=@($ledger.phaseTimes)+@(@{phase='stage-3-load-probe';startedAtUtc=$caseStart2;
        finishedAtUtc='';elapsedSeconds=0;caseKey=$caseKey2})
    $ledger.updatedAtUtc=$caseStart2
    Write-FixtureJson $fixture.ledger $ledger

    $progress=Read-FixtureJson $fixture.progress
    $progress.runId=$secondWorkerId; $progress.status='running'; $progress.phase='load-500-running'
    $progress.activeCase=$active2; $progress.updatedAtUtc=$caseStart2; $progress.currentTick=0
    Write-FixtureJson $fixture.progress $progress

    $reportPath2=Join-Path $workerFolder2 'process-report.json'
    Write-FixtureJson (Join-Path $workerFolder2 'launch.json') $identity2
    Write-FixtureJson (Join-Path $workerFolder2 'process-started.json') $identity2
    Write-FixtureJson $reportPath2 ($identity2+@{status='failed';exitCode=24;startedAtUtc=$workerStart2;
        finishedAtUtc=$workerEnd2;elapsedSeconds=9;attemptId='a2';caseKey=$caseKey2;sampledPeakWorkingSetBytes=1})
    $worker=@{status='running';runId=$secondWorkerId;runFolder=$fixture.run;workerFolder=$workerFolder2;
        workerProcessId=$absent[1];workerProcessStartTimeUtc=$workerStart2;matlabProcessId=$absent[0];
        matlabProcessStartTimeUtc=$workerStart2;executable=$script:shellExe;arguments=$identity2.arguments;
        processReport=$reportPath2;progressFile=(Join-Path (Split-Path $fixture.progress -Parent) 'worker-progress.json');
        heartbeat=(Join-Path $workerFolder2 'heartbeat.json')}
    Write-FixtureJson (Join-Path $fixture.run 'worker.json') $worker
    $manifest=Read-FixtureJson (Join-Path $fixture.run 'run-manifest.json')
    $manifest.runId=$secondWorkerId; $manifest.status='running'
    Add-Member -InputObject $manifest -MemberType NoteProperty -Name 'updatedAtUtc' -Value $caseStart2 -Force
    Write-FixtureJson (Join-Path $fixture.run 'run-manifest.json') $manifest
    $fixture.runId=$secondWorkerId; $fixture.processFolder=$workerFolder2; $fixture.report=$reportPath2

    $second=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $second.exitCode 'Second worker distinct attempt reconcile exit.'
    Assert-Equal 'reconciled' $second.json.status 'Second worker distinct attempt status.'
    $after=Read-FixtureJson $fixture.ledger
    Assert-Equal 120.5 $after.elapsedSeconds 'Second worker attempt total charge.'
    Assert-Equal 2 @($after.attempts).Count 'Second worker attempt history length.'
    Assert-Equal $firstWorkerId $after.attempts[0].runId 'Prior worker attempt identity was rewritten.'
    Assert-Equal $secondWorkerId $after.attempts[1].runId 'New worker attempt identity was not retained.'
    Assert-Equal '' ([string]$after.attempts[0].processReportSha256) 'Second worker report was attributed to the prior attempt.'
    Assert-Equal 12.5 $after.attempts[0].chargedSeconds 'Second worker changed prior attempt charge.'
    Assert-Equal 8 $after.attempts[1].chargedSeconds 'Second worker attempt charge.'
    $secondReportSha=(Get-FileHash -LiteralPath $fixture.report -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $secondReportSha ([string]$after.attempts[1].processReportSha256).ToLowerInvariant() 'Second worker report SHA must belong to a2.'
    $secondIntent=Read-FixtureJson (Join-Path $fixture.run 'reconcile-intent.json')
    Assert-Equal 'clean-paused-worker' $secondIntent.predecessorProof.intent.accountingKind 'Second worker intent must retain the clean-pause predecessor proof for crash recovery.'
    Assert-Equal $firstWorkerId $secondIntent.predecessorProof.commit.runId 'Embedded predecessor commit worker identity.'
    $secondCommit=Read-FixtureJson (Join-Path $fixture.run 'reconcile-commit.json')
    Assert-Equal $secondWorkerId $secondCommit.runId 'Second worker commit identity.'
}

Invoke-FixtureScenario 'R4.4 predecessor replay survives rotated backups' {
    $fixture=New-AccountingFixture
    Initialize-CleanPauseAccountingFixture $fixture 112.5
    $first=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $first.exitCode 'First clean-pause fixture setup.'
    $oldCommitPath=Join-Path $fixture.run 'reconcile-commit.json'
    $oldCommitRaw=[IO.File]::ReadAllText($oldCommitPath)

    $secondWorker=Initialize-SecondAttemptFixture $fixture
    $second=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $second.exitCode 'Second-attempt transaction fixture setup.'
    $newIntentPath=Join-Path $fixture.run 'reconcile-intent.json'
    $newIntent=Read-FixtureJson $newIntentPath
    Assert-Equal $fixture.runId $newIntent.runId 'New intent must identify worker 2.'
    Assert-Equal 'clean-paused-worker' $newIntent.predecessorProof.intent.accountingKind 'New intent must embed worker 1 clean-pause proof.'

    # Model interruption after intent publication and backup rotation, before
    # targets and the old commit are replaced. The shared .before files now
    # correctly contain worker 2's transaction baseline, not worker 1's.
    foreach($entry in $newIntent.entries) {
        Assert-Equal ([string]$entry.oldSha256) ((Get-FileHash -LiteralPath ([string]$entry.beforePath) -Algorithm SHA256).Hash.ToLowerInvariant()) 'Rotated backup must match the pending intent baseline.'
        [IO.File]::Copy([string]$entry.beforePath,[string]$entry.path,$true)
    }
    [IO.File]::WriteAllText($oldCommitPath,$oldCommitRaw,[Text.UTF8Encoding]::new($false))
    $oldTargetHashes=@(foreach($entry in $newIntent.entries) { (Get-FileHash -LiteralPath ([string]$entry.path) -Algorithm SHA256).Hash.ToLowerInvariant() })
    $rotatedBackupHashes=@(foreach($entry in $newIntent.entries) { (Get-FileHash -LiteralPath ([string]$entry.beforePath) -Algorithm SHA256).Hash.ToLowerInvariant() })

    $replay=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $replay.exitCode "Crash-window recovery after backup rotation. reason=$($replay.json.reason)"
    Assert-Equal 'reconciled' $replay.json.status 'Pending second-attempt intent must replay after predecessor backup rotation.'
    Assert-Equal $true $replay.json.replayed 'Crash-window scenario must exercise transaction replay.'
    $after=Read-FixtureJson $fixture.ledger
    Assert-Equal 119.75 $after.elapsedSeconds 'Crash recovery must charge worker 2 exactly once.'
    Assert-Equal 2 @($after.attempts).Count 'Crash recovery must preserve both attempt rows.'
    Assert-Equal $secondWorker.caseKey $after.attempts[1].caseKey 'Crash recovery must retain worker 2 attempt identity.'
    Assert-Equal 7.25 $after.attempts[1].chargedSeconds 'Crash recovery changed the worker 2 charge.'
    $newCommit=Read-FixtureJson $oldCommitPath
    Assert-Equal $fixture.runId $newCommit.runId 'Crash recovery must publish the second worker commit.'
    foreach($entry in $newIntent.entries) {
        Assert-Equal ([string]$entry.newSha256) ((Get-FileHash -LiteralPath ([string]$entry.path) -Algorithm SHA256).Hash.ToLowerInvariant()) 'Crash recovery target digest.'
    }
    $replayAgain=Invoke-ReconcileFixture $fixture -Apply
    Assert-Equal 0 $replayAgain.exitCode 'Repeated crash recovery Apply exit.'
    Assert-Equal $true $replayAgain.json.replayed 'Repeated Apply must use the committed replay path.'
    $afterRepeat=Read-FixtureJson $fixture.ledger
    Assert-Equal 119.75 $afterRepeat.elapsedSeconds 'Repeated recovery charged worker 2 more than once.'
    Assert-Equal 2 @($afterRepeat.attempts).Count 'Repeated recovery changed attempt history length.'
    Assert-Equal 7.25 $afterRepeat.attempts[1].chargedSeconds 'Repeated recovery changed worker 2 charge.'
    Assert-Equal $newIntent.entries.Count $oldTargetHashes.Count 'Crash fixture target capture.'
    Assert-Equal $newIntent.entries.Count $rotatedBackupHashes.Count 'Crash fixture backup capture.'
}

Invoke-FixtureScenario 'R4.6 exhausted clean pause refuses resume without worker' {
    $fixture=New-AccountingFixture
    $budget=57600.0
    Initialize-CleanPauseAccountingFixture $fixture $budget
    $probe=Split-Path $fixture.progress -Parent
    $projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $sourceManifestSha=Get-FixtureSourceManifestSha256 $projectRoot
    $runnerSha=(Get-FileHash -LiteralPath (Join-Path $projectRoot 'experiments\runLoadProbe.m') -Algorithm SHA256).Hash.ToLowerInvariant()
    $progress=Read-FixtureJson $fixture.progress
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'runFolder' -Value $probe -Force
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'sourceManifestSha256' -Value $sourceManifestSha -Force
    Add-Member -InputObject $progress -MemberType NoteProperty -Name 'runnerSha256' -Value $runnerSha -Force
    Write-FixtureJson $fixture.progress $progress
    Write-FixtureJson (Join-Path $probe 'preflight.json') @{status='passed';sourceManifestSha256=$sourceManifestSha;runnerSha256=$runnerSha}
    $clean=Invoke-ReconcileFixture $fixture -Apply
    $intentPath=Join-Path $fixture.run 'reconcile-intent.json'
    $commitPath=Join-Path $fixture.run 'reconcile-commit.json'
    $cleanIntent=Read-FixtureJson $intentPath
    $cleanCommit=Read-FixtureJson $commitPath
    $observedIntentResume=[bool]$cleanIntent.resumeAllowed
    $observedCommitResume=[bool]$cleanCommit.resumeAllowed

    # Independently exercise the runner's budget-only path with the exact
    # synthetic run identity and ledger. A missing worker manifest is
    # intentional: exhaustion must be resolved before any process tuple read.
    $manifestPath=Join-Path $fixture.run 'run-manifest.json'
    $runManifest=Read-FixtureJson $manifestPath
    $runManifest.runId=$fixture.runId; $runManifest.runFolder=$fixture.run
    $runManifest.sharedBudgetLedger=$fixture.ledger; $runManifest.status='running'
    Add-Member -InputObject $runManifest -MemberType NoteProperty -Name 'updatedAtUtc' -Value '2026-01-01T00:00:00.0000000Z' -Force
    Add-Member -InputObject $runManifest -MemberType NoteProperty -Name 'round3PreservationSentinel' -Value 'must-survive-budget-pause' -Force
    Write-FixtureJson $manifestPath $runManifest
    $options=Read-FixtureJson (Join-Path $fixture.run 'worker-options.json')
    $options.budgetLedgerFile=$fixture.ledger; $options.outputFolder=$probe
    Add-Member -InputObject $options -MemberType NoteProperty -Name 'stage2AcceptanceFile' -Value (Join-Path $PSScriptRoot '..\completion\stage-2\acceptance.json') -Force
    Write-FixtureJson (Join-Path $fixture.run 'worker-options.json') $options

    # Supply the expected frozen clean-pause transaction contract to the runner
    # fixture. The reconciler assertions below independently require that real
    # Apply emit the same false authorization at all three boundaries.
    Add-Member -InputObject $cleanIntent -MemberType NoteProperty -Name 'accountingKind' -Value 'clean-paused-worker' -Force
    $cleanIntent.resumeAllowed=$false; Write-FixtureJson $intentPath $cleanIntent
    Add-Member -InputObject $cleanCommit -MemberType NoteProperty -Name 'accountingKind' -Value 'clean-paused-worker' -Force
    $cleanCommit.resumeAllowed=$false; Write-FixtureJson $commitPath $cleanCommit
    $workerPath=Join-Path $fixture.run 'worker.json'
    if (Test-Path -LiteralPath $workerPath) { Remove-Item -LiteralPath $workerPath -Force }
    $ledgerBefore=(Get-FileHash -LiteralPath $fixture.ledger -Algorithm SHA256).Hash.ToLowerInvariant()
    $progressBefore=(Get-FileHash -LiteralPath $fixture.progress -Algorithm SHA256).Hash.ToLowerInvariant()
    $intentBefore=(Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $commitBefore=(Get-FileHash -LiteralPath $commitPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedBudgetManifest=Read-FixtureJson $manifestPath
    $expectedBudgetManifest.status='budget-paused'
    $expectedBudgetManifestStableJson=($expectedBudgetManifest | Select-Object -Property * -ExcludeProperty status,updatedAtUtc) | ConvertTo-Json -Depth 20 -Compress
    $optionsPath=Join-Path $fixture.run 'worker-options.json'
    $optionsBefore=(Get-FileHash -LiteralPath $optionsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestBeforeContendedResume=Read-FixtureJson $manifestPath
    $contendedResume=Invoke-BudgetResumeFixture $fixture -HoldWriterLease
    $manifestAfterContendedResume=Read-FixtureJson $manifestPath
    $manifestAfterContendedResumeHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $resume=Invoke-BudgetResumeFixture $fixture
    $manifestAfterBudget=Read-FixtureJson $manifestPath
    $manifestAfterBudgetStableJson=($manifestAfterBudget | Select-Object -Property * -ExcludeProperty status,updatedAtUtc) | ConvertTo-Json -Depth 20 -Compress
    $manifestUpdatedAtUtcParsed=$false; $manifestUpdatedAtUtc=[DateTimeOffset]::MinValue
    try { $manifestUpdatedAtUtc=[DateTimeOffset]::Parse([string]$manifestAfterBudget.updatedAtUtc); $manifestUpdatedAtUtcParsed=$true } catch { }
    $resumeAgain=Invoke-BudgetResumeFixture $fixture
    $manifestAfterRepeat=Read-FixtureJson $manifestPath
    $optionsAfterBudget=(Get-FileHash -LiteralPath $optionsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $mismatchedIdentity=Invoke-BudgetResumeFixture $fixture -MismatchRunIdentity
    $mismatchedIdentityManifestAfter=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $mismatchedLedger=Invoke-BudgetResumeFixture $fixture -MismatchLedgerPath
    $mismatchedLedgerManifestAfter=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $ownerStopManifest=Read-FixtureJson $manifestPath
    $ownerStopManifest.runId=$fixture.runId; $ownerStopManifest.sharedBudgetLedger=$fixture.ledger
    Write-FixtureJson $manifestPath $ownerStopManifest
    $ownerStopPath=Join-Path $fixture.run 'owner-stop.json'
    Write-FixtureJson $ownerStopPath @{stoppedAtUtc='2026-01-01T00:00:13.0000000Z';reason='synthetic owner stop'}
    $ownerStopResume=Invoke-BudgetResumeFixture $fixture
    $ownerStopManifestAfter=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Remove-Item -LiteralPath $ownerStopPath -Force

    $ledgerAfter=(Get-FileHash -LiteralPath $fixture.ledger -Algorithm SHA256).Hash.ToLowerInvariant()
    $progressAfter=(Get-FileHash -LiteralPath $fixture.progress -Algorithm SHA256).Hash.ToLowerInvariant()
    $intentAfter=(Get-FileHash -LiteralPath $intentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $commitAfter=(Get-FileHash -LiteralPath $commitPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $failures=[Collections.Generic.List[string]]::new()
    foreach($check in @(
        { Assert-Equal 0 $clean.exitCode 'Exhausted clean-pause reconcile exit.' },
        { Assert-Equal $false $clean.json.resumeAllowed 'Exhausted clean pause must deny resume in the response.' },
        { Assert-Equal $false $observedIntentResume 'Exhausted clean pause must deny resume in its intent.' },
        { Assert-Equal $false $observedCommitResume 'Exhausted clean pause must deny resume in its commit.' },
        { Assert-Equal $budget (Read-FixtureJson $fixture.ledger).elapsedSeconds 'Budget test must use exact shared-ledger exhaustion.' },
        { Assert-Equal 'error' $contendedResume.json.status 'Writer lease contention must fail closed.' },
        { Assert-True ([string]$contendedResume.json.reason -match '^writer-lease-unavailable:') 'Writer lease contention must report writer-lease-unavailable.' },
        { Assert-Equal 0 $contendedResume.json.liveLookups 'Writer lease contention must fail before live process/PID lookup.' },
        { Assert-Equal $contendedResume.manifestHashBefore $manifestAfterContendedResumeHash 'Writer lease contention must not write run-manifest.' },
        { Assert-Equal 'running' $manifestAfterContendedResume.status 'Writer lease contention must preserve run-manifest status.' },
        { Assert-Equal ([string]$manifestBeforeContendedResume.updatedAtUtc) ([string]$manifestAfterContendedResume.updatedAtUtc) 'Writer lease contention must preserve run-manifest updatedAtUtc.' },
        { Assert-True (-not (Test-Path -LiteralPath $workerPath)) 'Writer lease contention must not create a worker manifest.' },
        { Assert-Equal 'returned' $resume.json.status "Exact exhausted identity should take the no-worker branch. reason=$($resume.json.reason)" },
        { Assert-Equal 'budget-paused' $resume.json.result.status 'Exhausted clean pause must report budget-paused.' },
        { Assert-Equal $false $resume.json.result.workerStarted 'Exhausted clean pause must not start a worker.' },
        { Assert-Equal 0 $resume.json.liveLookups 'No-worker budget route must precede live process/PID lookup.' },
        { Assert-Equal 'budget-paused' $manifestAfterBudget.status 'Validated exhausted no-worker Resume must mark run-manifest budget-paused.' },
        { Assert-Equal $expectedBudgetManifestStableJson $manifestAfterBudgetStableJson 'Budget pause must preserve every manifest field except status and updatedAtUtc.' },
        { Assert-True $manifestUpdatedAtUtcParsed 'Budget pause must write a valid run-manifest updatedAtUtc.' },
        { Assert-True ($manifestUpdatedAtUtc -gt [DateTimeOffset]::Parse('2026-01-01T00:00:00.0000000Z')) 'Budget pause must advance run-manifest updatedAtUtc.' },
        { Assert-Equal 'budget-paused' $resumeAgain.json.result.status 'Repeated no-worker Resume must remain budget-paused.' },
        { Assert-Equal 0 $resumeAgain.json.liveLookups 'Repeated budget pause must remain before live process/PID lookup.' },
        { Assert-Equal 'budget-paused' $manifestAfterRepeat.status 'Repeated Resume must keep run-manifest budget-paused.' },
        { Assert-True (($mismatchedIdentity.json.status -ne 'returned') -or ($mismatchedIdentity.json.result.status -ne 'budget-paused')) 'Mismatched run identity must fail closed instead of receiving the no-worker budget result.' },
        { Assert-Equal 0 $mismatchedIdentity.json.liveLookups 'Mismatched run identity must fail before live process/PID lookup.' },
        { Assert-Equal $mismatchedIdentity.manifestHashBefore $mismatchedIdentityManifestAfter 'Mismatched run identity must not update run-manifest.' },
        { Assert-True (($mismatchedLedger.json.status -ne 'returned') -or ($mismatchedLedger.json.result.status -ne 'budget-paused')) 'Mismatched shared ledger path must fail closed instead of receiving the no-worker budget result.' },
        { Assert-Equal 0 $mismatchedLedger.json.liveLookups 'Mismatched shared ledger path must fail before live process/PID lookup.' },
        { Assert-Equal $mismatchedLedger.manifestHashBefore $mismatchedLedgerManifestAfter 'Mismatched shared ledger path must not update run-manifest.' },
        { Assert-Equal 'error' $ownerStopResume.json.status 'Owner-stop must refuse the no-worker budget route.' },
        { Assert-True ([string]$ownerStopResume.json.reason -match '^owner-stopped:') 'Owner-stop refusal must have the owner-stopped reason.' },
        { Assert-Equal 0 $ownerStopResume.json.liveLookups 'Owner-stop refusal must precede live process/PID lookup.' },
        { Assert-Equal $ownerStopResume.manifestHashBefore $ownerStopManifestAfter 'Owner-stop must leave run-manifest unchanged.' },
        { Assert-Equal $ledgerBefore $ledgerAfter 'No-worker budget route changed accounting ledger.' },
        { Assert-Equal $progressBefore $progressAfter 'No-worker budget route changed progress.' },
        { Assert-Equal $intentBefore $intentAfter 'No-worker budget route changed reconcile intent.' },
        { Assert-Equal $commitBefore $commitAfter 'No-worker budget route changed reconcile commit.' },
        { Assert-Equal $optionsBefore $optionsAfterBudget 'No-worker budget route changed worker options.' },
        { Assert-True (-not (Test-Path -LiteralPath $workerPath)) 'No-worker budget route created a worker manifest.' }
    )) { Record-FixtureAssertion $failures $check }
    if ($failures.Count -gt 0) { throw ($failures -join ' || ') }
}
Complete-FixtureSuite 'accounting-fixtures.json'
