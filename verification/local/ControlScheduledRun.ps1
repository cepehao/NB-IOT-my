[CmdletBinding()]
param([ValidateSet('inspect','stop-after-case','cancel','resume')][string]$Action='inspect',[string]$RunFolder='')
$ErrorActionPreference='Stop'

# Shared with the worker/reconciler by dot-sourcing; importing never performs an action.
function Read-RunJson([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=[IO.StreamReader]::new($stream)
    try { $raw=$reader.ReadToEnd() } finally { $reader.Dispose() }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ConvertFrom-Json -InputObject $raw -DateKind String }
    return ConvertFrom-Json -InputObject $raw
}
function Write-RunJson([string]$Path,$Value) {
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
        # PowerShell coerces $null to an empty string for this string argument;
        # NullString preserves CLR null (no backup) without an empty-path error.
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
function Set-RunField($Value,[string]$Name,$Content) { $Value|Add-Member -NotePropertyName $Name -NotePropertyValue $Content -Force }
function Get-RunHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-RunContainedPath([string]$Root,[string]$Candidate,[string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or -not [IO.Path]::IsPathRooted($Candidate)) { throw "$Label path is missing or not absolute." }
    $rootPath=(Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path.TrimEnd('\')
    $candidatePath=(Resolve-Path -LiteralPath $Candidate -ErrorAction Stop).Path
    $prefix=$rootPath+[IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "$Label escapes its approved folder." }
    return $candidatePath
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
        $files.Add($relative,(Get-RunHash $full))
    }
    foreach ($entryPoint in @('setupProject.m','experiments/runStaticSweep.m','experiments/runStaticSweepParallel.m','experiments/optimizationSourceManifest.m')) {
        $full=Join-Path $root ($entryPoint.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Required source entry point is missing: $entryPoint" }
        $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Source entry point is a reparse point: $entryPoint" }
        $canonical=[IO.Path]::GetFullPath($item.FullName)
        if (-not $canonical.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Source entry point escapes the project root: $entryPoint" }
        $relative=$canonical.Substring($prefix.Length).Replace('\','/')
        $files[$relative]=(Get-RunHash $canonical)
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
    # runVariant2 changes to ProjectRoot, adds ProjectRoot, then setupProject
    # adds exactly src/configs/examples/experiments. Require one candidate on
    # that effective MATLAB search set so the static hash matches which().
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
function Test-RunSourceProof([string]$RunFolder) {
    try {
        $runRoot=(Resolve-Path -LiteralPath $RunFolder -ErrorAction Stop).Path
        $probePath=Join-Path $runRoot 'probe'
        if (-not (Test-Path -LiteralPath $probePath -PathType Container)) { throw 'Saved probe folder is missing.' }
        $probe=(Resolve-Path -LiteralPath $probePath -ErrorAction Stop).Path
        $runPrefix=$runRoot.TrimEnd('\')+[IO.Path]::DirectorySeparatorChar
        if (-not $probe.StartsWith($runPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Probe folder escapes RunFolder.' }
        $progressPath=Get-RunContainedPath $probe (Join-Path $probe 'progress.json') 'progress.json'
        $preflightPath=Get-RunContainedPath $probe (Join-Path $probe 'preflight.json') 'preflight.json'
        foreach ($path in @($progressPath,$preflightPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Saved progress/preflight source proof is missing.' } }
        $progress=Read-RunJson $progressPath
        $preflight=Read-RunJson $preflightPath
        if ($preflight.status -cne 'passed') { throw 'Saved preflight did not pass.' }
        if (-not ($progress.PSObject.Properties.Name -contains 'runFolder') -or [string]::IsNullOrWhiteSpace([string]$progress.runFolder)) { throw 'Progress runFolder is missing.' }
        $savedProbe=Get-RunContainedPath $runRoot ([string]$progress.runFolder) 'progress.runFolder'
        $expectedProbe=$probe
        if (-not [string]::Equals($savedProbe.TrimEnd('\'),$expectedProbe.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Progress belongs to another output folder.' }
        foreach ($field in @('sourceManifestSha256','runnerSha256')) {
            if (-not ($progress.PSObject.Properties.Name -contains $field) -or -not ($preflight.PSObject.Properties.Name -contains $field)) { throw "Saved $field is missing." }
            $progressHash=[string]$progress.$field
            $preflightHash=[string]$preflight.$field
            if ($progressHash -notmatch '^[0-9a-fA-F]{64}$' -or $preflightHash -notmatch '^[0-9a-fA-F]{64}$') { throw "Saved $field is malformed." }
            if (-not [string]::Equals($progressHash,$preflightHash,[StringComparison]::OrdinalIgnoreCase)) { throw "Progress/preflight $field conflict." }
        }
        $projectRoot=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..') -ErrorAction Stop).Path
        $currentManifest=Get-CurrentSourceManifestSha256 $projectRoot
        $currentRunner=Get-RunHash (Get-RunLoadProbePath $projectRoot)
        if (-not [string]::Equals([string]$progress.sourceManifestSha256,$currentManifest,[StringComparison]::OrdinalIgnoreCase)) { throw 'Current computational source manifest differs.' }
        if (-not [string]::Equals([string]$progress.runnerSha256,$currentRunner,[StringComparison]::OrdinalIgnoreCase)) { throw 'Current runLoadProbe source differs.' }
        return [pscustomobject]@{valid=$true;reason='source-match';detail=''}
    } catch {
        return [pscustomobject]@{valid=$false;reason='source-mismatch';detail=$_.Exception.Message}
    }
}
function Add-RunInspectionAccounting($Result,$Context,$Started) {
    $ledgerPath=[string]$Context.manifest.sharedBudgetLedger
    if ($ledgerPath -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        $ledger=Read-RunJson $ledgerPath; $Result.committedSeconds=$ledger.elapsedSeconds
        $observationPath=Join-Path $Context.processFolder 'accounting-observation.json'
        if (Test-Path -LiteralPath $observationPath -PathType Leaf) {
            $observation=Read-RunJson $observationPath
            $attempt=@($ledger.attempts|Where-Object { $_.attemptId -eq $observation.attemptId -and $_.runId -eq $Started.runId -and $_.caseKey -eq $observation.caseKey })
            if ($observation.runId -eq $Started.runId -and $attempt.Count -eq 1 -and -not [double]::IsNaN([double]$observation.observedSeconds) -and -not [double]::IsInfinity([double]$observation.observedSeconds) -and $observation.observedSeconds -ge 0) {
                $Result.estimatedSeconds=[double]$ledger.elapsedSeconds+[Math]::Max([double]0,[double]$observation.observedSeconds-[double]$attempt[0].chargedSeconds)
                $Result.estimateLabel='estimated'
            }
        }
    }
}
function Get-RunContext([string]$Folder) {
    if (-not [IO.Path]::IsPathRooted($Folder)) { throw 'RunFolder must be absolute.' }
    $run=(Resolve-Path -LiteralPath $Folder -ErrorAction Stop).Path
    $worker=Read-RunJson (Join-Path $run 'worker.json')
    $manifest=Read-RunJson (Join-Path $run 'run-manifest.json')
    $processFolder=[IO.Path]::GetFullPath([string]$worker.workerFolder)
    if (-not $processFolder.StartsWith($run.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Process folder escapes RunFolder.' }
    $launch=Read-RunJson (Join-Path $processFolder 'launch.json')
    $started=Read-RunJson (Join-Path $processFolder 'process-started.json')
    foreach ($field in @('runId','rootProcessId','processStartTimeUtc','workerProcessId','workerProcessStartTimeUtc')) {
        if ([string]::IsNullOrWhiteSpace([string]$started.$field) -or [string]$started.$field -cne [string]$launch.$field) { throw "Identity metadata conflict: $field" }
    }
    if ([string]$worker.runId -cne [string]$started.runId) { throw 'Worker runId conflict.' }
    if ($null -ne $manifest.runId -and [string]$manifest.runId -cne [string]$started.runId) { throw 'Manifest runId conflict.' }
    foreach ($pair in @(@('matlabProcessId','rootProcessId'),@('matlabProcessStartTimeUtc','processStartTimeUtc'),@('workerProcessId','workerProcessId'),@('workerProcessStartTimeUtc','workerProcessStartTimeUtc'))) {
        if ([string]$worker.($pair[0]) -cne [string]$started.($pair[1])) { throw "Worker identity conflict: $($pair[0])" }
    }
    [pscustomobject]@{run=$run;worker=$worker;manifest=$manifest;processFolder=$processFolder;launch=$launch;started=$started}
}
function Get-RunProcessState([int]$ProcessId,[string]$StartTime,[string]$Executable,[string]$CommandLine) {
    $process=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return 'absent' }
    try {
        if ($process.StartTime.ToUniversalTime().ToString('o') -cne $StartTime) { return 'identity-conflict' }
        $cim=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($null -eq $cim -or [string]::IsNullOrWhiteSpace($Executable) -or [string]::IsNullOrWhiteSpace($CommandLine)) { return 'unknown' }
        if (-not [string]::Equals([string]$cim.ExecutablePath,$Executable,[StringComparison]::OrdinalIgnoreCase) -or [string]$cim.CommandLine -cne $CommandLine) { return 'identity-conflict' }
        return 'alive'
    } catch { return 'unknown' }
}
function Get-RunStates($Context) {
    $s=$Context.started
    $rootCommand=[string]$s.rootCommandLine
    if (-not $rootCommand) { $rootCommand=[string]$Context.worker.matlabCommandLine }
    $workerCommand=[string]$s.workerCommandLine
    if (-not $workerCommand) { $workerCommand=[string]$Context.worker.workerCommandLine }
    $workerExecutable=[string]$s.workerExecutable
    if (-not $workerExecutable) { $workerExecutable=(Get-Process -Id $PID).Path }
    [pscustomobject]@{
        root=(Get-RunProcessState $s.rootProcessId $s.processStartTimeUtc $s.executable $rootCommand)
        worker=(Get-RunProcessState $s.workerProcessId $s.workerProcessStartTimeUtc $workerExecutable $workerCommand)
    }
}
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if (-not [IO.Path]::IsPathRooted($RunFolder)) { throw 'RunFolder must be absolute.' }
    $runRoot=(Resolve-Path -LiteralPath $RunFolder -ErrorAction Stop).Path
    $preManifest=$null; $preProgress=$null
    $preManifestPath=Join-Path $runRoot 'run-manifest.json'
    if (Test-Path -LiteralPath $preManifestPath -PathType Leaf) {
        try { $preManifest=Read-RunJson $preManifestPath } catch { $preManifest=$null }
    }
    $preProgressPath=Join-Path $runRoot 'probe/progress.json'
    if (Test-Path -LiteralPath $preProgressPath -PathType Leaf) {
        try { $preProgress=Read-RunJson (Get-RunContainedPath $runRoot $preProgressPath 'progress.json') } catch { $preProgress=$null }
    }
    $ownerStopped=(Test-Path -LiteralPath (Join-Path $runRoot 'owner-stop.json')) -or
        [string]$preManifest.status -ceq 'owner-stopped' -or [string]$preProgress.status -ceq 'owner-stopped'
    if ($ownerStopped) {
        if ($Action -in @('inspect','resume')) {
            $runId=if($null -ne $preManifest.runId){$preManifest.runId}else{$preProgress.runId}
            $result=[ordered]@{status='inspected';runId=$runId;rootState='not-checked';workerState='not-checked';accountingState='not-checked';resumeAllowed=$false;resumeCommand=$null;reason='owner-stopped'}
            $result|ConvertTo-Json -Depth 10; exit 0
        }
        throw 'owner-stopped: resume/control is refused before process lookup or mutation.'
    }
    $sourceProof=$null
    if ($Action -in @('inspect','resume')) {
        $sourceProof=Test-RunSourceProof $runRoot
        if (-not $sourceProof.valid) {
            $runId=if($null -ne $preManifest.runId){$preManifest.runId}else{$preProgress.runId}
            $result=[ordered]@{status='inspected';runId=$runId;rootState='not-checked';workerState='not-checked';accountingState='not-checked';resumeAllowed=$false;resumeCommand=$null;reason='source-mismatch'}
            $result|ConvertTo-Json -Depth 10; exit 0
        }
    }
    # Recheck stop evidence after source hashing and immediately before any
    # saved worker/launch/process-started tuple is read by Get-RunContext.
    $gateManifest=$null; $gateProgress=$null
    try {
        if (Test-Path -LiteralPath $preManifestPath -PathType Leaf) { $gateManifest=Read-RunJson $preManifestPath }
        if (Test-Path -LiteralPath $preProgressPath -PathType Leaf) { $gateProgress=Read-RunJson (Get-RunContainedPath $runRoot $preProgressPath 'progress.json') }
    } catch {
        if ($Action -in @('inspect','resume')) {
            $result=[ordered]@{status='inspected';runId=$null;rootState='not-checked';workerState='not-checked';accountingState='not-checked';resumeAllowed=$false;resumeCommand=$null;reason='source-mismatch'}
            $result|ConvertTo-Json -Depth 10; exit 0
        }
        throw
    }
    $ownerStopped=(Test-Path -LiteralPath (Join-Path $runRoot 'owner-stop.json')) -or
        [string]$gateManifest.status -ceq 'owner-stopped' -or [string]$gateProgress.status -ceq 'owner-stopped'
    if ($ownerStopped) {
        if ($Action -in @('inspect','resume')) {
            $runId=if($null -ne $gateManifest.runId){$gateManifest.runId}else{$gateProgress.runId}
            $result=[ordered]@{status='inspected';runId=$runId;rootState='not-checked';workerState='not-checked';accountingState='not-checked';resumeAllowed=$false;resumeCommand=$null;reason='owner-stopped'}
            $result|ConvertTo-Json -Depth 10; exit 0
        }
        throw 'owner-stopped: resume/control is refused before process lookup or mutation.'
    }
    $context=Get-RunContext $runRoot
    $s=$context.started
    # Recheck stop evidence after saved-source validation and before any live lookup.
    $lateProgressPath=Join-Path $runRoot 'probe/progress.json'
    $lateProgress=$null
    if (Test-Path -LiteralPath $lateProgressPath -PathType Leaf) { $lateProgress=Read-RunJson (Get-RunContainedPath $runRoot $lateProgressPath 'progress.json') }
    $ownerStopped=(Test-Path -LiteralPath (Join-Path $runRoot 'owner-stop.json')) -or
        [string]$context.manifest.status -ceq 'owner-stopped' -or [string]$lateProgress.status -ceq 'owner-stopped'
    if ($ownerStopped) {
        if ($Action -in @('inspect','resume')) {
            $result=[ordered]@{status='inspected';runId=$s.runId;rootState='not-checked';workerState='not-checked';accountingState='not-checked';resumeAllowed=$false;resumeCommand=$null;reason='owner-stopped'}
            $result|ConvertTo-Json -Depth 10; exit 0
        }
        throw 'owner-stopped: resume/control is refused before process lookup or mutation.'
    }
    $states=Get-RunStates $context
    if ($states.root -in @('unknown','identity-conflict') -or $states.worker -in @('unknown','identity-conflict')) { throw 'Process identity is unknown or conflicts with PID/start tuple.' }
    if ($Action -in @('inspect','resume')) {
        $reason=if($states.root -ne 'absent' -or $states.worker -ne 'absent'){'process-active'}else{'reconcile-required'}
        # A clean reconcile commit is required before offering a resume command.
        $allowed=$false; $command=$null
        $commitPath=Join-Path $context.run 'reconcile-commit.json'
        if ($reason -eq 'reconcile-required' -and (Test-Path -LiteralPath $commitPath)) {
            $commit=Read-RunJson $commitPath
            if ($commit.schemaVersion -eq 1 -and $commit.runId -eq $s.runId -and $commit.resumeAllowed -eq $true) {
                $allowed=$true; $reason='reconciled'
                $runner=Join-Path $PSScriptRoot '../completion/stage-3/runVariant2.ps1'
                $command='& "'+[IO.Path]::GetFullPath($runner)+'" -Resume -RunFolder "'+$context.run+'"'
            }
        }
        $result=[ordered]@{status='inspected';runId=$s.runId;rootState=$states.root;workerState=$states.worker;resumeAllowed=$allowed;resumeCommand=$command;reason=$reason}
        Add-RunInspectionAccounting $result $context $s
        $result|ConvertTo-Json -Depth 10; exit 0
    }
    if ($states.root -ne 'alive' -or $states.worker -ne 'alive') { throw 'Control requires both exact live identities.' }
    $request=[ordered]@{schemaVersion=1;requestId=[guid]::NewGuid().ToString();runId=$s.runId;action=$Action;requestedAtUtc=[DateTime]::UtcNow.ToString('o');rootProcessId=$s.rootProcessId;processStartTimeUtc=$s.processStartTimeUtc;workerProcessId=$s.workerProcessId;workerProcessStartTimeUtc=$s.workerProcessStartTimeUtc}
    if ($Action -eq 'stop-after-case') { Write-RunJson (Join-Path $context.run 'stop-after-case.request.json') $request }
    Write-RunJson (Join-Path $context.processFolder 'control-request.json') $request
    [ordered]@{status='requested';requestId=$request.requestId;runId=$s.runId;action=$Action}|ConvertTo-Json
    exit 0
} catch {
    [ordered]@{status='rejected';reason=$_.Exception.Message;resumeAllowed=$false;resumeCommand=$null}|ConvertTo-Json
    exit 1
}
