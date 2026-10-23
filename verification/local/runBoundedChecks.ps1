param(
    [string[]]$TestFiles = @('tests/TestExecutionBudget.m'),
    [string]$MatlabCommand = 'matlab',
    [ValidateRange(1,300)][int]$MaxCaseSeconds = 300,
    [ValidateRange(1,900)][int]$MaxSuiteSeconds = 900,
    [string]$OutputFolder = '',
    [switch]$NoFigureWindows
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InvokeBoundedProcess.ps1')
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ($TestFiles.Count -eq 0) { throw 'Choose specific test files, not the complete tests folder.' }
$selectedFiles = @()
foreach ($testFile in $TestFiles) {
    $resolved = (Resolve-Path -LiteralPath (Join-Path $projectRoot $testFile)).Path
    $testRoot = Join-Path $projectRoot 'tests'
    if (-not $resolved.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($resolved) -ne '.m') {
        throw 'Only explicit MATLAB test files inside tests/ are allowed.'
    }
    $selectedFiles += $resolved
}
if ($OutputFolder -eq '') {
    $OutputFolder = Join-Path $PSScriptRoot ('checks-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}
if ((Test-Path -LiteralPath $OutputFolder) -and @(Get-ChildItem -LiteralPath $OutputFolder -Force).Count -gt 0) { throw 'Output folder must be empty.' }
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputFolder).Path
$executable = (Get-Command $MatlabCommand -ErrorAction Stop).Source
$suiteClock = [Diagnostics.Stopwatch]::StartNew()
$reports = @()
for ($index = 0; $index -lt $selectedFiles.Count; $index++) {
    $remaining = $MaxSuiteSeconds - $suiteClock.Elapsed.TotalSeconds
    if ($remaining -le 0) { throw 'Suite time budget exhausted; no further processes started.' }
    $caseFolder = Join-Path $outputRoot ('test-' + $index)
    New-Item -ItemType Directory -Path $caseFolder | Out-Null
    $batchFile = Join-Path $caseFolder 'runTests.m'
    $matlabTest = $selectedFiles[$index].Replace('\','/').Replace("'","''")
    $matlabResults = (Join-Path $caseFolder 'test-results.mat').Replace('\','/').Replace("'","''")
    $matlabRoot = $projectRoot.Replace('\','/').Replace("'","''")
    $batchText = "cd('$matlabRoot'); addpath('$matlabRoot'); setupProject(); testResults=runtests('$matlabTest'); save('$matlabResults','testResults'); fprintf('BOUNDED_TEST total=%d passed=%d failed=%d incomplete=%d\n',numel(testResults),sum([testResults.Passed]),sum([testResults.Failed]),sum([testResults.Incomplete])); assertSuccess(testResults);"
    [IO.File]::WriteAllText($batchFile,$batchText,[Text.UTF8Encoding]::new($false))
    $matlabBatch = $batchFile.Replace('\','/').Replace("'","''")
    $displayArguments = if ($NoFigureWindows) { '-noFigureWindows ' } else { '' }
    $report = Invoke-BoundedProcess -Executable $executable -Arguments "${displayArguments}-batch `"run('$matlabBatch')`"" -WorkingDirectory $projectRoot -OutputFolder (Join-Path $caseFolder 'process') -TimeoutSeconds ([Math]::Min($MaxCaseSeconds,$remaining))
    $reports += $report
    $reports | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'suite-report.json') -Encoding UTF8
    Write-Output "BOUNDED_CHECK file=$($TestFiles[$index]) status=$($report.status) seconds=$([Math]::Round($report.elapsedSeconds,2))"
    if ($report.status -ne 'completed') {
        Get-Content -LiteralPath $report.stdout -Tail 45
        Get-Content -LiteralPath $report.stderr -Tail 12
        exit $report.exitCode
    }
}
Write-Output "BOUNDED_CHECK_OUTPUT=$outputRoot"
