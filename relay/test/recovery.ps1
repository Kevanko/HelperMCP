$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert($condition, $message) { if (-not $condition) { throw $message } }
foreach ($file in 'recovery.ps1','recovery-worker.ps1') {
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "agent/$file"), [ref]$null, [ref]$errors) | Out-Null
    Assert (-not $errors) ($errors | Out-String)
}
$temp = Join-Path $env:TEMP ('hm-recovery-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
$env:HELPER_RECOVERY_LIBRARY_ONLY = '1'
. (Join-Path $root 'agent/recovery-worker.ps1') -JobDirectory $temp
$recovery = [IO.File]::ReadAllText((Join-Path $root 'agent/recovery.ps1')).Replace('__RECOVERY_WORKER_B64__', [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'agent/recovery-worker.ps1')))).Replace('__RECOVERY_NETWORK_B64__', [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'agent/network.cs'))))
Invoke-Expression $recovery
Remove-Item Env:HELPER_RECOVERY_LIBRARY_ONLY
$script:Changes = New-Object Collections.ArrayList
$script:AdapterUp = $true
$script:FailRestore = $false
function Get-NetAdapter { param([switch]$IncludeHidden, $InterfaceIndex, $ErrorAction) [pscustomobject]@{ InterfaceGuid = 'fixture-guid'; ifIndex = 42; AdminStatus = $(if ($script:AdapterUp) { 'Up' } else { 'Down' }) } }
function Disable-NetAdapter { param([Parameter(ValueFromPipeline=$true)]$InputObject, $Confirm) process { $script:AdapterUp = $false; [void]$script:Changes.Add('disable') } }
function Enable-NetAdapter { param([Parameter(ValueFromPipeline=$true)]$InputObject, $Confirm) process { if ($script:FailRestore) { throw 'fixture restore failed' }; $script:AdapterUp = $true; [void]$script:Changes.Add('enable') } }
function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) [void]$script:Changes.Add('unregister') }
function New-State($steps, $allow=$false) {
    $s = [pscustomobject]@{ id = '123456789012345678901234'; task_name = 'fixture-task'; status = 'armed'; steps = @($steps); undo = @(); probes = @(); errors = @(); failure = $null; guard_ready = $false; guard_pid = 0; allow_commit = $allow; created_utc = [DateTime]::UtcNow.ToString('o'); updated_utc = [DateTime]::UtcNow.ToString('o'); deadline_utc = [DateTime]::UtcNow.AddSeconds(60).ToString('o') }
    [IO.File]::WriteAllText((Join-Path $temp 'state.json'), ($s | ConvertTo-Json -Depth 14))
}
$step = [pscustomobject]@{ op = 'adapter_disable'; interface_index = 42; interface_guid = 'fixture-guid' }
try {
    # A reader holding the old journal must not prevent an atomic replacement.
    # This reproduced during real SYSTEM preflight polling on Windows 11.
    New-State @()
    $journal=Join-Path $temp 'state.json'
    $readerStream=[IO.File]::Open($journal,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $state=Recovery-Read $temp; $state.status='running'; Save-State $state
        Assert ((Recovery-Read $temp).status -eq 'running') 'atomic journal replacement was blocked by reader'
        $oldReader=New-Object IO.StreamReader $readerStream
        try { Assert (($oldReader.ReadToEnd()|ConvertFrom-Json).status -eq 'armed') 'open journal reader saw a partial replacement' }
        finally { $oldReader.Dispose() }
    } finally { $readerStream.Dispose() }
    Write-Output 'recovery concurrent reader and atomic journal replacement PASS'

    New-State @($step)
    $Action = 'run'; Invoke-RecoveryWorker
    $s = Read-State
    Assert ($s.status -eq 'rolled_back' -and $script:AdapterUp -and $s.undo[0].restored) 'default scenario did not restore'
    Assert (($script:Changes -join ',') -eq 'disable,enable,unregister') 'incorrect rollback order'
    Write-Output 'recovery default offline apply/rollback PASS'

    $script:Changes.Clear(); New-State @($step, [pscustomobject]@{op='restore'}, $step)
    $Action = 'run'; Invoke-RecoveryWorker
    Assert (($script:Changes -join ',') -eq 'disable,enable,disable,enable,unregister') 'intermediate restore did not permit subsequent scenario'
    Write-Output 'recovery background restore/continue PASS'

    New-State @($step) $true
    $Action = 'run'; Invoke-RecoveryWorker
    $s = Read-State
    Assert ($s.status -eq 'awaiting_commit' -and -not $script:AdapterUp -and $s.undo.Count -eq 1) 'undo not journaled before disconnect'
    # Simulate dead scenario process: a new recovery invocation needs no relay.
    $Action = 'recover'; Invoke-RecoveryWorker
    Assert ((Read-State).status -eq 'rolled_back' -and $script:AdapterUp) 'independent recovery failed'
    Write-Output 'recovery abandoned mutation / independent worker PASS'

    New-State @($step) $true; $Action='run'; Invoke-RecoveryWorker
    $script:FailRestore = $true; $Action='recover'; Invoke-RecoveryWorker
    Assert ((Read-State).status -eq 'rollback_failed' -and -not (Read-State).undo[0].restored) 'failed restore removed retry state'
    $script:FailRestore = $false; Invoke-RecoveryWorker
    Assert ((Read-State).status -eq 'rolled_back') 'retry failed'
    Write-Output 'recovery retry after restore failure PASS'

    New-State @($step) $true; $Action='run'; Invoke-RecoveryWorker
    $s = Read-State; $s.deadline_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o'); Save-State $s
    $Action='commit'
    try { Invoke-RecoveryWorker; throw 'expired commit accepted' } catch { Assert ($_.Exception.Message -match 'eligible') 'deadline commit error' }
    $Action='recover'; Invoke-RecoveryWorker
    Write-Output 'recovery expired commit rejected PASS'

    New-State @($step) $true; $Action='run'; Invoke-RecoveryWorker
    $Action='commit'; Invoke-RecoveryWorker
    Assert ((Read-State).status -eq 'committed') 'explicit commit failed'
    $script:AdapterUp = $true
    Write-Output 'recovery explicit commit state machine PASS'

    New-State @($step)
    $Action='preflight'; Invoke-RecoveryWorker
    Assert ((Read-State).guard_identity -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -and (Read-State).status -eq 'armed') 'preflight changed network or identity wrong'
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { Assert (-not (Read-State).guard_ready) 'non-SYSTEM preflight accepted' }
    $mismatch = [pscustomobject]@{ op='adapter_disable'; interface_index=42; interface_guid='recycled-index' }
    try { Adapter $mismatch; throw 'recycled adapter accepted' } catch { Assert ($_.Exception.Message -match 'identity changed') 'identity guard' }
    foreach ($name in 'guard-selftest','disconnect','adapter-cycle','zapret-ab','warp-cycle','fake-dns','stale-route','mtu-trial') {
        $a = @{ template=$name; interface_index=42; interface_indices=@(42); service=$(if($name -eq 'warp-cycle'){'CloudflareWARP'}else{'zapret'}); servers=@('1.1.1.1'); destination='198.18.0.0/24'; gateway='192.168.0.1' }
        $steps = @(Recovery-TemplateSteps $a)
        Assert ($steps.Count -gt 0 -and $steps.Count -le 12) "invalid template $name"
    }
    Write-Output 'recovery preflight, identity, templates PASS'

    # Real child scripts touch ONLY a marker in this fixture directory.
    $marker = Join-Path $temp 'script-marker.txt'
    $apply = Join-Path $temp 'apply.ps1'; $undo = Join-Path $temp 'undo.ps1'
    [IO.File]::WriteAllText($apply, "[IO.File]::WriteAllText('$($marker.Replace("'","''"))','fixture')")
    [IO.File]::WriteAllText($undo, "if([IO.File]::Exists('$($marker.Replace("'","''"))')){[IO.File]::Delete('$($marker.Replace("'","''"))')}")
    $scriptStep = Recovery-Snapshot @{op='script';apply_path=$apply;undo_path=$undo;timeout_s=3}
    # Edit original after snapshot: the frozen copy must run, not the replacement.
    [IO.File]::WriteAllText($apply, "throw 'edited source must never execute'")
    New-State @($scriptStep)
    $Action='run'; Invoke-RecoveryWorker
    Assert ((Read-State).status -eq 'rolled_back' -and -not [IO.File]::Exists($marker)) 'custom script freeze/rollback failed'
    [IO.File]::WriteAllText($apply, "[IO.File]::WriteAllText('$($marker.Replace("'","''"))','fixture'); Start-Sleep -Seconds 20")
    $scriptStep = Recovery-Snapshot @{op='script';apply_path=$apply;undo_path=$undo;timeout_s=2}
    New-State @($scriptStep)
    $Action='run'
    try { Invoke-RecoveryWorker; throw 'script timeout not enforced' } catch { Assert ($_.Exception.Message -match 'timed out') 'script timeout error' }
    Assert ((Read-State).status -eq 'rolled_back' -and -not [IO.File]::Exists($marker)) 'timed-out script not undone'
    Write-Output 'recovery frozen custom scripts, child timeout and explicit undo PASS'

    # Failure to arm the SYSTEM preflight must make mutation impossible.
    function Test-Admin { $true }
    function Ensure-Network { }
    function Recovery-Root { $temp }
    function Recovery-SecureDirectory($dir) { }
    function New-ScheduledTaskAction { throw 'fixture scheduler unavailable' }
    function Quote-Arg($s) { '"' + $s + '"' }
    Remove-Item -LiteralPath (Join-Path $temp 'state.json') -Force
    $script:Changes.Clear()
    try { Recovery-Operation ('{"op":"start","steps":[{"op":"wait","seconds":1}]}'|ConvertFrom-Json); throw 'scheduler failure accepted' }
    catch { Assert ($_.Exception.Message -match 'scheduler unavailable') 'preparation error not propagated' }
    Assert (-not $script:Changes.Contains('disable')) 'mutation started without guard'
    Write-Output 'recovery fail-closed scheduler preparation PASS'
} finally {
    $script:AdapterUp = $true
    # Only this fixture directory is removed; no real adapters/tasks changed.
    Remove-Item -LiteralPath $temp -Recurse -Force
}
