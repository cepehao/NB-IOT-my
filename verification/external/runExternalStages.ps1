[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageFolder,
    [Parameter(Mandatory = $true)]
    [ValidateSet('validate','pilot','data','assemble','train','freeze','evaluate','admit','compare','summarize')]
    [string]$Stage,
    [ValidateSet('local-development','external-machine')]
    [string]$ExecutionProfile = 'local-development',
    [string]$ReviewFile = '',
    [switch]$Inspect,
    [switch]$Execute,
    [switch]$RecoverInterrupted
)

$ErrorActionPreference = 'Stop'

function Stop-BlockedStage([string]$Reason) {
    Write-Output "EXTERNAL_STAGE_BLOCKED=$Reason"
    throw "External stage is blocked: $Reason"
}

function Test-ExplicitBudget($Value) {
    if ($null -eq $Value) { return $false }
    foreach ($name in @('targetMachine','availableMemoryBytes','maxUE','maxCaseSeconds','maxSuiteSeconds','maxProcesses')) {
        if ($null -eq $Value.PSObject.Properties[$name]) { return $false }
    }
    $machine = [string]$Value.targetMachine
    if ([string]::IsNullOrWhiteSpace($machine) -or $machine.Length -gt 64 -or
        $machine -match '[\\/:]|\.\.|[\r\n]') { return $false }
    foreach ($name in @('availableMemoryBytes','maxUE','maxCaseSeconds','maxSuiteSeconds','maxProcesses')) {
        $number = 0.0
        if (-not [double]::TryParse([string]$Value.$name, [ref]$number) -or
            [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -le 0) {
            return $false
        }
    }
    if ([double]$Value.maxSuiteSeconds -lt [double]$Value.maxCaseSeconds) { return $false }
    if ([double]$Value.availableMemoryBytes -ne [math]::Floor([double]$Value.availableMemoryBytes) -or
        [double]$Value.maxUE -ne [math]::Floor([double]$Value.maxUE) -or
        [double]$Value.maxProcesses -ne [math]::Floor([double]$Value.maxProcesses)) { return $false }
    return $true
}

function Test-MeasuredResourceBudget($Evidence, $Budget) {
    if (-not (Test-ExplicitBudget $Evidence) -or -not (Test-ExplicitBudget $Budget) -or
        [string]$Evidence.targetMachine -cne [string]$Budget.targetMachine) { return $false }
    foreach ($name in @('availableMemoryBytes','maxUE','maxCaseSeconds','maxSuiteSeconds','maxProcesses')) {
        if ([double]$Evidence.$name -ne [double]$Budget.$name) { return $false }
    }
    $measurements = @(
        @{ field = 'sampledPeakWorkingSetBytes'; limit = 'availableMemoryBytes' },
        @{ field = 'sampledPeakProcessCount'; limit = 'maxProcesses' },
        @{ field = 'maxMeasuredCaseSeconds'; limit = 'maxCaseSeconds' },
        @{ field = 'measuredSuiteSeconds'; limit = 'maxSuiteSeconds' },
        @{ field = 'processRunnerElapsedSeconds'; limit = 'maxSuiteSeconds' }
    )
    foreach ($measurement in $measurements) {
        if ($null -eq $Evidence.PSObject.Properties[$measurement.field]) { return $false }
        $value = 0.0
        if (-not [double]::TryParse([string]$Evidence.($measurement.field), [ref]$value) -or
            [double]::IsNaN($value) -or [double]::IsInfinity($value) -or
            $value -le 0 -or $value -gt [double]$Budget.($measurement.limit)) { return $false }
    }
    return $true
}

function Assert-ExactProperties($Value, [string[]]$Allowed, [string]$Label) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) {
        Stop-BlockedStage 'stage-state-invalid'
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Allowed.Count -or @($actual | Where-Object { $_ -notin $Allowed }).Count -gt 0) {
        Stop-BlockedStage 'stage-state-invalid'
    }
}

function Get-ExpectedDependencies([string]$Name) {
    switch ($Name) {
        'validate' { return @() }
        'pilot' { return @('validate') }
        'data' { return @('pilot') }
        'assemble' { return @('data') }
        'train' { return @('assemble') }
        'freeze' { return @('train') }
        'evaluate' { return @('freeze') }
        'admit' { return @('evaluate') }
        'compare' { return @('admit') }
        'summarize' { return @('compare') }
        default { Stop-BlockedStage 'stage-name-invalid' }
    }
}

function Test-StringSequence($Actual, [string[]]$Expected) {
    $items = @($Actual | ForEach-Object { [string]$_ })
    if ($items.Count -ne $Expected.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($items[$index] -cne $Expected[$index]) { return $false }
    }
    return $true
}

function ConvertFrom-JsonWithoutDateCoercion([string]$Json) {
    $converter = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($converter.Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Json -DateKind String
    }
    return ConvertFrom-Json -InputObject $Json
}

function Read-ValidatedStageState([string]$Path, $Manifest) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-BlockedStage 'stage-state-missing'
    }
    try { $value = ConvertFrom-JsonWithoutDateCoercion (Get-Content -LiteralPath $Path -Raw) }
    catch { Stop-BlockedStage 'stage-state-invalid' }
    Assert-ExactProperties $value @('schemaVersion','runId','packageDigest','registryDigest','updatedAtUtc','stages') 'root'
    if ([int]$value.schemaVersion -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$value.runId) -or
        [string]$value.packageDigest -cne [string]$Manifest.codeManifestSha256 -or
        [string]$value.registryDigest -notmatch '^[A-Fa-f0-9]{64}$' -or
        $null -eq $value.stages) {
        Stop-BlockedStage 'stage-state-invalid'
    }
    $names = @('validate','pilot','data','assemble','train','freeze','evaluate','admit','compare','summarize')
    $stages = @($value.stages)
    if ($stages.Count -ne $names.Count) { Stop-BlockedStage 'stage-state-invalid' }
    foreach ($name in $names) {
        $matches = @($stages | Where-Object { [string]$_.name -ceq $name })
        if ($matches.Count -ne 1) { Stop-BlockedStage 'stage-state-invalid' }
        $entry = $matches[0]
        Assert-ExactProperties $entry @('name','dependencies','command','inputs','outputs','executionBudget','requiredDecision','configuration','status','inputDigest','outputDigest','reportPath','registryInputDigest','worker') $name
        if (-not (Test-StringSequence $entry.dependencies (Get-ExpectedDependencies $name))) {
            Stop-BlockedStage 'stage-state-invalid'
        }
        Assert-ExactProperties $entry.command @('executable','arguments') "$name command"
        $expectedCommand = "report=runExternalStage(pwd,'$name');"
        if ([string]$entry.command.executable -cne 'matlab' -or
            -not (Test-StringSequence $entry.command.arguments @('-batch',$expectedCommand))) {
            Stop-BlockedStage 'stage-command-rejected'
        }
        if (-not (Test-ExplicitBudget $entry.executionBudget) -or
            [string]$entry.status -notin @('not-started','running','completed','failed','stale','awaiting-review') -or
            ([string]$entry.inputDigest -ne '' -and [string]$entry.inputDigest -notmatch '^[A-Fa-f0-9]{64}$') -or
            ([string]$entry.outputDigest -ne '' -and [string]$entry.outputDigest -notmatch '^[A-Fa-f0-9]{64}$') -or
            ([string]$entry.registryInputDigest -ne '' -and [string]$entry.registryInputDigest -notmatch '^[A-Fa-f0-9]{64}$')) {
            Stop-BlockedStage 'stage-state-invalid'
        }
        if ($null -ne $entry.inputs) {
            foreach ($input in @($entry.inputs)) {
                Assert-ExactProperties $input @('path','sha256') "$name input"
                if ([string]$input.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { Stop-BlockedStage 'stage-state-invalid' }
            }
        }
        if ($null -ne $entry.outputs) {
            foreach ($output in @($entry.outputs)) {
                Assert-ExactProperties $output @('path','sha256') "$name output"
                if ([string]$output.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { Stop-BlockedStage 'stage-state-invalid' }
            }
        }
    }
    return $value
}

function Find-Stage($State, [string]$Name) {
    return @($State.stages | Where-Object { [string]$_.name -ceq $Name })[0]
}

function Test-PackageSourceIntegrity($Manifest) {
    if ($null -eq $Manifest.PSObject.Properties['codeFiles'] -or
        $null -eq $Manifest.codeFiles -or
        [string]$Manifest.codeManifestSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        Stop-BlockedStage 'package-source-manifest-invalid'
    }
    $codeFilesJson = ConvertTo-Json -InputObject @($Manifest.codeFiles) -Depth 16 -Compress
    if ((Get-Sha256Text $codeFilesJson) -cne ([string]$Manifest.codeManifestSha256).ToLowerInvariant()) {
        Stop-BlockedStage 'package-source-manifest-digest-mismatch'
    }
    foreach ($entry in @($Manifest.codeFiles)) {
        Assert-ExactProperties $entry @('path','sha256','packagePath','packageSha256','sanitized') 'package source entry'
        if ($null -eq $entry.PSObject.Properties['packagePath'] -or
            $null -eq $entry.PSObject.Properties['packageSha256'] -or
            [string]$entry.packageSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            Stop-BlockedStage 'package-source-manifest-invalid'
        }
        $sourcePath = Resolve-PackageFile ([string]$entry.packagePath) -MustExist
        if ((Get-Sha256 $sourcePath) -cne [string]$entry.packageSha256) {
            Stop-BlockedStage 'package-source-hash-mismatch'
        }
    }
    $reference = $Manifest.calibration
    if ($null -eq $reference -or $null -eq $reference.PSObject.Properties['packagePath'] -or
        $null -eq $reference.PSObject.Properties['sha256'] -or
        [string]$reference.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        Stop-BlockedStage 'package-input-manifest-invalid'
    }
    $inputPath = Resolve-PackageFile ([string]$reference.packagePath) -MustExist
    if ((Get-Sha256 $inputPath) -cne [string]$reference.sha256) {
        Stop-BlockedStage 'package-input-hash-mismatch'
    }
}

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-Sha256Text([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Resolve-PackageFile([string]$RelativePath, [switch]$MustExist) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[:]|(^|[\\/])\.\.?([\\/]|$)' -or
        [IO.Path]::IsPathRooted($RelativePath)) {
        Stop-BlockedStage 'package-path-invalid'
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $packageRoot ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
    $prefix = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-BlockedStage 'package-path-invalid'
    }
    if ($MustExist) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { Stop-BlockedStage 'package-file-missing' }
        $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-BlockedStage 'package-path-invalid'
        }
        return $resolved
    }
    return $candidate
}

function Save-StageState($Value, [string]$Path) {
    $Value.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $Path + '.' + [guid]::NewGuid().ToString('N') + '.bak'
    $json = $Value | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    try {
        [IO.File]::Replace($temporary, $Path, $backup, $true)
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Get-StageInputDigest($Entry, $Manifest, $State, $AdditionalInputs = @()) {
    $script:stageInputContractChanged = $false
    $registryInputDigest = [string]$State.registryDigest
    if ([string]$Entry.status -ceq 'completed' -and [string]$Entry.registryInputDigest -match '^[A-Fa-f0-9]{64}$') {
        $registryInputDigest = [string]$Entry.registryInputDigest
    }
    $parts = @('stage-v1', [string]$Entry.name, [string]$Manifest.codeManifestSha256, (Get-Sha256 (Join-Path $packageRoot 'manifest.json')), $registryInputDigest, ($Entry.configuration | ConvertTo-Json -Depth 16 -Compress))
    foreach ($additionalInput in @($AdditionalInputs)) { $parts += [string]$additionalInput }
    foreach ($input in @($Entry.inputs)) {
        $inputPath = Resolve-PackageFile ([string]$input.path) -MustExist
        $actualHash = Get-Sha256 $inputPath
        if ($actualHash -cne [string]$input.sha256) {
            if ([string]$Entry.status -cne 'completed') {
                $input.sha256 = $actualHash
                $script:stageInputContractChanged = $true
            }
        }
        $parts += ([string]$input.path + ':' + $actualHash)
    }
    foreach ($dependencyName in @($Entry.dependencies)) {
        $dependency = Find-Stage $State ([string]$dependencyName)
        $parts += ([string]$dependency.name + ':' + [string]$dependency.outputDigest)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-CompleteStageReport($Entry) {
    if ([string]::IsNullOrWhiteSpace([string]$Entry.reportPath) -or
        [string]$Entry.outputDigest -notmatch '^[A-Fa-f0-9]{64}$') { return $null }
    try {
        $reportPath = Resolve-PackageFile ([string]$Entry.reportPath) -MustExist
        if ((Get-Sha256 $reportPath) -cne [string]$Entry.outputDigest) { return $null }
        $report = ConvertFrom-JsonWithoutDateCoercion (Get-Content -LiteralPath $reportPath -Raw)
        if ([int]$report.schemaVersion -ne 1 -or [string]$report.status -cne 'complete' -or
            [string]$report.stage -cne [string]$Entry.name -or
            [string]$report.inputDigest -cne [string]$Entry.inputDigest) { return $null }
        foreach ($output in @($report.outputFiles)) {
            $outputPath = Resolve-PackageFile ((Split-Path -Parent ([string]$Entry.reportPath)) + '/' + [string]$output.path) -MustExist
            if ([string]$output.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-Sha256 $outputPath) -cne [string]$output.sha256) { return $null }
        }
        return $report
    }
    catch { return $null }
}

function Test-ValidWorkerTimestamp([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch 'Z$') { return $false }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed) -and
        $parsed.Offset -eq [TimeSpan]::Zero -and
        $parsed -le [DateTimeOffset]::UtcNow.AddMinutes(1)
}

function Get-RecordedProcessState([int]$ProcessId, [string]$StartedAtUtc) {
    if ($ProcessId -le 0 -or -not (Test-ValidWorkerTimestamp $StartedAtUtc)) { return 'unknown' }
    try { $process = Get-Process -Id $ProcessId -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound -and
            $_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId,*') { return 'dead' }
        return 'unknown'
    }
    try { $actualStart = $process.StartTime.ToUniversalTime().ToString('o') }
    catch { return 'unknown' }
    if ($actualStart -ceq $StartedAtUtc) { return 'alive' }
    return 'dead'
}

function Get-WorkerLiveness($Worker) {
    if ($null -eq $Worker) { return 'unknown' }
    $unknown = $false
    foreach ($processRecord in @($Worker.ownedProcesses)) {
        if ($null -eq $processRecord) { $unknown = $true; continue }
        $state = Get-RecordedProcessState ([int]$processRecord.processId) ([string]$processRecord.startedAtUtc)
        if ($state -ceq 'alive') { return 'alive' }
        if ($state -ceq 'unknown') { $unknown = $true }
    }
    if ($null -ne $Worker.ownerProcessId -and $null -ne $Worker.ownerStartedAtUtc) {
        $ownerState = Get-RecordedProcessState ([int]$Worker.ownerProcessId) ([string]$Worker.ownerStartedAtUtc)
        if ($ownerState -ceq 'alive') { return 'alive' }
        if ($ownerState -ceq 'unknown') { $unknown = $true }
    }
    if ($unknown) { return 'unknown' }
    return 'dead'
}

function Assert-NoActiveOrInterruptedStage($State) {
    foreach ($entry in @($State.stages)) {
        if ([string]$entry.status -cne 'running') { continue }
        $workerLiveness = Get-WorkerLiveness $entry.worker
        if ($workerLiveness -ceq 'alive') { Stop-BlockedStage 'worker-active' }
        if ($workerLiveness -ceq 'unknown') { Stop-BlockedStage 'interrupted-worker-identity-required' }
        Stop-BlockedStage 'interrupted-reconciliation-required'
    }
}

function Assert-DependencyComplete($Entry) {
    if ([string]$Entry.status -cne 'completed') { Stop-BlockedStage 'dependency-required' }
    if ($null -eq (Read-CompleteStageReport $Entry)) { Stop-BlockedStage 'dependency-output-invalid' }
}

function Get-StageDependencyClosure($Entry, $State) {
    $pending = New-Object System.Collections.Stack
    foreach ($dependencyName in @($Entry.dependencies)) { $pending.Push([string]$dependencyName) }
    $seen = @{}
    while ($pending.Count -gt 0) {
        $dependencyName = [string]$pending.Pop()
        if ($seen.ContainsKey($dependencyName)) { continue }
        $seen[$dependencyName] = $true
        $dependency = Find-Stage $State $dependencyName
        foreach ($childName in @($dependency.dependencies)) { $pending.Push([string]$childName) }
    }
    return @($seen.Keys)
}

function Mark-StageDependencyStale($Entry, $State) {
    $Entry.status = 'stale'
    $Entry.worker = $null
    Save-StageState $State $statePath
    Write-Output "EXTERNAL_STAGE_STALE=$($Entry.name)"
    throw "Completed stage dependency '$($Entry.name)' no longer matches its current human approval or review."
}

function Get-AdmissionReviewPackagePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { $fullPath = [IO.Path]::GetFullPath($Path) }
    catch { return '' }
    $packagePrefix = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return '' }
    try { $resolved = (Resolve-Path -LiteralPath $fullPath -ErrorAction Stop).Path }
    catch { return '' }
    if (-not $resolved.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $resolved.Substring($packagePrefix.Length).Replace('\', '/')
}

function Assert-HumanGateDependenciesCurrent($Entry, $Manifest, $State) {
    $dependencyNames = Get-StageDependencyClosure $Entry $State
    foreach ($gateName in @('pilot','admit')) {
        if ($gateName -notin $dependencyNames) { continue }
        $gate = Find-Stage $State $gateName
        if ([string]$gate.status -ceq 'stale') { Stop-BlockedStage 'dependency-stale' }
        if ([string]$gate.status -cne 'completed') { Stop-BlockedStage 'dependency-required' }
        $report = Read-CompleteStageReport $gate
        if ($null -eq $report) { Mark-StageDependencyStale $gate $State }

        $identityBefore = ''
        $identityAfter = ''
        $currentInputDigest = ''
        $validationFailed = $false
        if ($gateName -ceq 'pilot') {
            $identityBefore = Get-Pilot5000ApprovalInputIdentity $gate
            try { Test-ExplicitPilot5000Approval $gate $Manifest *> $null }
            catch { $validationFailed = $true }
            $identityAfter = Get-Pilot5000ApprovalInputIdentity $gate
            try { $currentInputDigest = Get-StageInputDigest $gate $Manifest $State @($identityBefore) }
            catch { $validationFailed = $true }
        }
        else {
            $relativeReviewPath = ''
            if ($null -ne $gate.configuration -and
                $null -ne $gate.configuration.PSObject.Properties['reviewFile']) {
                $relativeReviewPath = [string]$gate.configuration.reviewFile
            }
            $reviewFullPath = ''
            if (-not [string]::IsNullOrWhiteSpace($relativeReviewPath)) {
                try { $reviewFullPath = Resolve-PackageFile $relativeReviewPath -MustExist }
                catch { $validationFailed = $true }
            }
            $identityBefore = Get-AdmissionReviewInputIdentity $reviewFullPath
            if ([string]::IsNullOrWhiteSpace($reviewFullPath)) { $validationFailed = $true }
            else {
                try { Test-ExplicitAdmission $reviewFullPath $Manifest *> $null }
                catch { $validationFailed = $true }
            }
            $identityAfter = Get-AdmissionReviewInputIdentity $reviewFullPath
            try { $currentInputDigest = Get-StageInputDigest $gate $Manifest $State @($identityBefore) }
            catch { $validationFailed = $true }
        }

        if ($validationFailed -or
            $identityBefore -cne $identityAfter -or
            $currentInputDigest -cne [string]$gate.inputDigest) {
            Mark-StageDependencyStale $gate $State
        }
    }
}

function Get-CurrentRegistryDigest($Manifest) {
    $path = Resolve-PackageFile ([string]$Manifest.registry.packagePath) -MustExist
    return Get-Sha256 $path
}

function Test-AuthorizedStage2RegistryAdvance([string]$Name, [string]$ActualDigest) {
    if ($Name -cne 'validate') { return $false }
    $acceptancePath = Join-Path $packageRoot 'project\verification\completion\stage-2\acceptance.json'
    if (-not (Test-Path -LiteralPath $acceptancePath -PathType Leaf)) { return $false }
    try { $acceptance = ConvertFrom-JsonWithoutDateCoercion (Get-Content -LiteralPath $acceptancePath -Raw) }
    catch { return $false }
    return ([int]$acceptance.schemaVersion -eq 2 -and
        [string]$acceptance.status -ceq 'accepted-for-stage-3' -and
        [string]$acceptance.registrySha256 -ceq $ActualDigest)
}

function Refresh-RegistryDigest($State, $Manifest) {
    $State.registryDigest = Get-CurrentRegistryDigest $Manifest
}

function Test-ExplicitAdmission([string]$Path, $Manifest) {
    if ([string]::IsNullOrWhiteSpace($Path)) { Stop-BlockedStage 'review-required' }
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $full -PathType Leaf)) { Stop-BlockedStage 'review-required' }
    try { $review = ConvertFrom-JsonWithoutDateCoercion (Get-Content -LiteralPath $full -Raw) }
    catch { Stop-BlockedStage 'review-invalid' }
    if ([string]$Manifest.modelAcceptance.evidenceKind -in @('test-fixture','development-fixture') -or
        ($null -ne $review.PSObject.Properties['evidenceKind'] -and
        [string]$review.evidenceKind -in @('test-fixture','development-fixture'))) {
        Stop-BlockedStage 'fixture-evidence-rejected'
    }
    $required = @('decision','reviewer','reviewedAtUtc','evidenceDigest','protocolSha256','limitations')
    if ($null -eq $review -or @($required | Where-Object { $null -eq $review.PSObject.Properties[$_] }).Count -gt 0 -or
        [string]$review.decision -notin @('accepted','rejected') -or
        [string]::IsNullOrWhiteSpace([string]$review.reviewer) -or
        [string]::IsNullOrWhiteSpace([string]$review.limitations) -or
        [string]$review.evidenceDigest -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string]$review.protocolSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        Stop-BlockedStage 'review-invalid'
    }
}

function Get-Pilot5000ScopeDigest($Manifest) {
    $budget = $Manifest.resourceBudget
    if (-not (Test-ExplicitBudget $budget) -or [long]$budget.maxUE -lt 5000 -or
        [string]$Manifest.codeManifestSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        return ''
    }
    $scope = [ordered]@{
        schema = 'pilot5000-approval-scope-v1'
        stage = 'pilot'
        counts = @([long]100, [long]500, [long]1000, [long]2500, [long]5000)
        codeManifestSha256 = ([string]$Manifest.codeManifestSha256).ToLowerInvariant()
        targetMachine = [string]$budget.targetMachine
        availableMemoryBytes = [long]$budget.availableMemoryBytes
        maxUE = [long]$budget.maxUE
        maxCaseSeconds = [double]$budget.maxCaseSeconds
        maxSuiteSeconds = [double]$budget.maxSuiteSeconds
        maxProcesses = [long]$budget.maxProcesses
    }
    $json = ConvertTo-Json -InputObject $scope -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-Pilot5000ApprovalInputIdentity($Entry) {
    if ($null -eq $Entry.configuration -or
        $null -eq $Entry.configuration.PSObject.Properties['pilot5000ApprovalFile'] -or
        [string]::IsNullOrWhiteSpace([string]$Entry.configuration.pilot5000ApprovalFile)) {
        return 'pilot5000ApprovalFile:missing-config'
    }
    $relativePath = ([string]$Entry.configuration.pilot5000ApprovalFile).Replace('\', '/')
    if ($relativePath -match '[:]|(^|[\/])\.\.?([\/]|$)' -or [IO.Path]::IsPathRooted($relativePath)) {
        return 'pilot5000ApprovalFile:invalid-path:' + (Get-Sha256Text $relativePath)
    }
    try {
        $candidate = [IO.Path]::GetFullPath((Join-Path $packageRoot ($relativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
        $packagePrefix = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $candidate.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return 'pilot5000ApprovalFile:invalid-path:' + (Get-Sha256Text $relativePath)
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return 'pilot5000ApprovalFile:' + $relativePath + ':missing'
        }
        $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        if (-not $resolved.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return 'pilot5000ApprovalFile:invalid-path:' + (Get-Sha256Text $relativePath)
        }
        $normalizedRelativePath = $resolved.Substring($packagePrefix.Length).Replace('\', '/')
        return 'pilot5000ApprovalFile:' + $normalizedRelativePath + ':' + (Get-Sha256 $resolved)
    }
    catch { return 'pilot5000ApprovalFile:' + $relativePath + ':missing' }
}

function Get-AdmissionReviewInputIdentity([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'reviewFile:missing' }
    try { $fullPath = [IO.Path]::GetFullPath($Path) }
    catch { return 'reviewFile:invalid-path' }
    $packagePrefix = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return 'reviewFile:outside-package'
    }
    $relativePath = $fullPath.Substring($packagePrefix.Length).Replace('\', '/')
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return 'reviewFile:' + $relativePath + ':missing'
    }
    try {
        $resolved = (Resolve-Path -LiteralPath $fullPath -ErrorAction Stop).Path
        if (-not $resolved.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return 'reviewFile:outside-package'
        }
        $normalizedRelativePath = $resolved.Substring($packagePrefix.Length).Replace('\', '/')
        return 'reviewFile:' + $normalizedRelativePath + ':' + (Get-Sha256 $resolved)
    }
    catch { return 'reviewFile:' + $relativePath + ':missing' }
}

function Test-ExplicitPilot5000Approval($Entry, $Manifest) {
    $script:pilot5000ApprovalInput = Get-Pilot5000ApprovalInputIdentity $Entry
    if (-not (Test-ExplicitBudget $Manifest.resourceBudget) -or
        [long]$Manifest.resourceBudget.maxUE -lt 5000) {
        Stop-BlockedStage 'pilot-fixed-count-exceeds-budget'
    }
    if ($null -eq $Entry.configuration -or
        $null -eq $Entry.configuration.PSObject.Properties['pilot5000ApprovalFile'] -or
        [string]::IsNullOrWhiteSpace([string]$Entry.configuration.pilot5000ApprovalFile)) {
        Stop-BlockedStage 'pilot-5000-professor-approval-required'
    }
    $relativePath = ([string]$Entry.configuration.pilot5000ApprovalFile).Replace('\', '/')
    try { $approvalPath = Resolve-PackageFile $relativePath -MustExist }
    catch { Stop-BlockedStage 'pilot-5000-professor-approval-required' }
    try { $approval = ConvertFrom-JsonWithoutDateCoercion (Get-Content -LiteralPath $approvalPath -Raw) }
    catch { Stop-BlockedStage 'pilot-5000-professor-approval-required' }
    Assert-ExactProperties $approval @('schemaVersion','decision','authority','reviewer','reviewedAtUtc','scopeDigest','recordReference') 'pilot-5000 approval'
    $reviewedAt = [DateTimeOffset]::MinValue
    $validDate = [DateTimeOffset]::TryParse(
        [string]$approval.reviewedAtUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$reviewedAt)
    if ([int]$approval.schemaVersion -ne 1 -or
        [string]$approval.decision -cne 'approved' -or
        [string]$approval.authority -cne 'professor' -or
        [string]::IsNullOrWhiteSpace([string]$approval.reviewer) -or
        [string]::IsNullOrWhiteSpace([string]$approval.recordReference) -or
        [string]$approval.recordReference -match '[\r\n]' -or
        [string]$approval.reviewedAtUtc -notmatch 'Z$' -or
        -not $validDate -or $reviewedAt.Offset -ne [TimeSpan]::Zero -or
        $reviewedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) {
        Stop-BlockedStage 'pilot-5000-professor-approval-required'
    }
    $expectedScope = Get-Pilot5000ScopeDigest $Manifest
    if ([string]$expectedScope -notmatch '^[A-Fa-f0-9]{64}$' -or
        [string]$approval.scopeDigest -cne [string]$expectedScope) {
        Stop-BlockedStage 'pilot-5000-approval-scope-mismatch'
    }
    $script:pilot5000ApprovalInput = Get-Pilot5000ApprovalInputIdentity $Entry
}

function ConvertTo-ComparisonInteger($Value, [long]$Minimum, [long]$Maximum) {
    [double]$parsed = 0
    $style = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse([string]$Value, $style, $culture, [ref]$parsed) -or
        [double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or
        $parsed -ne [math]::Floor($parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        return $null
    }
    return [long]$parsed
}

function Assert-SharedScenarioIdentity($Configuration) {
    if ($null -eq $Configuration -or
        $null -eq $Configuration.PSObject.Properties['scenarioMatrix'] -or
        $null -eq $Configuration.PSObject.Properties['comparisonOptions']) {
        Stop-BlockedStage 'comparison-scenario-identity-required'
    }
    $options = $Configuration.comparisonOptions
    foreach ($name in @('counts','burstDurations','methods','realizationIds')) {
        if ($null -eq $options.PSObject.Properties[$name]) {
            Stop-BlockedStage 'comparison-scenario-identity-required'
        }
    }
    $counts = @()
    foreach ($value in @($options.counts)) {
        $integer = ConvertTo-ComparisonInteger $value 1 65535
        if ($null -eq $integer) { Stop-BlockedStage 'comparison-scenario-options-mismatch' }
        $counts += $integer
    }
    $burstDurations = @()
    foreach ($value in @($options.burstDurations)) {
        $integer = ConvertTo-ComparisonInteger $value 1 16777215
        if ($null -eq $integer) { Stop-BlockedStage 'comparison-scenario-options-mismatch' }
        $burstDurations += $integer
    }
    $realizationIds = @()
    foreach ($value in @($options.realizationIds)) {
        $integer = ConvertTo-ComparisonInteger $value 0 4095
        if ($null -eq $integer) { Stop-BlockedStage 'comparison-scenario-options-mismatch' }
        $realizationIds += $integer
    }
    if ($counts.Count -eq 0 -or $burstDurations.Count -eq 0 -or $realizationIds.Count -eq 0 -or
        (@($counts | Select-Object -Unique).Count -ne $counts.Count) -or
        (@($burstDurations | Select-Object -Unique).Count -ne $burstDurations.Count) -or
        (@($realizationIds | Select-Object -Unique).Count -ne $realizationIds.Count)) {
        Stop-BlockedStage 'comparison-scenario-options-mismatch'
    }
    $methods = @($options.methods | ForEach-Object { [string]$_ })
    $supportedMethods = @('Static','Adaptive-P','Adaptive-RA/DT')
    if ($methods.Count -lt 2 -or @($methods | Select-Object -Unique).Count -ne $methods.Count -or
        @($methods | Where-Object { $supportedMethods -cnotcontains $_ }).Count -gt 0) {
        Stop-BlockedStage 'comparison-scenario-options-mismatch'
    }

    $durationTicks = [long]5000
    if ($null -ne $options.PSObject.Properties['config']) {
        if ($null -eq $options.config -or
            $null -eq $options.config.PSObject.Properties['simulation'] -or
            $null -eq $options.config.simulation.PSObject.Properties['durationTicks']) {
            Stop-BlockedStage 'comparison-scenario-options-mismatch'
        }
        $durationTicks = ConvertTo-ComparisonInteger $options.config.simulation.durationTicks 1 16777215
        if ($null -eq $durationTicks) { Stop-BlockedStage 'comparison-scenario-options-mismatch' }
    }

    $expected = @{}
    foreach ($count in $counts) {
        foreach ($burst in $burstDurations) {
            foreach ($realizationId in $realizationIds) {
                foreach ($method in $methods) {
                    $key = [string]::Format([Globalization.CultureInfo]::InvariantCulture,
                        '{0}|{1}|{2}|{3}|{4}', $count, $burst, $durationTicks, $realizationId, $method)
                    $expected[$key] = $true
                }
            }
        }
    }

    $rows = @($Configuration.scenarioMatrix)
    if ($rows.Count -lt 2 -or $rows.Count -ne $expected.Count) {
        Stop-BlockedStage 'comparison-scenario-options-mismatch'
    }
    $seen = @{}
    $groups = @{}
    foreach ($row in $rows) {
        foreach ($name in @('method','numUE','durationTicks','burstDurationTicks','realizationId','scenarioIdentity')) {
            if ($null -eq $row.PSObject.Properties[$name]) { Stop-BlockedStage 'comparison-scenario-identity-required' }
        }
        $method = [string]$row.method
        $identity = [string]$row.scenarioIdentity
        $numUE = ConvertTo-ComparisonInteger $row.numUE 1 65535
        $rowDuration = ConvertTo-ComparisonInteger $row.durationTicks 1 16777215
        $burst = ConvertTo-ComparisonInteger $row.burstDurationTicks 1 16777215
        $realizationId = ConvertTo-ComparisonInteger $row.realizationId 0 4095
        if ($null -eq $numUE -or $null -eq $rowDuration -or $null -eq $burst -or $null -eq $realizationId) {
            Stop-BlockedStage 'comparison-scenario-options-mismatch'
        }
        $key = [string]::Format([Globalization.CultureInfo]::InvariantCulture,
            '{0}|{1}|{2}|{3}', $numUE, $burst, $rowDuration, $realizationId)
        $methodKey = $key + '|' + $method
        if ([string]::IsNullOrWhiteSpace($method) -or [string]::IsNullOrWhiteSpace($identity) -or
            $seen.ContainsKey($methodKey)) {
            Stop-BlockedStage 'scenario-identity-mismatch'
        }
        if (-not $expected.ContainsKey($methodKey)) { Stop-BlockedStage 'comparison-scenario-options-mismatch' }
        $seen[$methodKey] = $true
        if (-not $groups.ContainsKey($key)) { $groups[$key] = [ordered]@{ identity = $identity; methods = @{} } }
        if ([string]$groups[$key].identity -cne $identity) { Stop-BlockedStage 'scenario-identity-mismatch' }
        $groups[$key].methods[$method] = $true
    }
    if ($seen.Count -ne $expected.Count) { Stop-BlockedStage 'comparison-scenario-options-mismatch' }
    foreach ($key in $groups.Keys) {
        if ($groups[$key].methods.Count -lt 2) { Stop-BlockedStage 'scenario-identity-mismatch' }
    }
}

function ConvertTo-MatlabLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-WindowsArgument([string]$Value) {
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

$requestedModeCount = 0
if ($Inspect.IsPresent) { $requestedModeCount++ }
if ($Execute.IsPresent) { $requestedModeCount++ }
if ($RecoverInterrupted.IsPresent) { $requestedModeCount++ }
if ($requestedModeCount -gt 1) {
    throw 'Choose only one of inspect, execute, or interrupted-recovery mode.'
}
if (-not [IO.Path]::IsPathRooted($PackageFolder)) {
    throw 'PackageFolder must be an absolute path.'
}
$packageRoot = (Resolve-Path -LiteralPath $PackageFolder -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
    throw 'PackageFolder must be an existing folder.'
}
$manifestPath = Join-Path $packageRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'The package manifest is missing.'
}
$manifest = ConvertFrom-JsonWithoutDateCoercion (Get-Content -LiteralPath $manifestPath -Raw)
if ($null -eq $manifest.schemaVersion -or [int]$manifest.schemaVersion -ne 1 -or
    [string]::IsNullOrWhiteSpace([string]$manifest.status)) {
    throw 'The package manifest is invalid.'
}

# Inspection is deliberately read-only. The external state ledger is only
# initialized after an explicit Execute request has passed its stage gates.
if (-not $Execute -and -not $RecoverInterrupted) {
    Write-Output "EXTERNAL_STAGE_INSPECT=$Stage"
    Write-Output "EXTERNAL_STAGE_STATUS=$($manifest.status)"
    Write-Output "EXTERNAL_STAGE_COMMAND=matlab -batch report=runExternalStage(pwd,'$Stage');"
    if ($Stage -eq 'pilot' -and (Test-ExplicitBudget $manifest.resourceBudget)) {
        if ([long]$manifest.resourceBudget.maxUE -ge 5000) {
            $pilotScopeDigest = Get-Pilot5000ScopeDigest $manifest
            if (-not [string]::IsNullOrWhiteSpace([string]$pilotScopeDigest)) {
                Write-Output "EXTERNAL_STAGE_PILOT5000_SCOPE_DIGEST=$pilotScopeDigest"
            }
        }
        else {
            Write-Output 'EXTERNAL_STAGE_PILOT5000_BUDGET_STATUS=insufficient'
        }
    }
    $inspectStatePath = Join-Path $packageRoot 'stages.json'
    if (Test-Path -LiteralPath $inspectStatePath -PathType Leaf) {
        try {
            $inspectState = ConvertFrom-JsonWithoutDateCoercion (Get-Content -LiteralPath $inspectStatePath -Raw)
            $inspectEntry = @($inspectState.stages | Where-Object { [string]$_.name -ceq $Stage })
            if ($inspectEntry.Count -eq 1) { Write-Output "EXTERNAL_STAGE_STATE=$($inspectEntry[0].status)" }
        }
        catch { Write-Output 'EXTERNAL_STAGE_STATE=invalid' }
    }
    return
}

if ($Execute -and $ExecutionProfile -ne 'external-machine') {
    Stop-BlockedStage 'external-profile-required'
}
if ($Execute -and -not (Test-ExplicitBudget $manifest.resourceBudget)) {
    Stop-BlockedStage 'budget-required'
}

$statePath = Join-Path $packageRoot 'stages.json'
$stageState = Read-ValidatedStageState $statePath $manifest
Test-PackageSourceIntegrity $manifest
$selectedStage = Find-Stage $stageState $Stage
if ($RecoverInterrupted) {
    if ([string]$selectedStage.status -cne 'running') {
        Stop-BlockedStage 'stage-not-interrupted'
    }
    $runningStages = @($stageState.stages | Where-Object { [string]$_.status -ceq 'running' })
    if ($runningStages.Count -ne 1 -or [string]$runningStages[0].name -cne $Stage) {
        Stop-BlockedStage 'interrupted-stage-selection-ambiguous'
    }
    if ($null -eq $selectedStage.worker) {
        Stop-BlockedStage 'interrupted-worker-identity-required'
    }
    Assert-ExactProperties $selectedStage.worker @('ownerProcessId','ownerStartedAtUtc','ownedProcesses') 'interrupted worker'
    if ([int]$selectedStage.worker.ownerProcessId -le 0 -or
        -not (Test-ValidWorkerTimestamp ([string]$selectedStage.worker.ownerStartedAtUtc)) -or
        $null -eq $selectedStage.worker.ownedProcesses) {
        Stop-BlockedStage 'interrupted-worker-identity-required'
    }
    foreach ($processRecord in @($selectedStage.worker.ownedProcesses)) {
        Assert-ExactProperties $processRecord @('processId','startedAtUtc') 'interrupted process'
        if ([int]$processRecord.processId -le 0 -or
            -not (Test-ValidWorkerTimestamp ([string]$processRecord.startedAtUtc))) {
            Stop-BlockedStage 'interrupted-worker-identity-required'
        }
    }
    $workerLiveness = Get-WorkerLiveness $selectedStage.worker
    if ($workerLiveness -ceq 'alive') { Stop-BlockedStage 'worker-active' }
    if ($workerLiveness -ceq 'unknown') { Stop-BlockedStage 'interrupted-worker-identity-required' }
    $recoveryRegistryDigest = Get-CurrentRegistryDigest $manifest
    if ($recoveryRegistryDigest -cne [string]$stageState.registryDigest -or
        $recoveryRegistryDigest -cne [string]$selectedStage.registryInputDigest) {
        Stop-BlockedStage 'interrupted-registry-reconciliation-required'
    }
    $selectedStage.status = 'failed'
    $selectedStage.worker = $null
    Save-StageState $stageState $statePath
    Write-Output "EXTERNAL_STAGE_INTERRUPTED_RECONCILED=$Stage"
    Write-Output 'EXTERNAL_STAGE_RETRY=review the preserved attempt folder, then use a separate -Execute call'
    return
}
Assert-NoActiveOrInterruptedStage $stageState
$actualRegistryDigest = Get-CurrentRegistryDigest $manifest
if ($actualRegistryDigest -cne [string]$stageState.registryDigest) {
    if (-not (Test-AuthorizedStage2RegistryAdvance $Stage $actualRegistryDigest)) {
        Stop-BlockedStage 'registry-hash-mismatch'
    }
    $stageState.registryDigest = $actualRegistryDigest
    Save-StageState $stageState $statePath
}
foreach ($dependencyName in @($selectedStage.dependencies)) {
    $dependency = Find-Stage $stageState ([string]$dependencyName)
    Assert-DependencyComplete $dependency
}

if ($Stage -eq 'admit' -and [string]$selectedStage.status -cne 'completed') {
    $relativeReviewPath = Get-AdmissionReviewPackagePath $ReviewFile
    if ([string]::IsNullOrWhiteSpace($relativeReviewPath)) { Stop-BlockedStage 'review-required' }
    $selectedStage.configuration | Add-Member -NotePropertyName 'reviewFile' -NotePropertyValue $relativeReviewPath -Force
    $ReviewFile = Resolve-PackageFile $relativeReviewPath -MustExist
}
Assert-HumanGateDependenciesCurrent $selectedStage $manifest $stageState

$additionalStageInputs = @()
$pilotApprovalInputBeforeValidation = ''
if ($Stage -eq 'pilot') {
    $pilotApprovalInputBeforeValidation = Get-Pilot5000ApprovalInputIdentity $selectedStage
    $script:pilot5000ApprovalInput = $pilotApprovalInputBeforeValidation
    $additionalStageInputs += $pilotApprovalInputBeforeValidation
}
$admissionReviewInputBeforeValidation = ''
if ($Stage -eq 'admit') {
    $admissionReviewInputBeforeValidation = Get-AdmissionReviewInputIdentity $ReviewFile
    $additionalStageInputs += $admissionReviewInputBeforeValidation
}
if ([string]$selectedStage.status -ceq 'completed' -and $Stage -in @('pilot','admit')) {
    $identityInputDigest = Get-StageInputDigest $selectedStage $manifest $stageState $additionalStageInputs
    $identityReport = Read-CompleteStageReport $selectedStage
    if ([string]$selectedStage.inputDigest -cne $identityInputDigest -or $null -eq $identityReport) {
        $selectedStage.status = 'stale'
        Save-StageState $stageState $statePath
        Write-Output "EXTERNAL_STAGE_STALE=$Stage"
        throw 'Completed stage inputs or outputs changed; inspect the new stage state before starting a fresh output.'
    }
}

if ($Stage -in @('pilot','data','compare') -and
    [string]$manifest.resourceStatus -notin @('target-reviewed','measured-and-target-reviewed')) {
    Stop-BlockedStage 'resource-budget-review-required'
}

if ($Stage -eq 'pilot') {
    Test-ExplicitPilot5000Approval $selectedStage $manifest
    if ([string]$script:pilot5000ApprovalInput -cne $pilotApprovalInputBeforeValidation) {
        Stop-BlockedStage 'stage-input-changed-during-validation'
    }
}

if ($Stage -in @('data','compare')) {
    $pilot = Find-Stage $stageState 'pilot'
    $pilotReport = Read-CompleteStageReport $pilot
    if ($null -eq $pilotReport -or $null -eq $pilotReport.resourceEvidence -or
        [string]$pilotReport.resourceEvidence.status -cne 'measured' -or
        -not (Test-ExplicitBudget $pilotReport.resourceEvidence)) {
        Stop-BlockedStage 'measured-resource-evidence-required'
    }
    if (-not (Test-MeasuredResourceBudget $pilotReport.resourceEvidence $manifest.resourceBudget)) {
        Stop-BlockedStage 'measured-resource-budget-exceeded'
    }
}
if ($Stage -eq 'admit') {
    Test-ExplicitAdmission $ReviewFile $manifest
    if ((Get-AdmissionReviewInputIdentity $ReviewFile) -cne $admissionReviewInputBeforeValidation) {
        Stop-BlockedStage 'stage-input-changed-during-validation'
    }
}
if ($Stage -eq 'compare') {
    $admitReport = Read-CompleteStageReport (Find-Stage $stageState 'admit')
    if ($null -eq $admitReport -or [string]$admitReport.modelAcceptanceStatus -cne 'accepted') {
        Stop-BlockedStage 'scientific-model-acceptance-required'
    }
    Assert-SharedScenarioIdentity $selectedStage.configuration
}

$currentInputDigest = Get-StageInputDigest $selectedStage $manifest $stageState $additionalStageInputs
if ([string]$selectedStage.status -cne 'completed') {
    $selectedStage.registryInputDigest = [string]$stageState.registryDigest
}
if ($script:stageInputContractChanged -or [string]$selectedStage.status -ceq 'stale') {
    Save-StageState $stageState $statePath
    if ($script:stageInputContractChanged) { Write-Output "EXTERNAL_STAGE_INPUTS_REFRESHED=$Stage" }
}
if ([string]$selectedStage.status -ceq 'completed') {
    $completedReport = Read-CompleteStageReport $selectedStage
    if ([string]$selectedStage.inputDigest -ceq $currentInputDigest -and $null -ne $completedReport) {
        Write-Output "EXTERNAL_STAGE_ALREADY_COMPLETE=$Stage"
        return
    }
    $selectedStage.status = 'stale'
    Save-StageState $stageState $statePath
    Write-Output "EXTERNAL_STAGE_STALE=$Stage"
    throw 'Completed stage inputs or outputs changed; inspect the new stage state before starting a fresh output.'
}

$supervisorPath = Resolve-PackageFile 'project/verification/local/InvokeBoundedProcess.ps1' -MustExist
. $supervisorPath
if (-not (Get-Command Invoke-BoundedProcess -ErrorAction SilentlyContinue)) {
    Stop-BlockedStage 'process-supervisor-invalid'
}
$attemptFolder = Join-Path $packageRoot ('stage-results\' + $Stage + '\' + $currentInputDigest)
if (Test-Path -LiteralPath $attemptFolder) {
    $attemptFolder = $attemptFolder + '-' + [guid]::NewGuid().ToString('N')
}
$null = New-Item -ItemType Directory -Path $attemptFolder -Force
$processFolder = Join-Path $attemptFolder 'process'
$reportPath = Join-Path $attemptFolder 'stage-report.json'
$packagePrefix = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$relativeReportPath = $reportPath.Substring($packagePrefix.Length).Replace('\','/')
$owner = Get-Process -Id $PID -ErrorAction Stop
$selectedStage.status = 'running'
$selectedStage.inputDigest = $currentInputDigest
$selectedStage.reportPath = $relativeReportPath
$selectedStage.outputDigest = ''
$selectedStage.outputs = @()
$selectedStage.worker = [ordered]@{
    ownerProcessId = $PID
    ownerStartedAtUtc = $owner.StartTime.ToUniversalTime().ToString('o')
    ownedProcesses = @()
}
Save-StageState $stageState $statePath

$projectPath = Resolve-PackageFile 'project'
$reviewFullPath = ''
if (-not [string]::IsNullOrWhiteSpace($ReviewFile)) {
    $reviewFullPath = [IO.Path]::GetFullPath($ReviewFile)
    $packagePrefixForReview = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $reviewFullPath.StartsWith($packagePrefixForReview, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-BlockedStage 'review-required'
    }
}
$matlabCode = "cd($(ConvertTo-MatlabLiteral $projectPath)); addpath('experiments'); addpath('verification/external'); report=runExternalStage($(ConvertTo-MatlabLiteral $packageRoot),$(ConvertTo-MatlabLiteral $Stage),$(ConvertTo-MatlabLiteral $attemptFolder),$(ConvertTo-MatlabLiteral $currentInputDigest),$(ConvertTo-MatlabLiteral $reviewFullPath));"
$oldReportEnv = $env:NBIOT_EXTERNAL_STAGE_REPORT_PATH
$oldNameEnv = $env:NBIOT_EXTERNAL_STAGE_NAME
$oldDigestEnv = $env:NBIOT_EXTERNAL_STAGE_INPUT_DIGEST
$oldProfileEnv = $env:NBIOT_EXTERNAL_STAGE_PROFILE
$oldRegistryEnv = $env:NBIOT_EXTERNAL_STAGE_REGISTRY_PATH
$env:NBIOT_EXTERNAL_STAGE_REPORT_PATH = $reportPath
$env:NBIOT_EXTERNAL_STAGE_NAME = $Stage
$env:NBIOT_EXTERNAL_STAGE_INPUT_DIGEST = $currentInputDigest
$env:NBIOT_EXTERNAL_STAGE_PROFILE = $ExecutionProfile
$env:NBIOT_EXTERNAL_STAGE_REGISTRY_PATH = Resolve-PackageFile ([string]$manifest.registry.packagePath) -MustExist
$resourceSample = [pscustomobject]@{
    peakWorkingSetBytes = [int64]0
    peakProcessCount = 0
    processRunnerElapsedSeconds = 0.0
}
$saveStageStateAction = [scriptblock]::Create((Get-Command Save-StageState -ErrorAction Stop).Definition)
$sampleCallback = {
    param($ProcessIds)
    $records = @()
    [int64]$workingSetBytes = 0
    $processCount = @($ProcessIds).Count
    if ($processCount -gt [int]$manifest.resourceBudget.maxProcesses) {
        throw [InvalidOperationException]::new('nbiot:externalStage:ProcessBudgetExceeded')
    }
    if ($processCount -gt $resourceSample.peakProcessCount) {
        $resourceSample.peakProcessCount = $processCount
    }
    foreach ($processId in @($ProcessIds)) {
        try {
            $process = Get-Process -Id ([int]$processId) -ErrorAction Stop
            $records += [ordered]@{ processId = [int]$processId; startedAtUtc = $process.StartTime.ToUniversalTime().ToString('o') }
            $workingSetBytes += [int64]$process.WorkingSet64
        }
        catch { }
    }
    if ($Stage -eq 'pilot' -and $workingSetBytes -gt $resourceSample.peakWorkingSetBytes) {
        $resourceSample.peakWorkingSetBytes = $workingSetBytes
    }
    $previous = @($selectedStage.worker.ownedProcesses)
    $same = $previous.Count -eq $records.Count
    if ($same) {
        for ($index = 0; $index -lt $records.Count; $index++) {
            if ([int]$previous[$index].processId -ne [int]$records[$index].processId -or
                [string]$previous[$index].startedAtUtc -cne [string]$records[$index].startedAtUtc) {
                $same = $false
                break
            }
        }
    }
    if ($same) { return }
    $selectedStage.worker.ownedProcesses = $records
    & $saveStageStateAction $stageState $statePath
}.GetNewClosure()
try {
    $processResult = Invoke-BoundedProcess -Executable 'matlab.exe' `
        -Arguments ('-batch ' + (ConvertTo-WindowsArgument $matlabCode)) `
        -WorkingDirectory $projectPath -OutputFolder $processFolder `
        -TimeoutSeconds ([double]$manifest.resourceBudget.maxSuiteSeconds) -OnSample $sampleCallback
    if ($null -ne $processResult.PSObject.Properties['elapsedSeconds']) {
        $resourceSample.processRunnerElapsedSeconds = [double]$processResult.elapsedSeconds
    }
}
catch {
    $processFailure = $_.Exception
    $selectedStage.status = 'failed'
    $selectedStage.worker = $null
    Refresh-RegistryDigest $stageState $manifest
    Save-StageState $stageState $statePath
    if ([string]$processFailure.Message -ceq 'nbiot:externalStage:ProcessBudgetExceeded') {
        Stop-BlockedStage 'process-budget-exceeded'
    }
    Stop-BlockedStage 'stage-process-failed'
}
finally {
    if ($null -eq $oldReportEnv) { Remove-Item Env:NBIOT_EXTERNAL_STAGE_REPORT_PATH -ErrorAction SilentlyContinue } else { $env:NBIOT_EXTERNAL_STAGE_REPORT_PATH = $oldReportEnv }
    if ($null -eq $oldNameEnv) { Remove-Item Env:NBIOT_EXTERNAL_STAGE_NAME -ErrorAction SilentlyContinue } else { $env:NBIOT_EXTERNAL_STAGE_NAME = $oldNameEnv }
    if ($null -eq $oldDigestEnv) { Remove-Item Env:NBIOT_EXTERNAL_STAGE_INPUT_DIGEST -ErrorAction SilentlyContinue } else { $env:NBIOT_EXTERNAL_STAGE_INPUT_DIGEST = $oldDigestEnv }
    if ($null -eq $oldProfileEnv) { Remove-Item Env:NBIOT_EXTERNAL_STAGE_PROFILE -ErrorAction SilentlyContinue } else { $env:NBIOT_EXTERNAL_STAGE_PROFILE = $oldProfileEnv }
    if ($null -eq $oldRegistryEnv) { Remove-Item Env:NBIOT_EXTERNAL_STAGE_REGISTRY_PATH -ErrorAction SilentlyContinue } else { $env:NBIOT_EXTERNAL_STAGE_REGISTRY_PATH = $oldRegistryEnv }
}

if ($null -eq $processResult -or [string]$processResult.status -cne 'completed' -or [int]$processResult.exitCode -ne 0) {
    $selectedStage.status = 'failed'
    $selectedStage.worker = $null
    Refresh-RegistryDigest $stageState $manifest
    Save-StageState $stageState $statePath
    Stop-BlockedStage 'stage-process-failed'
}
if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    $selectedStage.status = 'failed'
    $selectedStage.worker = $null
    Refresh-RegistryDigest $stageState $manifest
    Save-StageState $stageState $statePath
    Stop-BlockedStage 'completion-marker-required'
}
try { $stageReport = ConvertFrom-JsonWithoutDateCoercion (Get-Content -LiteralPath $reportPath -Raw) }
catch {
    $selectedStage.status = 'failed'
    $selectedStage.worker = $null
    Refresh-RegistryDigest $stageState $manifest
    Save-StageState $stageState $statePath
    Stop-BlockedStage 'completion-marker-invalid'
}
if ([int]$stageReport.schemaVersion -ne 1 -or [string]$stageReport.stage -cne $Stage -or
    [string]$stageReport.inputDigest -cne $currentInputDigest -or
    [string]$stageReport.status -notin @('complete','awaiting-review')) {
    $selectedStage.status = 'failed'
    $selectedStage.worker = $null
    Refresh-RegistryDigest $stageState $manifest
    Save-StageState $stageState $statePath
    Stop-BlockedStage 'completion-marker-invalid'
}
if ([string]$stageReport.status -ceq 'awaiting-review') {
    $selectedStage.status = 'awaiting-review'
    $selectedStage.worker = $null
    Refresh-RegistryDigest $stageState $manifest
    Save-StageState $stageState $statePath
    Write-Output "EXTERNAL_STAGE_AWAITING_REVIEW=$Stage"
    return
}
if ($Stage -eq 'pilot' -and $null -ne $stageReport.resourceEvidence) {
    $stageReport.resourceEvidence | Add-Member -NotePropertyName 'sampledPeakWorkingSetBytes' `
        -NotePropertyValue ([int64]$resourceSample.peakWorkingSetBytes) -Force
    $stageReport.resourceEvidence | Add-Member -NotePropertyName 'sampledPeakProcessCount' `
        -NotePropertyValue ([int]$resourceSample.peakProcessCount) -Force
    $stageReport.resourceEvidence | Add-Member -NotePropertyName 'processRunnerElapsedSeconds' `
        -NotePropertyValue ([double]$resourceSample.processRunnerElapsedSeconds) -Force
    $stageReport | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
if ($Stage -eq 'pilot' -and
    ($null -eq $stageReport.resourceEvidence -or
        [string]$stageReport.resourceEvidence.status -cne 'measured' -or
        -not (Test-MeasuredResourceBudget $stageReport.resourceEvidence $manifest.resourceBudget))) {
    $selectedStage.status = 'failed'
    $selectedStage.worker = $null
    Refresh-RegistryDigest $stageState $manifest
    Save-StageState $stageState $statePath
    Stop-BlockedStage 'measured-resource-budget-exceeded'
}
foreach ($output in @($stageReport.outputFiles)) {
    $outputPath = Resolve-PackageFile ((Split-Path -Parent $relativeReportPath) + '/' + [string]$output.path) -MustExist
    if ([string]$output.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-Sha256 $outputPath) -cne [string]$output.sha256) {
        $selectedStage.status = 'failed'
        $selectedStage.worker = $null
        Refresh-RegistryDigest $stageState $manifest
        Save-StageState $stageState $statePath
        Stop-BlockedStage 'output-hash-mismatch'
    }
}
$selectedStage.status = 'completed'
$selectedStage.outputDigest = Get-Sha256 $reportPath
$selectedStage.outputs = @([ordered]@{ path = $relativeReportPath; sha256 = $selectedStage.outputDigest })
$selectedStage.worker = $null
Refresh-RegistryDigest $stageState $manifest
Save-StageState $stageState $statePath
Write-Output "EXTERNAL_STAGE_COMPLETE=$Stage"
