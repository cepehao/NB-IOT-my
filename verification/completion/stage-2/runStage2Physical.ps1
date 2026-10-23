[CmdletBinding()]
param(
    [string]$MatlabCommand = 'matlab',
    [ValidateSet('local-development','external-machine','scheduled-local')][string]$ExecutionProfile = 'local-development',
    [double]$MaxCaseSeconds = 57600,
    [double]$MaxSuiteSeconds = 57600,
    [switch]$TargetedOnly,
    [switch]$Resume,
    [string]$RunFolder = '',
    [string]$TargetedLog = ''
)
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic([string]$Path,[object]$Value) {
    $temporary="$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-Json([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-ProcessIdentity([int]$ProcessId,[string]$StartTimeUtc,[string]$ExpectedCommand) {
    if ($ProcessId -le 0) { return $false }
    $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        if ([Math]::Abs(($process.StartTime.ToUniversalTime()-[DateTime]::Parse($StartTimeUtc).ToUniversalTime()).TotalSeconds) -gt 0.05) { return $false }
    } catch { return $false }
    $wmi=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $wmi -or [string]::IsNullOrWhiteSpace([string]$wmi.CommandLine) -or [string]::IsNullOrWhiteSpace($ExpectedCommand)) { return $false }
    return [string]::Equals([string]$wmi.CommandLine,$ExpectedCommand,[StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoMatlabSession {
    if (@(Get-Process -Name 'MATLAB*' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Закройте другие MATLAB-сеансы перед проверкой Stage 2, чтобы не запустить второй расчёт.'
    }
}

function Assert-TargetedLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Нет свежего журнала Stage 2: $Path" }
    $content=Get-Content -LiteralPath $Path -Raw
    if ($content -notmatch 'MATLAB_VERSION=.*RELEASE=2025b' -or
        $content -notmatch 'LTE_TOOLBOX version=.+?' -or
        $content -notmatch 'STAGE2_TARGETED total=38 passed=38 failed=0 incomplete=0') {
        throw 'Stage 2 не запущен: журнал должен подтверждать MATLAB R2025b, LTE Toolbox и 38/38 успешных targeted-проверок.'
    }
}

$caseCount = 232
$scheduledSeed = 43
if ($Resume -and $ExecutionProfile -eq 'local-development') { $ExecutionProfile='scheduled-local' }
if ([double]::IsInfinity($MaxCaseSeconds) -or [double]::IsNaN($MaxCaseSeconds) -or
    [double]::IsInfinity($MaxSuiteSeconds) -or [double]::IsNaN($MaxSuiteSeconds)) {
    throw 'ExecutionBudget: Stage 2 limits must be finite. No MATLAB process was started.'
}
if ($TargetedOnly -and ($Resume -or $RunFolder -ne '' -or $TargetedLog -ne '')) {
    throw 'Для -TargetedOnly нельзя указывать -Resume, -RunFolder или -TargetedLog.'
}
if ($Resume -and ($ExecutionProfile -ne 'scheduled-local' -or $RunFolder -eq '')) {
    throw 'Resume Stage 2 доступен в профиле scheduled-local: укажите -Resume -RunFolder <absolute path>.'
}
if (-not $Resume -and $RunFolder -ne '') { throw '-RunFolder допустим только вместе с -Resume.' }
if (-not $TargetedOnly -and -not $Resume -and $TargetedLog -eq '') {
    throw 'Перед физическим Stage 2 запустите -TargetedOnly и передайте -TargetedLog <путь к его журналу>.'
}
if ($TargetedOnly) {
    if ($ExecutionProfile -notin @('local-development','scheduled-local')) { throw 'Targeted-only check must run locally.' }
} elseif ($ExecutionProfile -eq 'scheduled-local') {
    if ($MaxCaseSeconds -le 0 -or $MaxCaseSeconds -gt 57600 -or
        $MaxSuiteSeconds -le 0 -or $MaxSuiteSeconds -gt 57600) {
        throw 'ExecutionBudget: scheduled-local Stage 2 requires explicit limits up to 57600 seconds. No MATLAB process was started.'
    }
} elseif (-not $Resume -and ($ExecutionProfile -ne 'external-machine' -or
    $MaxCaseSeconds -le 0 -or $MaxSuiteSeconds -lt ($caseCount * $MaxCaseSeconds) -or
    $MaxSuiteSeconds -gt 864000)) {
    throw 'ExecutionBudget: fresh Stage 2 physical validation requires explicit finite external-machine limits for all 232 cases. No MATLAB process was started.'
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$stageFolder = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$executable = (Get-Command $MatlabCommand -ErrorAction Stop).Source
$matlabRoot = $projectRoot.Replace('\','/').Replace("'","''")
$ledgerFile = Join-Path $stageFolder 'budget-ledger.json'

if ($TargetedOnly) {
    Assert-NoMatlabSession
    $targetRoot=Join-Path $stageFolder ('targeted-run-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $processFolder=Join-Path $targetRoot 'process'
    New-Item -ItemType Directory -Path $targetRoot | Out-Null
    $batch="cd('$matlabRoot'); addpath('$matlabRoot'); setupProject(); addpath('verification/completion/stage-2'); stage2Targeted();"
    . (Join-Path $projectRoot 'verification\local\InvokeBoundedProcess.ps1')
    $check=Invoke-BoundedProcess -Executable $executable -Arguments ('-batch "'+$batch+'"') `
        -WorkingDirectory $projectRoot -OutputFolder $processFolder -TimeoutSeconds 900
    $targetLogPath=Join-Path $targetRoot 'stage2-targeted.log'
    if (Test-Path -LiteralPath $check.stdout -PathType Leaf) { Copy-Item -LiteralPath $check.stdout -Destination $targetLogPath }
    else { [IO.File]::WriteAllText($targetLogPath,'',[Text.UTF8Encoding]::new($false)) }
    $targetRun=[ordered]@{
        status=$check.status
        exitCode=$check.exitCode
        elapsedSeconds=$check.elapsedSeconds
        targetedLog=$targetLogPath
        processFolder=$processFolder
        matlabCommand=$executable
        scope='stage-2-targeted'
        expected='MATLAB R2025b, LTE Toolbox, 38/38 passed'
        finishedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic (Join-Path $targetRoot 'targeted-run.json') $targetRun
    if ($check.exitCode -ne 0) { throw "Stage 2 targeted checks failed or exceeded 900 seconds; see $targetLogPath and $($check.stderr)." }
    Assert-TargetedLog $targetLogPath
    Write-Output "STAGE2_TARGETED_LOG=$targetLogPath"
    Write-Output "STAGE2_TARGETED_STATUS=$($check.status)"
    return
}

$runRoot=''
$physicalFolder=''
$history=@()
$targetedPath=''
$previousWorker=$null
if ($Resume) {
    if (-not [IO.Path]::IsPathFullyQualified($RunFolder)) { throw '-RunFolder должен содержать абсолютный путь.' }
    $runRoot=(Resolve-Path -LiteralPath $RunFolder).Path
    $hostRunPath=Join-Path $runRoot 'stage2-host-run.json'
    if (-not (Test-Path -LiteralPath $hostRunPath -PathType Leaf)) { throw "Нет Stage 2 run manifest: $hostRunPath" }
    $previous=Read-Json $hostRunPath
    if ($previous.executionProfile -ne 'scheduled-local') { throw 'Resume допустим только для scheduled-local run.' }
    if ($null -eq $previous.realizationSeed -or [double]$previous.realizationSeed -ne $scheduledSeed) {
        throw 'Resume остановлен: seed физической матрицы отличается от записанного в host-run manifest.'
    }
    $physicalFolder=[string]$previous.physicalRunFolder
    $targetedPath=[string]$previous.targetedLog
    if (-not (Test-Path -LiteralPath $physicalFolder -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $physicalFolder 'progress.json') -PathType Leaf)) {
        throw 'Resume требует исходную папку физических данных и progress.json.'
    }
    Assert-TargetedLog $targetedPath
    $previousWorker=$previous.worker
    if ($null -ne $previousWorker) {
        $workerAlive=Test-ProcessIdentity ([int]$previousWorker.workerProcessId) `
            ([string]$previousWorker.workerProcessStartTimeUtc) ([string]$previousWorker.workerCommandLine)
        $matlabAlive=Test-ProcessIdentity ([int]$previousWorker.matlabProcessId) `
            ([string]$previousWorker.matlabProcessStartTimeUtc) ([string]$previousWorker.matlabCommandLine)
        if ($workerAlive -or $matlabAlive) {
            throw "Resume остановлен: старый MATLAB расчёт ещё работает (worker PID=$($previousWorker.workerProcessId), MATLAB PID=$($previousWorker.matlabProcessId))."
        }
        if (Test-Path -LiteralPath ([string]$previousWorker.processReport) -PathType Leaf) {
            $processReport=Read-Json ([string]$previousWorker.processReport)
            $previousWorker.status=[string]$processReport.status
            $previousWorker.exitCode=[int]$processReport.exitCode
            $previousWorker.elapsedSeconds=[double]$processReport.elapsedSeconds
            $previousWorker.settledAtUtc=[DateTime]::UtcNow.ToString('o')
        }
        $history=@($previous.history)
        if ($null -eq $history) { $history=@() }
        $history+=,[pscustomobject]@{
            runId=$previousWorker.runId
            workerProcessId=$previousWorker.workerProcessId
            matlabProcessId=$previousWorker.matlabProcessId
            status=$previousWorker.status
            elapsedSeconds=$previousWorker.elapsedSeconds
            processReport=$previousWorker.processReport
            settledAtUtc=$previousWorker.settledAtUtc
        }
    }
    $oldProgress=Read-Json (Join-Path $physicalFolder 'progress.json')
    if ($oldProgress.status -eq 'completed' -and
        (Test-Path -LiteralPath (Join-Path $physicalFolder 'stage2-report.mat') -PathType Leaf)) {
        $previous.status='physical-completed'
        $previous.history=$history
        $previous.worker=$previousWorker
        $previous.updatedAtUtc=[DateTime]::UtcNow.ToString('o')
        Write-JsonAtomic $hostRunPath $previous
        [pscustomobject]@{status='physical-completed';runFolder=$runRoot;physicalRunFolder=$physicalFolder;workerStarted=$false}
        return
    }
} else {
    Assert-TargetedLog $TargetedLog
    $targetedPath=(Resolve-Path -LiteralPath $TargetedLog).Path
    $runRoot=Join-Path $stageFolder ('host-run-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $physicalFolder=Join-Path $runRoot 'physical-evidence'
}

if (@(Get-Process -Name 'MATLAB*' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close other MATLAB sessions before Stage 2 physical validation so the process budget stays isolated.'
}
if ($ExecutionProfile -eq 'scheduled-local') {
    if (-not $Resume -and -not (Test-Path -LiteralPath $ledgerFile -PathType Leaf)) {
        $null=New-Item -ItemType Directory -Path $stageFolder -Force
    }
    $caseLimit=$MaxCaseSeconds.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
    $suiteLimit=$MaxSuiteSeconds.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
    $physicalM=$physicalFolder.Replace('\','/').Replace("'","''")
    $ledgerM=$ledgerFile.Replace('\','/').Replace("'","''")
    $resumeValue=if($Resume){'true'}else{'false'}
    $batchCommand="cd('$matlabRoot'); addpath('$matlabRoot'); setupProject(); addpath('verification/completion/stage-2'); ledger=nbiot.experiments.loadVariant2BudgetLedger('$ledgerM',true); execution=struct('profile','scheduled-local','role','stage-2-collision-diagnostics','maxUE',10,'maxCaseSeconds',$caseLimit,'maxSuiteSeconds',$suiteLimit,'timePolicy','finish-current'); runOptions=struct('outputFolder','$physicalM','resume',$resumeValue,'budgetLedgerFile','$ledgerM','realizationSeed',$scheduledSeed); stage2Physical(execution,false,runOptions);"
    $workerBase=Join-Path $runRoot 'workers'
    New-Item -ItemType Directory -Path $workerBase -Force | Out-Null
    $runId=[guid]::NewGuid().ToString('N')
    $workerFolder=Join-Path $workerBase ('worker-'+$runId)
    $memoryCsv=Join-Path $workerFolder 'memory.csv'
    $scheduledWrapper=Join-Path $projectRoot 'verification\local\InvokeScheduledProcess.ps1'
    $progressFile=Join-Path $physicalFolder 'progress.json'
    $launch=& $scheduledWrapper -Executable $executable -Arguments ('-batch "'+$batchCommand+'"') `
        -WorkingDirectory $projectRoot -OutputFolder $workerFolder -ProgressFile $progressFile `
        -MemoryCsvPath $memoryCsv -SampleIntervalSeconds 1 -HeartbeatSeconds 30 `
        -NoProgressWarningSeconds 900 -StartupWaitSeconds 60
    $workerProcess=Get-Process -Id ([int]$launch.workerProcessId) -ErrorAction Stop
    $workerCim=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$launch.workerProcessId)"
    $matlabCim=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$launch.rootProcessId)"
    if ($null -eq $workerCim -or $null -eq $matlabCim -or
        [string]::IsNullOrWhiteSpace([string]$workerCim.CommandLine) -or
        [string]::IsNullOrWhiteSpace([string]$matlabCim.CommandLine)) {
        throw 'Worker identities were unavailable; the child was left running and its launch folder was preserved.'
    }
    $worker=[ordered]@{
        status='running';runId=$runId;workerFolder=$workerFolder
        workerProcessId=[int]$launch.workerProcessId
        workerProcessStartTimeUtc=$workerProcess.StartTime.ToUniversalTime().ToString('o')
        workerCommandLine=[string]$workerCim.CommandLine
        matlabProcessId=[int]$launch.rootProcessId
        matlabProcessStartTimeUtc=[string]$launch.processStartTimeUtc
        matlabCommandLine=[string]$matlabCim.CommandLine
        arguments=[string]$launch.arguments;executable=$executable
        processReport=[string]$launch.processReport;heartbeat=[string]$launch.heartbeat
        stdout=[string]$launch.stdout;stderr=[string]$launch.stderr
        memoryCsv=$memoryCsv;recordedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    $hostRun=[ordered]@{
        status='running';executionProfile=$ExecutionProfile;runFolder=$runRoot
        physicalRunFolder=$physicalFolder;targetedLog=$targetedPath
        runId=$runId;stage2CaseBudget=$caseCount;realizationSeed=$scheduledSeed;worker=$worker;history=$history
        budgetLedger=$ledgerFile;progressFile=$progressFile
        createdAtUtc=if($Resume){[string]$previous.createdAtUtc}else{[DateTime]::UtcNow.ToString('o')}
        updatedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic (Join-Path $runRoot 'stage2-host-run.json') $hostRun
    Write-Output "STAGE2_PHYSICAL_HOST_RUN=$runRoot"
    Write-Output "STAGE2_PHYSICAL_EVIDENCE=$physicalFolder"
    Write-Output "STAGE2_PHYSICAL_HOST_STATUS=running"
    Write-Output "STAGE2_PHYSICAL_REALIZATION_SEED=$scheduledSeed"
    Write-Output "STAGE2_PHYSICAL_WORKER_PID=$($launch.workerProcessId)"
    Write-Output "STAGE2_PHYSICAL_MATLAB_PID=$($launch.rootProcessId)"
    return
}

. (Join-Path $projectRoot 'verification\local\InvokeBoundedProcess.ps1')
$caseLimit=$MaxCaseSeconds.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
$suiteLimit=$MaxSuiteSeconds.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
$physicalM=$physicalFolder.Replace('\','/').Replace("'","''")
$resumeValue=if($Resume){'true'}else{'false'}
$batchCommand="cd('$matlabRoot'); addpath('$matlabRoot'); setupProject(); addpath('verification/completion/stage-2'); execution=struct('profile','external-machine','role','stage-2-collision-diagnostics','maxUE',10,'maxCaseSeconds',$caseLimit,'maxSuiteSeconds',$suiteLimit); runOptions=struct('outputFolder','$physicalM','resume',$resumeValue,'budgetLedgerFile',''); stage2Physical(execution,false,runOptions);"
$report=Invoke-BoundedProcess -Executable $executable -Arguments ('-batch "'+$batchCommand+'"') `
    -WorkingDirectory $projectRoot -OutputFolder (Join-Path $runRoot 'worker') -TimeoutSeconds $MaxSuiteSeconds
[ordered]@{status=$report.status;executionProfile=$ExecutionProfile;exitCode=$report.exitCode
    elapsedSeconds=$report.elapsedSeconds;stage2CaseBudget=$caseCount;processIds=$report.processIds
    physicalRunFolder=$physicalFolder;targetedLog=$targetedPath;stdout='worker/stdout.log';stderr='worker/stderr.log'} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runRoot 'stage2-host-run.json') -Encoding UTF8
Write-Output "STAGE2_PHYSICAL_HOST_RUN=$runRoot"
Write-Output "STAGE2_PHYSICAL_EVIDENCE=$physicalFolder"
Write-Output "STAGE2_PHYSICAL_HOST_STATUS=$($report.status)"
Write-Output "STAGE2_PHYSICAL_HOST_EXIT_CODE=$($report.exitCode)"
if ($report.exitCode -ne 0) { exit $report.exitCode }
