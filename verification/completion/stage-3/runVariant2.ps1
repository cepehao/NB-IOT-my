[CmdletBinding()]
param(
    [switch]$DesignOnly,
    [switch]$Execute,
    [switch]$Resume,
    [string]$RunFolder = '',
    [string]$MatlabCommand = 'matlab',
    [string]$Stage2AcceptanceFile = ''
)
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic([string]$Path,[object]$Value) {
    $temporary="$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json=$Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-Json([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Set-OptionField($Value,[string]$Name,$Content) {
    if ($Value -is [Collections.IDictionary]) { $Value[$Name]=$Content }
    else { $Value | Add-Member -NotePropertyName $Name -NotePropertyValue $Content -Force }
}

function Clear-StopAfterCaseMarkerForResume([string]$RunRoot,[string]$PreviousRunId) {
    $markerPath=Join-Path $RunRoot 'stop-after-case.request.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return }
    $marker=Read-Json $markerPath
    if ($marker.schemaVersion -ne 1 -or [string]$marker.action -cne 'stop-after-case' -or
        [string]::IsNullOrWhiteSpace([string]$marker.requestId) -or
        [string]$marker.runId -cne $PreviousRunId) {
        throw 'identity-unknown: stop-after-case marker does not belong to the previous worker run.'
    }
    Remove-Item -LiteralPath $markerPath -ErrorAction Stop
}

function Get-ResumeFileHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-CurrentSourceManifestSha256([string]$ProjectRoot) {
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
        $files.Add($relative,(Get-ResumeFileHash $full))
    }
    foreach ($entryPoint in @('setupProject.m','experiments/runStaticSweep.m','experiments/runStaticSweepParallel.m','experiments/optimizationSourceManifest.m')) {
        $full=Join-Path $root ($entryPoint.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Required source entry point is missing: $entryPoint" }
        $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Source entry point is a reparse point: $entryPoint" }
        $canonical=[IO.Path]::GetFullPath($item.FullName)
        if (-not $canonical.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Source entry point escapes the project root: $entryPoint" }
        $relative=$canonical.Substring($prefix.Length).Replace('\','/')
        $files[$relative]=(Get-ResumeFileHash $canonical)
    }
    $canonicalText=[Text.StringBuilder]::new()
    foreach ($relative in $files.Keys) {
        [void]$canonicalText.Append($relative)
        [void]$canonicalText.Append([char]0)
        [void]$canonicalText.Append($files[$relative])
        [void]$canonicalText.Append([char]10)
    }
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($canonicalText.ToString())
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RunLoadProbePath([string]$ProjectRoot) {
    # The MATLAB batch changes to ProjectRoot, adds ProjectRoot, then
    # setupProject adds exactly src/configs/examples/experiments. Require one
    # candidate on that effective search set to match fileHash(which(...)).
    $root=(Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
    $searchFolders=@($root)
    foreach ($name in @('src','configs','examples','experiments')) { $searchFolders+=,(Join-Path $root $name) }
    $runnerCandidates=[Collections.Generic.List[string]]::new()
    foreach ($folder in $searchFolders) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "MATLAB search folder is missing: $folder" }
        $folderItem=Get-Item -LiteralPath $folder -Force -ErrorAction Stop
        if (($folderItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "MATLAB search folder is a reparse point: $folder" }
        $candidate=Join-Path $folder 'runLoadProbe.m'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $item=Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'runLoadProbe search candidate is a reparse point.' }
        $full=[IO.Path]::GetFullPath($item.FullName)
        $prefix=$root.TrimEnd('\')+[IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'runLoadProbe search candidate escapes ProjectRoot.' }
        $runnerCandidates.Add($full)
    }
    if ($runnerCandidates.Count -ne 1) { throw "MATLAB runLoadProbe resolution is not unique on the runVariant2 search path ($($runnerCandidates.Count) candidates)." }
    return $runnerCandidates[0]
}

function Get-ResumeContainedPath([string]$RunRoot,[string]$Candidate,[string]$Label,[switch]$RequireLeaf) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or -not [IO.Path]::IsPathFullyQualified($Candidate)) { throw "identity-unknown: $Label path is missing or not absolute." }
    $resolved=Resolve-Path -LiteralPath $Candidate -ErrorAction Stop
    if ($RequireLeaf -and $resolved.ProviderPath -and -not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Leaf)) { throw "identity-unknown: $Label is not a file." }
    $root=[IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($resolved.ProviderPath)
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "identity-unknown: $Label escapes RunFolder." }
    return $full
}

function Get-ResumeContainedDeclaredFilePath([string]$RunRoot,[string]$Candidate,[string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or -not [IO.Path]::IsPathFullyQualified($Candidate)) { throw "identity-unknown: $Label path is missing or not absolute." }
    if (Test-Path -LiteralPath $Candidate) {
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { throw "identity-unknown: $Label is not a file." }
        $existingPath=Get-ResumeContainedPath $RunRoot $Candidate $Label -RequireLeaf
        return $existingPath
    }
    $root=(Resolve-Path -LiteralPath $RunRoot -ErrorAction Stop).Path.TrimEnd('\')
    $candidateFull=[IO.Path]::GetFullPath($Candidate)
    $parent=(Resolve-Path -LiteralPath ([IO.Path]::GetDirectoryName($candidateFull)) -ErrorAction Stop).Path.TrimEnd('\')
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    if (-not [string]::Equals($parent,$root,[StringComparison]::OrdinalIgnoreCase) -and -not $parent.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "identity-unknown: $Label parent escapes RunFolder." }
    return Join-Path $parent ([IO.Path]::GetFileName($candidateFull))
}

function Test-ResumeTimeEqual([string]$Left,[string]$Right) {
    try {
        $leftValue=[DateTimeOffset]::Parse($Left,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $rightValue=[DateTimeOffset]::Parse($Right,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        return $leftValue.Ticks -eq $rightValue.Ticks
    } catch { return $false }
}

function Assert-ResumeSourceProof([string]$ProjectRoot,[string]$RunRoot,[string]$ProbeFolder,[string]$ProgressPath,[string]$PreflightPath) {
    try {
        $progressFile=Get-ResumeContainedPath $RunRoot $ProgressPath 'progress.json' -RequireLeaf
        $preflightFile=Get-ResumeContainedPath $RunRoot $PreflightPath 'preflight.json' -RequireLeaf
        $progress=Read-Json $progressFile
        $preflight=Read-Json $preflightFile
        if ($preflight.status -cne 'passed') { throw 'Saved preflight did not pass.' }
        if (-not ($progress.PSObject.Properties.Name -contains 'runFolder') -or [string]::IsNullOrWhiteSpace([string]$progress.runFolder)) { throw 'Progress runFolder is missing.' }
        $savedProbe=Get-ResumeContainedPath $RunRoot ([string]$progress.runFolder) 'progress.runFolder'
        $expectedProbe=[IO.Path]::GetFullPath($ProbeFolder)
        if (-not [string]::Equals($savedProbe.TrimEnd('\'),$expectedProbe.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Progress belongs to another output folder.' }
        foreach ($field in @('sourceManifestSha256','runnerSha256')) {
            if (-not ($progress.PSObject.Properties.Name -contains $field) -or -not ($preflight.PSObject.Properties.Name -contains $field)) { throw "Saved $field is missing." }
            $progressHash=[string]$progress.$field
            $preflightHash=[string]$preflight.$field
            if ($progressHash -notmatch '^[0-9a-fA-F]{64}$' -or $preflightHash -notmatch '^[0-9a-fA-F]{64}$') { throw "Saved $field is malformed." }
            if (-not [string]::Equals($progressHash,$preflightHash,[StringComparison]::OrdinalIgnoreCase)) { throw "Progress/preflight $field conflict." }
        }
        $currentManifest=Get-CurrentSourceManifestSha256 $ProjectRoot
        $currentRunner=Get-ResumeFileHash (Get-RunLoadProbePath $ProjectRoot)
        if (-not [string]::Equals([string]$progress.sourceManifestSha256,$currentManifest,[StringComparison]::OrdinalIgnoreCase)) { throw 'Current computational source manifest differs.' }
        if (-not [string]::Equals([string]$progress.runnerSha256,$currentRunner,[StringComparison]::OrdinalIgnoreCase)) { throw 'Current runLoadProbe source differs.' }
        return [pscustomobject]@{progress=$progress;preflight=$preflight}
    } catch {
        throw "source-mismatch: saved source identity could not be verified. $($_.Exception.Message)"
    }
}

function Get-ReconcileEntryByPath($Transaction,[string]$Path,[string]$DigestProperty) {
    $matches=@($Transaction.entries|Where-Object { [string]$_.path -ceq $Path })
    if ($matches.Count -ne 1) { throw "reconcile-required: transaction must contain exactly one entry for $Path." }
    return [string]$matches[0].$DigestProperty
}

function Get-DeclaredSharedLedgerPath([string]$RunRoot) {
    $runManifestPath=Join-Path $RunRoot 'run-manifest.json'
    $optionsPath=Join-Path $RunRoot 'worker-options.json'
    if (-not (Test-Path -LiteralPath $runManifestPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $optionsPath -PathType Leaf)) {
        throw 'identity-unknown: run-manifest or worker-options is missing while resolving the shared writer lease.'
    }
    $runManifest=Read-Json $runManifestPath
    $options=Read-Json $optionsPath
    $manifestLedgerPath=[string]$runManifest.sharedBudgetLedger
    $optionLedgerPath=[string]$options.budgetLedgerFile
    if ([string]::IsNullOrWhiteSpace($manifestLedgerPath) -or [string]::IsNullOrWhiteSpace($optionLedgerPath) -or
        -not [IO.Path]::IsPathFullyQualified($manifestLedgerPath) -or -not [IO.Path]::IsPathFullyQualified($optionLedgerPath)) {
        throw 'identity-unknown: run does not declare an absolute shared ledger path for its writer lease.'
    }
    $manifestLedger=[IO.Path]::GetFullPath($manifestLedgerPath)
    $optionLedger=[IO.Path]::GetFullPath($optionLedgerPath)
    if (-not [string]::Equals($manifestLedger,$optionLedger,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'identity-unknown: run-manifest and worker-options shared ledger paths conflict.'
    }
    return $manifestLedger
}

function Open-SharedLedgerWriterLease([string]$LedgerPath) {
    if ([string]::IsNullOrWhiteSpace($LedgerPath) -or -not [IO.Path]::IsPathFullyQualified($LedgerPath)) {
        throw 'identity-unknown: shared ledger writer lease path is missing or not absolute.'
    }
    $lockPath=[IO.Path]::GetFullPath($LedgerPath)+'.writer.lock'
    try {
        return [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch {
        throw 'writer-lease-unavailable: shared budget ledger writer lease could not be acquired.'
    }
}

function Set-NoWorkerRunManifestStatus([string]$RunRoot,[string]$TargetStatus,[string]$ExpectedProgressStatus,[switch]$RequireBudgetExhausted) {
    $runManifestPath=Join-Path $RunRoot 'run-manifest.json'
    $progressPath=Join-Path (Join-Path $RunRoot 'probe') 'progress.json'
    $optionsPath=Join-Path $RunRoot 'worker-options.json'
    $ownerStopPath=Join-Path $RunRoot 'owner-stop.json'
    $candidateLedgerPath=Get-DeclaredSharedLedgerPath $RunRoot
    $lease=Open-SharedLedgerWriterLease $candidateLedgerPath
    try {
        if (Test-Path -LiteralPath $ownerStopPath) { throw 'owner-stopped: no-worker status update is refused after owner-stop.' }
        foreach($path in @($runManifestPath,$progressPath,$optionsPath,$candidateLedgerPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'reconcile-required: no-worker status evidence is missing under the shared writer lease.' }
        }
        $manifestHashBefore=Get-ResumeFileHash $runManifestPath
        $progressHashBefore=Get-ResumeFileHash $progressPath
        $optionsHashBefore=Get-ResumeFileHash $optionsPath
        $ledgerHashBefore=Get-ResumeFileHash $candidateLedgerPath
        $runManifest=Read-Json $runManifestPath
        $progress=Read-Json $progressPath
        $options=Read-Json $optionsPath
        $ledger=Read-Json $candidateLedgerPath
        $ledgerPath=Get-DeclaredSharedLedgerPath $RunRoot
        if (-not [string]::Equals($ledgerPath,$candidateLedgerPath,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'reconcile-required: shared ledger path changed while acquiring the writer lease.'
        }
        if ([string]$runManifest.status -ceq 'owner-stopped' -or [string]$progress.status -ceq 'owner-stopped') {
            throw 'owner-stopped: no-worker status update is refused after owner-stop.'
        }
        foreach($path in @($candidateLedgerPath,$progressPath,$optionsPath)) {
            $resolved=(Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
            $item=Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not [string]::Equals([IO.Path]::GetFullPath($resolved),[IO.Path]::GetFullPath($path),[StringComparison]::OrdinalIgnoreCase)) {
                throw 'identity-unknown: no-worker status evidence path is redirected.'
            }
        }
        $manifestRunFolder=(Resolve-Path -LiteralPath ([string]$runManifest.runFolder) -ErrorAction Stop).Path
        if (-not [string]::Equals($manifestRunFolder.TrimEnd('\'),$RunRoot.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
            throw 'identity-unknown: run-manifest folder changed before no-worker status update.'
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedProgressStatus) -and [string]$progress.status -cne $ExpectedProgressStatus) {
            throw 'reconcile-required: progress status changed before no-worker status update.'
        }
        $elapsed=[double]$ledger.elapsedSeconds; $budget=[double]$ledger.budgetSeconds
        if ($ledger.schemaVersion -ne 1 -or [double]::IsNaN($elapsed) -or [double]::IsInfinity($elapsed) -or
            [double]::IsNaN($budget) -or [double]::IsInfinity($budget) -or $elapsed -lt 0 -or $budget -le 0) {
            throw 'reconcile-required: shared ledger is invalid under the writer lease.'
        }
        if ($RequireBudgetExhausted -and $elapsed -lt $budget) {
            throw 'reconcile-required: shared budget is not exhausted under the writer lease.'
        }
        if ((Test-Path -LiteralPath $ownerStopPath) -or
            (Get-ResumeFileHash $runManifestPath) -cne $manifestHashBefore -or
            (Get-ResumeFileHash $progressPath) -cne $progressHashBefore -or
            (Get-ResumeFileHash $optionsPath) -cne $optionsHashBefore -or
            (Get-ResumeFileHash $candidateLedgerPath) -cne $ledgerHashBefore) {
            throw 'reconcile-required: no-worker status evidence changed under the shared writer lease.'
        }
        $runManifest.status=$TargetStatus
        $runManifest.updatedAtUtc=[DateTime]::UtcNow.ToString('o')
        Write-JsonAtomic $runManifestPath $runManifest
        return $runManifest
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
    }
}

function Get-CleanPauseBudgetStop([string]$RunRoot,$RunManifest,$Progress,[string]$OptionsPath,[string]$ProgressPath) {
    if ([string]$Progress.status -cne 'paused') { return $null }
    # This preliminary read only decides whether the clean-pause path needs the
    # lease. The complete identity/evidence validation is repeated while held.
    $candidateLedgerPath=Get-DeclaredSharedLedgerPath $RunRoot
    if (-not (Test-Path -LiteralPath $candidateLedgerPath -PathType Leaf)) {
        throw 'identity-unknown: shared ledger is missing while checking the paused run budget.'
    }
    $candidateLedger=Read-Json $candidateLedgerPath
    $candidateElapsed=[double]$candidateLedger.elapsedSeconds; $candidateBudget=[double]$candidateLedger.budgetSeconds
    if ($candidateLedger.schemaVersion -ne 1 -or [double]::IsNaN($candidateElapsed) -or [double]::IsInfinity($candidateElapsed) -or
        [double]::IsNaN($candidateBudget) -or [double]::IsInfinity($candidateBudget) -or $candidateElapsed -lt 0 -or $candidateBudget -le 0) {
        throw 'reconcile-required: shared ledger schema or elapsed value is invalid.'
    }
    if ($candidateElapsed -lt $candidateBudget) { return $null }
    $writerLease=Open-SharedLedgerWriterLease $candidateLedgerPath
    $passedRunId=[string]$Progress.runId
    $passedSourceManifestSha=[string]$Progress.sourceManifestSha256
    $passedRunnerSha=[string]$Progress.runnerSha256
    $runManifestPath=Join-Path $RunRoot 'run-manifest.json'
    try {
        if (Test-Path -LiteralPath (Join-Path $RunRoot 'owner-stop.json')) { throw 'owner-stopped: budget pause is refused after owner-stop.' }
        $manifestHashBefore=Get-ResumeFileHash $runManifestPath
        $progressHashBefore=Get-ResumeFileHash $ProgressPath
        $optionsHashBefore=Get-ResumeFileHash $OptionsPath
        $RunManifest=Read-Json $runManifestPath
        $Progress=Read-Json $ProgressPath
        if ([string]$RunManifest.status -ceq 'owner-stopped' -or [string]$Progress.status -ceq 'owner-stopped') {
            throw 'owner-stopped: budget pause is refused after owner-stop.'
        }
        if ([string]$Progress.status -cne 'paused') { throw 'reconcile-required: paused progress changed before budget validation.' }
        if ([string]$Progress.runId -cne $passedRunId -or
            -not [string]::Equals([string]$Progress.sourceManifestSha256,$passedSourceManifestSha,[StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$Progress.runnerSha256,$passedRunnerSha,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'source-mismatch: paused run identity or source proof changed before budget validation.'
        }
        $runId=[string]$Progress.runId
        if ([string]::IsNullOrWhiteSpace($runId)) { throw 'identity-unknown: paused progress has no runId.' }
        if (@($RunManifest.PSObject.Properties.Name) -contains 'runId') {
            if ([string]::IsNullOrWhiteSpace([string]$RunManifest.runId) -or [string]$RunManifest.runId -cne $runId) {
                throw 'identity-unknown: paused run-manifest runId does not match progress.'
            }
        }
        $manifestRunFolder=(Resolve-Path -LiteralPath ([string]$RunManifest.runFolder) -ErrorAction Stop).Path
        if (-not [string]::Equals($manifestRunFolder.TrimEnd('\'),$RunRoot.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
            throw 'identity-unknown: paused run-manifest folder does not match RunFolder.'
        }
        $progressProbe=Get-ResumeContainedPath $RunRoot ([string]$Progress.runFolder) 'progress.runFolder'
        $expectedProbe=[IO.Path]::GetFullPath((Join-Path $RunRoot 'probe'))
        if (-not [string]::Equals($progressProbe.TrimEnd('\'),$expectedProbe.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
            throw 'identity-unknown: paused progress belongs to another probe folder.'
        }
        if (-not (Test-Path -LiteralPath $OptionsPath -PathType Leaf)) { throw 'identity-unknown: worker-options.json is missing.' }
        $options=Read-Json $OptionsPath
        $manifestLedgerPath=[string]$RunManifest.sharedBudgetLedger
        $optionLedgerPath=[string]$options.budgetLedgerFile
        if ([string]::IsNullOrWhiteSpace($manifestLedgerPath) -or [string]::IsNullOrWhiteSpace($optionLedgerPath) -or
            -not [IO.Path]::IsPathFullyQualified($manifestLedgerPath) -or -not [IO.Path]::IsPathFullyQualified($optionLedgerPath)) {
            throw 'identity-unknown: paused run does not declare an absolute shared ledger path.'
        }
        $manifestLedger=[IO.Path]::GetFullPath($manifestLedgerPath)
        $optionLedger=[IO.Path]::GetFullPath($optionLedgerPath)
        if (-not [string]::Equals($manifestLedger,$optionLedger,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'identity-unknown: run-manifest and worker-options shared ledger paths conflict.'
        }
        $resolvedLedger=(Resolve-Path -LiteralPath $manifestLedger -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolvedLedger -PathType Leaf)) { throw 'identity-unknown: shared ledger is not a file.' }
        $ledgerItem=Get-Item -LiteralPath $resolvedLedger -Force -ErrorAction Stop
        if (($ledgerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'identity-unknown: shared ledger is a reparse point.' }
        $ledgerPath=[IO.Path]::GetFullPath($resolvedLedger)
        if (-not [string]::Equals($ledgerPath,$candidateLedgerPath,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'identity-unknown: paused shared ledger path changed while acquiring its writer lease.'
        }
        if (-not [string]::Equals([IO.Path]::GetFullPath($manifestLedger),$ledgerPath,[StringComparison]::OrdinalIgnoreCase)) {
            throw 'identity-unknown: shared ledger path resolves through a redirected location.'
        }
        $resolvedProgress=(Resolve-Path -LiteralPath $ProgressPath -ErrorAction Stop).Path
        if (-not [string]::Equals([IO.Path]::GetFullPath($ProgressPath),[IO.Path]::GetFullPath($resolvedProgress),[StringComparison]::OrdinalIgnoreCase)) {
            throw 'identity-unknown: progress path resolves through a redirected location.'
        }
        $ledgerHashBefore=Get-ResumeFileHash $ledgerPath
        $ledger=Read-Json $ledgerPath
        $elapsed=[double]$ledger.elapsedSeconds; $budget=[double]$ledger.budgetSeconds
        if ($ledger.schemaVersion -ne 1 -or $budget -ne 57600 -or [double]::IsNaN($elapsed) -or
            [double]::IsInfinity($elapsed) -or $elapsed -lt 0) { throw 'reconcile-required: shared ledger schema or elapsed value is invalid.' }
        if ($elapsed -lt $budget) { throw 'reconcile-required: exhausted budget candidate changed before locked validation.' }
        if ([double]$Progress.budgetElapsedSeconds -ne $elapsed) { throw 'reconcile-required: paused progress does not match the exhausted shared ledger.' }
        $pending=@($Progress.pendingCounts)
        if ($pending.Count -eq 0 -or
            -not [string]::Equals(($pending|ConvertTo-Json -Depth 12 -Compress),(@($ledger.pendingCases)|ConvertTo-Json -Depth 12 -Compress),[StringComparison]::Ordinal)) {
            throw 'reconcile-required: paused progress pending cases do not match the exhausted shared ledger.'
        }
        if (@($Progress.PSObject.Properties.Name) -notcontains 'activeCase' -or
            @($ledger.PSObject.Properties.Name) -notcontains 'activeCase' -or
            @($ledger.PSObject.Properties.Name) -notcontains 'pendingCases') {
            throw 'reconcile-required: exhausted clean pause omits active or pending accounting fields.'
        }
        foreach($active in @($ledger.activeCase)) {
            if ($null -ne $active) {
                foreach($field in @('runId','attemptId','caseKey','startedAtUtc')) {
                    if ((@($active.PSObject.Properties.Name) -contains $field) -and -not [string]::IsNullOrWhiteSpace([string]$active.$field)) {
                        throw 'reconcile-required: exhausted clean pause ledger still has an active case.'
                    }
                }
            }
        }
        foreach($active in @($Progress.activeCase)) {
            if ($null -ne $active) {
                foreach($field in @('runId','attemptId','caseKey','startedAtUtc')) {
                    if ((@($active.PSObject.Properties.Name) -contains $field) -and -not [string]::IsNullOrWhiteSpace([string]$active.$field)) {
                        throw 'reconcile-required: exhausted clean pause still has an active case.'
                    }
                }
            }
        }
        if ([string]$Progress.phase -cne 'paused') { throw 'reconcile-required: exhausted progress phase is not paused.' }

        $intentPath=Join-Path $RunRoot 'reconcile-intent.json'
        $commitPath=Join-Path $RunRoot 'reconcile-commit.json'
        if (-not (Test-Path -LiteralPath $intentPath -PathType Leaf) -or -not (Test-Path -LiteralPath $commitPath -PathType Leaf)) {
            throw 'reconcile-required: exhausted clean pause needs both R4 intent and commit.'
        }
        $intentHashBefore=Get-ResumeFileHash $intentPath
        $commitHashBefore=Get-ResumeFileHash $commitPath
        $intent=Read-Json $intentPath; $commit=Read-Json $commitPath
        if ($intent.schemaVersion -ne 1 -or $commit.schemaVersion -ne 1 -or
            [string]$intent.accountingKind -cne 'clean-paused-worker' -or [string]$commit.accountingKind -cne 'clean-paused-worker' -or
            [string]$intent.runId -cne $runId -or [string]$commit.runId -cne $runId -or
            [string]::IsNullOrWhiteSpace([string]$intent.transactionId) -or [string]::IsNullOrWhiteSpace([string]$intent.attemptId) -or
            [string]$intent.transactionId -cne [string]$commit.transactionId -or
            [string]$intent.attemptId -cne [string]$commit.attemptId -or
            [string]$intent.processReportSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
            [string]$intent.processReportSha256 -cne [string]$commit.processReportSha256 -or
            $intent.resumeAllowed -isnot [bool] -or $commit.resumeAllowed -isnot [bool] -or
            $intent.resumeAllowed -ne $false -or $commit.resumeAllowed -ne $false -or
            [double]$intent.targetSeconds -ne 0 -or [double]$intent.deltaSeconds -ne 0) {
            throw 'reconcile-required: R4 transaction does not prove an exhausted clean pause for this run.'
        }
        if (@($intent.entries).Count -ne 2 -or @($commit.entries).Count -ne 2) { throw 'reconcile-required: clean pause transaction path set is unsupported.' }
        $boundLedgerSha=''; $boundProgressSha=''
        foreach($path in @($ledgerPath,$ProgressPath)) {
            $intentSha=Get-ReconcileEntryByPath $intent $path 'newSha256'
            $commitSha=Get-ReconcileEntryByPath $commit $path 'sha256'
            $intentEntry=@($intent.entries|Where-Object { [string]$_.path -ceq $path })[0]
            $targetSha=Get-ResumeFileHash $path
            if ([string]$intentEntry.beforePath -cne ($path+'.before') -or
                [string]$intentEntry.oldSha256 -cne $intentSha -or $commitSha -cne $intentSha -or
                [string]$intentEntry.newContent -eq '' -or
                [string]::Equals($intentSha,'',[StringComparison]::Ordinal) -or
                $targetSha -cne $intentSha) {
                throw "reconcile-required: clean pause transaction does not bind the current target $path."
            }
            if ($path -ceq $ledgerPath) { $boundLedgerSha=$targetSha } else { $boundProgressSha=$targetSha }
            $contentSha=[Security.Cryptography.SHA256]::Create()
            try {
                $contentHash=([BitConverter]::ToString($contentSha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes([string]$intentEntry.newContent)))).Replace('-','').ToLowerInvariant()
            } finally { $contentSha.Dispose() }
            if ($contentHash -cne $intentSha) { throw "reconcile-required: clean pause intent content digest conflicts for $path." }
        }
        if (Test-Path -LiteralPath (Join-Path $RunRoot 'owner-stop.json')) { throw 'owner-stopped: budget pause was interrupted by owner-stop.' }
        if ((Get-ResumeFileHash $runManifestPath) -cne $manifestHashBefore -or
            (Get-ResumeFileHash $ProgressPath) -cne $progressHashBefore -or
            (Get-ResumeFileHash $OptionsPath) -cne $optionsHashBefore -or
            (Get-ResumeFileHash $ledgerPath) -cne $ledgerHashBefore -or $boundLedgerSha -cne $ledgerHashBefore -or
            $boundProgressSha -cne $progressHashBefore -or
            (Get-ResumeFileHash $intentPath) -cne $intentHashBefore -or
            (Get-ResumeFileHash $commitPath) -cne $commitHashBefore) {
            throw 'reconcile-required: exhausted clean pause evidence changed during validation.'
        }
        if (Test-Path -LiteralPath (Join-Path $RunRoot 'owner-stop.json')) {
            throw 'owner-stopped: budget pause was interrupted before run-manifest status update.'
        }
        $manifestForUpdateHash=Get-ResumeFileHash $runManifestPath
        if ($manifestForUpdateHash -cne $manifestHashBefore) {
            throw 'reconcile-required: run-manifest changed before budget-paused status update.'
        }
        $manifestForUpdate=Read-Json $runManifestPath
        if ([string]$manifestForUpdate.status -ceq 'owner-stopped') {
            throw 'owner-stopped: run-manifest was stopped before budget-paused status update.'
        }
        if ((Test-Path -LiteralPath (Join-Path $RunRoot 'owner-stop.json')) -or
            (Get-ResumeFileHash $runManifestPath) -cne $manifestForUpdateHash -or
            (Get-ResumeFileHash $ProgressPath) -cne $progressHashBefore -or
            (Get-ResumeFileHash $OptionsPath) -cne $optionsHashBefore -or
            (Get-ResumeFileHash $ledgerPath) -cne $ledgerHashBefore -or
            (Get-ResumeFileHash $intentPath) -cne $intentHashBefore -or
            (Get-ResumeFileHash $commitPath) -cne $commitHashBefore) {
            throw 'reconcile-required: exhausted clean pause evidence changed immediately before run-manifest update.'
        }
        $manifestForUpdate.status='budget-paused'
        $manifestForUpdate.updatedAtUtc=[DateTime]::UtcNow.ToString('o')
        Write-JsonAtomic $runManifestPath $manifestForUpdate
        return [pscustomobject]@{status='budget-paused';runFolder=$RunRoot;report=(Join-Path (Join-Path $RunRoot 'probe') 'load-probe.json');pendingCounts=$pending;elapsedSeconds=$elapsed;budgetSeconds=$budget;workerStarted=$false}
    } catch {
        if ([string]$_.Exception.Message -match '^(identity-unknown|reconcile-required|owner-stopped|source-mismatch|writer-lease-unavailable):') { throw }
        throw "reconcile-required: exhausted clean pause evidence could not be verified. $($_.Exception.Message)"
    } finally {
        if ($null -ne $writerLease) { $writerLease.Dispose() }
    }
}

function Assert-ResumeProcessTuple([string]$RunRoot,$Worker) {
    try {
        if ([string]::IsNullOrWhiteSpace([string]$Worker.runId)) { throw 'worker runId is missing.' }
        $workerFolder=Get-ResumeContainedPath $RunRoot ([string]$Worker.workerFolder) 'workerFolder'
        if (-not (Test-Path -LiteralPath $workerFolder -PathType Container)) { throw 'workerFolder is not a directory.' }
        $launchPath=Join-Path $workerFolder 'launch.json'
        $startedPath=Join-Path $workerFolder 'process-started.json'
        $launchFile=Get-ResumeContainedPath $RunRoot $launchPath 'launch.json' -RequireLeaf
        $startedFile=Get-ResumeContainedPath $RunRoot $startedPath 'process-started.json' -RequireLeaf
        $launch=Read-Json $launchFile
        $started=Read-Json $startedFile
        foreach ($identity in @($Worker,$launch,$started)) {
            if ([string]$identity.runId -cne [string]$Worker.runId) { throw 'runId tuple conflict.' }
        }
        foreach ($field in @('workerProcessId','matlabProcessId')) {
            $value=$Worker.$field
            $number=[int64]0
            if (-not [int64]::TryParse([string]$value,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or $number -le 0 -or $number -gt [int]::MaxValue) { throw "$field is not a positive integral identity." }
        }
        if ([int]$Worker.workerProcessId -ne [int]$launch.workerProcessId -or [int]$Worker.workerProcessId -ne [int]$started.workerProcessId) { throw 'workerProcessId tuple conflict.' }
        if ([int]$Worker.matlabProcessId -ne [int]$launch.rootProcessId -or [int]$Worker.matlabProcessId -ne [int]$started.rootProcessId) { throw 'rootProcessId tuple conflict.' }
        if (-not (Test-ResumeTimeEqual ([string]$Worker.workerProcessStartTimeUtc) ([string]$launch.workerProcessStartTimeUtc)) -or -not (Test-ResumeTimeEqual ([string]$Worker.workerProcessStartTimeUtc) ([string]$started.workerProcessStartTimeUtc))) { throw 'worker process start-time tuple conflict.' }
        if (-not (Test-ResumeTimeEqual ([string]$Worker.matlabProcessStartTimeUtc) ([string]$launch.processStartTimeUtc)) -or -not (Test-ResumeTimeEqual ([string]$Worker.matlabProcessStartTimeUtc) ([string]$started.processStartTimeUtc))) { throw 'root process start-time tuple conflict.' }
        if ([string]::IsNullOrWhiteSpace([string]$Worker.executable) -or [string]$Worker.executable -cne [string]$started.executable -or [string]$Worker.executable -cne [string]$launch.executable) { throw 'executable metadata conflict.' }
        if ([string]::IsNullOrWhiteSpace([string]$Worker.arguments) -or [string]$Worker.arguments -cne [string]$started.arguments -or [string]$Worker.arguments -cne [string]$launch.arguments) { throw 'arguments metadata conflict.' }
        if ([string]$started.workingDirectory -cne [string]$launch.workingDirectory) { throw 'workingDirectory metadata conflict.' }
        if ([string]$Worker.matlabCommandLine -cne [string]$started.rootCommandLine -or [string]::IsNullOrWhiteSpace([string]$Worker.matlabCommandLine)) { throw 'root command-line metadata conflict.' }
        if ([string]$Worker.workerCommandLine -cne [string]$started.workerCommandLine -or [string]::IsNullOrWhiteSpace([string]$Worker.workerCommandLine)) { throw 'worker command-line metadata conflict.' }
        $expectedProcessStarted=[IO.Path]::GetFullPath($startedPath)
        if (-not [string]::Equals([IO.Path]::GetFullPath([string]$launch.processStarted),$expectedProcessStarted,[StringComparison]::OrdinalIgnoreCase)) { throw 'processStarted path metadata conflict.' }
        $workerProgressPath=Get-ResumeContainedDeclaredFilePath $RunRoot ([string]$Worker.progressFile) 'worker.progressFile'
        $launchProgressPath=Get-ResumeContainedDeclaredFilePath $RunRoot ([string]$launch.progressFile) 'launch.progressFile'
        if (-not [string]::Equals($workerProgressPath,$launchProgressPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'progressFile metadata conflict.' }
        $workerReportPath=Get-ResumeContainedDeclaredFilePath $RunRoot ([string]$Worker.processReport) 'worker.processReport'
        $launchReportPath=Get-ResumeContainedDeclaredFilePath $RunRoot ([string]$launch.processReport) 'launch.processReport'
        if (-not [string]::Equals($workerReportPath,$launchReportPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'processReport metadata conflict.' }
        return $true
    } catch {
        throw "identity-unknown: process-started/launch tuple could not be verified. $($_.Exception.Message)"
    }
}

function Test-ProcessIdentity([int]$ProcessId,[string]$StartTimeUtc,[string]$ExpectedCommand) {
    if ($ProcessId -le 0) { return $false }
    $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        $actualStart=$process.StartTime.ToUniversalTime()
        $expectedStart=[DateTime]::Parse($StartTimeUtc).ToUniversalTime()
        if ([Math]::Abs(($actualStart-$expectedStart).TotalSeconds) -gt 0.05) { return $false }
    } catch { return $false }
    $wmi=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $wmi -or [string]::IsNullOrWhiteSpace([string]$wmi.CommandLine)) { return $false }
    if ([string]::IsNullOrWhiteSpace($ExpectedCommand)) { return $false }
    return [string]::Equals([string]$wmi.CommandLine,$ExpectedCommand,[StringComparison]::OrdinalIgnoreCase)
}

function Assert-LocalResources([string]$Path) {
    $driveName=[IO.Path]::GetPathRoot($Path).TrimEnd('\').TrimEnd(':')
    $drive=Get-PSDrive -Name $driveName -ErrorAction Stop
    $requiredDisk=[int64](20GB)
    if ([int64]$drive.Free -lt $requiredDisk) {
        throw "Вариант 2 не запущен: свободно на диске $([Math]::Round($drive.Free/1GB,1)) GiB, требуется не меньше 20 GiB."
    }
    $os=Get-CimInstance Win32_OperatingSystem
    $freeMemory=[int64]$os.FreePhysicalMemory*1KB
    $requiredMemory=[int64](16GB)
    if ($freeMemory -lt $requiredMemory) {
        throw "Вариант 2 не запущен: свободно в RAM $([Math]::Round($freeMemory/1GB,1)) GiB, требуется не меньше 16 GiB."
    }
}

if (($DesignOnly -and ($Execute -or $Resume)) -or ($Execute -and $Resume) -or ($RunFolder -ne '' -and -not $Resume)) {
    throw 'Выберите один режим: -DesignOnly, -Execute или -Resume -RunFolder <absolute path>.'
}

$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$planned=[pscustomobject]@{
    scope='variant2-preliminary-load-probe'
    counts=@(100,500,1000,2500)
    policy='Static'
    durationTicks=5000
    burstDurationTicks=100
    sharedBudgetSeconds=57600
    realization='one fresh Stage 3 ID shared across four sizes; ID 1064 is forbidden'
    fullPilotCompleted=$false
    missingFullPilotCounts=5000
}
if (-not $Execute -and -not $Resume) {
    if ($DesignOnly) { $planned | Add-Member -NotePropertyName mode -NotePropertyValue 'design-only' }
    else { $planned | Add-Member -NotePropertyName mode -NotePropertyValue 'plan-only' }
    $planned
    return
}

$stage2Directory=Join-Path $projectRoot 'verification\completion\stage-2'
if ([string]::IsNullOrWhiteSpace($Stage2AcceptanceFile)) {
    $Stage2AcceptanceFile=Join-Path $stage2Directory 'acceptance.json'
}
$sharedLedger=Join-Path $stage2Directory 'budget-ledger.json'
$probeFolder=''
$runRoot=''
$history=@()
$oldWorker=$null

if ($Execute) {
    if (-not (Test-Path -LiteralPath $Stage2AcceptanceFile -PathType Leaf)) {
        throw "Вариант 2 не запущен: нет допуска Stage 2 $Stage2AcceptanceFile"
    }
    if (-not (Test-Path -LiteralPath $sharedLedger -PathType Leaf)) {
        throw "Вариант 2 не запущен: нет общего бюджета Stage 2/3 $sharedLedger"
    }
    $base=Join-Path $projectRoot 'verification\completion\stage-3'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    $runRoot=Join-Path $base ('variant2-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $probeFolder=Join-Path $runRoot 'probe'
    Assert-LocalResources $runRoot
    $runManifest=[ordered]@{
        scope='variant2-preliminary-load-probe'
        status='preparing'
        createdAtUtc=[DateTime]::UtcNow.ToString('o')
        projectRoot=$projectRoot
        runFolder=$runRoot
        probeFolder=$probeFolder
        sharedBudgetLedger=$sharedLedger
        stage2AcceptanceFile=$Stage2AcceptanceFile
        counts=@(100,500,1000,2500)
        durationTicks=5000
        burstDurationTicks=100
        policy='Static'
        fullPilotCompleted=$false
    }
    Write-JsonAtomic (Join-Path $runRoot 'run-manifest.json') $runManifest
    $options=[ordered]@{
        designOnly=$false
        counts=@(100,500,1000,2500)
        outputFolder=$probeFolder
        stage2AcceptanceFile=$Stage2AcceptanceFile
        calibrationFile=(Join-Path $projectRoot 'results\nprach-calibration.mat')
        registryFile=(Join-Path $projectRoot 'experiments\realizationRegistry.json')
        realizationId=$null
        execution=@{profile='scheduled-local';role='stage-3-load-pilot';maxUE=2500;maxCaseSeconds=57600;maxSuiteSeconds=57600;timePolicy='finish-current'}
        resume=$false
        budgetLedgerFile=$sharedLedger
        memoryRootFolder=$runRoot
    }
    Write-JsonAtomic (Join-Path $runRoot 'worker-options.json') $options
} else {
    if (-not [IO.Path]::IsPathFullyQualified($RunFolder)) { throw '-RunFolder должен содержать абсолютный путь.' }
    $runRoot=(Resolve-Path -LiteralPath $RunFolder).Path
    $probeFolder=Join-Path $runRoot 'probe'
    $optionsPath=Join-Path $runRoot 'worker-options.json'
    $manifestPath=Join-Path $runRoot 'worker.json'
    $runManifestPath=Join-Path $runRoot 'run-manifest.json'
    $progressPath=Join-Path $probeFolder 'progress.json'
    if (Test-Path -LiteralPath (Join-Path $runRoot 'owner-stop.json')) {
        throw 'owner-stopped: resume is refused before process lookup or any RunFolder write.'
    }
    if (-not (Test-Path -LiteralPath $runManifestPath -PathType Leaf)) { throw 'identity-unknown: run-manifest.json is missing.' }
    $runManifest=Read-Json $runManifestPath
    if ($runManifest.status -eq 'owner-stopped') { throw 'owner-stopped: resume is refused before process lookup or any RunFolder write.' }
    if (-not (Test-Path -LiteralPath $progressPath -PathType Leaf)) { throw "Нет файла для безопасного resume: $progressPath" }
    $progress=Read-Json $progressPath
    if ([string]$progress.status -ceq 'owner-stopped') {
        throw 'owner-stopped: saved progress is stopped; resume is refused before worker tuple, source, or process lookup and any RunFolder write.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$runManifest.runFolder) -or -not [IO.Path]::IsPathFullyQualified([string]$runManifest.runFolder)) {
        throw 'identity-unknown: run-manifest folder does not match RunFolder.'
    }
    $manifestRunFolder=(Resolve-Path -LiteralPath ([string]$runManifest.runFolder) -ErrorAction Stop).Path
    if (-not [string]::Equals($manifestRunFolder.TrimEnd('\'),$runRoot.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'identity-unknown: run-manifest folder does not match RunFolder.'
    }
    $sourceProof=Assert-ResumeSourceProof $projectRoot $runRoot $probeFolder $progressPath (Join-Path $probeFolder 'preflight.json')
    $progress=$sourceProof.progress
    # Recheck owner-stop and the two pre-worker identity files immediately
    # before reading worker.json or any saved process tuple.
    if (Test-Path -LiteralPath (Join-Path $runRoot 'owner-stop.json')) {
        throw 'owner-stopped: resume is refused before worker tuple, process lookup, or any RunFolder write.'
    }
    $latestRunManifest=Read-Json $runManifestPath
    $latestProgress=Read-Json (Get-ResumeContainedPath $runRoot $progressPath 'progress.json' -RequireLeaf)
    if ([string]$latestRunManifest.status -ceq 'owner-stopped' -or [string]$latestProgress.status -ceq 'owner-stopped') {
        throw 'owner-stopped: saved run/progress is stopped; resume is refused before worker tuple, process lookup, or any RunFolder write.'
    }
    $latestRunFolder=(Resolve-Path -LiteralPath ([string]$latestRunManifest.runFolder) -ErrorAction Stop).Path
    if (-not [string]::Equals($latestRunFolder.TrimEnd('\'),$runRoot.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'identity-unknown: run-manifest folder changed before worker tuple validation.'
    }
    foreach ($field in @('sourceManifestSha256','runnerSha256')) {
        if (-not [string]::Equals([string]$latestProgress.$field,[string]$progress.$field,[StringComparison]::OrdinalIgnoreCase)) {
            throw "source-mismatch: progress $field changed before worker tuple validation."
        }
    }
    $progress=$latestProgress
    if (-not (Test-Path -LiteralPath $optionsPath -PathType Leaf)) {
        throw "Нет файла для безопасного resume: $optionsPath"
    }
    $budgetStop=Get-CleanPauseBudgetStop $runRoot $latestRunManifest $progress $optionsPath $progressPath
    if ($null -ne $budgetStop) {
        $budgetStop
        return
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Нет файла для безопасного resume: $manifestPath" }
    $oldWorker=Read-Json $manifestPath
    if ($oldWorker.status -eq 'owner-stopped') { throw 'owner-stopped: worker manifest is stopped; resume is refused before process lookup or any RunFolder write.' }
    if ([string]::IsNullOrWhiteSpace([string]$oldWorker.runFolder) -or -not [IO.Path]::IsPathFullyQualified([string]$oldWorker.runFolder)) {
        throw 'identity-unknown: worker manifest folder does not match RunFolder.'
    }
    $workerRunFolder=(Resolve-Path -LiteralPath ([string]$oldWorker.runFolder) -ErrorAction Stop).Path
    if (-not [string]::Equals($workerRunFolder.TrimEnd('\'),$runRoot.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'identity-unknown: worker manifest folder does not match RunFolder.'
    }
    $reconcileCommitPath=Join-Path $runRoot 'reconcile-commit.json'
    if (-not (Test-Path -LiteralPath $reconcileCommitPath -PathType Leaf)) { throw 'reconcile-required: a matching R4 reconcile commit is required before direct resume.' }
    $reconcileCommit=Read-Json $reconcileCommitPath
    if ($reconcileCommit.schemaVersion -ne 1 -or [string]$reconcileCommit.runId -cne [string]$oldWorker.runId -or $reconcileCommit.resumeAllowed -ne $true) {
        throw 'reconcile-required: the R4 reconcile commit does not authorize this run.'
    }
    [void](Assert-ResumeProcessTuple $runRoot $oldWorker)
    $workerAlive=Test-ProcessIdentity ([int]$oldWorker.workerProcessId) `
        ([string]$oldWorker.workerProcessStartTimeUtc) ([string]$oldWorker.workerCommandLine)
    $matlabAlive=Test-ProcessIdentity ([int]$oldWorker.matlabProcessId) `
        ([string]$oldWorker.matlabProcessStartTimeUtc) ([string]$oldWorker.matlabCommandLine)
    if ($workerAlive -or $matlabAlive) {
        throw "Resume не запущен: MATLAB worker ещё работает (worker PID=$($oldWorker.workerProcessId), MATLAB PID=$($oldWorker.matlabProcessId))."
    }
    $previousReport=$null
    if (Test-Path -LiteralPath ([string]$oldWorker.processReport) -PathType Leaf) {
        $previousReport=Read-Json ([string]$oldWorker.processReport)
        $oldWorker.status=[string]$previousReport.status
        $oldWorker.exitCode=[int]$previousReport.exitCode
        $oldWorker.processReportRecordedAtUtc=[DateTime]::UtcNow.ToString('o')
        Write-JsonAtomic $manifestPath $oldWorker
    }
    if ($progress.status -eq 'preliminary-completed') {
        $runManifest=Set-NoWorkerRunManifestStatus $runRoot 'preliminary-completed' 'preliminary-completed'
        [pscustomobject]@{status='preliminary-completed';runFolder=$runRoot;report=(Join-Path $probeFolder 'load-probe.json');workerStarted=$false}
        return
    }
    if ($Stage2AcceptanceFile -ne (Join-Path $stage2Directory 'acceptance.json')) {
        $options=Read-Json $optionsPath
        $Stage2AcceptanceFile=[string]$options.stage2AcceptanceFile
    }
    $options=Read-Json $optionsPath
    $options.resume=$true
    $options.memoryRootFolder=$runRoot
    $sharedLedger=[string]$options.budgetLedgerFile
    if ($progress.status -eq 'budget-paused' -and (Test-Path -LiteralPath $sharedLedger -PathType Leaf)) {
        $ledger=Read-Json $sharedLedger
        if ([double]$ledger.elapsedSeconds -ge [double]$ledger.budgetSeconds) {
            $runManifest=Set-NoWorkerRunManifestStatus $runRoot 'budget-paused' 'budget-paused' -RequireBudgetExhausted
            [pscustomobject]@{
                status='budget-paused'
                runFolder=$runRoot
                report=(Join-Path $probeFolder 'load-probe.json')
                pendingCounts=@($progress.pendingCounts)
                workerStarted=$false
            }
            return
        }
    }
    Clear-StopAfterCaseMarkerForResume $runRoot ([string]$oldWorker.runId)
    $optionsPath=Join-Path $runRoot 'worker-options.json'
    Write-JsonAtomic $optionsPath $options
    $history=@($oldWorker.history)
    if ($null -eq $history) { $history=@() }
    $history+=,[pscustomobject]@{
        runId=$oldWorker.runId
        workerProcessId=$oldWorker.workerProcessId
        matlabProcessId=$oldWorker.matlabProcessId
        workerStatus='exited'
        workerFolder=$oldWorker.workerFolder
        previousRecordedAtUtc=$oldWorker.recordedAtUtc
    }
}

Assert-LocalResources $runRoot
$matlab=(Get-Command $MatlabCommand -ErrorAction Stop).Source
$workerRoot=Join-Path $runRoot 'workers'
New-Item -ItemType Directory -Path $workerRoot -Force | Out-Null
$runId=[guid]::NewGuid().ToString('N')
$workerFolder=Join-Path $workerRoot ('worker-'+$runId)
$memoryCsv=Join-Path $workerFolder 'memory.csv'
$optionsPath=Join-Path $runRoot 'worker-options.json'
Set-OptionField $options 'runId' $runId
Set-OptionField $options 'runControlFolder' $runRoot
Write-JsonAtomic $optionsPath $options
$matlabRoot=$projectRoot.Replace('\','/').Replace("'","''")
$optionsM=(Resolve-Path -LiteralPath $optionsPath).Path.Replace('\','/').Replace("'","''")
$batch="cd('$matlabRoot'); addpath('$matlabRoot'); setupProject(); options=jsondecode(fileread('$optionsM')); report=runLoadProbe(options); assert(any(strcmp(report.status,{'preliminary-completed','budget-paused','paused'})),'Load probe requires attention; inspect progress.json and case evidence.');"
$arguments='-batch "'+$batch+'"'
$scheduledWrapper=Join-Path $PSScriptRoot '..\..\local\InvokeScheduledProcess.ps1'
$scheduledWrapper=(Resolve-Path -LiteralPath $scheduledWrapper).Path
$progressFile=Join-Path $probeFolder 'worker-progress.json'
$launch=& $scheduledWrapper -Executable $matlab -Arguments $arguments -RunId $runId `
    -WorkingDirectory $projectRoot -OutputFolder $workerFolder `
    -ProgressFile $progressFile -MemoryCsvPath $memoryCsv `
    -SampleIntervalSeconds 1 -HeartbeatSeconds 30 `
    -NoProgressWarningSeconds 900 -StartupWaitSeconds 60

$workerProcess=Get-Process -Id ([int]$launch.workerProcessId) -ErrorAction Stop
$workerCim=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$launch.workerProcessId)"
$matlabCim=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$launch.rootProcessId)"
if ($null -eq $workerCim -or $null -eq $matlabCim -or
    [string]::IsNullOrWhiteSpace([string]$workerCim.CommandLine) -or
    [string]::IsNullOrWhiteSpace([string]$matlabCim.CommandLine)) {
    throw 'Worker identities were not available after the scheduled process started; the child was left running and its launch folder was preserved.'
}
$currentWorker=[ordered]@{
    status='running'
    runId=$runId
    runFolder=$runRoot
    workerFolder=$workerFolder
    workerProcessId=[int]$launch.workerProcessId
    workerProcessStartTimeUtc=$workerProcess.StartTime.ToUniversalTime().ToString('o')
    workerCommandLine=[string]$workerCim.CommandLine
    matlabProcessId=[int]$launch.rootProcessId
    matlabProcessStartTimeUtc=[string]$launch.processStartTimeUtc
    matlabCommandLine=[string]$matlabCim.CommandLine
    executable=$matlab
    arguments=$arguments
    stdout=[string]$launch.stdout
    stderr=[string]$launch.stderr
    memoryCsv=$memoryCsv
    progressFile=$progressFile
    processReport=[string]$launch.processReport
    heartbeat=[string]$launch.heartbeat
    recordedAtUtc=[DateTime]::UtcNow.ToString('o')
    history=$history
}
Write-JsonAtomic (Join-Path $runRoot 'worker.json') $currentWorker
$manifest=Read-Json (Join-Path $runRoot 'run-manifest.json')
$manifest.status='running'
$manifest.updatedAtUtc=[DateTime]::UtcNow.ToString('o')
Write-JsonAtomic (Join-Path $runRoot 'run-manifest.json') $manifest
[pscustomobject]@{
    status='running'
    runFolder=$runRoot
    probeFolder=$probeFolder
    workerFolder=$workerFolder
    workerProcessId=$launch.workerProcessId
    matlabProcessId=$launch.rootProcessId
    heartbeat=$launch.heartbeat
    processReport=$launch.processReport
    fullPilotCompleted=$false
}
