[CmdletBinding()]
param(
    [string]$Executable,
    [string]$Arguments = '',
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$OutputFolder = '',
    [string]$RunId = [guid]::NewGuid().ToString('N'),
    [string]$ProgressFile = '',
    [string]$MemoryCsvPath = '',
    [ValidateRange(0.05,60)][double]$SampleIntervalSeconds = 1,
    [ValidateRange(0.05,3600)][double]$HeartbeatSeconds = 30,
    [ValidateRange(0.1,86400)][double]$NoProgressWarningSeconds = 900,
    [ValidateRange(1,300)][int]$StartupWaitSeconds = 30,
    [switch]$WorkerMode,
    [string]$ConfigPath = ''
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ControlScheduledRun.ps1"

function Write-JsonFile([string]$Path,[object]$Value) {
    Write-RunJson $Path $Value
}

function Add-WorkerLog([string]$Path,[string]$Message) {
    try { Add-Content -LiteralPath $Path -Value $Message -Encoding UTF8 } catch { }
}

function Read-ProgressState([string]$Path) {
    $state=[ordered]@{phase='unknown';currentTick='';lastCheckpoint='';updatedAtUtc=''}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$state
    }
    try {
        $value=Read-RunJson $Path
        if ($null -ne $value.phase) { $state.phase=[string]$value.phase }
        if ($null -ne $value.currentTick) { $state.currentTick=[string]$value.currentTick }
        elseif ($null -ne $value.tick) { $state.currentTick=[string]$value.tick }
        if ($null -ne $value.lastCheckpoint) { $state.lastCheckpoint=[string]$value.lastCheckpoint }
        if ($null -ne $value.updatedAtUtc) { $state.updatedAtUtc=[string]$value.updatedAtUtc }
    } catch { }
    return [pscustomobject]$state
}

function Csv-Quote([string]$Value) {
    return '"' + $Value.Replace('"','""') + '"'
}

function Start-ScheduledWorker([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing worker config: $Path" }
    $workerLog=Join-Path ([IO.Path]::GetDirectoryName($Path)) 'worker.log'
    Add-WorkerLog $workerLog 'WORKER_ENTRY'
    $config=Read-RunJson $Path
    $workerLog=[string]$config.workerLog
    $workerPid=$PID
    $job=$null
    $writer=$null
    $samplerError=''
    $monitorError=''
    $idsSeen=[System.Collections.Generic.HashSet[uint32]]::new()
    $sampleCount=0
    $peakSampledWorkingSetBytes=[int64]0
    $progressWarned=$false
    $cancelled=$false
    $lastActive=$null
    $handledRequests=@{}
    $processStartTimeUtc=''; $workerStartTimeUtc=''
    $runWatch=[Diagnostics.Stopwatch]::StartNew()
    try {
        Add-WorkerLog $workerLog 'ADD_TYPE_BEGIN'
        if (-not ('Nbiot.Runtime.OwnedProcessJob' -as [type])) {
            Add-Type -Path ([string]$config.ownedProcessJobSource)
        }
        Add-WorkerLog $workerLog 'ADD_TYPE_COMPLETE'
        Add-WorkerLog $workerLog "PROCESS_CREATE_BEGIN executable=$($config.executable)"
        $job=[Nbiot.Runtime.OwnedProcessJob]::new(
            [string]$config.executable,[string]$config.arguments,
            [string]$config.workingDirectory,[string]$config.stdout,
            [string]$config.stderr,$false)
        $rootId=[uint32]$job.RootProcessId
        Add-WorkerLog $workerLog "PROCESS_CREATE_COMPLETE rootPid=$rootId"
        [void]$idsSeen.Add($rootId)
        $rootProcess=[Diagnostics.Process]::GetProcessById([int]$rootId)
        $processStartTimeUtc=$rootProcess.StartTime.ToUniversalTime().ToString('o')
        $workerStartTimeUtc=(Get-Process -Id $workerPid).StartTime.ToUniversalTime().ToString('o')
        Add-WorkerLog $workerLog "PROCESS_IDENTITY_READY rootPid=$rootId"
        $started=[ordered]@{
            runId=[string]$config.runId
            workerProcessId=$workerPid
            workerProcessStartTimeUtc=$workerStartTimeUtc
            rootProcessId=[int]$rootId
            processStartTimeUtc=$processStartTimeUtc
            executable=[string]$config.executable
            arguments=[string]$config.arguments
            workingDirectory=[string]$config.workingDirectory
            rootCommandLine=[string](Get-CimInstance Win32_Process -Filter "ProcessId=$rootId").CommandLine
            workerCommandLine=[string](Get-CimInstance Win32_Process -Filter "ProcessId=$workerPid").CommandLine
            workerExecutable=(Get-Process -Id $workerPid).Path
            stdout=[string]$config.stdout
            stderr=[string]$config.stderr
            workerStdout=[string]$config.workerStdout
            workerStderr=[string]$config.workerStderr
            memoryCsv=[string]$config.memoryCsv
            heartbeat=[string]$config.heartbeat
            progressFile=[string]$config.progressFile
        }
        Write-JsonFile ([string]$config.processStarted) $started
        Add-WorkerLog $workerLog "START runId=$($config.runId) rootPid=$rootId processStartTimeUtc=$processStartTimeUtc"
        try {
            $writer=[IO.StreamWriter]::new([string]$config.memoryCsv,$false,
                [Text.UTF8Encoding]::new($false))
            $writer.WriteLine('timestampUtc,runId,rootProcessId,processId,processName,workingSetBytes,treeWorkingSetBytes,phase,currentTick,lastCheckpoint,progressUnchangedSeconds')
            $writer.Flush()
        } catch {
            $samplerError=$_.Exception.Message
            Add-WorkerLog $workerLog "SAMPLER_ERROR $samplerError"
            if ($null -ne $writer) { $writer.Dispose(); $writer=$null }
        }

        $trackedIds=@{}
        $lastSignature=$null
        $lastProgressChangeSeconds=0.0
        $lastHeartbeatSeconds=-[double]::PositiveInfinity
        while ($true) {
            $processIds=@()
            try { $processIds=@($job.ProcessIds()) }
            catch {
                $monitorError=$_.Exception.Message
                Add-WorkerLog $workerLog "PROCESS_TREE_ERROR $monitorError"
                if (-not $job.RootExited) { $processIds=@($rootId) }
            }
            foreach ($processId in $processIds) {
                $numericId=[uint32]$processId
                [void]$idsSeen.Add($numericId)
                $trackedIds[[string]$numericId]=$true
            }
            $progress=Read-ProgressState ([string]$config.progressFile)
            $requestPath=Join-Path ([string]$config.outputFolder) 'control-request.json'
            if (Test-Path -LiteralPath $requestPath) {
                try {
                    $request=Read-RunJson $requestPath
                    if (-not $handledRequests.ContainsKey([string]$request.requestId)) {
                        $valid=$request.schemaVersion -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$request.requestId) -and $request.action -in @('cancel','stop-after-case')
                        foreach ($field in @('runId','rootProcessId','processStartTimeUtc','workerProcessId','workerProcessStartTimeUtc')) {
                            $valid=$valid -and ([string]$request.$field -ceq [string]$started.$field)
                        }
                        $valid=$valid -and (Get-RunProcessState $rootId $processStartTimeUtc $started.executable $started.rootCommandLine) -eq 'alive'
                        $valid=$valid -and (Get-RunProcessState $workerPid $workerStartTimeUtc $started.workerExecutable $started.workerCommandLine) -eq 'alive'
                        $reason='identity-conflict'; $ackStatus='rejected'
                        if ($valid) {
                            if ($request.action -eq 'stop-after-case') {
                                if (-not $config.runFolder) { throw 'Cannot resolve run root for stop-after-case.' }
                                $markerPath=Join-Path ([string]$config.runFolder) 'stop-after-case.request.json'
                                if (Test-Path -LiteralPath $markerPath) {
                                    $marker=Read-RunJson $markerPath
                                    if ($marker.runId -cne $started.runId) { throw 'Persistent stop marker runId conflict.' }
                                } else { Write-JsonFile $markerPath $request }
                            } else {
                                $job.Stop(); $cancelled=$true
                            }
                            $reason='explicit-request'; $ackStatus='applied'
                        }
                        $ack=[ordered]@{requestId=$request.requestId;status=$ackStatus;reason=$reason;acknowledgedAtUtc=[DateTime]::UtcNow.ToString('o')}
                        Write-JsonFile (Join-Path ([string]$config.outputFolder) 'control-ack.json') $ack
                        $handledRequests[[string]$request.requestId]=$true
                    }
                } catch { Add-WorkerLog $workerLog "CONTROL_REJECTED $($_.Exception.Message)" }
            }
            # Read runner-owned active case; the worker never writes the compute ledger.
            $caseProgressPath=if($config.progressFile){Join-Path ([IO.Path]::GetDirectoryName([string]$config.progressFile)) 'progress.json'}else{''}
            if ($caseProgressPath -and (Test-Path -LiteralPath $caseProgressPath)) {
                try {
                    $caseProgress=Read-RunJson $caseProgressPath
                    $active=$caseProgress.activeCase
                    if ($active.attemptId -and $active.runId -ceq $config.runId -and $active.caseKey) {
                        $caseStart=[DateTimeOffset]::Parse([string]$active.startedAtUtc,[Globalization.CultureInfo]::InvariantCulture)
                        $observed=[Math]::Max([double]0,([DateTimeOffset]::UtcNow-$caseStart).TotalSeconds)
                        $lastActive=$active
                        Write-JsonFile (Join-Path ([string]$config.outputFolder) 'accounting-observation.json') ([ordered]@{runId=$config.runId;attemptId=$active.attemptId;caseKey=$active.caseKey;observedAtUtc=[DateTime]::UtcNow.ToString('o');observedSeconds=$observed})
                    }
                } catch { Add-WorkerLog $workerLog "OBSERVATION_UNAVAILABLE $($_.Exception.Message)" }
            }
            $signature=('{0}|{1}|{2}' -f $progress.phase,$progress.currentTick,$progress.lastCheckpoint)
            if ($signature -ne $lastSignature) {
                $lastSignature=$signature
                $lastProgressChangeSeconds=$runWatch.Elapsed.TotalSeconds
            }
            $progressUnchangedSeconds=$runWatch.Elapsed.TotalSeconds-$lastProgressChangeSeconds
            if (-not $progressWarned -and $progressUnchangedSeconds -ge [double]$config.noProgressWarningSeconds) {
                $progressWarned=$true
                $warning=[ordered]@{
                    runId=[string]$config.runId
                    timestampUtc=[DateTime]::UtcNow.ToString('o')
                    reason='no-progress'
                    status='needs-attention'
                    unchangedSeconds=$progressUnchangedSeconds
                    phase=$progress.phase
                    currentTick=$progress.currentTick
                    lastCheckpoint=$progress.lastCheckpoint
                    action='warning-only; the active process was not stopped'
                    inspectCommand=('& "{0}" -Action inspect -RunFolder "{1}"' -f (Join-Path $PSScriptRoot 'ControlScheduledRun.ps1'),$config.runFolder)
                    cancelCommand=('& "{0}" -Action cancel -RunFolder "{1}"' -f (Join-Path $PSScriptRoot 'ControlScheduledRun.ps1'),$config.runFolder)
                }
                try { Write-JsonFile ([string]$config.progressWarning) $warning } catch { }
                Add-WorkerLog $workerLog "NO_PROGRESS_WARNING unchangedSeconds=$progressUnchangedSeconds phase=$($progress.phase) currentTick=$($progress.currentTick) lastCheckpoint=$($progress.lastCheckpoint)"
            }

            $rows=@()
            $treeWorkingSet=[int64]0
            foreach ($processId in $processIds) {
                try {
                    $process=[Diagnostics.Process]::GetProcessById([int]$processId)
                    $workingSet=[int64]$process.WorkingSet64
                    $treeWorkingSet+=$workingSet
                    $rows+=,[pscustomobject]@{processId=[int]$processId;name=$process.ProcessName;workingSetBytes=$workingSet}
                } catch { }
            }
            if ($treeWorkingSet -gt $peakSampledWorkingSetBytes) {
                $peakSampledWorkingSetBytes=$treeWorkingSet
            }
            if ($null -ne $writer) {
                try {
                    $stamp=[DateTime]::UtcNow.ToString('o')
                    foreach ($row in $rows) {
                        $values=@($stamp,[string]$config.runId,[string]$rootId,
                            [string]$row.processId,[string]$row.name,
                            [string]$row.workingSetBytes,[string]$treeWorkingSet,
                            [string]$progress.phase,[string]$progress.currentTick,
                            [string]$progress.lastCheckpoint,
                            [string][Math]::Round($progressUnchangedSeconds,1))
                        $writer.WriteLine(($values | ForEach-Object { Csv-Quote $_ }) -join ',')
                    }
                    $writer.Flush()
                    $sampleCount++
                } catch {
                    $samplerError=$_.Exception.Message
                    Add-WorkerLog $workerLog "SAMPLER_ERROR $samplerError"
                    $writer.Dispose(); $writer=$null
                }
            }
            if (($runWatch.Elapsed.TotalSeconds-$lastHeartbeatSeconds) -ge [double]$config.heartbeatSeconds) {
                $lastHeartbeatSeconds=$runWatch.Elapsed.TotalSeconds
                $heartbeat=[ordered]@{
                    runId=[string]$config.runId
                    timestampUtc=[DateTime]::UtcNow.ToString('o')
                    rootProcessId=[int]$rootId
                    processStartTimeUtc=$processStartTimeUtc
                    workerProcessId=$workerPid
                    workerProcessStartTimeUtc=$workerStartTimeUtc
                    processIds=@($processIds | ForEach-Object { [int]$_ })
                    elapsedSeconds=$runWatch.Elapsed.TotalSeconds
                    sampledTreeWorkingSetBytes=$treeWorkingSet
                    peakSampledTreeWorkingSetBytes=$peakSampledWorkingSetBytes
                    sampleIntervalSeconds=[double]$config.sampleIntervalSeconds
                    progressPhase=$progress.phase
                    currentTick=$progress.currentTick
                    lastCheckpoint=$progress.lastCheckpoint
                    progressUnchangedSeconds=$progressUnchangedSeconds
                    progressWarningIssued=$progressWarned
                    samplerError=$samplerError
                }
                try { Write-JsonFile ([string]$config.heartbeat) $heartbeat } catch {
                    Add-WorkerLog $workerLog "HEARTBEAT_ERROR $($_.Exception.Message)"
                }
            }
            if ($job.RootExited -and $processIds.Count -eq 0) { break }
            Start-Sleep -Milliseconds ([Math]::Max(25,[int]([double]$config.sampleIntervalSeconds*1000)))
        }
        $exitCode=[int]$job.ExitCode
        $status=if ($cancelled) { 'cancelled' } elseif ($exitCode -eq 0) { 'completed' } else { 'failed' }
    } catch {
        $monitorError=$_.Exception.Message
        Add-WorkerLog $workerLog "WORKER_ERROR $monitorError"
        $exitCode=125
        $status='failed'
        if ($null -ne $job) {
            try {
                while (-not $job.RootExited) { Start-Sleep -Milliseconds 250 }
                $exitCode=[int]$job.ExitCode
            } catch { }
        }
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $job) { $job.Dispose() }
    }
    $report=[ordered]@{
        runId=[string]$config.runId
        status=$status
        reason=if($cancelled){'explicit-request'}else{'process-exited'}
        startedAtUtc=$workerStartTimeUtc
        finishedAtUtc=[DateTime]::UtcNow.ToString('o')
        processStartTimeUtc=$processStartTimeUtc
        workerProcessStartTimeUtc=$workerStartTimeUtc
        executable=[string]$config.executable
        arguments=[string]$config.arguments
        attemptId=if($null -ne $lastActive){$lastActive.attemptId}else{$null}
        caseKey=if($null -ne $lastActive){$lastActive.caseKey}else{$null}
        exitCode=$exitCode
        elapsedSeconds=$runWatch.Elapsed.TotalSeconds
        workerProcessId=$workerPid
        rootProcessId=if ($null -ne $job) { [int]$job.RootProcessId } else { 0 }
        processIds=@($idsSeen | ForEach-Object { [int]$_ } | Sort-Object)
        peakSampledWorkingSetBytes=$peakSampledWorkingSetBytes
        sampleIntervalSeconds=[double]$config.sampleIntervalSeconds
        sampleCount=$sampleCount
        maximumDescription='maximum sampled tree working set; not a continuous peak'
        memoryCsv=[string]$config.memoryCsv
        stdout=[string]$config.stdout
        stderr=[string]$config.stderr
        samplerError=$samplerError
        monitorError=$monitorError
        progressWarningIssued=$progressWarned
    }
    try { Write-JsonFile ([string]$config.processReport) $report } catch {
        Add-WorkerLog $workerLog "REPORT_WRITE_ERROR $($_.Exception.Message)"
    }
    Add-WorkerLog $workerLog "END runId=$($config.runId) status=$status exitCode=$exitCode"
}

if ($WorkerMode) {
    try { Start-ScheduledWorker $ConfigPath; exit 0 }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
            try {
                $failedConfig=Read-RunJson $ConfigPath
                Add-WorkerLog ([string]$failedConfig.workerLog) "STARTUP_ERROR $($_.Exception.Message)"
            } catch { }
        }
        exit 1
    }
}

if ([string]::IsNullOrWhiteSpace($Executable)) { throw 'Executable is required.' }
if ([string]::IsNullOrWhiteSpace($OutputFolder)) { throw 'OutputFolder is required.' }
$resolvedExecutable=(Get-Command $Executable -ErrorAction Stop).Source
$resolvedWorkingDirectory=(Resolve-Path -LiteralPath $WorkingDirectory).Path
if (Test-Path -LiteralPath $OutputFolder) {
    if (@(Get-ChildItem -LiteralPath $OutputFolder -Force).Count -gt 0) { throw 'Output folder must be empty.' }
} else {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}
$resolvedOutputFolder=(Resolve-Path -LiteralPath $OutputFolder).Path
if ([string]::IsNullOrWhiteSpace($MemoryCsvPath)) {
    $MemoryCsvPath=Join-Path $resolvedOutputFolder 'host-memory-samples.csv'
}
$workerStdout=Join-Path $resolvedOutputFolder 'worker.stdout.log'
$workerStderr=Join-Path $resolvedOutputFolder 'worker.stderr.log'
$configPath=Join-Path $resolvedOutputFolder 'worker-config.json'
$processStarted=Join-Path $resolvedOutputFolder 'process-started.json'
$processReport=Join-Path $resolvedOutputFolder 'process-report.json'
$heartbeat=Join-Path $resolvedOutputFolder 'heartbeat.json'
$progressWarning=Join-Path $resolvedOutputFolder 'no-progress-warning.json'
$workerLog=Join-Path $resolvedOutputFolder 'worker.log'
$stdout=Join-Path $resolvedOutputFolder 'process.stdout.log'
$stderr=Join-Path $resolvedOutputFolder 'process.stderr.log'
$ownedSource=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'OwnedProcessJob.cs')).Path
$config=[ordered]@{
    runId=$RunId
    executable=$resolvedExecutable
    arguments=$Arguments
    workingDirectory=$resolvedWorkingDirectory
    outputFolder=$resolvedOutputFolder
    runFolder=if($ProgressFile){Split-Path (Split-Path ([IO.Path]::GetFullPath($ProgressFile)) -Parent) -Parent}else{$resolvedWorkingDirectory}
    stdout=$stdout
    stderr=$stderr
    workerStdout=$workerStdout
    workerStderr=$workerStderr
    workerLog=$workerLog
    processStarted=$processStarted
    processReport=$processReport
    heartbeat=$heartbeat
    progressWarning=$progressWarning
    progressFile=$ProgressFile
    memoryCsv=$MemoryCsvPath
    sampleIntervalSeconds=$SampleIntervalSeconds
    heartbeatSeconds=$HeartbeatSeconds
    noProgressWarningSeconds=$NoProgressWarningSeconds
    ownedProcessJobSource=$ownedSource
}
Write-JsonFile $configPath $config
Write-JsonFile (Join-Path $resolvedOutputFolder 'launch-request.json') ([ordered]@{
    runId=$RunId
    requestedAtUtc=[DateTime]::UtcNow.ToString('o')
    controllerProcessId=$PID
    scriptPath=$PSCommandPath
    configPath=$configPath
    executable=$resolvedExecutable
    arguments=$Arguments
    workingDirectory=$resolvedWorkingDirectory
    workerStdout=$workerStdout
    workerStderr=$workerStderr
})
$powerShellExe=(Get-Process -Id $PID).Path
$workerArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),
    '-WorkerMode','-ConfigPath',('"{0}"' -f $configPath))
$workerStartOptions=@{
    FilePath=$powerShellExe
    ArgumentList=$workerArgs
    WorkingDirectory=$resolvedWorkingDirectory
    WindowStyle='Hidden'
    PassThru=$true
    RedirectStandardOutput=$workerStdout
    RedirectStandardError=$workerStderr
}
$workerProcess=Start-Process @workerStartOptions
$workerStartTimeUtc=$workerProcess.StartTime.ToUniversalTime().ToString('o')
$deadline=[DateTime]::UtcNow.AddSeconds($StartupWaitSeconds)
while (-not (Test-Path -LiteralPath $processStarted -PathType Leaf)) {
    $workerProcess.Refresh()
    if ($workerProcess.HasExited) {
        $workerProcess.Refresh()
        $tail=''
        if (Test-Path -LiteralPath $workerStderr) { $tail=Get-Content -LiteralPath $workerStderr -Tail 10 | Out-String }
        throw "Scheduled worker exited before MATLAB/process launch. Worker PID=$($workerProcess.Id). $tail"
    }
    if ([DateTime]::UtcNow -ge $deadline) {
        throw "Scheduled worker did not record its process PID within $StartupWaitSeconds seconds. Worker PID=$($workerProcess.Id); see $workerLog and $workerStderr. The worker was not stopped."
    }
    Start-Sleep -Milliseconds 100
}
$started=Read-RunJson $processStarted
$launch=[ordered]@{
    runId=$RunId
    status='running'
    launchedAtUtc=[DateTime]::UtcNow.ToString('o')
    controllerProcessId=$PID
    workerProcessId=$workerProcess.Id
    workerProcessStartTimeUtc=$workerStartTimeUtc
    rootProcessId=[int]$started.rootProcessId
    processStartTimeUtc=[string]$started.processStartTimeUtc
    executable=$resolvedExecutable
    arguments=$Arguments
    workingDirectory=$resolvedWorkingDirectory
    stdout=$stdout
    stderr=$stderr
    workerStdout=$workerStdout
    workerStderr=$workerStderr
    processStarted=$processStarted
    processReport=$processReport
    memoryCsv=$MemoryCsvPath
    heartbeat=$heartbeat
    progressFile=$ProgressFile
    sampleIntervalSeconds=$SampleIntervalSeconds
}
$launchPath=Join-Path $resolvedOutputFolder 'launch.json'
Write-JsonFile $launchPath $launch
[pscustomobject]$launch
