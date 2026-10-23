[CmdletBinding()]
param([string]$RunFolder='', [switch]$Apply, [string]$OwnerStopEvidenceFolder='')
$ErrorActionPreference='Stop'
$ownerStopEvidenceSpecified=[bool]$PSBoundParameters.ContainsKey('OwnerStopEvidenceFolder')
$ownerStopEvidencePath=$OwnerStopEvidenceFolder
. "$PSScriptRoot/ControlScheduledRun.ps1" -RunFolder $RunFolder

function Get-TextHash([string]$Text) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function New-ReconcileEntry([string]$Path,$Value) {
    $content=$Value|ConvertTo-Json -Depth 40
    [ordered]@{path=$Path;oldSha256=(Get-RunHash $Path);newSha256=(Get-TextHash $content);newContent=$content;beforePath=($Path+'.before')}
}
function New-ReconcileUnchangedEntry([string]$Path) {
    $content=[IO.File]::ReadAllText($Path)
    $sha=Get-RunHash $Path
    [ordered]@{path=$Path;oldSha256=$sha;newSha256=$sha;newContent=$content;beforePath=($Path+'.before')}
}
function Publish-ReconcileEntry($Entry) {
    $current=Get-RunHash $Entry.path
    if ($current -ceq $Entry.newSha256) { return }
    if ($current -cne $Entry.oldSha256) { throw "Transaction conflict: $($Entry.path) has foreign digest." }
    $temp=$Entry.path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,[string]$Entry.newContent,[Text.UTF8Encoding]::new($false))
        if ((Get-RunHash $temp) -cne $Entry.newSha256) { throw 'Transaction content digest mismatch.' }
        [IO.File]::Replace($temp,[string]$Entry.path,[System.Management.Automation.Language.NullString]::Value)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}
function Read-RunTime([string]$Value) {
    if (-not $Value) { throw 'Missing interval timestamp.' }
    # Historical runner timestamps without a suffix are UTC by documented convention.
    [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
}
function Assert-FiniteSeconds($Value,[string]$Name) {
    if ($null -eq $Value -or $Value -is [string] -or [double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value) -or [double]$Value -lt 0) { throw "Invalid finite nonnegative $Name." }
}
function Assert-ReconcileHash([string]$Value,[string]$Name) {
    if ($Value -cnotmatch '^[0-9a-f]{64}$') { throw "Invalid SHA-256 in $Name." }
}
function Read-ReconcileJsonText([string]$Text) {
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $Text -DateKind String }
    return ConvertFrom-Json -InputObject $Text
}
function Resolve-ExternalPreviewCanonicalPath([string]$Candidate,[string]$BasePath='') {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { throw 'External preview path is missing.' }
    if ([IO.Path]::IsPathRooted($Candidate)) { $full=[IO.Path]::GetFullPath($Candidate) }
    elseif (-not [string]::IsNullOrWhiteSpace($BasePath)) { $full=[IO.Path]::GetFullPath((Join-Path $BasePath $Candidate)) }
    else { throw 'External preview path is not rooted.' }
    $volume=[IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($volume)) { throw 'External preview path has no volume root.' }
    $segments=$full.Substring($volume.Length).Split([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),[StringSplitOptions]::RemoveEmptyEntries)
    $current=$volume
    foreach($segment in $segments) {
        $next=Join-Path $current $segment
        $item=Get-Item -LiteralPath $next -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $method=$item.GetType().GetMethod('ResolveLinkTarget',[Type[]]@([bool]))
            if ($null -eq $method) { throw 'Reparse point could not be resolved; external preview fails closed.' }
            $target=$method.Invoke($item,@($true))
            if ($null -eq $target) { throw 'Reparse point target could not be resolved; external preview fails closed.' }
            $current=[IO.Path]::GetFullPath([string]$target.FullName)
        } else {
            $current=[IO.Path]::GetFullPath([string]$item.FullName)
        }
    }
    return [IO.Path]::GetFullPath($current)
}
function Test-ExternalPreviewCanonicalContainment([string]$Root,[string]$Candidate,[switch]$AllowRoot) {
    if ([string]::Equals($Root,$Candidate,[StringComparison]::OrdinalIgnoreCase)) { return [bool]$AllowRoot }
    $prefix=$Root
    if (-not $prefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)) { $prefix+=[IO.Path]::DirectorySeparatorChar }
    return $Candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
}
function New-ExternalPreviewResult([string]$RunId,$Committed,$Candidate,[string]$Reason) {
    $candidateStatus='unavailable'
    if ($null -ne $Candidate) { $candidateStatus='unconfirmed' }
    [ordered]@{
        status='accounting-incomplete';runId=$RunId
        committedSeconds=$Committed;elapsedSeconds=$Committed
        candidateProcessDurationSeconds=$Candidate;candidateProcessDurationStatus=$candidateStatus
        chargedCandidateSeconds=0;applied=$false;applyAllowed=$false;resumeAllowed=$false
        applyCommand=$null;resumeCommand=$null;reason=$Reason
    }
}
function Get-ExternalOwnerStopPreview([string]$RequestedRunFolder,[string]$EvidenceFolder) {
    $runId=$null; $committed=$null; $candidate=$null
    $reason='External owner-stop evidence is invalid or mismatched; no accounting was applied.'
    try {
        if (-not [IO.Path]::IsPathRooted($RequestedRunFolder)) { throw 'RunFolder must be absolute.' }
        $run=Resolve-ExternalPreviewCanonicalPath $RequestedRunFolder
        $runItem=Get-Item -LiteralPath $run -Force -ErrorAction Stop
        if (-not $runItem.PSIsContainer) { throw 'RunFolder is not a directory.' }

        $repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $manifestPath=Resolve-ExternalPreviewCanonicalPath (Join-Path $run 'run-manifest.json') $run
        if (-not (Test-ExternalPreviewCanonicalContainment $run $manifestPath) -or
            -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Run manifest path is outside the run or missing.' }
        $manifest=Read-RunJson $manifestPath
        $manifestRunFolder=Resolve-ExternalPreviewCanonicalPath ([string]$manifest.runFolder)
        if (-not [string]::Equals($manifestRunFolder,$run,[StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest runFolder does not identify the requested run.' }
        if ([string]$manifest.status -notin @('running','owner-stopped')) { throw 'Manifest status is not a supported historical preview state.' }

        $evidenceRoot=Resolve-ExternalPreviewCanonicalPath $EvidenceFolder
        $evidenceItem=Get-Item -LiteralPath $evidenceRoot -Force -ErrorAction Stop
        if (-not $evidenceItem.PSIsContainer) { throw 'Owner-stop evidence path is not a directory.' }
        if ((Test-ExternalPreviewCanonicalContainment $run $evidenceRoot) -or
            (Test-ExternalPreviewCanonicalContainment $evidenceRoot $run -AllowRoot)) { throw 'External evidence folder overlaps the run tree.' }
        $ownerStopPath=Resolve-ExternalPreviewCanonicalPath (Join-Path $evidenceRoot 'owner-stop.json') $evidenceRoot
        $snapshotPath=Resolve-ExternalPreviewCanonicalPath (Join-Path $evidenceRoot 'before-owner-stop.json') $evidenceRoot
        if (-not (Test-ExternalPreviewCanonicalContainment $evidenceRoot $ownerStopPath) -or
            -not (Test-ExternalPreviewCanonicalContainment $evidenceRoot $snapshotPath) -or
            -not (Test-Path -LiteralPath $ownerStopPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw 'Owner-stop evidence files are missing or outside the evidence folder.' }
        $ownerStop=Read-RunJson $ownerStopPath
        $snapshot=Read-RunJson $snapshotPath
        $worker=$snapshot.worker
        if ($null -eq $worker -or [string]::IsNullOrWhiteSpace([string]$worker.runId)) { throw 'Saved worker runId is missing.' }
        $workerRunFolder=Resolve-ExternalPreviewCanonicalPath ([string]$worker.runFolder)
        if (-not [string]::Equals($workerRunFolder,$run,[StringComparison]::OrdinalIgnoreCase)) { throw 'Saved worker runFolder does not identify the requested run.' }
        $runId=[string]$worker.runId

        if ($null -eq $snapshot.ledger -or $null -eq $snapshot.ledger.elapsedSeconds -or
            $snapshot.ledger.elapsedSeconds -is [string] -or [double]::IsNaN([double]$snapshot.ledger.elapsedSeconds) -or
            [double]::IsInfinity([double]$snapshot.ledger.elapsedSeconds) -or $snapshot.ledger.elapsedSeconds -lt 0) {
            throw 'Saved snapshot ledger elapsedSeconds is invalid.'
        }
        $committed=[double]$snapshot.ledger.elapsedSeconds

        $manifestRunIdProperty=$manifest.PSObject.Properties['runId']
        if ($null -ne $manifestRunIdProperty -and [string]$manifestRunIdProperty.Value -cne $runId) {
            throw 'Manifest runId conflicts with saved worker runId.'
        }
        foreach($source in @(@{name='owner-stop';value=$ownerStop},@{name='snapshot';value=$snapshot},
                @{name='snapshot process';value=$snapshot.process},
                @{name='snapshot progress';value=$snapshot.progress},@{name='snapshot ledger';value=$snapshot.ledger})) {
            $sourceRunIdProperty=$null
            if ($null -ne $source.value) { $sourceRunIdProperty=$source.value.PSObject.Properties['runId'] }
            if ($null -ne $sourceRunIdProperty -and [string]$sourceRunIdProperty.Value -cne $runId) {
                throw "$($source.name) runId conflicts with saved worker runId."
            }
        }
        if ($null -ne $snapshot.progress -and $null -ne $snapshot.progress.PSObject.Properties['budgetElapsedSeconds'] -and
            $null -ne $snapshot.progress.budgetElapsedSeconds) {
            Assert-FiniteSeconds $snapshot.progress.budgetElapsedSeconds 'snapshot progress budgetElapsedSeconds'
            if ([Math]::Abs([double]$snapshot.progress.budgetElapsedSeconds-$committed) -gt 0.000001) {
                throw 'Saved snapshot progress and ledger elapsedSeconds conflict.'
            }
        }

        $capturedAt=Read-RunTime ([string]$snapshot.capturedAtUtc)
        $stoppedAt=Read-RunTime ([string]$ownerStop.stoppedAtUtc)
        if ($stoppedAt -lt $capturedAt) { throw 'Owner-stop timestamp predates the saved snapshot.' }

        $expectedLedger=[IO.Path]::GetFullPath((Join-Path $repoRoot 'verification\completion\stage-2\budget-ledger.json'))
        $declaredLedger=[string]$manifest.sharedBudgetLedger
        if ([string]::IsNullOrWhiteSpace($declaredLedger)) { throw 'Manifest sharedBudgetLedger path is missing.' }
        if ([IO.Path]::IsPathRooted($declaredLedger)) { $declaredLedger=[IO.Path]::GetFullPath($declaredLedger) }
        else { $declaredLedger=[IO.Path]::GetFullPath((Join-Path $repoRoot $declaredLedger)) }
        if (-not [string]::Equals($declaredLedger,$expectedLedger,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Manifest sharedBudgetLedger is not the approved stage-2 ledger path.'
        }
        # The manifest path is allowlisted for identity only; this preview never opens it.
        if ([string]::IsNullOrWhiteSpace([string]$manifest.probeFolder)) { throw 'Manifest probeFolder is missing.' }
        $probePath=Resolve-ExternalPreviewCanonicalPath ([string]$manifest.probeFolder) $run
        if (-not (Test-ExternalPreviewCanonicalContainment $run $probePath) -or
            -not (Test-Path -LiteralPath $probePath -PathType Container)) { throw 'Manifest probeFolder is outside the run or missing.' }

        foreach($field in @('workerFolder','processReport','progressFile')) {
            if ([string]::IsNullOrWhiteSpace([string]$worker.$field)) { throw "Saved worker $field path is missing." }
        }
        $workerFolder=Resolve-ExternalPreviewCanonicalPath ([string]$worker.workerFolder) $run
        $reportPath=Resolve-ExternalPreviewCanonicalPath ([string]$worker.processReport) $run
        $progressPath=Resolve-ExternalPreviewCanonicalPath ([string]$worker.progressFile) $run
        foreach($path in @($workerFolder,$reportPath,$progressPath)) {
            if (-not (Test-ExternalPreviewCanonicalContainment $run $path)) { throw 'Saved worker path escapes the run.' }
        }
        if (-not (Test-ExternalPreviewCanonicalContainment $workerFolder $reportPath) -or
            -not (Test-Path -LiteralPath $workerFolder -PathType Container) -or
            -not (Test-Path -LiteralPath $reportPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $progressPath -PathType Leaf)) {
            throw 'Saved worker, process-report, or progress path is missing or mismatched.'
        }

        foreach($field in @('ledgerPath','progressPath')) {
            $snapshotProperty=$snapshot.PSObject.Properties[$field]
            if ($null -ne $snapshotProperty -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.$field)) {
                $snapshotPathValue=Resolve-ExternalPreviewCanonicalPath ([string]$snapshot.$field) $run
                if (-not (Test-ExternalPreviewCanonicalContainment $run $snapshotPathValue)) { throw "Snapshot $field escapes the run." }
                if ($field -eq 'progressPath' -and -not [string]::Equals($snapshotPathValue,$progressPath,[StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Snapshot progressPath conflicts with saved worker progressFile.'
                }
            }
        }

        $report=Read-RunJson $reportPath
        if ($null -ne $report.PSObject.Properties['startedAtUtc'] -and -not [string]::IsNullOrWhiteSpace([string]$report.startedAtUtc)) {
            $reportStart=Read-RunTime ([string]$report.startedAtUtc)
            if ($reportStart -gt $stoppedAt) { throw 'Saved process report starts after owner-stop.' }
        }
        if ($null -ne $report.PSObject.Properties['finishedAtUtc'] -and -not [string]::IsNullOrWhiteSpace([string]$report.finishedAtUtc)) {
            $reportFinish=Read-RunTime ([string]$report.finishedAtUtc)
            if ($reportFinish -gt $stoppedAt) { throw 'Saved process report finishes after owner-stop.' }
            if ($null -ne $reportStart -and $reportFinish -lt $reportStart) { throw 'Saved process report interval is invalid.' }
        }
        if ($null -ne $report.elapsedSeconds -and $report.elapsedSeconds -isnot [string]) {
            try {
                $duration=[double]$report.elapsedSeconds
                if (-not [double]::IsNaN($duration) -and -not [double]::IsInfinity($duration) -and $duration -ge 0) { $candidate=$duration }
            } catch {}
        }
        $reason='External owner-stop evidence is linked to the run; saved report duration remains unconfirmed.'
    } catch {
        $reason='External owner-stop evidence rejected: '+$_.Exception.Message
    }
    New-ExternalPreviewResult $runId $committed $candidate $reason
}
function Resolve-HistoricalPreviewPath([string]$Run,[string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
    try {
        if ([IO.Path]::IsPathRooted($Candidate)) { $full=[IO.Path]::GetFullPath($Candidate) }
        else { $full=[IO.Path]::GetFullPath((Join-Path $Run $Candidate)) }
        $root=[IO.Path]::GetFullPath($Run)
        $rootPrefix=$root
        if (-not $rootPrefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)) { $rootPrefix+=[IO.Path]::DirectorySeparatorChar }
        if (-not $full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { return $null }
        if (Test-Path -LiteralPath $full) {
            $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $full -ErrorAction Stop).Path)
            if (-not $resolved.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { return $null }
            return $resolved
        }
        return $full
    } catch { return $null }
}
function Get-HistoricalReconcilePreview($Context) {
    $run=[IO.Path]::GetFullPath([string]$Context.run)
    $manifest=$Context.manifest
    $worker=$null; $snapshot=$null; $ledger=$null
    $workerPath=Join-Path $run 'worker.json'
    $snapshotPath=Join-Path $run 'before-owner-stop.json'
    if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) { try { $snapshot=Read-RunJson $snapshotPath } catch {} }
    if (Test-Path -LiteralPath $workerPath -PathType Leaf) { try { $worker=Read-RunJson $workerPath } catch {} }
    if ($null -eq $worker -and $null -ne $snapshot) { $worker=$snapshot.worker }

    $ledgerCandidate=[string]$manifest.sharedBudgetLedger
    $ledgerPath=Resolve-HistoricalPreviewPath $run $ledgerCandidate
    if (-not $ledgerPath) { $ledgerPath=Resolve-HistoricalPreviewPath $run 'budget ledger.json' }
    if ($ledgerPath -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { try { $ledger=Read-RunJson $ledgerPath } catch {} }

    $committed=$null
    $committedValue=$ledger.elapsedSeconds
    if ($null -eq $committedValue -and $null -ne $snapshot) { $committedValue=$snapshot.ledger.elapsedSeconds }
    if ($null -ne $committedValue -and $committedValue -isnot [string]) {
        try {
            $number=[double]$committedValue
            if (-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0) { $committed=$number }
        } catch {}
    }

    $candidatePath=$null
    $workerFolder=Resolve-HistoricalPreviewPath $run ([string]$worker.workerFolder)
    if ($workerFolder -and (Test-Path -LiteralPath $workerFolder -PathType Container)) {
        $workerReportPath=Resolve-HistoricalPreviewPath $run (Join-Path $workerFolder 'process-report.json')
        if ($workerReportPath -and (Test-Path -LiteralPath $workerReportPath -PathType Leaf)) { $candidatePath=$workerReportPath }
    }
    if (-not $candidatePath) { $candidatePath=Resolve-HistoricalPreviewPath $run ([string]$worker.processReport) }
    $candidate=$null; $candidateStatus='unavailable'
    if ($candidatePath -and (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        try {
            $report=Read-RunJson $candidatePath
            $candidateValue=$report.elapsedSeconds
            if ($null -ne $candidateValue -and $candidateValue -isnot [string]) {
                $number=[double]$candidateValue
                if (-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0) {
                    $candidate=$number; $candidateStatus='unconfirmed'
                }
            }
        } catch {}
    }

    [ordered]@{
        status='accounting-incomplete'; runId=[string]$manifest.runId
        committedSeconds=$committed; elapsedSeconds=$committed
        candidateProcessDurationSeconds=$candidate; candidateProcessDurationStatus=$candidateStatus
        chargedCandidateSeconds=0; applied=$false; applyAllowed=$false; resumeAllowed=$false
        applyCommand=$null; resumeCommand=$null
        reason='Historical owner-stop linkage is ambiguous; saved process duration is unconfirmed.'
    }
}
function Get-ReconcileIntentEntry($Intent,[string]$Path) {
    $matches=@($Intent.entries|Where-Object { [string]$_.path -ceq $Path })
    if ($matches.Count -ne 1) { throw "Intent must contain exactly one entry for $Path." }
    return $matches[0]
}
function Get-ReconcileAccountingKind($Transaction) {
    $property=Get-ReconcileObjectProperty $Transaction 'accountingKind'
    if (-not $property.exists) { return 'interrupted-attempt' }
    $kind=[string]$property.value
    if ($kind -notin @('interrupted-attempt','clean-paused-worker')) { throw 'Transaction accounting kind is unsupported.' }
    return $kind
}
function Assert-ReconcileIntent($Intent,[string]$RunId,[string[]]$AllowedPaths,[string]$LedgerPath,[string]$ProgressPath,[switch]$VerifyBackups) {
    if ($Intent.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$Intent.transactionId) -or
        [string]$Intent.runId -cne $RunId -or [string]::IsNullOrWhiteSpace([string]$Intent.attemptId)) { throw 'Intent identity/schema conflict.' }
    Assert-ReconcileHash ([string]$Intent.processReportSha256) 'intent process report'
    Assert-FiniteSeconds $Intent.targetSeconds 'intent target seconds'
    Assert-FiniteSeconds $Intent.deltaSeconds 'intent delta seconds'
    $kind=Get-ReconcileAccountingKind $Intent
    if ($kind -eq 'clean-paused-worker') {
        if ([double]$Intent.targetSeconds -ne 0 -or [double]$Intent.deltaSeconds -ne 0) { throw 'Clean paused intent policy/accounting conflict.' }
    } elseif ($Intent.resumeAllowed -ne $false) { throw 'Intent resume policy conflict.' }
    $entries=@($Intent.entries)
    if ($entries.Count -lt 2 -or $entries.Count -gt 3) { throw 'Intent entry count conflict.' }
    $paths=@()
    foreach($entry in $entries) {
        $path=[string]$entry.path; $beforePath=[string]$entry.beforePath
        if ($path -notin $AllowedPaths -or $beforePath -cne ($path+'.before')) { throw 'Intent path conflict.' }
        if ($path -in $paths) { throw 'Intent duplicate path conflict.' }
        $paths+= $path
        Assert-ReconcileHash ([string]$entry.oldSha256) 'intent old digest'
        Assert-ReconcileHash ([string]$entry.newSha256) 'intent new digest'
        if ([string]$entry.newContent -eq '' -or (Get-TextHash ([string]$entry.newContent)) -cne [string]$entry.newSha256) { throw 'Intent content digest conflict.' }
        if ($VerifyBackups) {
            if (-not (Test-Path -LiteralPath $beforePath -PathType Leaf) -or (Get-RunHash $beforePath) -cne [string]$entry.oldSha256) { throw 'Intent backup digest conflict.' }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Intent target missing: $path" }
        }
    }
    if ($LedgerPath -notin $paths -or $ProgressPath -notin $paths) { throw 'Intent omits ledger or progress.' }
    if ($kind -eq 'clean-paused-worker') {
        if ($Intent.resumeAllowed -isnot [bool]) { throw 'Clean paused intent resume policy is not boolean.' }
        $ledgerEntries=@($Intent.entries|Where-Object { [string]$_.path -ceq $LedgerPath })
        if ($ledgerEntries.Count -ne 1) { throw 'Clean paused intent omits its unique ledger content.' }
        $savedLedger=Read-ReconcileJsonText ([string]$ledgerEntries[0].newContent)
        Assert-ReconcileLedger $savedLedger $RunId
        $expectedResume=([double]$savedLedger.elapsedSeconds -lt [double]$savedLedger.budgetSeconds)
        if ($Intent.resumeAllowed -ne $expectedResume) { throw 'Clean paused intent resume policy conflicts with committed budget.' }
    }
}
function Assert-ReconcileCommitShape($Commit,[string]$RunId,[string[]]$AllowedPaths,[string]$LedgerPath,[string]$ProgressPath) {
    if ($Commit.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$Commit.transactionId) -or
        [string]$Commit.runId -cne $RunId -or [string]::IsNullOrWhiteSpace([string]$Commit.attemptId)) { throw 'Commit identity/schema conflict.' }
    Assert-ReconcileHash ([string]$Commit.processReportSha256) 'commit process report'
    $kind=Get-ReconcileAccountingKind $Commit
    if ($kind -eq 'clean-paused-worker') {
        if ($Commit.resumeAllowed -isnot [bool]) { throw 'Clean paused commit resume policy is not boolean.' }
    } elseif ($Commit.resumeAllowed -ne $false) { throw 'Commit resume policy conflict.' }
    $entries=@($Commit.entries); $paths=@()
    if ($entries.Count -lt 2 -or $entries.Count -gt 3) { throw 'Commit entry count conflict.' }
    foreach($entry in $entries) {
        $path=[string]$entry.path
        if ($path -notin $AllowedPaths -or $path -in $paths) { throw 'Commit path conflict.' }
        Assert-ReconcileHash ([string]$entry.sha256) 'commit entry digest'
        $paths+= $path
    }
    if ($LedgerPath -notin $paths -or $ProgressPath -notin $paths) { throw 'Commit omits ledger or progress.' }
}
function Test-ReconcileCommitMatchesIntent($Commit,$Intent) {
    if ([string]$Commit.transactionId -cne [string]$Intent.transactionId -or
        [string]$Commit.runId -cne [string]$Intent.runId -or
        [string]$Commit.attemptId -cne [string]$Intent.attemptId -or
        [string]$Commit.processReportSha256 -cne [string]$Intent.processReportSha256 -or
        $Commit.resumeAllowed -ne $Intent.resumeAllowed -or
        (Get-ReconcileAccountingKind $Commit) -cne (Get-ReconcileAccountingKind $Intent)) { return $false }
    $commitEntries=@($Commit.entries); $intentEntries=@($Intent.entries)
    if ($commitEntries.Count -ne $intentEntries.Count) { return $false }
    foreach($entry in $intentEntries) {
        $match=@($commitEntries|Where-Object { [string]$_.path -ceq [string]$entry.path })
        if ($match.Count -ne 1 -or [string]$match[0].sha256 -cne [string]$entry.newSha256) { return $false }
    }
    return $true
}
function Get-ReconcileIntentLedger($Intent,[string]$LedgerPath) {
    $entry=Get-ReconcileIntentEntry $Intent $LedgerPath
    return Read-ReconcileJsonText ([string]$entry.newContent)
}
function Get-ReconcileIntentBeforeLedger($Intent,[string]$LedgerPath) {
    $entry=Get-ReconcileIntentEntry $Intent $LedgerPath
    if (-not (Test-Path -LiteralPath $entry.beforePath -PathType Leaf) -or (Get-RunHash $entry.beforePath) -cne [string]$entry.oldSha256) { throw 'Intent backup digest conflict.' }
    return Read-RunJson ([string]$entry.beforePath)
}
function Get-ReconcileAttemptRows($Ledger,[string]$AttemptId) {
    return @($Ledger.attempts|Where-Object { [string]$_.attemptId -ceq $AttemptId })
}
function Assert-ReconcileLedger($Ledger,[string]$RunId) {
    if ($Ledger.schemaVersion -ne 1 -or $Ledger.budgetSeconds -ne 57600) { throw 'Unsupported ledger schema/budget.' }
    Assert-FiniteSeconds $Ledger.elapsedSeconds 'committed seconds'
    $ids=@()
    foreach($attempt in @($Ledger.attempts)) {
        $id=[string]$attempt.attemptId
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace([string]$attempt.runId) -or
            [string]::IsNullOrWhiteSpace([string]$attempt.caseKey) -or $id -in $ids) { throw 'Ledger attempt identity is missing or non-unique.' }
        $ids+= $id
        if ($null -ne $attempt.chargedSeconds) { Assert-FiniteSeconds $attempt.chargedSeconds 'attempt charged seconds' }
        if ($null -ne $attempt.observedSeconds) { Assert-FiniteSeconds $attempt.observedSeconds 'attempt observed seconds' }
        if ([string]$attempt.processReportSha256) { Assert-ReconcileHash ([string]$attempt.processReportSha256) 'ledger attempt process report' }
    }
}
function Test-ReconcileTimeEqual($Left,$Right) {
    $leftText=[string]$Left; $rightText=[string]$Right
    if (-not $leftText -or -not $rightText) { return (-not $leftText -and -not $rightText) }
    try { return (Read-RunTime $leftText).UtcDateTime.Ticks -eq (Read-RunTime $rightText).UtcDateTime.Ticks }
    catch { return $false }
}
function Get-ReconcilePropertyNames($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys|ForEach-Object { [string]$_ }) }
    if ($Value -is [Management.Automation.PSCustomObject]) { return @($Value.PSObject.Properties|ForEach-Object { [string]$_.Name }) }
    throw 'Expected a JSON object while comparing committed state.'
}
function Get-ReconcileObjectProperty($Value,[string]$Name) {
    if ($Value -is [Collections.IDictionary]) {
        $matches=@($Value.Keys|Where-Object { [string]$_ -ceq $Name })
        if ($matches.Count -gt 1) { throw "Duplicate JSON property: $Name." }
        if ($matches.Count -eq 0) { return [pscustomobject]@{exists=$false;value=$null} }
        return [pscustomobject]@{exists=$true;value=$Value[$matches[0]]}
    }
    $matches=@($Value.PSObject.Properties|Where-Object { [string]$_.Name -ceq $Name })
    if ($matches.Count -gt 1) { throw "Duplicate JSON property: $Name." }
    if ($matches.Count -eq 0) { return [pscustomobject]@{exists=$false;value=$null} }
    return [pscustomobject]@{exists=$true;value=$matches[0].Value}
}
function Get-ReconcileCanonicalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [Collections.IDictionary]) {
        $names=@($Value.Keys|ForEach-Object { [string]$_ }|Sort-Object -CaseSensitive)
        $parts=@()
        foreach($name in $names) {
            $keyJson=ConvertTo-Json -InputObject $name -Compress
            $valueJson=Get-ReconcileCanonicalJson $Value[$name]
            $parts+=($keyJson+':'+$valueJson)
        }
        return '{'+($parts -join ',')+'}'
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $names=@($Value.PSObject.Properties|ForEach-Object { [string]$_.Name }|Sort-Object -CaseSensitive)
        $parts=@()
        foreach($name in $names) {
            $property=Get-ReconcileObjectProperty $Value $name
            $keyJson=ConvertTo-Json -InputObject $name -Compress
            $valueJson=Get-ReconcileCanonicalJson $property.value
            $parts+=($keyJson+':'+$valueJson)
        }
        return '{'+($parts -join ',')+'}'
    }
    if ($Value -is [Array] -or $Value -is [Collections.IList]) {
        $parts=@()
        foreach($item in $Value) { $parts+=(Get-ReconcileCanonicalJson $item) }
        return '['+($parts -join ',')+']'
    }
    return ConvertTo-Json -InputObject $Value -Compress -Depth 40
}
function Assert-ReconcileObjectFieldsEqualExcept($Baseline,$Current,[string[]]$Allowed,[string]$Name) {
    $oldNames=@(Get-ReconcilePropertyNames $Baseline); $newNames=@(Get-ReconcilePropertyNames $Current); $allNames=@()
    foreach($field in @($oldNames)+@($newNames)) { if ($field -cnotin $allNames) { $allNames+= [string]$field } }
    foreach($field in $allNames) {
        if ($field -cin $Allowed) { continue }
        $old=Get-ReconcileObjectProperty $Baseline $field; $new=Get-ReconcileObjectProperty $Current $field
        if ($old.exists -ne $new.exists -or ($old.exists -and (Get-ReconcileCanonicalJson $old.value) -cne (Get-ReconcileCanonicalJson $new.value))) {
            throw "$Name field changed outside the scheduler allowlist: $field."
        }
    }
}
function Assert-ReconcileUpdatedAt([string]$Name,$Previous,$Current) {
    $old=Get-ReconcileObjectProperty $Previous 'updatedAtUtc'; $new=Get-ReconcileObjectProperty $Current 'updatedAtUtc'
    if (-not $new.exists -or -not [string]$new.value) { throw "$Name updatedAtUtc is missing during the next attempt." }
    try { $newTime=Read-RunTime ([string]$new.value) }
    catch { throw "$Name updatedAtUtc is invalid during the next attempt." }
    if ($old.exists) {
        try { $oldTime=Read-RunTime ([string]$old.value) }
        catch { throw "$Name predecessor updatedAtUtc is invalid." }
        if ($newTime -lt $oldTime) { throw "$Name updatedAtUtc regressed during the next attempt." }
    }
}
function Assert-ReconcileActiveCaseShape($Active) {
    $allowed=@('runId','attemptId','caseKey','startedAtUtc','numUE','lastProgressAtUtc','runFolder',
        'rootProcessId','processStartTimeUtc','workerProcessId','workerProcessStartTimeUtc',
        'matlabProcessId','matlabProcessStartTimeUtc')
    $names=@(Get-ReconcilePropertyNames $Active)
    foreach($name in $names) { if ($name -cnotin $allowed) { throw "Active case contains an unrecognized scheduler field: $name." } }
}
function Get-ReconcilePositiveProcessId($Value,[string]$Name) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw "$Name is not a positive integral process ID." }
    try { $number=[double]$Value }
    catch { throw "$Name is not a positive integral process ID." }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -le 0 -or $number -ne [Math]::Floor($number)) {
        throw "$Name is not a positive integral process ID."
    }
    return $number
}
function Assert-ReconcileProcessIdentity($Active,$Started,[string]$Name) {
    $identityFields=@(
        @{field='rootProcessId';expected='rootProcessId'},
        @{field='processStartTimeUtc';expected='processStartTimeUtc'},
        @{field='workerProcessId';expected='workerProcessId'},
        @{field='workerProcessStartTimeUtc';expected='workerProcessStartTimeUtc'},
        @{field='matlabProcessId';expected='rootProcessId'},
        @{field='matlabProcessStartTimeUtc';expected='processStartTimeUtc'}
    )
    foreach($identity in $identityFields) {
        $value=Get-ReconcileObjectProperty $Active ([string]$identity.field)
        if (-not $value.exists) { continue }
        $expected=Get-ReconcileObjectProperty $Started ([string]$identity.expected)
        if (-not $expected.exists) { throw "$Name identity context is missing $($identity.expected)." }
        if ([string]$identity.field -match 'ProcessId$') {
            $actualProcessId=Get-ReconcilePositiveProcessId $value.value "$Name $($identity.field)"
            $expectedProcessId=Get-ReconcilePositiveProcessId $expected.value "$Name context $($identity.expected)"
            if ($actualProcessId -ne $expectedProcessId) {
                throw "$Name process identity conflicts with the started process tuple: $($identity.field)."
            }
        } elseif (-not (Test-ReconcileTimeEqual $value.value $expected.value)) {
            throw "$Name process identity conflicts with the started process tuple: $($identity.field)."
        }
    }
}
function Assert-ReconcileOwnerShape($Owner,$Started) {
    $expected=@('processId','matlabRelease','startedAtUtc','processStartTimeUtc','commandLine')
    $names=@(Get-ReconcilePropertyNames $Owner)
    if ($names.Count -ne $expected.Count) { throw 'Progress owner identity has an unexpected schema.' }
    foreach($name in $names) { if ($name -cnotin $expected) { throw "Progress owner identity has an unrecognized field: $name." } }
    foreach($name in $expected) { if ($name -cnotin $names) { throw "Progress owner identity is missing $name." } }
    $ownerProcessId=Get-ReconcilePositiveProcessId $Owner.processId 'owner processId'
    $rootProcessId=Get-ReconcilePositiveProcessId $Started.rootProcessId 'started root processId'
    if ([string]::IsNullOrWhiteSpace([string]$Owner.matlabRelease)) { throw 'Progress owner identity values are invalid.' }
    try { [void](Read-RunTime ([string]$Owner.startedAtUtc)) }
    catch { throw 'Progress owner start time is invalid.' }
    if ($ownerProcessId -ne $rootProcessId -or
        -not (Test-ReconcileTimeEqual $Owner.processStartTimeUtc $Started.processStartTimeUtc)) {
        throw 'Progress owner identity conflicts with the started MATLAB/root process tuple.'
    }
}
function Assert-ReconcilePhaseTimesTransition($PreviousLedger,$CurrentLedger,[string]$CaseKey,[string]$StartedAtUtc) {
    $oldProperty=Get-ReconcileObjectProperty $PreviousLedger 'phaseTimes'; $newProperty=Get-ReconcileObjectProperty $CurrentLedger 'phaseTimes'
    if (-not $oldProperty.exists -or -not $newProperty.exists) { throw 'Ledger phaseTimes is missing during the next attempt.' }
    $oldRows=@($oldProperty.value); $newRows=@($newProperty.value)
    if ($newRows.Count -lt $oldRows.Count -or $newRows.Count -gt ($oldRows.Count+1)) { throw 'Ledger phaseTimes changed by more than the allowed a2 append.' }
    for($index=0;$index -lt $oldRows.Count;$index++) {
        if ((Get-ReconcileCanonicalJson $oldRows[$index]) -cne (Get-ReconcileCanonicalJson $newRows[$index])) { throw "Committed phaseTimes history changed at row $index." }
    }
    if ($newRows.Count -eq ($oldRows.Count+1)) {
        $row=$newRows[-1]; $expected=@('phase','startedAtUtc','finishedAtUtc','elapsedSeconds','caseKey'); $names=@(Get-ReconcilePropertyNames $row)
        if ($names.Count -ne $expected.Count) { throw 'New phaseTimes row has an unexpected schema.' }
        foreach($name in $names) { if ($name -cnotin $expected) { throw "New phaseTimes row contains an unexpected field: $name." } }
        foreach($name in $expected) { if ($name -cnotin $names) { throw "New phaseTimes row is missing $name." } }
        if ([string]$row.phase -cne 'stage-3-load-probe' -or [string]$row.caseKey -cne $CaseKey -or
            -not (Test-ReconcileTimeEqual $row.startedAtUtc $StartedAtUtc) -or [string]$row.finishedAtUtc -cne '' -or
            $row.elapsedSeconds -is [string] -or [double]$row.elapsedSeconds -ne 0) { throw 'New phaseTimes row does not match the active a2 start.' }
    }
}
function Assert-ReconcileLedgerTransition($PreviousLedger,$CurrentLedger,$Started,[string]$RunId,[string]$AttemptId,[string]$CaseKey) {
    Assert-ReconcileObjectFieldsEqualExcept $PreviousLedger $CurrentLedger @('attempts','activeCase','phaseTimes','updatedAtUtc') 'Ledger'
    $oldAttempts=@($PreviousLedger.attempts); $newAttempts=@($CurrentLedger.attempts)
    if ($newAttempts.Count -ne ($oldAttempts.Count+1)) { throw 'Ledger attempts are not one appended active successor.' }
    for($index=0;$index -lt $oldAttempts.Count;$index++) {
        if ((Get-ReconcileCanonicalJson $oldAttempts[$index]) -cne (Get-ReconcileCanonicalJson $newAttempts[$index])) { throw "Committed attempt row changed at index $index." }
    }
    if ([string]$newAttempts[-1].attemptId -cne $AttemptId) { throw 'New active attempt is not the single appended ledger row.' }
    Assert-ReconcileActiveAttempt $CurrentLedger $RunId $AttemptId $CaseKey
    Assert-ReconcileActiveCaseShape $CurrentLedger.activeCase
    Assert-ReconcileProcessIdentity $CurrentLedger.activeCase $Started 'Ledger activeCase'
    Assert-ReconcilePhaseTimesTransition $PreviousLedger $CurrentLedger $CaseKey ([string]$CurrentLedger.activeCase.startedAtUtc)
    Assert-ReconcileUpdatedAt 'Ledger' $PreviousLedger $CurrentLedger
}
function Assert-ReconcileAttemptRowsPreserved($BaselineLedger,$CurrentLedger,[string]$ExcludeAttemptId='') {
    Assert-ReconcileLedger $BaselineLedger ([string]$BaselineLedger.attempts[0].runId)
    Assert-ReconcileLedger $CurrentLedger ([string]$CurrentLedger.attempts[0].runId)
    if ([double]$CurrentLedger.elapsedSeconds -lt [double]$BaselineLedger.elapsedSeconds) { throw 'Ledger elapsed time regressed after a committed attempt.' }
    foreach($old in @($BaselineLedger.attempts)) {
        if ($ExcludeAttemptId -and [string]$old.attemptId -ceq $ExcludeAttemptId) { continue }
        $matches=Get-ReconcileAttemptRows $CurrentLedger ([string]$old.attemptId)
        if ($matches.Count -ne 1) { throw "Committed attempt history was removed or duplicated: $($old.attemptId)." }
        $current=$matches[0]
        if ((Get-ReconcileCanonicalJson $old) -cne (Get-ReconcileCanonicalJson $current)) { throw "Committed attempt history changed: $($old.attemptId)." }
    }
}
function Assert-ReconcileCommittedAttempt($Commit,$Ledger,[string]$RunId) {
    $matches=Get-ReconcileAttemptRows $Ledger ([string]$Commit.attemptId)
    if ($matches.Count -ne 1) { throw 'Committed transaction attempt is missing or duplicated in ledger history.' }
    $attempt=$matches[0]
    if ([string]$attempt.runId -cne $RunId -or [string]$attempt.status -cne 'interrupted' -or
        [string]$attempt.processReportSha256 -cne [string]$Commit.processReportSha256 -or -not [string]$attempt.finishedAtUtc) { throw 'Committed transaction does not match a closed ledger attempt.' }
    Assert-FiniteSeconds $attempt.chargedSeconds 'committed attempt charge'
    $reported=@($Ledger.attempts|Where-Object { [string]$_.processReportSha256 })
    if ($reported.Count -eq 0 -or [string]$reported[$reported.Count-1].attemptId -cne [string]$Commit.attemptId) { throw 'Commit is not the latest reconciled attempt in ledger history.' }
}
function Assert-ReconcilePredecessor($Commit,$HistoryLedger,[string]$RunId,[string[]]$AllowedPaths,[string]$LedgerPath,[string]$ProgressPath,$PriorIntent=$null) {
    $predecessorRunId=[string]$Commit.runId
    Assert-ReconcileCommitShape $Commit $predecessorRunId $AllowedPaths $LedgerPath $ProgressPath
    Assert-ReconcileLedger $HistoryLedger $RunId
    if ($null -ne $PriorIntent) {
        Assert-ReconcileIntent $PriorIntent ([string]$PriorIntent.runId) $AllowedPaths $LedgerPath $ProgressPath
        if (-not (Test-ReconcileCommitMatchesIntent $Commit $PriorIntent)) { throw 'Prior commit does not match its transaction intent.' }
        $priorLedger=Get-ReconcileIntentLedger $PriorIntent $LedgerPath
        Assert-ReconcileAttemptRowsPreserved $priorLedger $HistoryLedger
        if ((Get-ReconcileAccountingKind $Commit) -eq 'clean-paused-worker') {
            Assert-ReconcileCleanPausedTransaction $Commit $PriorIntent $priorLedger
        } else {
            Assert-ReconcileCommittedAttempt $Commit $priorLedger $predecessorRunId
        }
    }
    if ((Get-ReconcileAccountingKind $Commit) -ne 'clean-paused-worker') {
        Assert-ReconcileCommittedAttempt $Commit $HistoryLedger $predecessorRunId
    }
}
function Assert-ReconcileEmbeddedPredecessor($Commit,$CurrentIntent,$HistoryLedger,[string[]]$AllowedPaths,[string]$LedgerPath,[string]$ProgressPath,$Started=$null,$HistoryProgress=$null) {
    $commitRunId=[string]$Commit.runId
    Assert-ReconcileCommitShape $Commit $commitRunId $AllowedPaths $LedgerPath $ProgressPath
    if ((Get-ReconcileAccountingKind $Commit) -eq 'clean-paused-worker') {
        $proofProperty=Get-ReconcileObjectProperty $CurrentIntent 'predecessorProof'
        if (-not $proofProperty.exists -or $null -eq $proofProperty.value) { throw 'Clean predecessor proof is missing from the pending intent.' }
        $priorIntent=$proofProperty.value.intent; $priorCommit=$proofProperty.value.commit
        # The predecessor's shared .before paths belong to the new transaction
        # after backup rotation. Validate its immutable embedded content and
        # commit binding instead of expecting those mutable files to remain.
        Assert-ReconcileIntent $priorIntent ([string]$priorIntent.runId) $AllowedPaths $LedgerPath $ProgressPath
        Assert-ReconcileCommitShape $priorCommit ([string]$priorCommit.runId) $AllowedPaths $LedgerPath $ProgressPath
        if (-not (Test-ReconcileCommitMatchesIntent $priorCommit $priorIntent) -or
            -not (Test-ReconcileCommitMatchesIntent $Commit $priorIntent)) { throw 'Embedded clean predecessor transaction proof conflicts.' }
        $priorLedger=Get-ReconcileIntentLedger $priorIntent $LedgerPath
        Assert-ReconcileCleanPausedTransaction $priorCommit $priorIntent $priorLedger
        Assert-ReconcileAttemptRowsPreserved $priorLedger $HistoryLedger
        if ((Get-ReconcileAccountingKind $CurrentIntent) -eq 'interrupted-attempt') {
            if ($null -eq $Started -or $null -eq $HistoryProgress) { throw 'Active successor transition proof is incomplete.' }
            $attemptId=[string]$CurrentIntent.attemptId
            $caseKey=[string]$HistoryLedger.activeCase.caseKey
            Assert-ReconcileLedgerTransition $priorLedger $HistoryLedger $Started ([string]$CurrentIntent.runId) $attemptId $caseKey
            Assert-ReconcileProgressForAttempt $priorIntent $HistoryProgress $HistoryLedger $Started ([string]$CurrentIntent.runId) $attemptId $caseKey $ProgressPath
        }
        return
    }
    Assert-ReconcileCommittedAttempt $Commit $HistoryLedger $commitRunId
}
function Assert-ReconcileCleanPausedTransaction($Commit,$Intent,$Ledger) {
    if ($null -eq $Intent -or (Get-ReconcileAccountingKind $Intent) -ne 'clean-paused-worker' -or
        (Get-ReconcileAccountingKind $Commit) -ne 'clean-paused-worker' -or
        [string]$Commit.runId -cne [string]$Intent.runId -or
        [string]$Commit.attemptId -cne [string]$Intent.attemptId -or
        [string]$Commit.processReportSha256 -cne [string]$Intent.processReportSha256 -or
        [double]$Intent.targetSeconds -ne 0 -or [double]$Intent.deltaSeconds -ne 0) {
        throw 'Clean paused transaction identity/accounting conflict.'
    }
    $entries=@($Intent.entries)
    if ($entries.Count -ne 2) { throw 'Clean paused transaction must preserve only ledger and progress.' }
    foreach($entry in $entries) {
        if ([string]$entry.oldSha256 -cne [string]$entry.newSha256 -or
            (Get-TextHash ([string]$entry.newContent)) -cne [string]$entry.newSha256) { throw 'Clean paused transaction changed a run artifact.' }
    }
    $ledgerEntry=$null; $progressEntry=$null
    foreach($entry in $entries) {
        $candidate=Read-ReconcileJsonText ([string]$entry.newContent)
        $names=@(Get-ReconcilePropertyNames $candidate)
        if ('attempts' -in $names -and 'elapsedSeconds' -in $names) { $ledgerEntry=$entry }
        if ('budgetElapsedSeconds' -in $names -and 'pendingCounts' -in $names) { $progressEntry=$entry }
    }
    if ($null -eq $ledgerEntry -or $null -eq $progressEntry) { throw 'Clean paused transaction omits accounting state.' }
    $savedLedger=Read-ReconcileJsonText ([string]$ledgerEntry.newContent)
    $savedProgress=Read-ReconcileJsonText ([string]$progressEntry.newContent)
    Assert-ReconcileLedger $savedLedger ([string]$Intent.runId)
    $expectedResume=([double]$savedLedger.elapsedSeconds -lt [double]$savedLedger.budgetSeconds)
    if ($Intent.resumeAllowed -isnot [bool] -or $Commit.resumeAllowed -isnot [bool] -or
        $Intent.resumeAllowed -ne $expectedResume -or $Commit.resumeAllowed -ne $expectedResume) {
        throw 'Clean paused transaction resume policy conflicts with committed budget.'
    }
    Assert-FiniteSeconds $savedLedger.elapsedSeconds 'clean paused committed seconds'
    if ([double]$Ledger.elapsedSeconds -ne [double]$savedLedger.elapsedSeconds -or
        (Get-ReconcileCanonicalJson $Ledger) -cne (Get-ReconcileCanonicalJson $savedLedger)) { throw 'Clean paused ledger differs from its committed target.' }
    if ([string]$savedProgress.runId -cne [string]$Intent.runId -or [string]$savedProgress.status -cne 'paused' -or
        [string]$savedProgress.phase -cne 'paused' -or [double]$savedProgress.budgetElapsedSeconds -ne [double]$savedLedger.elapsedSeconds -or
        (Get-ReconcileCanonicalJson @($savedProgress.pendingCounts)) -cne (Get-ReconcileCanonicalJson @($savedLedger.pendingCases)) -or
        @($savedProgress.pendingCounts).Count -eq 0 -or [string]$savedProgress.activeCase.attemptId) {
        throw 'Clean paused progress is not a pending, exact accounting snapshot.'
    }
    if ([string]$savedLedger.activeCase.attemptId) { throw 'Clean paused ledger still has an active attempt.' }
    foreach($attempt in @($savedLedger.attempts)) {
        if ([string]$attempt.status -notin @('completed','interrupted') -or [string]$attempt.finishedAtUtc -eq '') {
            throw 'Clean paused ledger contains an incomplete attempt.'
        }
    }
    $commitEntries=@($Commit.entries)
    foreach($entry in $entries) {
        $match=@($commitEntries|Where-Object { [string]$_.path -ceq [string]$entry.path })
        if ($match.Count -ne 1 -or [string]$match[0].sha256 -cne [string]$entry.newSha256) { throw 'Clean paused commit target digest conflict.' }
    }
}
function Test-ReconcileEmptyActiveCase($ActiveCase) {
    foreach($name in @('runId','attemptId','caseKey','startedAtUtc')) {
        $property=Get-ReconcileObjectProperty $ActiveCase $name
        if ($property.exists -and [string]$property.value) { return $false }
    }
    return $true
}
function Assert-ReconcileCleanPausedState($Report,$Progress,$Ledger,[string]$RunId) {
    if ([string]$Report.status -cne 'completed' -or [int]$Report.exitCode -ne 0) { throw 'Clean pause requires a successful completed worker report.' }
    if ([string]$Progress.runId -cne $RunId -or [string]$Progress.status -cne 'paused' -or [string]$Progress.phase -cne 'paused') { throw 'Progress is not a paused worker for the current run.' }
    if (-not (Test-ReconcileEmptyActiveCase $Progress.activeCase) -or -not (Test-ReconcileEmptyActiveCase $Ledger.activeCase)) { throw 'Clean paused evidence still contains an active attempt.' }
    Assert-ReconcileLedger $Ledger $RunId
    Assert-FiniteSeconds $Ledger.elapsedSeconds 'clean paused committed seconds'
    if ([double]$Progress.budgetElapsedSeconds -ne [double]$Ledger.elapsedSeconds -or
        (Get-ReconcileCanonicalJson @($Progress.pendingCounts)) -cne (Get-ReconcileCanonicalJson @($Ledger.pendingCases)) -or
        @($Progress.pendingCounts).Count -eq 0) { throw 'Paused progress does not preserve the exact pending/accounting state.' }
    foreach($attempt in @($Ledger.attempts)) {
        if ([string]$attempt.status -notin @('completed','interrupted') -or -not [string]$attempt.finishedAtUtc) { throw 'Clean paused ledger contains an incomplete attempt.' }
        if ([string]$attempt.runId -ceq $RunId -and [string]$attempt.processReportSha256) { throw 'Current worker report is already attributed to a case attempt.' }
    }
    $reportAttempt=[string]$Report.attemptId
    if ($reportAttempt) {
        $matches=Get-ReconcileAttemptRows $Ledger $reportAttempt
        if ($matches.Count -ne 1 -or [string]$matches[0].status -cne 'completed' -or
            [string]$matches[0].processReportSha256 -or
            ([string]$Report.caseKey -and [string]$matches[0].caseKey -cne [string]$Report.caseKey)) {
            throw 'Clean pause report points to a different or already reconciled attempt.'
        }
    }
}
function Get-ReconcileBaselineLedger($Intent,[string]$LedgerPath) {
    $entry=Get-ReconcileIntentEntry $Intent $LedgerPath
    $current=Get-RunHash ([string]$entry.path)
    if ($current -ceq [string]$entry.oldSha256) { return Read-RunJson ([string]$entry.path) }
    if ($current -ceq [string]$entry.newSha256) {
        if (-not (Test-Path -LiteralPath $entry.beforePath -PathType Leaf) -or (Get-RunHash $entry.beforePath) -cne [string]$entry.oldSha256) { throw 'Intent baseline backup digest conflict.' }
        return Read-RunJson ([string]$entry.beforePath)
    }
    throw 'Intent ledger target has a foreign digest.'
}
function Get-ReconcileBaselineDocument($Intent,[string]$Path) {
    $entry=Get-ReconcileIntentEntry $Intent $Path
    $current=Get-RunHash ([string]$entry.path)
    if ($current -ceq [string]$entry.oldSha256) { return Read-RunJson ([string]$entry.path) }
    if ($current -ceq [string]$entry.newSha256) {
        if (-not (Test-Path -LiteralPath $entry.beforePath -PathType Leaf) -or (Get-RunHash $entry.beforePath) -cne [string]$entry.oldSha256) { throw 'Intent baseline backup digest conflict.' }
        return Read-RunJson ([string]$entry.beforePath)
    }
    throw 'Intent target has a foreign digest.'
}
function Assert-ReconcileActiveAttempt($Ledger,[string]$RunId,[string]$AttemptId,[string]$ReportCaseKey) {
    Assert-ReconcileLedger $Ledger $RunId
    $active=$Ledger.activeCase
    if ([string]$active.runId -cne $RunId -or [string]$active.attemptId -cne $AttemptId -or
        [string]$active.caseKey -cne $ReportCaseKey) { throw 'Active attempt does not match the final report.' }
    $matches=Get-ReconcileAttemptRows $Ledger $AttemptId
    if ($matches.Count -ne 1) { throw 'Active attempt row is missing or duplicated.' }
    if ([string]$Ledger.attempts[-1].attemptId -cne $AttemptId) { throw 'Active attempt is not the newest ledger row.' }
    $attempt=$matches[0]
    $expectedFields=@('attemptId','runId','caseKey','startedAtUtc','finishedAtUtc','status','observedSeconds','chargedSeconds','processReportSha256')
    $attemptFields=@(Get-ReconcilePropertyNames $attempt)
    if ($attemptFields.Count -ne $expectedFields.Count) { throw 'Active attempt row has an unexpected schema.' }
    foreach($field in $attemptFields) { if ($field -cnotin $expectedFields) { throw "Active attempt row contains an unexpected field: $field." } }
    foreach($field in $expectedFields) { if ($field -cnotin $attemptFields) { throw "Active attempt row is missing $field." } }
    if ([string]$attempt.runId -cne $RunId -or [string]$attempt.caseKey -cne $ReportCaseKey -or
        [string]$attempt.status -cne 'active' -or [string]$attempt.processReportSha256 -or [string]$attempt.finishedAtUtc) { throw 'Attempt is not an unclosed active row.' }
    Assert-FiniteSeconds $attempt.chargedSeconds 'active attempt charge'
    Assert-FiniteSeconds $attempt.observedSeconds 'active attempt observation'
    if ([double]$attempt.chargedSeconds -gt 0 -or [double]$attempt.observedSeconds -gt 0) { throw 'New active attempt already carries a charge.' }
    if (-not (Test-ReconcileTimeEqual $active.startedAtUtc $attempt.startedAtUtc)) { throw 'Active attempt start time conflicts with its ledger row.' }
}
function Assert-ReconcileIntentBaseline($Intent,$BaselineLedger,[string]$RunId,[string]$CaseKey) {
    Assert-ReconcileActiveAttempt $BaselineLedger $RunId ([string]$Intent.attemptId) $CaseKey
    $resultLedger=$null
    foreach($entry in $Intent.entries) {
        $candidate=Read-ReconcileJsonText ([string]$entry.newContent)
        if ($candidate.PSObject.Properties.Name -contains 'attempts') { $resultLedger=$candidate; break }
    }
    if ($null -eq $resultLedger) { throw 'Intent does not contain a parseable ledger result.' }
    Assert-ReconcileLedger $resultLedger $RunId
    $matches=Get-ReconcileAttemptRows $resultLedger ([string]$Intent.attemptId)
    if ($matches.Count -ne 1) { throw 'Intent result attempt row is missing or duplicated.' }
    $beforeMatches=Get-ReconcileAttemptRows $BaselineLedger ([string]$Intent.attemptId)
    if ($beforeMatches.Count -ne 1) { throw 'Intent baseline attempt row is missing or duplicated.' }
    if (@($resultLedger.attempts).Count -ne @($BaselineLedger.attempts).Count) { throw 'Intent result changed the number of attempt rows.' }
    $beforeAttempt=$beforeMatches[0]; $afterAttempt=$matches[0]
    $expectedDelta=[Math]::Max([double]0,([double]$Intent.targetSeconds-[double]$beforeAttempt.chargedSeconds))
    if ([Math]::Abs($expectedDelta-[double]$Intent.deltaSeconds) -gt 0.000001 -or
        [Math]::Abs(([double]$BaselineLedger.elapsedSeconds+[double]$Intent.deltaSeconds)-[double]$resultLedger.elapsedSeconds) -gt 0.000001 -or
        [Math]::Abs([Math]::Max([double]$beforeAttempt.chargedSeconds,[double]$Intent.targetSeconds)-[double]$afterAttempt.chargedSeconds) -gt 0.000001 -or
        [Math]::Abs([double]$Intent.targetSeconds-[double]$afterAttempt.observedSeconds) -gt 0.000001) { throw 'Intent accounting delta does not follow its baseline.' }
    if ([string]$afterAttempt.status -cne 'interrupted' -or [string]$afterAttempt.processReportSha256 -cne [string]$Intent.processReportSha256 -or
        -not [string]$afterAttempt.finishedAtUtc -or [string]$resultLedger.activeCase.attemptId) { throw 'Intent result does not close exactly its baseline attempt.' }
    Assert-ReconcileAttemptRowsPreserved $BaselineLedger $resultLedger ([string]$Intent.attemptId)
}
function Assert-ReconcileActiveProgress($Progress,$Ledger,[string]$RunId,[string]$AttemptId,[string]$CaseKey) {
    if ([string]$Progress.runId -cne $RunId -or [string]$Progress.status -cne 'running' -or
        [string]$Progress.activeCase.runId -cne $RunId -or [string]$Progress.activeCase.attemptId -cne $AttemptId -or
        [string]$Progress.activeCase.caseKey -cne $CaseKey) { throw 'Progress does not identify the active attempt.' }
    if ([double]$Progress.budgetElapsedSeconds -ne [double]$Ledger.elapsedSeconds) { throw 'Progress budget differs from the committed ledger.' }
}
function Assert-ReconcileProgressForAttempt($PreviousIntent,$Progress,$Ledger,$Started,[string]$RunId,[string]$AttemptId,[string]$CaseKey,[string]$ProgressPath) {
    $entry=Get-ReconcileIntentEntry $PreviousIntent $ProgressPath
    $previous=Read-ReconcileJsonText ([string]$entry.newContent)
    Assert-ReconcileObjectFieldsEqualExcept $previous $Progress @('runId','status','phase','activeCase','owner','updatedAtUtc','currentTick') 'Progress'
    Assert-ReconcileActiveProgress $Progress $Ledger $RunId $AttemptId $CaseKey
    if ([string]$Progress.phase -cne 'running' -and [string]$Progress.phase -cnotmatch '^load-[0-9]+-running$') { throw 'Progress phase is not a supported active-case scheduler phase.' }
    if ([string]$Progress.phase -cmatch '^load-([0-9]+)-running$' -and $null -ne $Progress.activeCase.PSObject.Properties['numUE'] -and
        [int]$Matches[1] -ne [int]$Progress.activeCase.numUE) { throw 'Progress phase UE count differs from the active case.' }
    Assert-ReconcileActiveCaseShape $Progress.activeCase
    Assert-ReconcileProcessIdentity $Progress.activeCase $Started 'Progress activeCase'
    if ((Get-ReconcileCanonicalJson $Progress.activeCase) -cne (Get-ReconcileCanonicalJson $Ledger.activeCase)) { throw 'Progress and ledger active case differ.' }
    $owner=Get-ReconcileObjectProperty $Progress 'owner'
    if ($owner.exists) { Assert-ReconcileOwnerShape $owner.value $Started }
    $oldOwner=Get-ReconcileObjectProperty $previous 'owner'
    if ($oldOwner.exists -and -not $owner.exists) { throw 'Progress scheduler owner disappeared during the next attempt.' }
    Assert-ReconcileUpdatedAt 'Progress' $previous $Progress
    $tick=Get-ReconcileObjectProperty $Progress 'currentTick'
    $oldTick=Get-ReconcileObjectProperty $previous 'currentTick'
    if ($oldTick.exists -and -not $tick.exists) { throw 'Progress currentTick disappeared during the next attempt.' }
    if ($tick.exists -and ($tick.value -is [string] -or [double]$tick.value -ne 0)) { throw 'Progress currentTick did not reset for the next attempt.' }
}
function Assert-ReconcileTransactionTargets($Intent,[switch]$RequireBackups) {
    $published=$false
    foreach($entry in $Intent.entries) {
        if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) { throw "Intent target missing: $($entry.path)" }
        $current=Get-RunHash ([string]$entry.path)
        if ($current -ceq [string]$entry.newSha256 -and $current -cne [string]$entry.oldSha256) { $published=$true }
        elseif ($current -cne [string]$entry.oldSha256) { throw 'Foreign transaction digest; no recovery permitted.' }
    }
    if ($RequireBackups -or $published) {
        foreach($entry in $Intent.entries) {
            if (-not (Test-Path -LiteralPath $entry.beforePath -PathType Leaf) -or (Get-RunHash $entry.beforePath) -cne [string]$entry.oldSha256) { throw 'Intent backup digest conflict.' }
        }
    }
    return $published
}
function Ensure-ReconcileBackups($Intent,[switch]$ReplaceExisting) {
    $published=Assert-ReconcileTransactionTargets $Intent
    if ($published) { return }
    foreach($entry in $Intent.entries) {
        if (Test-Path -LiteralPath $entry.beforePath -PathType Leaf) {
            if ((Get-RunHash $entry.beforePath) -ceq [string]$entry.oldSha256) { continue }
            if (-not $ReplaceExisting) { throw 'Existing before backup without matching intent; manual review required.' }
        }
        Save-ReconcileBackup $entry -ReplaceExisting:$ReplaceExisting
    }
}
function Assert-ReconcileCommittedTargets($Intent) {
    foreach($entry in $Intent.entries) {
        if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf) -or (Get-RunHash ([string]$entry.path)) -cne [string]$entry.newSha256) { throw 'Committed transaction target digest conflict.' }
        if (-not (Test-Path -LiteralPath $entry.beforePath -PathType Leaf) -or (Get-RunHash $entry.beforePath) -cne [string]$entry.oldSha256) { throw 'Committed transaction backup digest conflict.' }
    }
}
function Save-ReconcileBackup($Entry,[switch]$ReplaceExisting) {
    if ((Test-Path -LiteralPath $Entry.beforePath) -and -not $ReplaceExisting) { throw 'Existing before backup without matching intent; manual review required.' }
    $temporary=[string]$Entry.beforePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        Copy-Item -LiteralPath $Entry.path -Destination $temporary
        if ((Get-RunHash $temporary) -cne [string]$Entry.oldSha256) { throw 'Before backup digest conflict.' }
        if (Test-Path -LiteralPath $Entry.beforePath) { [IO.File]::Replace($temporary,[string]$Entry.beforePath,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,[string]$Entry.beforePath) }
        if ((Get-RunHash $Entry.beforePath) -cne [string]$Entry.oldSha256) { throw 'Before backup publication digest conflict.' }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
function Complete-ReconcileTransaction($Intent,[string]$CommitPath) {
    foreach ($entry in $Intent.entries) {
        if ((Get-TextHash ([string]$entry.newContent)) -cne $entry.newSha256) { throw 'Intent content digest conflict.' }
        if (-not (Test-Path -LiteralPath $entry.beforePath -PathType Leaf) -or (Get-RunHash $entry.beforePath) -cne [string]$entry.oldSha256) { throw 'Before backup digest conflict.' }
        $current=Get-RunHash $entry.path
        if ($current -cne $entry.oldSha256 -and $current -cne $entry.newSha256) { throw 'Foreign transaction digest; no recovery permitted.' }
    }
    foreach ($entry in $Intent.entries) { Publish-ReconcileEntry $entry }
    $commit=[ordered]@{schemaVersion=1;transactionId=$Intent.transactionId;runId=$Intent.runId;attemptId=$Intent.attemptId;processReportSha256=$Intent.processReportSha256;resumeAllowed=$Intent.resumeAllowed;committedAtUtc=[DateTime]::UtcNow.ToString('o');entries=@($Intent.entries|ForEach-Object { @{path=$_.path;sha256=$_.newSha256} })}
    if ((Get-ReconcileAccountingKind $Intent) -eq 'clean-paused-worker') { $commit.accountingKind='clean-paused-worker' }
    Write-RunJson $CommitPath $commit
}

$lease=$null
if ($ownerStopEvidenceSpecified) {
    Get-ExternalOwnerStopPreview $RunFolder $ownerStopEvidencePath | ConvertTo-Json -Depth 12
    exit 0
}
try {
    if (-not [IO.Path]::IsPathRooted($RunFolder)) { throw 'RunFolder must be absolute.' }
    $historicalRun=(Resolve-Path -LiteralPath $RunFolder -ErrorAction Stop).Path
    $historicalManifest=$null
    $manifestPath=Join-Path $historicalRun 'run-manifest.json'
    $ownerStopPath=Join-Path $historicalRun 'owner-stop.json'
    $ownerStopExists=Test-Path -LiteralPath $ownerStopPath -PathType Leaf
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try { $historicalManifest=Read-RunJson $manifestPath }
        catch { if (-not $ownerStopExists) { throw } }
    }
    if ($ownerStopExists -or [string]$historicalManifest.status -ceq 'owner-stopped') {
        $historicalContext=[pscustomobject]@{run=$historicalRun;manifest=$historicalManifest}
        Get-HistoricalReconcilePreview $historicalContext | ConvertTo-Json -Depth 12
        exit 0
    }
    $context=Get-RunContext $RunFolder; $states=Get-RunStates $context; $s=$context.started
    if ($states.root -eq 'absent' -and $states.worker -eq 'alive') {
        [ordered]@{status='wait-for-report';resumeAllowed=$false;applied=$false}|ConvertTo-Json; exit 0
    }
    if ($states.root -ne 'absent' -or $states.worker -ne 'absent') {
        [ordered]@{status='needs-attention';reason='Both exact process tuples must be absent.';rootState=$states.root;workerState=$states.worker;resumeAllowed=$false;applied=$false}|ConvertTo-Json
        exit 1
    }
    $ledgerPath=[IO.Path]::GetFullPath([string]$context.manifest.sharedBudgetLedger)
    $probe=[string]$context.manifest.probeFolder
    if (-not $probe) { $probe=Join-Path $context.run 'probe' }
    $progressPath=Join-Path $probe 'progress.json'
    $intentPath=Join-Path $context.run 'reconcile-intent.json'; $commitPath=Join-Path $context.run 'reconcile-commit.json'
    if ($Apply) {
        try { $lease=[IO.File]::Open(($ledgerPath+'.writer.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'Ledger writer lease is held by another process.' }
        # Repeat identity proof under the lease, before reading or publishing state.
        $context=Get-RunContext $RunFolder; $lockedStates=Get-RunStates $context
        if ($lockedStates.root -ne 'absent' -or $lockedStates.worker -ne 'absent') { throw 'Process identity changed before Apply.' }
    }
    $reportPath=Join-Path $context.processFolder 'process-report.json'
    if (-not (Test-Path -LiteralPath $reportPath)) {
        $lowerBound=$null
        $observationPath=Join-Path $context.processFolder 'accounting-observation.json'
        if (Test-Path -LiteralPath $observationPath) {
            $observation=Read-RunJson $observationPath; $savedLedger=Read-RunJson $ledgerPath
            if ($observation.runId -ceq $s.runId -and $observation.attemptId -ceq $savedLedger.activeCase.attemptId -and $observation.caseKey -ceq $savedLedger.activeCase.caseKey) {
                Assert-FiniteSeconds $observation.observedSeconds 'observation seconds'
                $lowerBound=[double]$observation.observedSeconds
            }
        }
        [ordered]@{status='interrupted-accounting-incomplete';resumeAllowed=$false;applied=$false;observedLowerBoundSeconds=$lowerBound;reason='Final report missing; no complete charge can be inferred.'}|ConvertTo-Json
        exit 0
    }
    $report=Read-RunJson $reportPath; $reportHash=Get-RunHash $reportPath
    foreach ($field in @('runId','rootProcessId','processStartTimeUtc','workerProcessId','workerProcessStartTimeUtc')) {
        if ([string]$report.$field -cne [string]$s.$field) { throw "Report identity conflict: $field" }
    }
    if ($report.status -notin @('failed','cancelled','completed')) { throw 'Final report has no terminal status.' }
    Assert-FiniteSeconds $report.elapsedSeconds 'report elapsedSeconds'
    $workerStart=Read-RunTime $report.startedAtUtc; $workerEnd=Read-RunTime $report.finishedAtUtc
    if ($workerEnd -lt $workerStart -or $workerStart -lt (Read-RunTime $s.workerProcessStartTimeUtc)) { throw 'Invalid worker report interval.' }
    if ([Math]::Abs(($workerEnd-$workerStart).TotalSeconds-[double]$report.elapsedSeconds) -gt 5) { throw 'Report elapsed/interval mismatch.' }
    $allowedPaths=@($ledgerPath,$progressPath,(Join-Path $probe 'load-probe.json'))
    $predecessorIntent=$null
    $predecessorCommit=$null
    if (Test-Path -LiteralPath $intentPath) {
        $savedIntent=Read-RunJson $intentPath
        $savedKind=Get-ReconcileAccountingKind $savedIntent
        if ([string]$savedIntent.processReportSha256 -ceq $reportHash) {
            Assert-ReconcileIntent $savedIntent $s.runId $allowedPaths $ledgerPath $progressPath
            if ([string]$savedIntent.runId -cne [string]$s.runId) { throw 'Intent run identity conflict.' }
            if ($savedKind -eq 'clean-paused-worker') {
                if ([string]$savedIntent.attemptId -cne $(if([string]$report.attemptId){[string]$report.attemptId}else{'worker:'+[string]$s.runId})) { throw 'Clean pause transaction report identity conflict.' }
                $cleanLedger=Read-RunJson $ledgerPath; $cleanProgress=Read-RunJson $progressPath
                Assert-ReconcileCleanPausedState $report $cleanProgress $cleanLedger $s.runId
                Assert-ReconcileCleanPausedTransaction ([pscustomobject]@{accountingKind='clean-paused-worker';runId=$savedIntent.runId;attemptId=$savedIntent.attemptId;processReportSha256=$savedIntent.processReportSha256;resumeAllowed=$savedIntent.resumeAllowed;entries=@($savedIntent.entries|ForEach-Object {@{path=$_.path;sha256=$_.newSha256}})}) $savedIntent $cleanLedger
                $currentCommit=$null
                if (Test-Path -LiteralPath $commitPath -PathType Leaf) {
                    $currentCommit=Read-RunJson $commitPath
                    Assert-ReconcileCommitShape $currentCommit $s.runId $allowedPaths $ledgerPath $progressPath
                    if (Test-ReconcileCommitMatchesIntent $currentCommit $savedIntent) {
                        Assert-ReconcileCommittedTargets $savedIntent
                        Assert-ReconcileCleanPausedTransaction $currentCommit $savedIntent $cleanLedger
                        [ordered]@{status='reconciled';applied=[bool]$Apply;replayed=$true;attemptId=$savedIntent.attemptId;elapsedSeconds=$cleanLedger.elapsedSeconds;resumeAllowed=[bool]$savedIntent.resumeAllowed}|ConvertTo-Json
                        exit 0
                    }
                    if ([string]$currentCommit.transactionId -ceq [string]$savedIntent.transactionId) { throw 'Current clean pause commit conflicts with its intent.' }
                    $priorLedger=Get-ReconcileIntentBeforeLedger $savedIntent $ledgerPath
                    Assert-ReconcileEmbeddedPredecessor $currentCommit $savedIntent $priorLedger $allowedPaths $ledgerPath $progressPath
                } elseif (@($cleanLedger.attempts|Where-Object { [string]$_.processReportSha256 }).Count -gt 0) {
                    throw 'Clean pause transaction has closed attempt history without a commit.'
                }
                if ($Apply) {
                    Ensure-ReconcileBackups $savedIntent -ReplaceExisting:($null -ne $currentCommit)
                    Complete-ReconcileTransaction $savedIntent $commitPath
                }
                [ordered]@{status=$(if($Apply){'reconciled'}else{'preview'});applied=[bool]$Apply;attemptId=$savedIntent.attemptId;elapsedSeconds=$cleanLedger.elapsedSeconds;resumeAllowed=[bool]($Apply -and $savedIntent.resumeAllowed)}|ConvertTo-Json
                exit 0
            }
            if ([string]$savedIntent.attemptId -cne [string]$report.attemptId) { throw 'Intent attempt identity conflict.' }
            $baselineLedger=Get-ReconcileBaselineLedger $savedIntent $ledgerPath
            $baselineProgress=Get-ReconcileBaselineDocument $savedIntent $progressPath
            Assert-ReconcileIntentBaseline $savedIntent $baselineLedger $s.runId ([string]$report.caseKey)
            $currentCommit=$null; $commitIsPredecessor=$false
            if (Test-Path -LiteralPath $commitPath -PathType Leaf) {
                $currentCommit=Read-RunJson $commitPath
                Assert-ReconcileCommitShape $currentCommit $s.runId $allowedPaths $ledgerPath $progressPath
                if (Test-ReconcileCommitMatchesIntent $currentCommit $savedIntent) {
                    $committedLedger=Read-RunJson $ledgerPath
                    Assert-ReconcileCommittedAttempt $currentCommit $committedLedger $s.runId
                    Assert-ReconcileCommittedTargets $savedIntent
                    [ordered]@{status='reconciled';applied=[bool]$Apply;replayed=$true;attemptId=$savedIntent.attemptId;resumeAllowed=$savedIntent.resumeAllowed}|ConvertTo-Json
                    exit 0
                }
                if ([string]$currentCommit.attemptId -ceq [string]$savedIntent.attemptId -or
                    [string]$currentCommit.transactionId -ceq [string]$savedIntent.transactionId) { throw 'Current commit conflicts with the intent.' }
                Assert-ReconcileEmbeddedPredecessor $currentCommit $savedIntent $baselineLedger $allowedPaths $ledgerPath $progressPath $s $baselineProgress
                $commitIsPredecessor=$true
            } else {
                $reportedPrior=@($baselineLedger.attempts|Where-Object { [string]$_.processReportSha256 -and [string]$_.attemptId -cne [string]$savedIntent.attemptId })
                if ($reportedPrior.Count -gt 0) { throw 'Committed predecessor is missing its transaction commit.' }
            }
            Assert-ReconcileActiveAttempt $baselineLedger $s.runId ([string]$savedIntent.attemptId) ([string]$report.caseKey)
            Assert-ReconcileActiveProgress $baselineProgress $baselineLedger $s.runId ([string]$savedIntent.attemptId) ([string]$report.caseKey)
            if ($Apply) {
                Ensure-ReconcileBackups $savedIntent -ReplaceExisting:$commitIsPredecessor
                Complete-ReconcileTransaction $savedIntent $commitPath
            }
            [ordered]@{status='reconciled';applied=[bool]$Apply;replayed=$true;attemptId=$savedIntent.attemptId;resumeAllowed=$savedIntent.resumeAllowed}|ConvertTo-Json
            exit 0
        }
        if ($savedKind -eq 'interrupted-attempt' -and -not [string]::IsNullOrWhiteSpace([string]$report.attemptId) -and
            [string]$savedIntent.runId -ceq [string]$s.runId -and [string]$savedIntent.attemptId -ceq [string]$report.attemptId) { throw 'Closed attempt report SHA conflict.' }
        if (-not (Test-Path -LiteralPath $commitPath -PathType Leaf)) { throw 'Cannot start a new attempt over an uncommitted prior intent.' }
        Assert-ReconcileIntent $savedIntent ([string]$savedIntent.runId) $allowedPaths $ledgerPath $progressPath -VerifyBackups
        $priorCommit=Read-RunJson $commitPath
        Assert-ReconcileCommitShape $priorCommit ([string]$priorCommit.runId) $allowedPaths $ledgerPath $progressPath
        if (-not (Test-ReconcileCommitMatchesIntent $priorCommit $savedIntent)) { throw 'Prior commit does not match its transaction intent.' }
        $ledger=Read-RunJson $ledgerPath; $progress=Read-RunJson $progressPath
        Assert-ReconcilePredecessor $priorCommit $ledger $s.runId $allowedPaths $ledgerPath $progressPath $savedIntent
        $predecessorIntent=$savedIntent
        $predecessorCommit=$priorCommit
        if ([string]$progress.status -ceq 'paused' -and [string]$report.status -ceq 'completed' -and
            (Test-ReconcileEmptyActiveCase $ledger.activeCase) -and (Test-ReconcileEmptyActiveCase $progress.activeCase)) {
            Assert-ReconcileCleanPausedState $report $progress $ledger $s.runId
            $previousLedger=Get-ReconcileIntentLedger $savedIntent $ledgerPath
            Assert-ReconcileAttemptRowsPreserved $previousLedger $ledger
            $oldCount=@($previousLedger.attempts).Count
            $newRows=@($ledger.attempts|Select-Object -Skip $oldCount)
            foreach($newRow in $newRows) {
                if ([string]$newRow.runId -cne [string]$s.runId -or [string]$newRow.status -cne 'completed' -or [string]$newRow.processReportSha256) {
                    throw 'Clean pause includes an unverified new worker attempt row.'
                }
            }
        } else {
            Assert-ReconcileActiveAttempt $ledger $s.runId ([string]$report.attemptId) ([string]$report.caseKey)
            $previousLedger=Get-ReconcileIntentLedger $savedIntent $ledgerPath
            if (@($ledger.attempts).Count -ne (@($previousLedger.attempts).Count+1) -or
                [double]$ledger.elapsedSeconds -ne [double]$previousLedger.elapsedSeconds) { throw 'New attempt baseline is not a single uncharged successor to the committed ledger.' }
            Assert-ReconcileLedgerTransition $previousLedger $ledger $s $s.runId ([string]$report.attemptId) ([string]$report.caseKey)
            Assert-ReconcileProgressForAttempt $savedIntent $progress $ledger $s $s.runId ([string]$report.attemptId) ([string]$report.caseKey) $progressPath
        }
    } elseif (Test-Path -LiteralPath $commitPath) {
        throw 'Transaction commit exists without its intent; manual review required.'
    }
    $ledger=Read-RunJson $ledgerPath; $progress=Read-RunJson $progressPath
    Assert-ReconcileLedger $ledger $s.runId
    if ($ledger.schemaVersion -ne 1 -or $ledger.budgetSeconds -ne 57600) { throw 'Unsupported ledger schema/budget.' }
    Assert-FiniteSeconds $ledger.elapsedSeconds 'committed seconds'
    if ($null -eq $predecessorIntent -and @($ledger.attempts|Where-Object { [string]$_.processReportSha256 }).Count -gt 0) { throw 'Closed attempt history has no matching transaction intent and commit.' }
    if ([string]$progress.status -ceq 'paused' -and [string]$report.status -ceq 'completed' -and
        (Test-ReconcileEmptyActiveCase $ledger.activeCase) -and (Test-ReconcileEmptyActiveCase $progress.activeCase)) {
        Assert-ReconcileCleanPausedState $report $progress $ledger $s.runId
        $cleanAttemptId=[string]$report.attemptId
        if (-not $cleanAttemptId) { $cleanAttemptId='worker:'+[string]$s.runId }
        $entries=@((New-ReconcileUnchangedEntry $ledgerPath),(New-ReconcileUnchangedEntry $progressPath))
        $resumeAllowed=([double]$ledger.elapsedSeconds -lt [double]$ledger.budgetSeconds)
        $intent=[ordered]@{schemaVersion=1;transactionId=[guid]::NewGuid().ToString();accountingKind='clean-paused-worker';runId=$s.runId;attemptId=$cleanAttemptId;processReportSha256=$reportHash;targetSeconds=0;deltaSeconds=0;resumeAllowed=$resumeAllowed;entries=$entries}
        if ($null -ne $predecessorIntent -and $null -ne $predecessorCommit) {
            $intent.predecessorProof=@{intent=$predecessorIntent;commit=$predecessorCommit}
        }
        if ($Apply) {
            foreach($entry in $entries) { if ((Get-RunHash ([string]$entry.path)) -cne [string]$entry.oldSha256) { throw 'Clean pause state changed before intent publication.' } }
            if ($null -eq $predecessorIntent) {
                if (Test-Path -LiteralPath $commitPath) { throw 'Clean pause commit exists without a validated predecessor.' }
                foreach($entry in $entries) { if (Test-Path -LiteralPath $entry.beforePath) { throw 'Existing before backup without matching intent; manual review required.' } }
            }
            Write-RunJson $intentPath $intent
            Ensure-ReconcileBackups $intent -ReplaceExisting:($null -ne $predecessorIntent)
            Complete-ReconcileTransaction $intent $commitPath
        }
        [ordered]@{status=$(if($Apply){'reconciled'}else{'preview'});applied=[bool]$Apply;elapsedSeconds=$ledger.elapsedSeconds;resumeAllowed=[bool]($Apply -and $resumeAllowed);attemptId=$cleanAttemptId}|ConvertTo-Json
        exit 0
    }
    $active=$ledger.activeCase
    if (-not $active.attemptId -or $active.runId -cne $s.runId -or $report.attemptId -cne $active.attemptId -or $report.caseKey -cne $active.caseKey) { throw 'Attempt linkage missing or conflicting; legacy accounting requires preview review.' }
    $attempts=@($ledger.attempts); $indices=@(for($index=0;$index -lt $attempts.Count;$index++){if($attempts[$index].attemptId -ceq $active.attemptId){$index}})
    if ($indices.Count -ne 1) { throw 'Attempt identity is not unique.' }
    $attempt=$attempts[$indices[0]]
    if ($attempt.runId -cne $s.runId -or $attempt.caseKey -cne $active.caseKey) { throw 'Attempt run/case conflict.' }
    Assert-FiniteSeconds $attempt.chargedSeconds 'charged seconds'
    if ($attempt.processReportSha256 -and $attempt.processReportSha256 -cne $reportHash) { throw 'Closed attempt report SHA conflict.' }
    $caseStart=Read-RunTime $active.startedAtUtc
    $intersectionStart=if($caseStart -gt $workerStart){$caseStart}else{$workerStart}
    $target=[Math]::Max([double]0,($workerEnd-$intersectionStart).TotalSeconds)
    $delta=[Math]::Max([double]0,$target-[double]$attempt.chargedSeconds)
    $ledger.elapsedSeconds=[double]$ledger.elapsedSeconds+$delta
    Set-RunField $attempt 'chargedSeconds' ([Math]::Max([double]$attempt.chargedSeconds,$target))
    Set-RunField $attempt 'observedSeconds' $target
    Set-RunField $attempt 'finishedAtUtc' ([string]$report.finishedAtUtc)
    Set-RunField $attempt 'status' 'interrupted'
    Set-RunField $attempt 'processReportSha256' $reportHash
    Set-RunField $ledger 'accountingVersion' 2
    Set-RunField $ledger 'attempts' $attempts
    Set-RunField $ledger 'activeCase' ([pscustomobject]@{})
    Set-RunField $ledger 'updatedAtUtc' ([DateTime]::UtcNow.ToString('o'))
    $ownerStopped=(Test-Path -LiteralPath (Join-Path $context.run 'owner-stop.json')) -or $context.manifest.status -eq 'owner-stopped'
    Set-RunField $progress 'status' $(if($ownerStopped){'owner-stopped'}else{'paused'})
    Set-RunField $progress 'phase' $(if($ownerStopped){'owner-stopped'}else{'paused'})
    Set-RunField $progress 'activeCase' ([pscustomobject]@{})
    Set-RunField $progress 'budgetElapsedSeconds' $ledger.elapsedSeconds
    Set-RunField $progress 'updatedAtUtc' ([DateTime]::UtcNow.ToString('o'))
    # Resume remains conservative until source/preflight evidence has been independently verified.
    $resumeAllowed=$false
    $entries=@((New-ReconcileEntry $ledgerPath $ledger),(New-ReconcileEntry $progressPath $progress))
    $summaryPath=Join-Path $probe 'load-probe.json'
    if (Test-Path -LiteralPath $summaryPath) {
        $summary=Read-RunJson $summaryPath
        foreach($name in @('status','phase','budgetElapsedSeconds')) { Set-RunField $summary $name $progress.$name }
        $entries+=New-ReconcileEntry $summaryPath $summary
    }
    $intent=[ordered]@{schemaVersion=1;transactionId=[guid]::NewGuid().ToString();runId=$s.runId;attemptId=$active.attemptId;processReportSha256=$reportHash;targetSeconds=$target;deltaSeconds=$delta;resumeAllowed=$resumeAllowed;entries=$entries}
    if ($null -ne $predecessorIntent -and $null -ne $predecessorCommit -and
        (Get-ReconcileAccountingKind $predecessorIntent) -eq 'clean-paused-worker') {
        $intent.predecessorProof=@{intent=$predecessorIntent;commit=$predecessorCommit}
    }
    if ($Apply) {
        foreach($entry in $entries) { if ((Get-RunHash ([string]$entry.path)) -cne [string]$entry.oldSha256) { throw 'Transaction source changed before intent publication.' } }
        if ($null -eq $predecessorIntent) {
            if (Test-Path -LiteralPath $commitPath) { throw 'Transaction commit exists without a validated predecessor.' }
            foreach($entry in $entries) { if (Test-Path -LiteralPath $entry.beforePath) { throw 'Existing before backup without matching intent; manual review required.' } }
        }
        Write-RunJson $intentPath $intent
        Ensure-ReconcileBackups $intent -ReplaceExisting:($null -ne $predecessorIntent)
        Complete-ReconcileTransaction $intent $commitPath
    }
    [ordered]@{status=$(if($Apply){'reconciled'}else{'preview'});applied=[bool]$Apply;targetSeconds=$target;deltaSeconds=$delta;elapsedSeconds=$ledger.elapsedSeconds;resumeAllowed=$resumeAllowed;attemptId=$active.attemptId}|ConvertTo-Json
    exit 0
} catch {
    [ordered]@{status='conflict';reason=$_.Exception.Message;resumeAllowed=$false;applied=$false}|ConvertTo-Json
    exit 1
} finally { if ($null -ne $lease) { $lease.Dispose() } }
