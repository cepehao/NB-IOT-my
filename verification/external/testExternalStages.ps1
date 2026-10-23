$ErrorActionPreference = 'Stop'

function Write-TestFailure([string]$Message) {
    Write-Output "EXTERNAL_STAGE_TEST_FAIL=$Message"
}

function Write-TestStageState([string]$Folder, $Manifest) {
    $dependencies = [ordered]@{
        validate = @()
        pilot = @('validate')
        data = @('pilot')
        assemble = @('data')
        train = @('assemble')
        freeze = @('train')
        evaluate = @('freeze')
        admit = @('evaluate')
        compare = @('admit')
        summarize = @('compare')
    }
    $stages = @(
        foreach ($name in $dependencies.Keys) {
            [ordered]@{
                name = $name
                dependencies = @($dependencies[$name])
                command = [ordered]@{
                    executable = 'matlab'
                    arguments = @('-batch', "report=runExternalStage(pwd,'$name');")
                }
                inputs = @([ordered]@{
                    path = 'manifest.json'
                    sha256 = (Get-FileHash -LiteralPath (Join-Path $Folder 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
                })
                outputs = @()
                executionBudget = $Manifest.resourceBudget
                requiredDecision = $(switch ($name) {
                    'validate' { 'stage-2-technical-review' }
                    'pilot' { 'professor-approval-for-5000-UE-load-pilot' }
                    'admit' { 'model-acceptance-review' }
                    default { '' }
                })
                configuration = $(if ($name -eq 'pilot') {
                    [ordered]@{ pilot5000ApprovalFile = 'reviews/pilot-5000-approval.json' }
                } else { [ordered]@{} })
                status = 'not-started'
                inputDigest = ''
                outputDigest = ''
                reportPath = ''
                registryInputDigest = ''
                worker = $null
            }
        }
    )
    $state = [ordered]@{
        schemaVersion = 1
        runId = 'fixture-run'
        packageDigest = [string]$Manifest.codeManifestSha256
        registryDigest = [string]$Manifest.registry.sha256
        updatedAtUtc = '2026-10-19T00:00:00Z'
        stages = $stages
    }
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Folder 'stages.json') -Encoding UTF8
}

function New-TestManifest([string]$Status = 'draft-needs-external-review', [string]$EvidenceKind = '') {
    return [ordered]@{
        schemaVersion = 1
        status = $Status
        readyForExecution = $false
        codeFiles = @()
        codeManifestSha256 = ('0' * 64)
        resourceBudget = @{
            targetMachine = 'fixture-machine'
            availableMemoryBytes = 1073741824
            maxUE = 1
            maxCaseSeconds = 30
            maxSuiteSeconds = 60
            maxProcesses = 1
        }
        resourceStatus = 'provided-but-requires-target-review'
        modelAcceptance = [ordered]@{ included = ($EvidenceKind -ne ''); status = 'candidate'; evidenceKind = $EvidenceKind }
    }
}

function Get-TestCodeManifestDigest($Entries) {
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 16 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Add-TestPackageInputs([string]$Folder, $Manifest) {
    $calibrationPath = Join-Path $Folder 'project\results\calibration.mat'
    $registryPath = Join-Path $Folder 'project\experiments\realizationRegistry.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $calibrationPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $registryPath) -Force | Out-Null
    [IO.File]::WriteAllText($calibrationPath, 'calibration fixture', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($registryPath, '{"schemaVersion":1,"assignments":[],"reservations":[]}', [Text.UTF8Encoding]::new($false))
    $Manifest.calibration = [ordered]@{ packagePath = 'project/results/calibration.mat'; sha256 = (Get-FileHash -LiteralPath $calibrationPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    $Manifest.registry = [ordered]@{ packagePath = 'project/experiments/realizationRegistry.json'; sha256 = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    $Manifest.codeManifestSha256 = Get-TestCodeManifestDigest $Manifest.codeFiles
    $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Folder 'manifest.json') -Encoding UTF8
}

function Set-TestStageComplete(
    [string]$Folder,
    [string]$Name,
    [string]$ResourceStatus = '',
    [string]$AcceptanceStatus = '',
    [double]$MaxMeasuredCaseSeconds = 10,
    [double]$MeasuredSuiteSeconds = 20,
    [double]$MaxMatlabMemoryAfterCaseBytes = 1048576,
    [double]$SampledPeakWorkingSetBytes = 1048576,
    [int]$SampledPeakProcessCount = 1) {
    $statePath = Join-Path $Folder 'stages.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $entry = @($state.stages | Where-Object { $_.name -eq $Name })[0]
    $inputDigest = ('a' * 64)
    $relativeFolder = 'stage-results/' + $Name
    $outputFolder = Join-Path $Folder ($relativeFolder -replace '/', '\')
    New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
    $report = [ordered]@{
        schemaVersion = 1
        stage = $Name
        status = 'complete'
        inputDigest = $inputDigest
        outputFiles = @()
    }
    if ($ResourceStatus -ne '') {
        $report.resourceEvidence = [ordered]@{
            status = $ResourceStatus
            targetMachine = 'fixture-machine'
            availableMemoryBytes = 1073741824
            maxUE = 1
            maxCaseSeconds = 30
            maxSuiteSeconds = 60
            maxProcesses = 1
            maxMatlabMemoryAfterCaseBytes = $MaxMatlabMemoryAfterCaseBytes
            sampledPeakWorkingSetBytes = $SampledPeakWorkingSetBytes
            sampledPeakProcessCount = $SampledPeakProcessCount
            maxMeasuredCaseSeconds = $MaxMeasuredCaseSeconds
            measuredSuiteSeconds = $MeasuredSuiteSeconds
            processRunnerElapsedSeconds = 20
        }
    }
    if ($AcceptanceStatus -ne '') {
        $report.modelAcceptanceStatus = $AcceptanceStatus
    }
    $reportPath = Join-Path $outputFolder 'stage-report.json'
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    $hash = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $entry.status = 'completed'
    $entry.inputDigest = $inputDigest
    $entry.reportPath = $relativeFolder + '/stage-report.json'
    $entry.outputDigest = $hash
    $entry.outputs = @([ordered]@{ path = $entry.reportPath; sha256 = $hash })
    $entry.registryInputDigest = [string]$state.registryDigest
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Write-TestSupervisor([string]$Folder) {
    $supervisor = Join-Path $Folder 'project\verification\local\InvokeBoundedProcess.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $supervisor) -Force | Out-Null
    @'
function Invoke-BoundedProcess {
    [CmdletBinding()]
    param([string]$Executable,[string]$Arguments,[string]$WorkingDirectory,[string]$OutputFolder,[double]$TimeoutSeconds,[scriptblock]$OnSample)
    if ($env:NBIOT_EXTERNAL_STAGE_STUB_MARKER) { Add-Content -LiteralPath $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER -Value 'called' }
    if ($env:NBIOT_EXTERNAL_STAGE_STUB_MUTATE_REGISTRY -eq '1') {
        Add-Content -LiteralPath $env:NBIOT_EXTERNAL_STAGE_REGISTRY_PATH -Value ' '
    }
    if ($env:NBIOT_EXTERNAL_STAGE_STUB_MODE -eq 'complete') {
        $report = [ordered]@{
            schemaVersion = 1
            stage = $env:NBIOT_EXTERNAL_STAGE_NAME
            status = 'complete'
            inputDigest = $env:NBIOT_EXTERNAL_STAGE_INPUT_DIGEST
            outputFiles = @()
        }
        if ($env:NBIOT_EXTERNAL_STAGE_NAME -eq 'pilot') {
            $manifestPath = Join-Path (Split-Path -Parent $WorkingDirectory) 'manifest.json'
            $budget = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).resourceBudget
            $report.resourceEvidence = [ordered]@{
                status = 'measured'
                targetMachine = [string]$budget.targetMachine
                availableMemoryBytes = [long]$budget.availableMemoryBytes
                maxUE = [long]$budget.maxUE
                maxCaseSeconds = [double]$budget.maxCaseSeconds
                maxSuiteSeconds = [double]$budget.maxSuiteSeconds
                maxProcesses = [int]$budget.maxProcesses
                maxMatlabMemoryAfterCaseBytes = 1048576
                sampledPeakWorkingSetBytes = 1048576
                sampledPeakProcessCount = 1
                maxMeasuredCaseSeconds = 10
                measuredSuiteSeconds = 20
                processRunnerElapsedSeconds = 20
            }
        }
        if ($env:NBIOT_EXTERNAL_STAGE_NAME -eq 'admit') {
            $report.modelAcceptanceStatus = 'accepted'
        }
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $env:NBIOT_EXTERNAL_STAGE_REPORT_PATH -Encoding UTF8
    }
    if ($null -ne $OnSample -and $env:NBIOT_EXTERNAL_STAGE_STUB_NO_SAMPLE -ne '1') {
        $sampledIds = [int[]]@($PID)
        if ($env:NBIOT_EXTERNAL_STAGE_STUB_PROCESS_COUNT -eq '2') { $sampledIds = [int[]]@($PID,2147483647) }
        & $OnSample $sampledIds
    }
    return [pscustomobject]@{ status = 'completed'; exitCode = 0; rootProcessId = 1; processIds = @(1); elapsedSeconds = 20 }
}
'@ | Set-Content -LiteralPath $supervisor -Encoding UTF8
}

function Set-TestPilotApproval([string]$Folder, [string]$Runner) {
    $inspectCapture = Join-Path $Folder 'pilot-approval-inspect.txt'
    & $Runner -PackageFolder $Folder -Stage pilot -Inspect *> $inspectCapture
    $scopeLine = Select-String -LiteralPath $inspectCapture -Pattern '^EXTERNAL_STAGE_PILOT5000_SCOPE_DIGEST=([A-Fa-f0-9]{64})$'
    if ($null -eq $scopeLine) { throw 'pilot inspect did not report a 5000 UE approval scope digest' }
    $scopeDigest = ($scopeLine.Line -split '=', 2)[1]
    $approvalPath = Join-Path $Folder 'reviews\pilot-5000-approval.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $approvalPath) -Force | Out-Null
    $approval = [ordered]@{
        schemaVersion = 1
        decision = 'approved'
        authority = 'professor'
        reviewer = 'Synthetic isolated test fixture'
        reviewedAtUtc = [DateTimeOffset]::UtcNow.ToString('ddd, dd MMM yyyy HH:mm:ss \Z', [Globalization.CultureInfo]::InvariantCulture)
        scopeDigest = $scopeDigest
        recordReference = 'Synthetic process-only fixture; not a real approval.'
    }
    $approval | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $approvalPath -Encoding UTF8
}

function Complete-TestPilotThroughRunner([string]$Folder, [string]$Runner, [string]$Marker, [string]$Capture) {
    Write-TestSupervisor $Folder
    Set-TestPilotApproval $Folder $Runner
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $Marker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MUTATE_REGISTRY = '0'
    $pilotFailed = $false
    try {
        & $Runner -PackageFolder $Folder -Stage pilot -ExecutionProfile external-machine -Execute *> $Capture
    }
    catch { $pilotFailed = $true }
    if ($pilotFailed -or -not (Select-String -LiteralPath $Capture -Pattern '^EXTERNAL_STAGE_COMPLETE=pilot$') -or
        -not (Test-Path -LiteralPath $Marker)) {
        throw ('the process-only approved pilot fixture did not complete: ' + (Get-Content -LiteralPath $Capture -Raw))
    }
}

function Set-TestPilotEvidence(
    [string]$Folder,
    [string]$Status = '',
    [double]$SampledPeakWorkingSetBytes = 0,
    [int]$SampledPeakProcessCount = 0,
    [double]$MaxMeasuredCaseSeconds = 0) {
    $statePath = Join-Path $Folder 'stages.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $entry = @($state.stages | Where-Object { $_.name -eq 'pilot' })[0]
    $reportPath = Join-Path $Folder ($entry.reportPath -replace '/', '\\')
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($Status -ne '') { $report.resourceEvidence.status = $Status }
    if ($SampledPeakWorkingSetBytes -gt 0) { $report.resourceEvidence.sampledPeakWorkingSetBytes = $SampledPeakWorkingSetBytes }
    if ($SampledPeakProcessCount -gt 0) { $report.resourceEvidence.sampledPeakProcessCount = $SampledPeakProcessCount }
    if ($MaxMeasuredCaseSeconds -gt 0) { $report.resourceEvidence.maxMeasuredCaseSeconds = $MaxMeasuredCaseSeconds }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    $hash = (Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $entry.outputDigest = $hash
    $entry.outputs = @([ordered]@{ path = [string]$entry.reportPath; sha256 = $hash })
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function New-TestAdmissionReview([string]$Path, [string]$Decision = 'accepted') {
    $review = [ordered]@{
        schemaVersion = 'model-acceptance-review-v1'
        decision = $Decision
        reviewer = 'fixture-reviewer'
        reviewedAtUtc = '2026-10-19T00:00:00Z'
        evidenceDigest = ('a' * 64)
        protocolSha256 = ('b' * 64)
        limitations = 'Process-only gate fixture.'
    }
    $review | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $review
}

function Complete-TestAdmissionThroughRunner([string]$Folder, [string]$Runner, [string]$Marker, [string]$Capture) {
    $reviewPath = Join-Path $Folder 'model-review.json'
    $null = New-TestAdmissionReview $reviewPath 'accepted'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $Marker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    & $Runner -PackageFolder $Folder -Stage admit -ReviewFile $reviewPath `
        -ExecutionProfile external-machine -Execute *> $Capture
    if (-not (Select-String -LiteralPath $Capture -Pattern '^EXTERNAL_STAGE_COMPLETE=admit$') -or
        -not (Test-Path -LiteralPath $Marker)) {
        throw 'the process-only accepted admission fixture did not complete'
    }
    return $reviewPath
}

function Set-TestComparisonScenario($State, [string]$StageName = 'compare') {
    $entry = @($State.stages | Where-Object { $_.name -eq $StageName })[0]
    $entry.configuration = [ordered]@{
        scenarioMatrix = @(
            [ordered]@{ method = 'Static'; numUE = 100; durationTicks = 5000; burstDurationTicks = 50; realizationId = 1800; scenarioIdentity = 'scenario-a' },
            [ordered]@{ method = 'Adaptive-P'; numUE = 100; durationTicks = 5000; burstDurationTicks = 50; realizationId = 1800; scenarioIdentity = 'scenario-a' }
        )
        comparisonOptions = [ordered]@{
            counts = @(100)
            burstDurations = @(50)
            methods = @('Static','Adaptive-P')
            realizationIds = @(1800)
            config = [ordered]@{ simulation = [ordered]@{ durationTicks = 5000 } }
        }
    }
}

$runner = Join-Path $PSScriptRoot 'runExternalStages.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    Write-TestFailure 'default-inspect:runner-missing'
    exit 1
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot ('nbiot-external-stage-' + [guid]::NewGuid().ToString('N'))))
$tempPrefix = $tempRoot + [IO.Path]::DirectorySeparatorChar
if (-not $testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The temporary test directory is outside the system temp folder.'
}
$packageFolder = Join-Path $testRoot 'portable package with spaces'
$binFolder = Join-Path $testRoot 'bin'
$stubMarker = Join-Path $testRoot 'matlab-called.marker'
$runnerCapture = Join-Path $testRoot 'runner-capture.txt'
$budgetPackageFolder = Join-Path $testRoot 'missing-budget-package'
$budgetMarker = Join-Path $testRoot 'missing-budget-stage-called.marker'
$budgetCapture = Join-Path $testRoot 'missing-budget-capture.txt'
$profilePackageFolder = Join-Path $testRoot 'missing-external-profile-package'
$profileMarker = Join-Path $testRoot 'missing-external-profile-stage-called.marker'
$profileCapture = Join-Path $testRoot 'missing-external-profile-capture.txt'
$dependencyPackageFolder = Join-Path $testRoot 'missing-dependency-package'
$dependencyMarker = Join-Path $testRoot 'missing-dependency-stage-called.marker'
$dependencyCapture = Join-Path $testRoot 'missing-dependency-capture.txt'
$resourcePackageFolder = Join-Path $testRoot 'missing-resource-evidence-package'
$resourceMarker = Join-Path $testRoot 'missing-resource-evidence-stage-called.marker'
$resourceCapture = Join-Path $testRoot 'missing-resource-evidence-capture.txt'
$overBudgetPackageFolder = Join-Path $testRoot 'over-budget-resource-evidence-package'
$overBudgetMarker = Join-Path $testRoot 'over-budget-resource-evidence-stage-called.marker'
$overBudgetCapture = Join-Path $testRoot 'over-budget-resource-evidence-capture.txt'
$overProcessEvidencePackageFolder = Join-Path $testRoot 'over-process-count-evidence-package'
$overProcessEvidenceMarker = Join-Path $testRoot 'over-process-count-evidence-stage-called.marker'
$overProcessEvidenceCapture = Join-Path $testRoot 'over-process-count-evidence-capture.txt'
$processBudgetPackageFolder = Join-Path $testRoot 'over-process-budget-package'
$processBudgetMarker = Join-Path $testRoot 'over-process-budget-stage-called.marker'
$processBudgetCapture = Join-Path $testRoot 'over-process-budget-capture.txt'
$missingSamplePackageFolder = Join-Path $testRoot 'missing-sampled-resource-package'
$missingSampleMarker = Join-Path $testRoot 'missing-sampled-resource-stage-called.marker'
$missingSampleCapture = Join-Path $testRoot 'missing-sampled-resource-capture.txt'
$reviewPackageFolder = Join-Path $testRoot 'missing-resource-review-package'
$reviewMarker = Join-Path $testRoot 'missing-resource-review-stage-called.marker'
$reviewCapture = Join-Path $testRoot 'missing-resource-review-capture.txt'
$workerPackageFolder = Join-Path $testRoot 'active-worker-package'
$workerMarker = Join-Path $testRoot 'active-worker-stage-called.marker'
$workerCapture = Join-Path $testRoot 'active-worker-capture.txt'
$interruptedPackageFolder = Join-Path $testRoot 'interrupted-stage-package'
$interruptedMarker = Join-Path $testRoot 'interrupted-stage-called.marker'
$interruptedCapture = Join-Path $testRoot 'interrupted-stage-capture.txt'
$fixturePackageFolder = Join-Path $testRoot 'fixture-admission-package'
$fixtureMarker = Join-Path $testRoot 'fixture-admission-stage-called.marker'
$fixtureCapture = Join-Path $testRoot 'fixture-admission-capture.txt'
$dispatchPackageFolder = Join-Path $testRoot 'dispatch-package'
$dispatchMarker = Join-Path $testRoot 'dispatch-call-count.txt'
$dispatchCapture = Join-Path $testRoot 'dispatch-capture.txt'
$originalPath = $env:PATH
$originalMarker = $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER
$originalMode = $env:NBIOT_EXTERNAL_STAGE_STUB_MODE
$originalMutateRegistry = $env:NBIOT_EXTERNAL_STAGE_STUB_MUTATE_REGISTRY
$originalNoSample = $env:NBIOT_EXTERNAL_STAGE_STUB_NO_SAMPLE
$originalProcessCount = $env:NBIOT_EXTERNAL_STAGE_STUB_PROCESS_COUNT
$failed = $null

try {
    New-Item -ItemType Directory -Path $packageFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $binFolder -Force | Out-Null
    $manifest = [ordered]@{
        schemaVersion = 1
        status = 'draft-needs-external-review'
        readyForExecution = $false
        codeFiles = @()
        codeManifestSha256 = ('0' * 64)
        resourceBudget = @{}
        resourceStatus = 'not-specified'
        modelAcceptance = [ordered]@{ included = $false; status = '' ; evidenceKind = '' }
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $packageFolder 'manifest.json') -Encoding UTF8
    @('@echo off', 'echo called>%NBIOT_EXTERNAL_STAGE_STUB_MARKER%', 'exit /b 0') |
        Set-Content -LiteralPath (Join-Path $binFolder 'matlab.cmd') -Encoding ASCII
    $env:PATH = $binFolder + [IO.Path]::PathSeparator + $originalPath
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $stubMarker

    & $runner -PackageFolder $packageFolder -Stage pilot *> $runnerCapture
    $runnerSucceeded = $?
    if (-not $runnerSucceeded) {
        throw 'default-inspect returned a failure status'
    }
    $inspectMarker = Select-String -LiteralPath $runnerCapture -Pattern '^EXTERNAL_STAGE_INSPECT=pilot$'
    if (-not $inspectMarker) {
        throw 'default-inspect did not report the requested stage in inspect mode'
    }
    if (Test-Path -LiteralPath $stubMarker) {
        throw 'default-inspect launched the MATLAB process stub'
    }
    if (Test-Path -LiteralPath (Join-Path $packageFolder 'stages.json')) {
        throw 'default-inspect modified the package stage state'
    }

    New-Item -ItemType Directory -Path $budgetPackageFolder -Force | Out-Null
    $budgetManifest = [ordered]@{
        schemaVersion = 1
        status = 'draft-needs-external-review'
        readyForExecution = $false
        codeFiles = @()
        codeManifestSha256 = ('0' * 64)
        resourceBudget = @{}
        resourceStatus = 'not-specified'
        modelAcceptance = [ordered]@{ included = $false; status = ''; evidenceKind = '' }
    }
    $budgetManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $budgetPackageFolder 'manifest.json') -Encoding UTF8
    $stage2StubFolder = Join-Path $budgetPackageFolder 'verification\completion\stage-2'
    New-Item -ItemType Directory -Path $stage2StubFolder -Force | Out-Null
    @("Write-Output 'STAGE2_STUB_CALLED'", 'exit 0') |
        Set-Content -LiteralPath (Join-Path $stage2StubFolder 'runStage2Physical.ps1') -Encoding UTF8
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $budgetMarker
    $budgetInvocationFailed = $false
    try {
        & $runner -PackageFolder $budgetPackageFolder -Stage validate `
            -ExecutionProfile external-machine -Execute *> $budgetCapture
    }
    catch { $budgetInvocationFailed = $true }
    $budgetBlocked = Select-String -LiteralPath $budgetCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=budget-required$'
    if (-not $budgetInvocationFailed -or -not $budgetBlocked) {
        throw 'validate execution without a resource budget did not report the expected blocked status'
    }
    if ((Test-Path -LiteralPath $budgetMarker) -or
        (Select-String -LiteralPath $budgetCapture -Pattern '^STAGE2_STUB_CALLED$')) {
        throw 'validate execution without a resource budget launched a stage process'
    }
    if (Test-Path -LiteralPath (Join-Path $budgetPackageFolder 'stages.json')) {
        throw 'a blocked stage initialized the package state file'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=missing-budget-blocks-before-launch'

    New-Item -ItemType Directory -Path $profilePackageFolder -Force | Out-Null
    $profileManifest = [ordered]@{
        schemaVersion = 1
        status = 'draft-needs-external-review'
        readyForExecution = $false
        codeFiles = @()
        codeManifestSha256 = ('0' * 64)
        resourceBudget = @{
            targetMachine = 'fixture-machine'
            maxUE = 1
            maxCaseSeconds = 30
            maxSuiteSeconds = 60
            maxProcesses = 1
        }
        resourceStatus = 'provided-but-requires-target-review'
        modelAcceptance = [ordered]@{ included = $false; status = ''; evidenceKind = '' }
    }
    $profileManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $profilePackageFolder 'manifest.json') -Encoding UTF8
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $profileMarker
    $profileInvocationFailed = $false
    try {
        & $runner -PackageFolder $profilePackageFolder -Stage validate -Execute *> $profileCapture
    }
    catch { $profileInvocationFailed = $true }
    $profileBlocked = Select-String -LiteralPath $profileCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=external-profile-required$'
    if (-not $profileInvocationFailed -or -not $profileBlocked) {
        throw 'validate execution without an explicit external-machine profile did not report the expected blocked status'
    }
    if (Test-Path -LiteralPath $profileMarker) {
        throw 'validate execution without an external-machine profile launched a stage process'
    }
    if (Test-Path -LiteralPath (Join-Path $profilePackageFolder 'stages.json')) {
        throw 'a stage blocked by the execution profile initialized the package state file'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=missing-external-profile-blocks-before-launch'

    New-Item -ItemType Directory -Path $dependencyPackageFolder -Force | Out-Null
    $dependencyManifest = [ordered]@{
        schemaVersion = 1
        status = 'draft-needs-external-review'
        readyForExecution = $false
        codeFiles = @()
        codeManifestSha256 = ('0' * 64)
        resourceBudget = @{
            targetMachine = 'fixture-machine'
            availableMemoryBytes = 1073741824
            maxUE = 1
            maxCaseSeconds = 30
            maxSuiteSeconds = 60
            maxProcesses = 1
        }
        resourceStatus = 'provided-but-requires-target-review'
        modelAcceptance = [ordered]@{ included = $false; status = ''; evidenceKind = '' }
    }
    Add-TestPackageInputs $dependencyPackageFolder $dependencyManifest
    Write-TestStageState $dependencyPackageFolder $dependencyManifest
    $dependencyState = Join-Path $dependencyPackageFolder 'stages.json'
    $dependencyStateHash = (Get-FileHash -LiteralPath $dependencyState -Algorithm SHA256).Hash
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $dependencyMarker
    $dependencyInvocationFailed = $false
    try {
        & $runner -PackageFolder $dependencyPackageFolder -Stage pilot `
            -ExecutionProfile external-machine -Execute *> $dependencyCapture
    }
    catch { $dependencyInvocationFailed = $true }
    $dependencyBlocked = Select-String -LiteralPath $dependencyCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=dependency-required$'
    if (-not $dependencyInvocationFailed -or -not $dependencyBlocked) {
        throw 'pilot without completed validate did not report the expected dependency block'
    }
    if (Test-Path -LiteralPath $dependencyMarker) {
        throw 'pilot without completed validate launched a stage process'
    }
    if ((Get-FileHash -LiteralPath $dependencyState -Algorithm SHA256).Hash -ne $dependencyStateHash) {
        throw 'a dependency-blocked stage changed stages.json'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=missing-dependency-blocks-before-launch'

    New-Item -ItemType Directory -Path $reviewPackageFolder -Force | Out-Null
    $reviewManifest = New-TestManifest
    Add-TestPackageInputs $reviewPackageFolder $reviewManifest
    Write-TestStageState $reviewPackageFolder $reviewManifest
    Set-TestStageComplete $reviewPackageFolder 'validate'
    Write-TestSupervisor $reviewPackageFolder
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $reviewMarker
    $reviewInvocationFailed = $false
    try {
        & $runner -PackageFolder $reviewPackageFolder -Stage pilot `
            -ExecutionProfile external-machine -Execute *> $reviewCapture
    }
    catch { $reviewInvocationFailed = $true }
    if (-not $reviewInvocationFailed -or
        -not (Select-String -LiteralPath $reviewCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=resource-budget-review-required$') -or
        (Test-Path -LiteralPath $reviewMarker)) {
        throw 'pilot without reviewed target resource budget was not blocked before launch'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=missing-resource-review-blocks-before-launch'

    New-Item -ItemType Directory -Path $resourcePackageFolder -Force | Out-Null
    $resourceManifest = New-TestManifest
    $resourceManifest.resourceBudget.maxUE = 5000
    $resourceManifest.resourceStatus = 'target-reviewed'
    Add-TestPackageInputs $resourcePackageFolder $resourceManifest
    Write-TestStageState $resourcePackageFolder $resourceManifest
    Set-TestStageComplete $resourcePackageFolder 'validate'
    Complete-TestPilotThroughRunner $resourcePackageFolder $runner `
        (Join-Path $testRoot 'resource-pilot-calls.txt') (Join-Path $testRoot 'resource-pilot-capture.txt')
    Set-TestPilotEvidence $resourcePackageFolder -Status 'not-measured'
    $resourceInvocationFailed = $false
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $resourceMarker
    try {
        & $runner -PackageFolder $resourcePackageFolder -Stage data `
            -ExecutionProfile external-machine -Execute *> $resourceCapture
    }
    catch { $resourceInvocationFailed = $true }
    if (-not $resourceInvocationFailed -or
        -not (Select-String -LiteralPath $resourceCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=measured-resource-evidence-required$')) {
        throw 'data without measured pilot resources did not report the expected resource gate'
    }
    if (Test-Path -LiteralPath $resourceMarker) { throw 'data without measured pilot resources launched a stage process' }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=missing-resource-evidence-blocks-before-launch'

    New-Item -ItemType Directory -Path $missingSamplePackageFolder -Force | Out-Null
    $missingSampleManifest = New-TestManifest
    $missingSampleManifest.resourceBudget.maxUE = 5000
    $missingSampleManifest.resourceStatus = 'target-reviewed'
    Add-TestPackageInputs $missingSamplePackageFolder $missingSampleManifest
    Write-TestStageState $missingSamplePackageFolder $missingSampleManifest
    Set-TestStageComplete $missingSamplePackageFolder 'validate'
    Write-TestSupervisor $missingSamplePackageFolder
    Set-TestPilotApproval $missingSamplePackageFolder $runner
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $missingSampleMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    $env:NBIOT_EXTERNAL_STAGE_STUB_NO_SAMPLE = '1'
    $missingSampleInvocationFailed = $false
    try {
        & $runner -PackageFolder $missingSamplePackageFolder -Stage pilot `
            -ExecutionProfile external-machine -Execute *> $missingSampleCapture
    }
    catch { $missingSampleInvocationFailed = $true }
    if (-not $missingSampleInvocationFailed -or
        -not (Select-String -LiteralPath $missingSampleCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=measured-resource-budget-exceeded$') -or
        -not (Test-Path -LiteralPath $missingSampleMarker)) {
        throw 'pilot without sampled process memory was not rejected after the bounded runner returned'
    }
    $env:NBIOT_EXTERNAL_STAGE_STUB_NO_SAMPLE = '0'
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=pilot-requires-sampled-process-memory'

    New-Item -ItemType Directory -Path $processBudgetPackageFolder -Force | Out-Null
    $processBudgetManifest = New-TestManifest
    Add-TestPackageInputs $processBudgetPackageFolder $processBudgetManifest
    Write-TestStageState $processBudgetPackageFolder $processBudgetManifest
    Write-TestSupervisor $processBudgetPackageFolder
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $processBudgetMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    $env:NBIOT_EXTERNAL_STAGE_STUB_PROCESS_COUNT = '2'
    $processBudgetInvocationFailed = $false
    try {
        & $runner -PackageFolder $processBudgetPackageFolder -Stage validate `
            -ExecutionProfile external-machine -Execute *> $processBudgetCapture
    }
    catch { $processBudgetInvocationFailed = $true }
    if (-not $processBudgetInvocationFailed -or
        -not (Select-String -LiteralPath $processBudgetCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=process-budget-exceeded$') -or
        -not (Test-Path -LiteralPath $processBudgetMarker)) {
        throw 'a stage process tree larger than the explicit maxProcesses budget was accepted'
    }
    $env:NBIOT_EXTERNAL_STAGE_STUB_PROCESS_COUNT = '1'
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=process-count-budget-stops-over-limit'

    New-Item -ItemType Directory -Path $overBudgetPackageFolder -Force | Out-Null
    $overBudgetManifest = New-TestManifest
    $overBudgetManifest.resourceBudget.maxUE = 5000
    $overBudgetManifest.resourceStatus = 'measured-and-target-reviewed'
    Add-TestPackageInputs $overBudgetPackageFolder $overBudgetManifest
    Write-TestStageState $overBudgetPackageFolder $overBudgetManifest
    Set-TestStageComplete $overBudgetPackageFolder 'validate'
    Complete-TestPilotThroughRunner $overBudgetPackageFolder $runner `
        (Join-Path $testRoot 'over-budget-pilot-calls.txt') (Join-Path $testRoot 'over-budget-pilot-capture.txt')
    Set-TestPilotEvidence $overBudgetPackageFolder -SampledPeakWorkingSetBytes 2147483648
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $overBudgetMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    $overBudgetInvocationFailed = $false
    try {
        & $runner -PackageFolder $overBudgetPackageFolder -Stage data `
            -ExecutionProfile external-machine -Execute *> $overBudgetCapture
    }
    catch { $overBudgetInvocationFailed = $true }
    if (-not $overBudgetInvocationFailed -or
        -not (Select-String -LiteralPath $overBudgetCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=measured-resource-budget-exceeded$') -or
        (Test-Path -LiteralPath $overBudgetMarker)) {
        throw 'data stage launched despite pilot measurements exceeding the explicit case budget'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=over-budget-resource-evidence-blocks-before-launch'

    New-Item -ItemType Directory -Path $overProcessEvidencePackageFolder -Force | Out-Null
    $overProcessEvidenceManifest = New-TestManifest
    $overProcessEvidenceManifest.resourceBudget.maxUE = 5000
    $overProcessEvidenceManifest.resourceStatus = 'measured-and-target-reviewed'
    Add-TestPackageInputs $overProcessEvidencePackageFolder $overProcessEvidenceManifest
    Write-TestStageState $overProcessEvidencePackageFolder $overProcessEvidenceManifest
    Set-TestStageComplete $overProcessEvidencePackageFolder 'validate'
    Complete-TestPilotThroughRunner $overProcessEvidencePackageFolder $runner `
        (Join-Path $testRoot 'over-process-evidence-pilot-calls.txt') (Join-Path $testRoot 'over-process-evidence-pilot-capture.txt')
    Set-TestPilotEvidence $overProcessEvidencePackageFolder -SampledPeakProcessCount 2
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $overProcessEvidenceMarker
    $overProcessEvidenceInvocationFailed = $false
    try {
        & $runner -PackageFolder $overProcessEvidencePackageFolder -Stage data `
            -ExecutionProfile external-machine -Execute *> $overProcessEvidenceCapture
    }
    catch { $overProcessEvidenceInvocationFailed = $true }
    if (-not $overProcessEvidenceInvocationFailed -or
        -not (Select-String -LiteralPath $overProcessEvidenceCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=measured-resource-budget-exceeded$') -or
        (Test-Path -LiteralPath $overProcessEvidenceMarker)) {
        throw 'data stage launched despite pilot process-count evidence exceeding maxProcesses'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=over-budget-process-count-evidence-blocks-before-launch'

    New-Item -ItemType Directory -Path $workerPackageFolder -Force | Out-Null
    $workerManifest = New-TestManifest
    Add-TestPackageInputs $workerPackageFolder $workerManifest
    Write-TestStageState $workerPackageFolder $workerManifest
    $workerStatePath = Join-Path $workerPackageFolder 'stages.json'
    $workerState = Get-Content -LiteralPath $workerStatePath -Raw | ConvertFrom-Json
    $validateEntry = @($workerState.stages | Where-Object { $_.name -eq 'validate' })[0]
    $owner = Get-Process -Id $PID
    $validateEntry.status = 'running'
    $validateEntry.worker = [ordered]@{
        ownerProcessId = $PID
        ownerStartedAtUtc = $owner.StartTime.ToUniversalTime().ToString('o')
        ownedProcesses = @()
    }
    $workerState | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $workerStatePath -Encoding UTF8
    $workerInvocationFailed = $false
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $workerMarker
    try {
        & $runner -PackageFolder $workerPackageFolder -Stage validate `
            -ExecutionProfile external-machine -Execute *> $workerCapture
    }
    catch { $workerInvocationFailed = $true }
    if (-not $workerInvocationFailed -or
        -not (Select-String -LiteralPath $workerCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=worker-active$')) {
        $workerMarkers = @(Get-Content -LiteralPath $workerCapture | Where-Object { $_ -match '^EXTERNAL_STAGE_' }) -join ';'
        throw "a live stage owner did not block a second launch: $workerMarkers"
    }
    if (Test-Path -LiteralPath $workerMarker) { throw 'a live stage owner allowed a second stage process' }
    $workerStateHashBeforeRecovery = (Get-FileHash -LiteralPath $workerStatePath -Algorithm SHA256).Hash
    $workerRecoveryCapture = Join-Path $testRoot 'active-worker-recovery-capture.txt'
    $workerRecoveryFailed = $false
    try {
        & $runner -PackageFolder $workerPackageFolder -Stage validate -RecoverInterrupted *> $workerRecoveryCapture
    }
    catch { $workerRecoveryFailed = $true }
    if (-not $workerRecoveryFailed -or
        -not (Select-String -LiteralPath $workerRecoveryCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=worker-active$') -or
        (Get-FileHash -LiteralPath $workerStatePath -Algorithm SHA256).Hash -ne $workerStateHashBeforeRecovery) {
        throw 'interrupted recovery changed a stage whose recorded owner is still active'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=active-worker-blocks-second-launch'

    $malformedOwnerState = Get-Content -LiteralPath $workerStatePath -Raw | ConvertFrom-Json
    $malformedOwnerEntry = @($malformedOwnerState.stages | Where-Object { $_.name -eq 'validate' })[0]
    $malformedOwnerEntry.worker.ownerStartedAtUtc = 'not-a-dateZ'
    $malformedOwnerState | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $workerStatePath -Encoding UTF8
    $malformedOwnerStateHash = (Get-FileHash -LiteralPath $workerStatePath -Algorithm SHA256).Hash
    $malformedOwnerCapture = Join-Path $testRoot 'malformed-owner-timestamp-capture.txt'
    $malformedOwnerFailed = $false
    try {
        & $runner -PackageFolder $workerPackageFolder -Stage validate -RecoverInterrupted *> $malformedOwnerCapture
    }
    catch { $malformedOwnerFailed = $true }
    if (-not $malformedOwnerFailed -or
        -not (Select-String -LiteralPath $malformedOwnerCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=interrupted-worker-identity-required$') -or
        (Get-FileHash -LiteralPath $workerStatePath -Algorithm SHA256).Hash -ne $malformedOwnerStateHash) {
        throw 'interrupted recovery accepted a malformed timestamp for its live owner or changed the ledger'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=malformed-owner-timestamp-fails-closed'

    $malformedChildState = Get-Content -LiteralPath $workerStatePath -Raw | ConvertFrom-Json
    $malformedChildEntry = @($malformedChildState.stages | Where-Object { $_.name -eq 'validate' })[0]
    $malformedChildEntry.worker.ownerProcessId = 2147483647
    $malformedChildEntry.worker.ownerStartedAtUtc = '2026-10-01T00:00:00.0000000Z'
    $malformedChildEntry.worker.ownedProcesses = @([ordered]@{
        processId = $PID
        startedAtUtc = 'not-a-dateZ'
    })
    $malformedChildState | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $workerStatePath -Encoding UTF8
    $malformedChildStateHash = (Get-FileHash -LiteralPath $workerStatePath -Algorithm SHA256).Hash
    $malformedChildCapture = Join-Path $testRoot 'malformed-child-timestamp-capture.txt'
    $malformedChildFailed = $false
    try {
        & $runner -PackageFolder $workerPackageFolder -Stage validate -RecoverInterrupted *> $malformedChildCapture
    }
    catch { $malformedChildFailed = $true }
    if (-not $malformedChildFailed -or
        -not (Select-String -LiteralPath $malformedChildCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=interrupted-worker-identity-required$') -or
        (Get-FileHash -LiteralPath $workerStatePath -Algorithm SHA256).Hash -ne $malformedChildStateHash) {
        throw 'interrupted recovery accepted a malformed child timestamp or changed the ledger'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=malformed-child-timestamp-fails-closed'

    New-Item -ItemType Directory -Path $interruptedPackageFolder -Force | Out-Null
    $interruptedManifest = New-TestManifest
    Add-TestPackageInputs $interruptedPackageFolder $interruptedManifest
    Write-TestStageState $interruptedPackageFolder $interruptedManifest
    $interruptedStatePath = Join-Path $interruptedPackageFolder 'stages.json'
    $interruptedState = Get-Content -LiteralPath $interruptedStatePath -Raw | ConvertFrom-Json
    $interruptedEntry = @($interruptedState.stages | Where-Object { $_.name -eq 'validate' })[0]
    $interruptedEntry.status = 'running'
    $interruptedEntry.worker = [ordered]@{
        ownerProcessId = 2147483647
        ownerStartedAtUtc = '2026-10-01T00:00:00.0000000Z'
        ownedProcesses = @()
    }
    $interruptedEntry.registryInputDigest = [string]$interruptedState.registryDigest
    $interruptedState | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $interruptedStatePath -Encoding UTF8
    $interruptedStateHash = (Get-FileHash -LiteralPath $interruptedStatePath -Algorithm SHA256).Hash
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $interruptedMarker
    $interruptedInvocationFailed = $false
    try {
        & $runner -PackageFolder $interruptedPackageFolder -Stage validate `
            -ExecutionProfile external-machine -Execute *> $interruptedCapture
    }
    catch { $interruptedInvocationFailed = $true }
    if (-not $interruptedInvocationFailed -or
        -not (Select-String -LiteralPath $interruptedCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=interrupted-reconciliation-required$') -or
        (Test-Path -LiteralPath $interruptedMarker) -or
        (Get-FileHash -LiteralPath $interruptedStatePath -Algorithm SHA256).Hash -ne $interruptedStateHash) {
        throw 'an interrupted stage was launched or rewritten instead of awaiting the approved reconciliation procedure'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=interrupted-stage-blocks-without-manual-rewrite'

    Write-TestSupervisor $interruptedPackageFolder
    $interruptedRecoveryCapture = Join-Path $testRoot 'interrupted-recovery-capture.txt'
    $interruptedRecoveryFailed = $false
    $interruptedRecoveryException = ''
    try {
        & $runner -PackageFolder $interruptedPackageFolder -Stage validate -RecoverInterrupted *> $interruptedRecoveryCapture
    }
    catch {
        $interruptedRecoveryFailed = $true
        $interruptedRecoveryException = $_.Exception.Message
    }
    $interruptedStateAfterRecovery = Get-Content -LiteralPath $interruptedStatePath -Raw | ConvertFrom-Json
    $interruptedEntryAfterRecovery = @($interruptedStateAfterRecovery.stages | Where-Object { $_.name -eq 'validate' })[0]
    $interruptedRegistryPath = Join-Path $interruptedPackageFolder 'project\experiments\realizationRegistry.json'
    $interruptedRecoveryMarker = Select-String -LiteralPath $interruptedRecoveryCapture -Pattern '^EXTERNAL_STAGE_INTERRUPTED_RECONCILED=validate$'
    $interruptedRegistryDigestMatches = [string]$interruptedStateAfterRecovery.registryDigest -ceq (Get-FileHash -LiteralPath $interruptedRegistryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($interruptedRecoveryFailed -or
        -not $interruptedRecoveryMarker -or
        [string]$interruptedEntryAfterRecovery.status -cne 'failed' -or
        $null -ne $interruptedEntryAfterRecovery.worker -or
        (Test-Path -LiteralPath $interruptedMarker) -or
        -not $interruptedRegistryDigestMatches) {
        $interruptedRecoveryOutput = @(Get-Content -LiteralPath $interruptedRecoveryCapture | Select-Object -First 8) -join ' | '
        throw "a dead interrupted stage with an unchanged ID registry was not reconciled safely; failed=$interruptedRecoveryFailed, marker=$([bool]$interruptedRecoveryMarker), status=$($interruptedEntryAfterRecovery.status), workerNull=$($null -eq $interruptedEntryAfterRecovery.worker), runnerMarker=$(Test-Path -LiteralPath $interruptedMarker), registryMatches=$interruptedRegistryDigestMatches, exception=$interruptedRecoveryException, output=$interruptedRecoveryOutput"
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=interrupted-stage-reconciles-only-after-owner-exits'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    & $runner -PackageFolder $interruptedPackageFolder -Stage validate -ExecutionProfile external-machine -Execute *> $interruptedRecoveryCapture
    if (-not (Select-String -LiteralPath $interruptedRecoveryCapture -Pattern '^EXTERNAL_STAGE_COMPLETE=validate$') -or
        -not (Test-Path -LiteralPath $interruptedMarker)) {
        throw 'a safely reconciled interrupted stage did not resume in a fresh supervised invocation'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=interrupted-stage-retries-after-safe-reconciliation'

    $changedRegistryInterruptedFolder = Join-Path $testRoot 'interrupted-registry-changed-package'
    New-Item -ItemType Directory -Path $changedRegistryInterruptedFolder -Force | Out-Null
    $changedRegistryInterruptedManifest = New-TestManifest
    Add-TestPackageInputs $changedRegistryInterruptedFolder $changedRegistryInterruptedManifest
    Write-TestStageState $changedRegistryInterruptedFolder $changedRegistryInterruptedManifest
    $changedRegistryInterruptedStatePath = Join-Path $changedRegistryInterruptedFolder 'stages.json'
    $changedRegistryInterruptedState = Get-Content -LiteralPath $changedRegistryInterruptedStatePath -Raw | ConvertFrom-Json
    $changedRegistryInterruptedEntry = @($changedRegistryInterruptedState.stages | Where-Object { $_.name -eq 'validate' })[0]
    $changedRegistryInterruptedEntry.status = 'running'
    $changedRegistryInterruptedEntry.worker = [ordered]@{
        ownerProcessId = 2147483647
        ownerStartedAtUtc = '2026-10-01T00:00:00.0000000Z'
        ownedProcesses = @()
    }
    $changedRegistryInterruptedEntry.registryInputDigest = [string]$changedRegistryInterruptedState.registryDigest
    $changedRegistryInterruptedState | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $changedRegistryInterruptedStatePath -Encoding UTF8
    $changedRegistryInterruptedRegistry = Join-Path $changedRegistryInterruptedFolder 'project\experiments\realizationRegistry.json'
    Add-Content -LiteralPath $changedRegistryInterruptedRegistry -Value ' '
    $changedRegistryInterruptedHash = (Get-FileHash -LiteralPath $changedRegistryInterruptedStatePath -Algorithm SHA256).Hash
    $changedRegistryInterruptedMarker = Join-Path $testRoot 'interrupted-registry-changed-calls.txt'
    $changedRegistryInterruptedCapture = Join-Path $testRoot 'interrupted-registry-changed-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $changedRegistryInterruptedMarker
    $changedRegistryRecoveryFailed = $false
    try {
        & $runner -PackageFolder $changedRegistryInterruptedFolder -Stage validate -RecoverInterrupted *> $changedRegistryInterruptedCapture
    }
    catch { $changedRegistryRecoveryFailed = $true }
    if (-not $changedRegistryRecoveryFailed -or
        -not (Select-String -LiteralPath $changedRegistryInterruptedCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=interrupted-registry-reconciliation-required$') -or
        (Test-Path -LiteralPath $changedRegistryInterruptedMarker) -or
        (Get-FileHash -LiteralPath $changedRegistryInterruptedStatePath -Algorithm SHA256).Hash -ne $changedRegistryInterruptedHash) {
        throw 'interrupted recovery rewrote a state after the ID registry changed'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=interrupted-registry-change-requires-manual-reconciliation'

    New-Item -ItemType Directory -Path $fixturePackageFolder -Force | Out-Null
    $fixtureManifest = New-TestManifest 'draft-needs-external-review' 'development-fixture'
    $fixtureManifest.resourceBudget.maxUE = 5000
    $fixtureManifest.resourceStatus = 'target-reviewed'
    Add-TestPackageInputs $fixturePackageFolder $fixtureManifest
    Write-TestStageState $fixturePackageFolder $fixtureManifest
    Set-TestStageComplete $fixturePackageFolder 'validate'
    Complete-TestPilotThroughRunner $fixturePackageFolder $runner `
        (Join-Path $testRoot 'fixture-pilot-calls.txt') (Join-Path $testRoot 'fixture-pilot-capture.txt')
    foreach ($name in @('data','assemble','train','freeze','evaluate')) {
        Set-TestStageComplete $fixturePackageFolder $name
    }
    $reviewPath = Join-Path $fixturePackageFolder 'model-review.json'
    [ordered]@{
        schemaVersion = 'model-acceptance-review-v1'
        decision = 'accepted'
        reviewer = 'fixture-reviewer'
        reviewedPackageDigest = $fixtureManifest.codeManifestSha256
        evidenceKind = 'development-fixture'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reviewPath -Encoding UTF8
    $fixtureInvocationFailed = $false
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $fixtureMarker
    try {
        & $runner -PackageFolder $fixturePackageFolder -Stage admit -ReviewFile $reviewPath `
            -ExecutionProfile external-machine -Execute *> $fixtureCapture
    }
    catch { $fixtureInvocationFailed = $true }
    if (-not $fixtureInvocationFailed -or
        -not (Select-String -LiteralPath $fixtureCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=fixture-evidence-rejected$')) {
        throw 'fixture evidence was not rejected for model admission'
    }
    if (Test-Path -LiteralPath $fixtureMarker) { throw 'fixture admission launched a stage process' }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=fixture-admission-rejected-before-launch'

    New-Item -ItemType Directory -Path $dispatchPackageFolder -Force | Out-Null
    $dispatchManifest = New-TestManifest
    Add-TestPackageInputs $dispatchPackageFolder $dispatchManifest
    Write-TestStageState $dispatchPackageFolder $dispatchManifest
    Write-TestSupervisor $dispatchPackageFolder
    $dispatchStatePath = Join-Path $dispatchPackageFolder 'stages.json'
    $beforeDispatchState = (Get-FileHash -LiteralPath $dispatchStatePath -Algorithm SHA256).Hash
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $dispatchMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'missing-marker'
    $missingMarkerInvocationFailed = $false
    $missingMarkerError = ''
    try {
        & $runner -PackageFolder $dispatchPackageFolder -Stage validate `
            -ExecutionProfile external-machine -Execute *> $dispatchCapture
    }
    catch { $missingMarkerInvocationFailed = $true; $missingMarkerError = $_.Exception.Message }
    if (-not $missingMarkerInvocationFailed -or
        -not (Select-String -LiteralPath $dispatchCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=completion-marker-required$')) {
        $dispatchLines = @(Get-Content -LiteralPath $dispatchCapture | Select-Object -First 4) -join ';'
        throw "a zero exit without a stage completion marker was accepted: $missingMarkerError $dispatchLines"
    }
    if (-not (Test-Path -LiteralPath $dispatchMarker) -or
        (Get-FileHash -LiteralPath $dispatchStatePath -Algorithm SHA256).Hash -eq $beforeDispatchState) {
        throw 'the process stub did not run or the failed stage state was not persisted'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=missing-completion-marker-is-failure'

    $repeatPackageFolder = Join-Path $testRoot 'repeat-completed-package'
    New-Item -ItemType Directory -Path $repeatPackageFolder -Force | Out-Null
    $repeatManifest = New-TestManifest
    Add-TestPackageInputs $repeatPackageFolder $repeatManifest
    Write-TestStageState $repeatPackageFolder $repeatManifest
    Write-TestSupervisor $repeatPackageFolder
    $repeatMarker = Join-Path $testRoot 'repeat-call-count.txt'
    $repeatCapture = Join-Path $testRoot 'repeat-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $repeatMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    & $runner -PackageFolder $repeatPackageFolder -Stage validate `
        -ExecutionProfile external-machine -Execute *> $repeatCapture
    $countAfterFirst = @(Get-Content -LiteralPath $repeatMarker).Count
    & $runner -PackageFolder $repeatPackageFolder -Stage validate `
        -ExecutionProfile external-machine -Execute *> $repeatCapture
    $countAfterRepeat = @(Get-Content -LiteralPath $repeatMarker).Count
    if ($countAfterFirst -ne 1 -or $countAfterRepeat -ne 1 -or
        -not (Select-String -LiteralPath $repeatCapture -Pattern '^EXTERNAL_STAGE_ALREADY_COMPLETE=validate$')) {
        throw 'same-input completed stage did not return a no-op'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=repeat-completed-same-input-is-no-op'

    $staleManifest = Get-Content -LiteralPath (Join-Path $repeatPackageFolder 'manifest.json') -Raw | ConvertFrom-Json
    $staleManifest.resourceBudget.maxUE = 2
    $staleManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $repeatPackageFolder 'manifest.json') -Encoding UTF8
    $staleInvocationFailed = $false
    try {
        & $runner -PackageFolder $repeatPackageFolder -Stage validate `
            -ExecutionProfile external-machine -Execute *> $repeatCapture
    }
    catch { $staleInvocationFailed = $true }
    $countAfterStale = @(Get-Content -LiteralPath $repeatMarker).Count
    if (-not $staleInvocationFailed -or $countAfterStale -ne 1 -or
        -not (Select-String -LiteralPath $repeatCapture -Pattern '^EXTERNAL_STAGE_STALE=validate$')) {
        throw 'changed stage inputs overwrote or reran a completed attempt'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=changed-inputs-mark-stage-stale'

    $comparisonPackageFolder = Join-Path $testRoot 'comparison-scenario-package'
    New-Item -ItemType Directory -Path $comparisonPackageFolder -Force | Out-Null
    $comparisonManifest = New-TestManifest
    $comparisonManifest.resourceBudget.maxUE = 5000
    $comparisonManifest.resourceStatus = 'measured-and-target-reviewed'
    Add-TestPackageInputs $comparisonPackageFolder $comparisonManifest
    Write-TestStageState $comparisonPackageFolder $comparisonManifest
    Set-TestStageComplete $comparisonPackageFolder 'validate'
    Complete-TestPilotThroughRunner $comparisonPackageFolder $runner `
        (Join-Path $testRoot 'comparison-pilot-calls.txt') (Join-Path $testRoot 'comparison-pilot-capture.txt')
    foreach ($name in @('data','assemble','train','freeze','evaluate')) {
        Set-TestStageComplete $comparisonPackageFolder $name
    }
    Complete-TestAdmissionThroughRunner $comparisonPackageFolder $runner `
        (Join-Path $testRoot 'comparison-admit-calls.txt') (Join-Path $testRoot 'comparison-admit-capture.txt') | Out-Null
    $comparisonStatePath = Join-Path $comparisonPackageFolder 'stages.json'
    $comparisonState = Get-Content -LiteralPath $comparisonStatePath -Raw | ConvertFrom-Json
    $compareEntry = @($comparisonState.stages | Where-Object { $_.name -eq 'compare' })[0]
    $compareEntry.configuration = [ordered]@{
        scenarioMatrix = @(
            [ordered]@{ method = 'Static'; numUE = 100; durationTicks = 5000; burstDurationTicks = 50; realizationId = 1800; scenarioIdentity = 'scenario-a' },
            [ordered]@{ method = 'Adaptive-P'; numUE = 100; durationTicks = 5000; burstDurationTicks = 50; realizationId = 1800; scenarioIdentity = 'scenario-b' }
        )
        comparisonOptions = [ordered]@{
            counts = @(100)
            burstDurations = @(50)
            methods = @('Static','Adaptive-P')
            realizationIds = @(1800)
            config = [ordered]@{ simulation = [ordered]@{ durationTicks = 5000 } }
        }
    }
    $comparisonState | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $comparisonStatePath -Encoding UTF8
    $comparisonMarker = Join-Path $testRoot 'comparison-process-calls.txt'
    $comparisonCapture = Join-Path $testRoot 'comparison-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $comparisonMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'missing-marker'
    $scenarioMismatchFailed = $false
    try {
        & $runner -PackageFolder $comparisonPackageFolder -Stage compare `
            -ExecutionProfile external-machine -Execute *> $comparisonCapture
    }
    catch { $scenarioMismatchFailed = $true }
    if (-not $scenarioMismatchFailed -or
        -not (Select-String -LiteralPath $comparisonCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=scenario-identity-mismatch$') -or
        (Test-Path -LiteralPath $comparisonMarker)) {
        throw 'comparison with different scenario identities was not blocked before launch'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=comparison-rejects-mismatched-scenario-identity'

    $compareEntry.configuration.scenarioMatrix[1].scenarioIdentity = 'scenario-a'
    $comparisonState | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $comparisonStatePath -Encoding UTF8
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    & $runner -PackageFolder $comparisonPackageFolder -Stage compare `
        -ExecutionProfile external-machine -Execute *> $comparisonCapture
    if (-not (Test-Path -LiteralPath $comparisonMarker) -or
        -not (Select-String -LiteralPath $comparisonCapture -Pattern '^EXTERNAL_STAGE_COMPLETE=compare$')) {
        throw 'comparison with a shared scenario identity did not reach the fixed dispatch point'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=comparison-shares-scenario-identity-across-methods'

    $registryPackageFolder = Join-Path $testRoot 'registry-digest-package'
    New-Item -ItemType Directory -Path $registryPackageFolder -Force | Out-Null
    $registryManifest = New-TestManifest
    $registryManifest.resourceBudget.maxUE = 5000
    $registryManifest.resourceStatus = 'target-reviewed'
    Add-TestPackageInputs $registryPackageFolder $registryManifest
    Write-TestStageState $registryPackageFolder $registryManifest
    Set-TestStageComplete $registryPackageFolder 'validate'
    Write-TestSupervisor $registryPackageFolder
    Set-TestPilotApproval $registryPackageFolder $runner
    $registryMarker = Join-Path $testRoot 'registry-call-count.txt'
    $registryCapture = Join-Path $testRoot 'registry-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $registryMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MUTATE_REGISTRY = '1'
    & $runner -PackageFolder $registryPackageFolder -Stage pilot `
        -ExecutionProfile external-machine -Execute *> $registryCapture
    $registryFile = Join-Path $registryPackageFolder 'project\experiments\realizationRegistry.json'
    $registryState = Get-Content -LiteralPath (Join-Path $registryPackageFolder 'stages.json') -Raw | ConvertFrom-Json
    if ($registryState.registryDigest -cne (Get-FileHash -LiteralPath $registryFile -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'a stage-owned registry change was not captured in the stage ledger'
    }
    $pilotEntry = @($registryState.stages | Where-Object { $_.name -eq 'pilot' })[0]
    $pilotReportPath = Join-Path $registryPackageFolder ($pilotEntry.reportPath -replace '/', '\')
    $pilotReport = Get-Content -LiteralPath $pilotReportPath -Raw | ConvertFrom-Json
    if ([int64]$pilotReport.resourceEvidence.sampledPeakWorkingSetBytes -le 0 -or
        [int]$pilotReport.resourceEvidence.sampledPeakProcessCount -ne 1 -or
        [double]$pilotReport.resourceEvidence.processRunnerElapsedSeconds -le 0) {
        throw 'the completed pilot did not persist sampled process memory, process count and runner duration'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=pilot-records-sampled-process-resources'
    $registryCallsAfterFirst = @(Get-Content -LiteralPath $registryMarker).Count
    $env:NBIOT_EXTERNAL_STAGE_STUB_MUTATE_REGISTRY = '0'
    & $runner -PackageFolder $registryPackageFolder -Stage pilot `
        -ExecutionProfile external-machine -Execute *> $registryCapture
    $registryCallsAfterRepeat = @(Get-Content -LiteralPath $registryMarker).Count
    if ($registryCallsAfterFirst -ne 1 -or $registryCallsAfterRepeat -ne 1 -or
        -not (Select-String -LiteralPath $registryCapture -Pattern '^EXTERNAL_STAGE_ALREADY_COMPLETE=pilot$')) {
        throw 'a completed pilot was not a no-op after its owned registry update'
    }
    $pilotApprovalPath = Join-Path $registryPackageFolder 'reviews\pilot-5000-approval.json'
    $pilotApprovalAfterRun = Get-Content -LiteralPath $pilotApprovalPath -Raw | ConvertFrom-Json
    $pilotApprovalAfterRun.recordReference = 'Changed synthetic fixture record.'
    $pilotApprovalAfterRun | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pilotApprovalPath -Encoding UTF8
    $approvalChangeFailed = $false
    try {
        & $runner -PackageFolder $registryPackageFolder -Stage pilot -ExecutionProfile external-machine -Execute *> $registryCapture
    }
    catch { $approvalChangeFailed = $true }
    $registryStateAfterApprovalChange = Get-Content -LiteralPath (Join-Path $registryPackageFolder 'stages.json') -Raw | ConvertFrom-Json
    $pilotEntryAfterApprovalChange = @($registryStateAfterApprovalChange.stages | Where-Object { $_.name -eq 'pilot' })[0]
    $registryCallsAfterApprovalChange = @(Get-Content -LiteralPath $registryMarker).Count
    if (-not $approvalChangeFailed -or
        -not (Select-String -LiteralPath $registryCapture -Pattern '^EXTERNAL_STAGE_STALE=pilot$') -or
        [string]$pilotEntryAfterApprovalChange.status -cne 'stale' -or
        $registryCallsAfterApprovalChange -ne $registryCallsAfterRepeat) {
        throw 'a changed 5000 UE approval record reused the completed pilot instead of marking it stale'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=changed-pilot-approval-invalidates-completed-run'

    & $runner -PackageFolder $registryPackageFolder -Stage pilot `
        -ExecutionProfile external-machine -Execute *> $registryCapture
    $registryCallsAfterApprovedRetry = @(Get-Content -LiteralPath $registryMarker).Count
    $approvedRetryState = Get-Content -LiteralPath (Join-Path $registryPackageFolder 'stages.json') -Raw | ConvertFrom-Json
    $approvedRetryEntry = @($approvedRetryState.stages | Where-Object { $_.name -eq 'pilot' })[0]
    if (-not (Select-String -LiteralPath $registryCapture -Pattern '^EXTERNAL_STAGE_COMPLETE=pilot$') -or
        [string]$approvedRetryEntry.status -cne 'completed' -or
        $registryCallsAfterApprovedRetry -ne ($registryCallsAfterRepeat + 1)) {
        throw 'a stale pilot could not be rerun with its current valid approval record'
    }
    $rejectedPilotApproval = Get-Content -LiteralPath $pilotApprovalPath -Raw | ConvertFrom-Json
    $rejectedPilotApproval.decision = 'rejected'
    $rejectedPilotApproval | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pilotApprovalPath -Encoding UTF8
    $rejectedApprovalFailed = $false
    try {
        & $runner -PackageFolder $registryPackageFolder -Stage pilot -ExecutionProfile external-machine -Execute *> $registryCapture
    }
    catch { $rejectedApprovalFailed = $true }
    $registryStateAfterRejectedApproval = Get-Content -LiteralPath (Join-Path $registryPackageFolder 'stages.json') -Raw | ConvertFrom-Json
    $pilotEntryAfterRejectedApproval = @($registryStateAfterRejectedApproval.stages | Where-Object { $_.name -eq 'pilot' })[0]
    $registryCallsAfterRejectedApproval = @(Get-Content -LiteralPath $registryMarker).Count
    if (-not $rejectedApprovalFailed -or
        -not (Select-String -LiteralPath $registryCapture -Pattern '^EXTERNAL_STAGE_STALE=pilot$') -or
        [string]$pilotEntryAfterRejectedApproval.status -cne 'stale' -or
        $registryCallsAfterRejectedApproval -ne $registryCallsAfterApprovedRetry) {
        throw 'a rejected replacement approval left the previous completed pilot usable as a current dependency'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=rejected-pilot-approval-invalidates-completed-run'

    Add-Content -LiteralPath $registryFile -Value ' '
    $registryMismatchFailed = $false
    try {
        & $runner -PackageFolder $registryPackageFolder -Stage pilot `
            -ExecutionProfile external-machine -Execute *> $registryCapture
    }
    catch { $registryMismatchFailed = $true }
    if (-not $registryMismatchFailed -or
        -not (Select-String -LiteralPath $registryCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=registry-hash-mismatch$')) {
        throw 'an out-of-band registry change was not rejected'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=registry-digest-tracks-owned-changes-and-blocks-outsiders'

    $admissionPackageFolder = Join-Path $testRoot 'admission-review-digest-package'
    New-Item -ItemType Directory -Path $admissionPackageFolder -Force | Out-Null
    $admissionManifest = New-TestManifest
    $admissionManifest.resourceBudget.maxUE = 5000
    $admissionManifest.resourceStatus = 'target-reviewed'
    Add-TestPackageInputs $admissionPackageFolder $admissionManifest
    Write-TestStageState $admissionPackageFolder $admissionManifest
    Set-TestStageComplete $admissionPackageFolder 'validate'
    Complete-TestPilotThroughRunner $admissionPackageFolder $runner `
        (Join-Path $testRoot 'admission-review-pilot-calls.txt') (Join-Path $testRoot 'admission-review-pilot-capture.txt')
    foreach ($name in @('data','assemble','train','freeze','evaluate')) {
        Set-TestStageComplete $admissionPackageFolder $name
    }
    Write-TestSupervisor $admissionPackageFolder
    $admissionReviewPath = Join-Path $admissionPackageFolder 'model-review.json'
    $admissionReview = [ordered]@{
        schemaVersion = 'model-acceptance-review-v1'
        decision = 'accepted'
        reviewer = 'fixture-reviewer'
        reviewedAtUtc = '2026-10-19T00:00:00Z'
        evidenceDigest = ('a' * 64)
        protocolSha256 = ('b' * 64)
        limitations = 'Process-only gate fixture.'
    }
    $admissionReview | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $admissionReviewPath -Encoding UTF8
    $admissionMarker = Join-Path $testRoot 'admission-process-calls.txt'
    $admissionCapture = Join-Path $testRoot 'admission-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $admissionMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    & $runner -PackageFolder $admissionPackageFolder -Stage admit -ReviewFile $admissionReviewPath `
        -ExecutionProfile external-machine -Execute *> $admissionCapture
    $admissionCallsAfterAcceptedReview = @(Get-Content -LiteralPath $admissionMarker).Count
    $admissionReview.decision = 'rejected'
    $admissionReview | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $admissionReviewPath -Encoding UTF8
    $admissionChangedInvocationFailed = $false
    try {
        & $runner -PackageFolder $admissionPackageFolder -Stage admit -ReviewFile $admissionReviewPath `
            -ExecutionProfile external-machine -Execute *> $admissionCapture
    }
    catch { $admissionChangedInvocationFailed = $true }
    $admissionCallsAfterChangedReview = @(Get-Content -LiteralPath $admissionMarker).Count
    if (-not $admissionChangedInvocationFailed -or $admissionCallsAfterAcceptedReview -ne 1 -or $admissionCallsAfterChangedReview -ne 1 -or
        -not (Select-String -LiteralPath $admissionCapture -Pattern '^EXTERNAL_STAGE_STALE=admit$')) {
        throw 'a changed rejected review reused the completed accepted admission instead of marking it stale'
    }
    $admissionState = Get-Content -LiteralPath (Join-Path $admissionPackageFolder 'stages.json') -Raw | ConvertFrom-Json
    if ([string](@($admissionState.stages | Where-Object { $_.name -eq 'admit' })[0].status) -cne 'stale') {
        throw 'a changed admission review did not persist stale stage state'
    }
    $admissionCompareMarker = Join-Path $testRoot 'admission-compare-process-calls.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $admissionCompareMarker
    $admissionCompareFailed = $false
    try {
        & $runner -PackageFolder $admissionPackageFolder -Stage compare `
            -ExecutionProfile external-machine -Execute *> $admissionCapture
    }
    catch { $admissionCompareFailed = $true }
    if (-not $admissionCompareFailed -or
        -not (Select-String -LiteralPath $admissionCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=dependency-required$') -or
        (Test-Path -LiteralPath $admissionCompareMarker)) {
        throw 'comparison proceeded using an admission whose review had changed'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=changed-admission-review-invalidates-old-acceptance'

    $pilotDependencyPackageFolder = Join-Path $testRoot 'dependent-pilot-approval-package'
    New-Item -ItemType Directory -Path $pilotDependencyPackageFolder -Force | Out-Null
    $pilotDependencyManifest = New-TestManifest
    $pilotDependencyManifest.resourceBudget.maxUE = 5000
    $pilotDependencyManifest.resourceStatus = 'target-reviewed'
    Add-TestPackageInputs $pilotDependencyPackageFolder $pilotDependencyManifest
    Write-TestStageState $pilotDependencyPackageFolder $pilotDependencyManifest
    Set-TestStageComplete $pilotDependencyPackageFolder 'validate'
    $pilotDependencySetupMarker = Join-Path $testRoot 'dependent-pilot-setup-calls.txt'
    $pilotDependencySetupCapture = Join-Path $testRoot 'dependent-pilot-setup-capture.txt'
    Complete-TestPilotThroughRunner $pilotDependencyPackageFolder $runner $pilotDependencySetupMarker $pilotDependencySetupCapture
    $pilotDependencyApprovalPath = Join-Path $pilotDependencyPackageFolder 'reviews\pilot-5000-approval.json'
    $pilotDependencyApproval = Get-Content -LiteralPath $pilotDependencyApprovalPath -Raw | ConvertFrom-Json
    $pilotDependencyApproval.decision = 'rejected'
    $pilotDependencyApproval | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pilotDependencyApprovalPath -Encoding UTF8
    $pilotDependencyStatePath = Join-Path $pilotDependencyPackageFolder 'stages.json'
    $pilotDependencyStateBefore = Get-Content -LiteralPath $pilotDependencyStatePath -Raw | ConvertFrom-Json
    $pilotDependencyRunId = [string]$pilotDependencyStateBefore.runId
    $pilotDependencyRegistryPath = Join-Path $pilotDependencyPackageFolder 'project\experiments\realizationRegistry.json'
    $pilotDependencyRegistryHash = (Get-FileHash -LiteralPath $pilotDependencyRegistryPath -Algorithm SHA256).Hash
    $dependentDataMarker = Join-Path $testRoot 'dependent-data-calls.txt'
    $dependentDataCapture = Join-Path $testRoot 'dependent-data-capture.txt'
    $dependentDataFailed = $false
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $dependentDataMarker
    try {
        & $runner -PackageFolder $pilotDependencyPackageFolder -Stage data `
            -ExecutionProfile external-machine -Execute *> $dependentDataCapture
    }
    catch { $dependentDataFailed = $true }
    $pilotDependencyStateAfter = Get-Content -LiteralPath $pilotDependencyStatePath -Raw | ConvertFrom-Json
    $pilotDependencyEntryAfter = @($pilotDependencyStateAfter.stages | Where-Object { $_.name -eq 'pilot' })[0]
    $dataDependencyEntryAfter = @($pilotDependencyStateAfter.stages | Where-Object { $_.name -eq 'data' })[0]
    if (-not $dependentDataFailed -or
        -not (Select-String -LiteralPath $dependentDataCapture -Pattern '^EXTERNAL_STAGE_STALE=pilot$') -or
        [string]$pilotDependencyEntryAfter.status -cne 'stale' -or
        [string]$dataDependencyEntryAfter.status -cne 'not-started' -or
        (Test-Path -LiteralPath $dependentDataMarker) -or
        (Test-Path -LiteralPath (Join-Path $pilotDependencyPackageFolder 'stage-results\data')) -or
        [string]$pilotDependencyStateAfter.runId -cne $pilotDependencyRunId -or
        (Get-FileHash -LiteralPath $pilotDependencyRegistryPath -Algorithm SHA256).Hash -cne $pilotDependencyRegistryHash) {
        throw ('data did not fail closed after its pilot approval was rejected: capture=' +
            (Get-Content -LiteralPath $dependentDataCapture -Raw) + ' pilotStatus=' + [string]$pilotDependencyEntryAfter.status +
            ' dataStatus=' + [string]$dataDependencyEntryAfter.status + ' dispatched=' + (Test-Path -LiteralPath $dependentDataMarker))
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=rejected-pilot-approval-invalidates-downstream-data'

    $transitiveStalePackageFolder = Join-Path $testRoot 'transitive-stale-pilot-package'
    New-Item -ItemType Directory -Path $transitiveStalePackageFolder -Force | Out-Null
    $transitiveStaleManifest = New-TestManifest
    $transitiveStaleManifest.resourceBudget.maxUE = 5000
    $transitiveStaleManifest.resourceStatus = 'measured-and-target-reviewed'
    Add-TestPackageInputs $transitiveStalePackageFolder $transitiveStaleManifest
    Write-TestStageState $transitiveStalePackageFolder $transitiveStaleManifest
    Set-TestStageComplete $transitiveStalePackageFolder 'validate'
    Complete-TestPilotThroughRunner $transitiveStalePackageFolder $runner `
        (Join-Path $testRoot 'transitive-stale-pilot-calls.txt') (Join-Path $testRoot 'transitive-stale-pilot-capture.txt')
    foreach ($name in @('data','assemble','train','freeze','evaluate')) {
        Set-TestStageComplete $transitiveStalePackageFolder $name
    }
    Complete-TestAdmissionThroughRunner $transitiveStalePackageFolder $runner `
        (Join-Path $testRoot 'transitive-stale-admit-calls.txt') (Join-Path $testRoot 'transitive-stale-admit-capture.txt') | Out-Null
    $transitiveStaleStatePath = Join-Path $transitiveStalePackageFolder 'stages.json'
    $transitiveStaleState = Get-Content -LiteralPath $transitiveStaleStatePath -Raw | ConvertFrom-Json
    Set-TestComparisonScenario $transitiveStaleState
    $transitiveStaleState | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $transitiveStaleStatePath -Encoding UTF8
    $transitiveStaleApprovalPath = Join-Path $transitiveStalePackageFolder 'reviews\pilot-5000-approval.json'
    $transitiveStaleApproval = Get-Content -LiteralPath $transitiveStaleApprovalPath -Raw | ConvertFrom-Json
    $transitiveStaleApproval.decision = 'rejected'
    $transitiveStaleApproval | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $transitiveStaleApprovalPath -Encoding UTF8
    $transitiveStaleRegistryPath = Join-Path $transitiveStalePackageFolder 'project\experiments\realizationRegistry.json'
    $transitiveStaleRegistryHash = (Get-FileHash -LiteralPath $transitiveStaleRegistryPath -Algorithm SHA256).Hash
    $transitiveStaleRunId = [string]$transitiveStaleState.runId
    $transitiveStaleDataStateBefore = @($transitiveStaleState.stages | Where-Object { $_.name -eq 'data' })[0]
    $transitiveStaleDataDigestBefore = [string]$transitiveStaleDataStateBefore.outputDigest
    $transitiveStaleDataMarker = Join-Path $testRoot 'transitive-stale-data-calls.txt'
    $transitiveStaleDataCapture = Join-Path $testRoot 'transitive-stale-data-capture.txt'
    $transitiveStaleDataFailed = $false
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $transitiveStaleDataMarker
    try {
        & $runner -PackageFolder $transitiveStalePackageFolder -Stage data `
            -ExecutionProfile external-machine -Execute *> $transitiveStaleDataCapture
    }
    catch { $transitiveStaleDataFailed = $true }
    $transitiveStaleAfterData = Get-Content -LiteralPath $transitiveStaleStatePath -Raw | ConvertFrom-Json
    $transitiveStalePilotAfterData = @($transitiveStaleAfterData.stages | Where-Object { $_.name -eq 'pilot' })[0]
    $transitiveStaleDataAfterData = @($transitiveStaleAfterData.stages | Where-Object { $_.name -eq 'data' })[0]
    if (-not $transitiveStaleDataFailed -or
        -not (Select-String -LiteralPath $transitiveStaleDataCapture -Pattern '^EXTERNAL_STAGE_STALE=pilot$') -or
        [string]$transitiveStalePilotAfterData.status -cne 'stale' -or
        [string]$transitiveStaleDataAfterData.status -cne 'completed' -or
        [string]$transitiveStaleDataAfterData.outputDigest -cne $transitiveStaleDataDigestBefore -or
        (Test-Path -LiteralPath $transitiveStaleDataMarker)) {
        throw ('first downstream call did not isolate the stale pilot without changing completed data: capture=' +
            (Get-Content -LiteralPath $transitiveStaleDataCapture -Raw) + ' pilotStatus=' + [string]$transitiveStalePilotAfterData.status +
            ' dataStatus=' + [string]$transitiveStaleDataAfterData.status + ' dispatched=' + (Test-Path -LiteralPath $transitiveStaleDataMarker))
    }
    $transitiveStaleCompareMarker = Join-Path $testRoot 'transitive-stale-compare-calls.txt'
    $transitiveStaleCompareCapture = Join-Path $testRoot 'transitive-stale-compare-capture.txt'
    $transitiveStaleCompareFailed = $false
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $transitiveStaleCompareMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    try {
        & $runner -PackageFolder $transitiveStalePackageFolder -Stage compare `
            -ExecutionProfile external-machine -Execute *> $transitiveStaleCompareCapture
    }
    catch { $transitiveStaleCompareFailed = $true }
    $transitiveStaleAfterCompare = Get-Content -LiteralPath $transitiveStaleStatePath -Raw | ConvertFrom-Json
    $transitiveStalePilotAfterCompare = @($transitiveStaleAfterCompare.stages | Where-Object { $_.name -eq 'pilot' })[0]
    $transitiveStaleAdmitAfterCompare = @($transitiveStaleAfterCompare.stages | Where-Object { $_.name -eq 'admit' })[0]
    $transitiveStaleCompareAfterCompare = @($transitiveStaleAfterCompare.stages | Where-Object { $_.name -eq 'compare' })[0]
    if (-not $transitiveStaleCompareFailed -or
        -not (Select-String -LiteralPath $transitiveStaleCompareCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=dependency-stale$') -or
        [string]$transitiveStalePilotAfterCompare.status -cne 'stale' -or
        [string]$transitiveStaleAdmitAfterCompare.status -cne 'completed' -or
        [string]$transitiveStaleCompareAfterCompare.status -cne 'not-started' -or
        (Test-Path -LiteralPath $transitiveStaleCompareMarker) -or
        (Test-Path -LiteralPath (Join-Path $transitiveStalePackageFolder 'stage-results\compare')) -or
        [string]$transitiveStaleAfterCompare.runId -cne $transitiveStaleRunId -or
        (Get-FileHash -LiteralPath $transitiveStaleRegistryPath -Algorithm SHA256).Hash -cne $transitiveStaleRegistryHash) {
        throw ('compare bypassed a stale transitive pilot gate after the first downstream rejection: capture=' +
            (Get-Content -LiteralPath $transitiveStaleCompareCapture -Raw) + ' pilotStatus=' + [string]$transitiveStalePilotAfterCompare.status +
            ' admitStatus=' + [string]$transitiveStaleAdmitAfterCompare.status + ' compareStatus=' + [string]$transitiveStaleCompareAfterCompare.status +
            ' dispatched=' + (Test-Path -LiteralPath $transitiveStaleCompareMarker))
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=stale-transitive-pilot-blocks-later-comparison'

    $transitiveStaleAdmissionPackageFolder = Join-Path $testRoot 'transitive-stale-admission-package'
    New-Item -ItemType Directory -Path $transitiveStaleAdmissionPackageFolder -Force | Out-Null
    $transitiveStaleAdmissionManifest = New-TestManifest
    $transitiveStaleAdmissionManifest.resourceBudget.maxUE = 5000
    $transitiveStaleAdmissionManifest.resourceStatus = 'measured-and-target-reviewed'
    Add-TestPackageInputs $transitiveStaleAdmissionPackageFolder $transitiveStaleAdmissionManifest
    Write-TestStageState $transitiveStaleAdmissionPackageFolder $transitiveStaleAdmissionManifest
    Set-TestStageComplete $transitiveStaleAdmissionPackageFolder 'validate'
    Complete-TestPilotThroughRunner $transitiveStaleAdmissionPackageFolder $runner `
        (Join-Path $testRoot 'transitive-stale-admission-pilot-calls.txt') (Join-Path $testRoot 'transitive-stale-admission-pilot-capture.txt')
    foreach ($name in @('data','assemble','train','freeze','evaluate')) {
        Set-TestStageComplete $transitiveStaleAdmissionPackageFolder $name
    }
    $transitiveStaleAdmissionReviewPath = Complete-TestAdmissionThroughRunner $transitiveStaleAdmissionPackageFolder $runner `
        (Join-Path $testRoot 'transitive-stale-admission-admit-calls.txt') (Join-Path $testRoot 'transitive-stale-admission-admit-capture.txt')
    $transitiveStaleAdmissionStatePath = Join-Path $transitiveStaleAdmissionPackageFolder 'stages.json'
    $transitiveStaleAdmissionState = Get-Content -LiteralPath $transitiveStaleAdmissionStatePath -Raw | ConvertFrom-Json
    Set-TestComparisonScenario $transitiveStaleAdmissionState
    $transitiveStaleAdmissionState | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $transitiveStaleAdmissionStatePath -Encoding UTF8
    $transitiveStaleAdmissionCompareMarker = Join-Path $testRoot 'transitive-stale-admission-compare-calls.txt'
    $transitiveStaleAdmissionCompareCapture = Join-Path $testRoot 'transitive-stale-admission-compare-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $transitiveStaleAdmissionCompareMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    & $runner -PackageFolder $transitiveStaleAdmissionPackageFolder -Stage compare `
        -ExecutionProfile external-machine -Execute *> $transitiveStaleAdmissionCompareCapture
    if (-not (Select-String -LiteralPath $transitiveStaleAdmissionCompareCapture -Pattern '^EXTERNAL_STAGE_COMPLETE=compare$') -or
        -not (Test-Path -LiteralPath $transitiveStaleAdmissionCompareMarker)) {
        throw 'the process-only comparison fixture did not complete before admission invalidation'
    }
    $transitiveStaleAdmissionReview = Get-Content -LiteralPath $transitiveStaleAdmissionReviewPath -Raw | ConvertFrom-Json
    $transitiveStaleAdmissionReview.decision = 'rejected'
    $transitiveStaleAdmissionReview | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $transitiveStaleAdmissionReviewPath -Encoding UTF8
    $transitiveStaleAdmissionRunId = [string]$transitiveStaleAdmissionState.runId
    $transitiveStaleAdmissionRegistryPath = Join-Path $transitiveStaleAdmissionPackageFolder 'project\experiments\realizationRegistry.json'
    $transitiveStaleAdmissionRegistryHash = (Get-FileHash -LiteralPath $transitiveStaleAdmissionRegistryPath -Algorithm SHA256).Hash
    $transitiveStaleAdmissionInvalidateFailed = $false
    try {
        & $runner -PackageFolder $transitiveStaleAdmissionPackageFolder -Stage compare `
            -ExecutionProfile external-machine -Execute *> $transitiveStaleAdmissionCompareCapture
    }
    catch { $transitiveStaleAdmissionInvalidateFailed = $true }
    $transitiveStaleAdmissionAfterInvalidate = Get-Content -LiteralPath $transitiveStaleAdmissionStatePath -Raw | ConvertFrom-Json
    $transitiveStaleAdmissionGateAfterInvalidate = @($transitiveStaleAdmissionAfterInvalidate.stages | Where-Object { $_.name -eq 'admit' })[0]
    $transitiveStaleAdmissionCompareAfterInvalidate = @($transitiveStaleAdmissionAfterInvalidate.stages | Where-Object { $_.name -eq 'compare' })[0]
    if (-not $transitiveStaleAdmissionInvalidateFailed -or
        -not (Select-String -LiteralPath $transitiveStaleAdmissionCompareCapture -Pattern '^EXTERNAL_STAGE_STALE=admit$') -or
        [string]$transitiveStaleAdmissionGateAfterInvalidate.status -cne 'stale' -or
        [string]$transitiveStaleAdmissionCompareAfterInvalidate.status -cne 'completed') {
        throw ('changed admission review did not stale only the human gate: capture=' +
            (Get-Content -LiteralPath $transitiveStaleAdmissionCompareCapture -Raw) + ' admitStatus=' +
            [string]$transitiveStaleAdmissionGateAfterInvalidate.status + ' compareStatus=' +
            [string]$transitiveStaleAdmissionCompareAfterInvalidate.status)
    }
    $transitiveStaleSummaryMarker = Join-Path $testRoot 'transitive-stale-admission-summary-calls.txt'
    $transitiveStaleSummaryCapture = Join-Path $testRoot 'transitive-stale-admission-summary-capture.txt'
    $transitiveStaleSummaryFailed = $false
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $transitiveStaleSummaryMarker
    try {
        & $runner -PackageFolder $transitiveStaleAdmissionPackageFolder -Stage summarize `
            -ExecutionProfile external-machine -Execute *> $transitiveStaleSummaryCapture
    }
    catch { $transitiveStaleSummaryFailed = $true }
    $transitiveStaleAdmissionAfterSummary = Get-Content -LiteralPath $transitiveStaleAdmissionStatePath -Raw | ConvertFrom-Json
    $transitiveStaleAdmissionGateAfterSummary = @($transitiveStaleAdmissionAfterSummary.stages | Where-Object { $_.name -eq 'admit' })[0]
    $transitiveStaleAdmissionCompareAfterSummary = @($transitiveStaleAdmissionAfterSummary.stages | Where-Object { $_.name -eq 'compare' })[0]
    $transitiveStaleSummaryAfterSummary = @($transitiveStaleAdmissionAfterSummary.stages | Where-Object { $_.name -eq 'summarize' })[0]
    if (-not $transitiveStaleSummaryFailed -or
        -not (Select-String -LiteralPath $transitiveStaleSummaryCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=dependency-stale$') -or
        [string]$transitiveStaleAdmissionGateAfterSummary.status -cne 'stale' -or
        [string]$transitiveStaleAdmissionCompareAfterSummary.status -cne 'completed' -or
        [string]$transitiveStaleSummaryAfterSummary.status -cne 'not-started' -or
        (Test-Path -LiteralPath $transitiveStaleSummaryMarker) -or
        (Test-Path -LiteralPath (Join-Path $transitiveStaleAdmissionPackageFolder 'stage-results\summarize')) -or
        [string]$transitiveStaleAdmissionAfterSummary.runId -cne $transitiveStaleAdmissionRunId -or
        (Get-FileHash -LiteralPath $transitiveStaleAdmissionRegistryPath -Algorithm SHA256).Hash -cne $transitiveStaleAdmissionRegistryHash) {
        throw ('summarize bypassed a stale transitive admission gate: capture=' +
            (Get-Content -LiteralPath $transitiveStaleSummaryCapture -Raw) + ' admitStatus=' +
            [string]$transitiveStaleAdmissionGateAfterSummary.status + ' compareStatus=' +
            [string]$transitiveStaleAdmissionCompareAfterSummary.status + ' summarizeStatus=' +
            [string]$transitiveStaleSummaryAfterSummary.status + ' dispatched=' + (Test-Path -LiteralPath $transitiveStaleSummaryMarker))
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=stale-transitive-admission-blocks-later-summary'

    $admissionDependencyPackageFolder = Join-Path $testRoot 'dependent-admission-review-package'
    New-Item -ItemType Directory -Path $admissionDependencyPackageFolder -Force | Out-Null
    $admissionDependencyManifest = New-TestManifest
    $admissionDependencyManifest.resourceBudget.maxUE = 5000
    $admissionDependencyManifest.resourceStatus = 'measured-and-target-reviewed'
    Add-TestPackageInputs $admissionDependencyPackageFolder $admissionDependencyManifest
    Write-TestStageState $admissionDependencyPackageFolder $admissionDependencyManifest
    Set-TestStageComplete $admissionDependencyPackageFolder 'validate'
    Complete-TestPilotThroughRunner $admissionDependencyPackageFolder $runner `
        (Join-Path $testRoot 'dependent-admission-pilot-calls.txt') (Join-Path $testRoot 'dependent-admission-pilot-capture.txt')
    foreach ($name in @('data','assemble','train','freeze','evaluate')) {
        Set-TestStageComplete $admissionDependencyPackageFolder $name
    }
    $admissionDependencyReviewPath = Complete-TestAdmissionThroughRunner $admissionDependencyPackageFolder $runner `
        (Join-Path $testRoot 'dependent-admission-calls.txt') (Join-Path $testRoot 'dependent-admission-capture.txt')
    $admissionDependencyStatePath = Join-Path $admissionDependencyPackageFolder 'stages.json'
    $admissionDependencyState = Get-Content -LiteralPath $admissionDependencyStatePath -Raw | ConvertFrom-Json
    Set-TestComparisonScenario $admissionDependencyState
    $admissionDependencyState | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $admissionDependencyStatePath -Encoding UTF8
    $admissionDependencyReview = Get-Content -LiteralPath $admissionDependencyReviewPath -Raw | ConvertFrom-Json
    $admissionDependencyReview.decision = 'rejected'
    $admissionDependencyReview | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $admissionDependencyReviewPath -Encoding UTF8
    $admissionDependencyStateBefore = Get-Content -LiteralPath $admissionDependencyStatePath -Raw | ConvertFrom-Json
    $admissionDependencyRunId = [string]$admissionDependencyStateBefore.runId
    $admissionDependencyRegistryPath = Join-Path $admissionDependencyPackageFolder 'project\experiments\realizationRegistry.json'
    $admissionDependencyRegistryHash = (Get-FileHash -LiteralPath $admissionDependencyRegistryPath -Algorithm SHA256).Hash
    $dependentCompareMarker = Join-Path $testRoot 'dependent-compare-calls.txt'
    $dependentCompareCapture = Join-Path $testRoot 'dependent-compare-capture.txt'
    $dependentCompareFailed = $false
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $dependentCompareMarker
    try {
        & $runner -PackageFolder $admissionDependencyPackageFolder -Stage compare `
            -ExecutionProfile external-machine -Execute *> $dependentCompareCapture
    }
    catch { $dependentCompareFailed = $true }
    $admissionDependencyStateAfter = Get-Content -LiteralPath $admissionDependencyStatePath -Raw | ConvertFrom-Json
    $admissionDependencyEntryAfter = @($admissionDependencyStateAfter.stages | Where-Object { $_.name -eq 'admit' })[0]
    $compareDependencyEntryAfter = @($admissionDependencyStateAfter.stages | Where-Object { $_.name -eq 'compare' })[0]
    if (-not $dependentCompareFailed -or
        -not (Select-String -LiteralPath $dependentCompareCapture -Pattern '^EXTERNAL_STAGE_STALE=admit$') -or
        [string]$admissionDependencyEntryAfter.status -cne 'stale' -or
        [string]$compareDependencyEntryAfter.status -cne 'not-started' -or
        (Test-Path -LiteralPath $dependentCompareMarker) -or
        (Test-Path -LiteralPath (Join-Path $admissionDependencyPackageFolder 'stage-results\compare')) -or
        [string]$admissionDependencyStateAfter.runId -cne $admissionDependencyRunId -or
        (Get-FileHash -LiteralPath $admissionDependencyRegistryPath -Algorithm SHA256).Hash -cne $admissionDependencyRegistryHash) {
        throw ('comparison did not fail closed after its admission review was rejected: capture=' +
            (Get-Content -LiteralPath $dependentCompareCapture -Raw) + ' admitStatus=' + [string]$admissionDependencyEntryAfter.status +
            ' compareStatus=' + [string]$compareDependencyEntryAfter.status + ' dispatched=' + (Test-Path -LiteralPath $dependentCompareMarker))
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=rejected-admission-review-invalidates-downstream-comparison'

    $matrixMismatchPackageFolder = Join-Path $testRoot 'comparison-options-mismatch-package'
    New-Item -ItemType Directory -Path $matrixMismatchPackageFolder -Force | Out-Null
    $matrixMismatchManifest = New-TestManifest
    $matrixMismatchManifest.resourceBudget.maxUE = 5000
    $matrixMismatchManifest.resourceStatus = 'measured-and-target-reviewed'
    Add-TestPackageInputs $matrixMismatchPackageFolder $matrixMismatchManifest
    Write-TestStageState $matrixMismatchPackageFolder $matrixMismatchManifest
    Set-TestStageComplete $matrixMismatchPackageFolder 'validate'
    Complete-TestPilotThroughRunner $matrixMismatchPackageFolder $runner `
        (Join-Path $testRoot 'matrix-mismatch-pilot-calls.txt') (Join-Path $testRoot 'matrix-mismatch-pilot-capture.txt')
    foreach ($name in @('data','assemble','train','freeze','evaluate')) {
        Set-TestStageComplete $matrixMismatchPackageFolder $name
    }
    Complete-TestAdmissionThroughRunner $matrixMismatchPackageFolder $runner `
        (Join-Path $testRoot 'matrix-mismatch-admit-calls.txt') (Join-Path $testRoot 'matrix-mismatch-admit-capture.txt') | Out-Null
    $matrixMismatchStatePath = Join-Path $matrixMismatchPackageFolder 'stages.json'
    $matrixMismatchState = Get-Content -LiteralPath $matrixMismatchStatePath -Raw | ConvertFrom-Json
    $matrixMismatchCompare = @($matrixMismatchState.stages | Where-Object { $_.name -eq 'compare' })[0]
    $matrixMismatchCompare.configuration = [ordered]@{
        scenarioMatrix = @(
            [ordered]@{ method = 'Static'; numUE = 100; durationTicks = 5000; burstDurationTicks = 50; realizationId = 1800; scenarioIdentity = 'scenario-a' },
            [ordered]@{ method = 'Adaptive-P'; numUE = 100; durationTicks = 5000; burstDurationTicks = 50; realizationId = 1800; scenarioIdentity = 'scenario-a' }
        )
        comparisonOptions = [ordered]@{
            counts = @(200)
            burstDurations = @(50)
            methods = @('Static','Adaptive-P')
            realizationIds = @(1800)
            config = [ordered]@{ simulation = [ordered]@{ durationTicks = 5000 } }
        }
    }
    $matrixMismatchState | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $matrixMismatchStatePath -Encoding UTF8
    $matrixMismatchMarker = Join-Path $testRoot 'comparison-options-mismatch-calls.txt'
    $matrixMismatchCapture = Join-Path $testRoot 'comparison-options-mismatch-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $matrixMismatchMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'missing-marker'
    $matrixMismatchFailed = $false
    try {
        & $runner -PackageFolder $matrixMismatchPackageFolder -Stage compare -ExecutionProfile external-machine -Execute *> $matrixMismatchCapture
    }
    catch { $matrixMismatchFailed = $true }
    if (-not $matrixMismatchFailed -or
        -not (Select-String -LiteralPath $matrixMismatchCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=comparison-scenario-options-mismatch$') -or
        (Test-Path -LiteralPath $matrixMismatchMarker)) {
        throw 'a comparison scenario matrix that disagreed with the executed sweep options reached the runner'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=comparison-options-must-match-scenario-identity'

    $pilot5000PackageFolder = Join-Path $testRoot 'pilot-5000-approval-required-package'
    New-Item -ItemType Directory -Path $pilot5000PackageFolder -Force | Out-Null
    $pilot5000Manifest = New-TestManifest
    $pilot5000Manifest.resourceBudget.maxUE = 5000
    $pilot5000Manifest.resourceStatus = 'target-reviewed'
    Add-TestPackageInputs $pilot5000PackageFolder $pilot5000Manifest
    Write-TestStageState $pilot5000PackageFolder $pilot5000Manifest
    Set-TestStageComplete $pilot5000PackageFolder 'validate'
    Write-TestSupervisor $pilot5000PackageFolder
    $pilot5000RegistryPath = Join-Path $pilot5000PackageFolder 'project\experiments\realizationRegistry.json'
    $pilot5000RegistryHash = (Get-FileHash -LiteralPath $pilot5000RegistryPath -Algorithm SHA256).Hash
    $pilot5000Marker = Join-Path $testRoot 'pilot-5000-without-approval-calls.txt'
    $pilot5000Capture = Join-Path $testRoot 'pilot-5000-without-approval-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $pilot5000Marker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'missing-marker'
    $pilot5000Failed = $false
    $pilot5000Exception = ''
    try {
        & $runner -PackageFolder $pilot5000PackageFolder -Stage pilot -ExecutionProfile external-machine -Execute *> $pilot5000Capture
    }
    catch {
        $pilot5000Failed = $true
        $pilot5000Exception = $_.Exception.Message
    }
    $pilot5000ApprovalBlock = Select-String -LiteralPath $pilot5000Capture -Pattern '^EXTERNAL_STAGE_BLOCKED=pilot-5000-professor-approval-required$'
    if (-not $pilot5000Failed -or
        -not $pilot5000ApprovalBlock -or
        (Test-Path -LiteralPath $pilot5000Marker) -or
        (Get-FileHash -LiteralPath $pilot5000RegistryPath -Algorithm SHA256).Hash -ne $pilot5000RegistryHash) {
        $pilot5000Output = @(Get-Content -LiteralPath $pilot5000Capture | Select-Object -First 8) -join ' | '
        $pilot5000State = Get-Content -LiteralPath (Join-Path $pilot5000PackageFolder 'stages.json') -Raw | ConvertFrom-Json
        $pilot5000Status = [string](@($pilot5000State.stages | Where-Object { $_.name -eq 'pilot' })[0].status)
        throw "the 5000 UE pilot was not blocked by its separate approval gate; failed=$pilot5000Failed, runnerMarker=$(Test-Path -LiteralPath $pilot5000Marker), pilotState=$pilot5000Status, exception=$pilot5000Exception, captured output: $pilot5000Output"
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=pilot-5000-requires-separate-professor-approval'

    $codeManifestPackageFolder = Join-Path $testRoot 'pilot-5000-code-manifest-package'
    New-Item -ItemType Directory -Path $codeManifestPackageFolder -Force | Out-Null
    $codeProbeRelativePath = 'verification/external/pilotScopeProbe.m'
    $codeProbePackagePath = 'project/' + $codeProbeRelativePath
    $codeProbePath = Join-Path $codeManifestPackageFolder ($codeProbePackagePath -replace '/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $codeProbePath) -Force | Out-Null
    [IO.File]::WriteAllText($codeProbePath, 'approved pilot code', [Text.UTF8Encoding]::new($false))
    $codeProbeHash = (Get-FileHash -LiteralPath $codeProbePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $codeManifestManifest = New-TestManifest
    $codeManifestManifest.resourceBudget.maxUE = 5000
    $codeManifestManifest.resourceStatus = 'target-reviewed'
    $codeManifestManifest.codeFiles = @([ordered]@{
        path = $codeProbeRelativePath
        sha256 = $codeProbeHash
        packagePath = $codeProbePackagePath
        packageSha256 = $codeProbeHash
        sanitized = $false
    })
    Add-TestPackageInputs $codeManifestPackageFolder $codeManifestManifest
    Write-TestStageState $codeManifestPackageFolder $codeManifestManifest
    Set-TestStageComplete $codeManifestPackageFolder 'validate'
    Write-TestSupervisor $codeManifestPackageFolder
    Set-TestPilotApproval $codeManifestPackageFolder $runner
    $codeManifestBeforeTamper = Get-Content -LiteralPath (Join-Path $codeManifestPackageFolder 'manifest.json') -Raw | ConvertFrom-Json
    $codeManifestDeclaredDigest = [string]$codeManifestBeforeTamper.codeManifestSha256
    [IO.File]::WriteAllText($codeProbePath, 'modified pilot code', [Text.UTF8Encoding]::new($false))
    $codeProbeUpdatedHash = (Get-FileHash -LiteralPath $codeProbePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $codeManifestAfterTamper = Get-Content -LiteralPath (Join-Path $codeManifestPackageFolder 'manifest.json') -Raw | ConvertFrom-Json
    $codeManifestAfterTamper.codeFiles[0].packageSha256 = $codeProbeUpdatedHash
    $codeManifestAfterTamper | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $codeManifestPackageFolder 'manifest.json') -Encoding UTF8
    $declaredDigestAfterTamper = [string](Get-Content -LiteralPath (Join-Path $codeManifestPackageFolder 'manifest.json') -Raw | ConvertFrom-Json | ForEach-Object { $_.codeManifestSha256 })
    if ($declaredDigestAfterTamper -cne $codeManifestDeclaredDigest) {
        throw 'the code manifest fixture did not retain its pre-approval aggregate digest after the package file hash changed'
    }
    $codeManifestRegistryPath = Join-Path $codeManifestPackageFolder 'project\experiments\realizationRegistry.json'
    $codeManifestRegistryHash = (Get-FileHash -LiteralPath $codeManifestRegistryPath -Algorithm SHA256).Hash
    $codeManifestStatePath = Join-Path $codeManifestPackageFolder 'stages.json'
    $codeManifestStateHash = (Get-FileHash -LiteralPath $codeManifestStatePath -Algorithm SHA256).Hash
    $codeManifestMarker = Join-Path $testRoot 'pilot-5000-code-manifest-dispatch.marker'
    $codeManifestCapture = Join-Path $testRoot 'pilot-5000-code-manifest-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $codeManifestMarker
    $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = 'complete'
    $codeManifestInvocationFailed = $false
    try {
        & $runner -PackageFolder $codeManifestPackageFolder -Stage pilot `
            -ExecutionProfile external-machine -Execute *> $codeManifestCapture
    }
    catch { $codeManifestInvocationFailed = $true }
    if (-not $codeManifestInvocationFailed -or
        -not (Select-String -LiteralPath $codeManifestCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=package-source-manifest-digest-mismatch$') -or
        (Test-Path -LiteralPath $codeManifestMarker) -or
        (Get-FileHash -LiteralPath $codeManifestRegistryPath -Algorithm SHA256).Hash -ne $codeManifestRegistryHash -or
        (Get-FileHash -LiteralPath $codeManifestStatePath -Algorithm SHA256).Hash -ne $codeManifestStateHash) {
        throw 'a 5000 UE approval remained usable after code bytes and per-file package hash changed without refreshing the aggregate digest'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=pilot-5000-recomputes-packaged-code-manifest-digest'

    $pilot5000ScopePackageFolder = Join-Path $testRoot 'pilot-5000-approval-scope-package'
    New-Item -ItemType Directory -Path $pilot5000ScopePackageFolder -Force | Out-Null
    $pilot5000ScopeManifest = New-TestManifest
    $pilot5000ScopeManifest.resourceBudget.maxUE = 5000
    $pilot5000ScopeManifest.resourceStatus = 'target-reviewed'
    Add-TestPackageInputs $pilot5000ScopePackageFolder $pilot5000ScopeManifest
    Write-TestStageState $pilot5000ScopePackageFolder $pilot5000ScopeManifest
    Set-TestStageComplete $pilot5000ScopePackageFolder 'validate'
    Write-TestSupervisor $pilot5000ScopePackageFolder
    Set-TestPilotApproval $pilot5000ScopePackageFolder $runner
    $pilot5000ScopeManifestAfterApproval = Get-Content -LiteralPath (Join-Path $pilot5000ScopePackageFolder 'manifest.json') -Raw | ConvertFrom-Json
    $pilot5000ScopeManifestAfterApproval.resourceBudget.availableMemoryBytes = 2147483648
    $pilot5000ScopeManifestAfterApproval | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $pilot5000ScopePackageFolder 'manifest.json') -Encoding UTF8
    $pilot5000ScopeRegistryPath = Join-Path $pilot5000ScopePackageFolder 'project\experiments\realizationRegistry.json'
    $pilot5000ScopeRegistryHash = (Get-FileHash -LiteralPath $pilot5000ScopeRegistryPath -Algorithm SHA256).Hash
    $pilot5000ScopeMarker = Join-Path $testRoot 'pilot-5000-wrong-scope-calls.txt'
    $pilot5000ScopeCapture = Join-Path $testRoot 'pilot-5000-wrong-scope-capture.txt'
    $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $pilot5000ScopeMarker
    $pilot5000ScopeFailed = $false
    try {
        & $runner -PackageFolder $pilot5000ScopePackageFolder -Stage pilot -ExecutionProfile external-machine -Execute *> $pilot5000ScopeCapture
    }
    catch { $pilot5000ScopeFailed = $true }
    if (-not $pilot5000ScopeFailed -or
        -not (Select-String -LiteralPath $pilot5000ScopeCapture -Pattern '^EXTERNAL_STAGE_BLOCKED=pilot-5000-approval-scope-mismatch$') -or
        (Test-Path -LiteralPath $pilot5000ScopeMarker) -or
        (Get-FileHash -LiteralPath $pilot5000ScopeRegistryPath -Algorithm SHA256).Hash -ne $pilot5000ScopeRegistryHash) {
        throw 'a pilot approval for different code/resource limits was not blocked before launch'
    }
    Write-Output 'EXTERNAL_STAGE_TEST_PASS=pilot-5000-approval-binds-code-and-resource-scope'
}
catch {
    $failed = $_.Exception.Message -replace '[\r\n]+', ' '
}
finally {
    $env:PATH = $originalPath
    if ($null -eq $originalMarker) {
        Remove-Item Env:NBIOT_EXTERNAL_STAGE_STUB_MARKER -ErrorAction SilentlyContinue
    }
    else {
        $env:NBIOT_EXTERNAL_STAGE_STUB_MARKER = $originalMarker
    }
    if ($null -eq $originalMode) {
        Remove-Item Env:NBIOT_EXTERNAL_STAGE_STUB_MODE -ErrorAction SilentlyContinue
    }
    else {
        $env:NBIOT_EXTERNAL_STAGE_STUB_MODE = $originalMode
    }
    if ($null -eq $originalMutateRegistry) {
        Remove-Item Env:NBIOT_EXTERNAL_STAGE_STUB_MUTATE_REGISTRY -ErrorAction SilentlyContinue
    }
    else {
        $env:NBIOT_EXTERNAL_STAGE_STUB_MUTATE_REGISTRY = $originalMutateRegistry
    }
    if ($null -eq $originalNoSample) {
        Remove-Item Env:NBIOT_EXTERNAL_STAGE_STUB_NO_SAMPLE -ErrorAction SilentlyContinue
    }
    else {
        $env:NBIOT_EXTERNAL_STAGE_STUB_NO_SAMPLE = $originalNoSample
    }
    if ($null -eq $originalProcessCount) {
        Remove-Item Env:NBIOT_EXTERNAL_STAGE_STUB_PROCESS_COUNT -ErrorAction SilentlyContinue
    }
    else {
        $env:NBIOT_EXTERNAL_STAGE_STUB_PROCESS_COUNT = $originalProcessCount
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot -ErrorAction Stop).Path
        if (-not [string]::Equals($resolvedTestRoot, $testRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not $resolvedTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to remove a test directory outside the system temp folder.'
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($null -ne $failed) {
    Write-TestFailure $failed
    exit 1
}
Write-Output 'EXTERNAL_STAGE_TEST_PASS=default-inspect-no-execute'
