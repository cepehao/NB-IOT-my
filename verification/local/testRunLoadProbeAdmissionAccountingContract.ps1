$ErrorActionPreference='Stop'
$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$probePath=Join-Path $projectRoot 'experiments\runLoadProbe.m'
$ledgerPath=Join-Path $projectRoot 'src\+nbiot\+experiments\loadVariant2BudgetLedger.m'
$runnerPath=Join-Path $projectRoot 'verification\completion\stage-3\runVariant2.ps1'
$testPath=Join-Path $projectRoot 'tests\TestLoadProbe.m'
$probe=[IO.File]::ReadAllText($probePath)
$ledger=[IO.File]::ReadAllText($ledgerPath)
$runner=[IO.File]::ReadAllText($runnerPath)
$matlabTest=[IO.File]::ReadAllText($testPath)
$mainEnd=$probe.IndexOf('function options=loadProbeOptions',[StringComparison]::Ordinal)
if ($mainEnd -lt 0) { throw 'Could not locate runLoadProbe main-function boundary.' }
$main=$probe.Substring(0,$mainEnd)
$loopIndex=$main.IndexOf('while ~isempty(progress.pendingCounts)',[StringComparison]::Ordinal)
$firstStopIndex=$main.IndexOf('if stopAfterCaseRequested(options,runId)',[StringComparison]::Ordinal)
$caseConfigIndex=$main.IndexOf('cfg=loadCaseConfig(count,realizationId,options);',[StringComparison]::Ordinal)
$attemptIndex=$main.IndexOf('attemptId=char(java.util.UUID.randomUUID())',[StringComparison]::Ordinal)
$appendAttemptIndex=$main.IndexOf('ledger=beginBudgetAttempt(ledger,active);',[StringComparison]::Ordinal)
$runnerIndex=$main.IndexOf('meta=nbiot.experiments.runStaticCase',[StringComparison]::Ordinal)
$evidenceIndex=$main.IndexOf('writeCaseEvidence(options.outputFolder,caseRecord,meta,identity);',[StringComparison]::Ordinal)
$secondStopIndex=$main.IndexOf('if stopAfterCaseRequested(options,runId)', $firstStopIndex + 1,[StringComparison]::Ordinal)
$postCaseStopIndex=$main.IndexOf('if ~isempty(progress.pendingCounts)&&stopAfterCaseRequested(options,runId)',[StringComparison]::Ordinal)
$postCaseSaveIndex=$main.IndexOf('saveProgressAndSummary(progressPath,options.outputFolder,progress,plan);',$postCaseStopIndex,[StringComparison]::Ordinal)
$postCaseBreakIndex=$main.IndexOf('break;',$postCaseSaveIndex,[StringComparison]::Ordinal)
$caseCatchIndex=$main.IndexOf('catch exception',$evidenceIndex,[StringComparison]::Ordinal)
if (-not ($loopIndex -ge 0 -and $firstStopIndex -gt $loopIndex -and
        $firstStopIndex -lt $caseConfigIndex -and $secondStopIndex -gt $caseConfigIndex -and
        $evidenceIndex -gt $secondStopIndex -and $postCaseStopIndex -gt $evidenceIndex -and
        $postCaseSaveIndex -gt $postCaseStopIndex -and $postCaseBreakIndex -gt $postCaseSaveIndex -and
        $postCaseBreakIndex -lt $caseCatchIndex)) {
    throw 'Stop-after-case checks must bracket case admission and run after verified case evidence.'
}
if (-not ($attemptIndex -ge 0 -and $appendAttemptIndex -gt $attemptIndex -and
        $appendAttemptIndex -lt $runnerIndex -and
        $main.IndexOf('runId', $attemptIndex,[StringComparison]::Ordinal) -ge 0)) {
    throw 'A run-linked UUID attempt must be saved to the ledger before runner dispatch.'
}
$finishStart=$probe.IndexOf('function ledger=finishBudgetCase',[StringComparison]::Ordinal)
$finishEnd=$probe.IndexOf('function ledger=closeBudgetPhase',[StringComparison]::Ordinal)
if ($finishStart -lt 0 -or $finishEnd -le $finishStart) { throw 'Could not locate budget-attempt finalizer.' }
$finish=$probe.Substring($finishStart,$finishEnd-$finishStart)
if ($finish -notmatch 'max\(0,seconds-chargedSeconds\)' -or
        $finish -notmatch 'chargedSeconds=max\(chargedSeconds,seconds\)' -or
        $finish -notmatch 'attempts') {
    throw 'Case finalization must charge only the uncharged delta and close its attempt record.'
}
if ($ledger -notmatch 'accountingVersion' -or $ledger -notmatch 'attempts' -or
        $ledger -notmatch 'attemptId' -or $ledger -notmatch 'processReportSha256') {
    throw 'The shared ledger reader must add compatible accountingVersion 2 attempt defaults.'
}
if ($runner -notmatch [regex]::Escape("Set-OptionField `$options 'runId' `$runId") -or
        $runner -notmatch [regex]::Escape("Set-OptionField `$options 'runControlFolder' `$runRoot") -or
        $runner -notmatch 'stop-after-case\.request\.json' -or
        $runner -notmatch 'Clear-StopAfterCaseMarkerForResume' -or
        $runner -notmatch '-RunId \$runId') {
    throw 'The scheduler must pass the current run identity/control root and clear the old stop marker on explicit resume.'
}
$runnerBatchStatus='report\.status,\{''preliminary-completed'',''budget-paused'',''paused''\}'
if ($runner -notmatch $runnerBatchStatus) {
    throw 'The MATLAB worker admission assertion must accept a clean paused report for explicit resume.'
}
$newProgressId=$main.IndexOf('progress.runId=options.runId;',[StringComparison]::Ordinal)
$newProgressState=$main.IndexOf("progress.status='allocation-pending';",$newProgressId,[StringComparison]::Ordinal)
$resumeValidate=$main.IndexOf('validateResumeState(progress,options,preflight,snapshotPath);',[StringComparison]::Ordinal)
$resumeProgressId=$main.IndexOf('progress.runId=options.runId;',$resumeValidate,[StringComparison]::Ordinal)
$resumeProgressWrite=$main.IndexOf('writeProgress(progressPath,progress);',$resumeProgressId,[StringComparison]::Ordinal)
if (-not ($newProgressId -ge 0 -and $newProgressId -lt $newProgressState -and
        $resumeValidate -ge 0 -and $resumeProgressId -gt $resumeValidate -and
        $resumeProgressWrite -gt $resumeProgressId -and $resumeProgressWrite -lt $loopIndex)) {
    throw 'Progress must persist the active worker runId on allocation and on resume before reconciliation can inspect a clean pause.'
}
foreach ($testName in @('stopAfterCaseMarkerPausesBeforeNextAdmission',
        'stopAfterCaseMarkerBeforeFirstAdmissionPreservesAllCounts',
        'activeAttemptIsPublishedBeforeRunnerAndChargedOnce')) {
    if ($matlabTest -notmatch [regex]::Escape($testName)) { throw "Missing MATLAB contract test: $testName" }
}
Write-Output 'PASS: stop-after-case admission order and run-linked attempt accounting contracts are present.'
