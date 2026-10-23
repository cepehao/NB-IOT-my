param(
    [string]$MatlabCommand = 'matlab',
    [ValidateSet('local-development','external-machine')][string]$ExecutionProfile = 'local-development',
    [double]$MaxCaseSeconds = 0,
    [double]$MaxSuiteSeconds = 0
)
$ErrorActionPreference = 'Stop'
if ($ExecutionProfile -ne 'external-machine' -or $MaxCaseSeconds -le 0 -or $MaxSuiteSeconds -lt 5*$MaxCaseSeconds -or [double]::IsInfinity($MaxCaseSeconds) -or [double]::IsInfinity($MaxSuiteSeconds) -or [double]::IsNaN($MaxCaseSeconds) -or [double]::IsNaN($MaxSuiteSeconds)) {
    throw 'ExecutionBudget: load pilot requires an explicit external-machine profile and finite case/suite budgets. Do not run the full pilot locally.'
}
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $projectRoot 'verification\local\InvokeBoundedProcess.ps1')
$runRoot = Join-Path $projectRoot ('verification\completion\stage-3\pilot-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$simulationOutput = Join-Path $runRoot 'simulation'
$hostOutput = Join-Path $runRoot 'host'
if (@(Get-Process -Name 'MATLAB*' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close other MATLAB sessions before a full external pilot so memory measurements stay isolated.'
}
$executable = (Get-Command $MatlabCommand -ErrorAction Stop).Source
$caseLimit = $MaxCaseSeconds.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
$suiteLimit = $MaxSuiteSeconds.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
$batchCommand = "addpath('experiments'); execution=struct('profile','external-machine','role','stage-3-load-pilot','maxUE',5000,'maxCaseSeconds',$caseLimit,'maxSuiteSeconds',$suiteLimit); runLoadPilot(struct('execution',execution));"
$priorOutput = $env:NBIOT_PILOT_OUTPUT
$env:NBIOT_PILOT_OUTPUT = $simulationOutput
$sampling = [pscustomobject]@{ peakBytes=[int64]0; samples=[System.Collections.Generic.List[object]]::new(); tracked=[System.Collections.Generic.HashSet[int]]::new() }
$sampleAction = {
    param($ownedIds)
    $aggregate = [int64]0; $matlabIds = @()
    foreach ($ownedId in $ownedIds) {
        $item = Get-Process -Id $ownedId -ErrorAction SilentlyContinue
        if ($null -ne $item -and $item.ProcessName -like 'MATLAB*') {
            [void]$sampling.tracked.Add([int]$ownedId); $matlabIds += $ownedId; $aggregate += [int64]$item.WorkingSet64
        }
    }
    if ($aggregate -gt $sampling.peakBytes) { $sampling.peakBytes = $aggregate }
    $sampling.samples.Add([pscustomobject]@{sampledUtc=[DateTime]::UtcNow.ToString('o');processIds=($matlabIds -join ';');aggregateWorkingSetBytes=$aggregate})
}.GetNewClosure()
try {
    New-Item -ItemType Directory -Path $simulationOutput -Force | Out-Null
    $report = Invoke-BoundedProcess -Executable $executable -Arguments ('-batch "' + $batchCommand + '"') -WorkingDirectory $projectRoot -OutputFolder $hostOutput -TimeoutSeconds $MaxSuiteSeconds -OnSample $sampleAction
    $sampling.samples | Export-Csv -LiteralPath (Join-Path $hostOutput 'process-memory-samples.csv') -NoTypeInformation -Encoding UTF8
    [ordered]@{matlabProcessId=$report.rootProcessId;processTreeIds=@($sampling.tracked | Sort-Object);sampleIntervalMilliseconds=100;peakAggregateWorkingSetBytes=$sampling.peakBytes;exitCode=$report.exitCode;status=$report.status;stdout='host/stdout.log';stderr='host/stderr.log';samples='host/process-memory-samples.csv'} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $hostOutput 'host-memory-summary.json') -Encoding UTF8
    Write-Output "LOAD_PILOT_RUN=$runRoot"
    Write-Output "LOAD_PILOT_PEAK_AGGREGATE_WORKING_SET_BYTES=$($sampling.peakBytes)"
    Write-Output "LOAD_PILOT_EXIT_CODE=$($report.exitCode)"
    if ($report.exitCode -ne 0) { exit $report.exitCode }
}
finally {
    if ($null -eq $priorOutput) { Remove-Item Env:NBIOT_PILOT_OUTPUT -ErrorAction SilentlyContinue }
    else { $env:NBIOT_PILOT_OUTPUT = $priorOutput }
}
