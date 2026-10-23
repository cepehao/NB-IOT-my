$ErrorActionPreference='Stop'
$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$implementationPath=Join-Path $projectRoot 'experiments\runLoadProbe.m'
$matlabTestPath=Join-Path $projectRoot 'tests\TestLoadProbe.m'
$source=[IO.File]::ReadAllText($implementationPath)
$matlabTest=[IO.File]::ReadAllText($matlabTestPath)
$mainEnd=$source.IndexOf('function options=loadProbeOptions')
if ($mainEnd -lt 0) { throw 'Could not locate runLoadProbe main-function boundary.' }
$main=$source.Substring(0,$mainEnd)
$leaseCall='ledgerWriterLease=acquireBudgetLedgerWriterLease(options.budgetLedgerFile);'
$leaseCallIndex=$main.IndexOf($leaseCall,[StringComparison]::Ordinal)
$modeIndex=$main.IndexOf('validateProbeMode(options);',[StringComparison]::Ordinal)
$newRunIndex=$main.IndexOf('newRun=~options.resume;',[StringComparison]::Ordinal)
$preflightIndex=$main.IndexOf('[execution,acceptance,preflight]=validatePreflight(options,root,snapshotPath);',[StringComparison]::Ordinal)
$firstLedgerSnapshotIndex=$main.IndexOf('syncBudgetLedgerSnapshot(options.outputFolder,options.budgetLedgerFile);',[StringComparison]::Ordinal)
$firstLedgerReadIndex=$main.IndexOf('nbiot.experiments.loadVariant2BudgetLedger(options.budgetLedgerFile,false);',[StringComparison]::Ordinal)
if (-not ($modeIndex -ge 0 -and $leaseCallIndex -gt $modeIndex -and
        $leaseCallIndex -lt $newRunIndex -and $leaseCallIndex -lt $preflightIndex -and
        $leaseCallIndex -lt $firstLedgerSnapshotIndex -and $leaseCallIndex -lt $firstLedgerReadIndex)) {
    throw 'runLoadProbe must acquire the writer lease after mode validation and before run setup, preflight, and ledger access.'
}
$helperStart=$source.IndexOf('function ledgerWriterLease=acquireBudgetLedgerWriterLease',[StringComparison]::Ordinal)
if ($helperStart -lt 0) { throw 'Java FileChannel lease helper is missing.' }
$helper=$source.Substring($helperStart,$mainEnd-$helperStart)
if ($helper -notmatch '(?s)\.writer\.lock' -or $helper -notmatch '(?s)tryLock\s*\(' -or
        $helper -notmatch '(?s)onCleanup\s*\(' -or $helper -notmatch '(?s)channel\.close\s*\(') {
    throw 'Lease helper must use the exact writer-lock suffix, tryLock, onCleanup, and channel close.'
}
if ($matlabTest -notmatch 'writerLeaseCoversRunnerAndReleasesAfterReturn' -or
        $matlabTest -notmatch 'refusesRunWhenAnotherWriterHoldsLedgerLease' -or
        $matlabTest -notmatch 'System[.]IO[.]FileShare[.]None' -or
        $matlabTest -notmatch 'tryJavaFileChannelLock' -or
        $matlabTest -notmatch 'preflight error must release the Java ledger lease') {
    throw 'MATLAB contract tests for lease lifetime and cleanup are missing.'
}
Write-Output 'PASS: runLoadProbe writer-lease ordering, Java tryLock cleanup, and MATLAB contract coverage are present.'
