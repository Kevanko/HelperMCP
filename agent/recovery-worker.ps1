param([Parameter(Mandatory=$true)][string]$JobDirectory, [ValidateSet('run','recover','commit','preflight')][string]$Action = 'recover')
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -le 5) { $env:PSModulePath = (Join-Path $PSHOME 'Modules') + ';' + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules') }

function Read-State {
    for($attempt=0;$attempt -lt 20;$attempt++){
        $stream=$null;$reader=$null
        try {
            $stream=[IO.File]::Open((Join-Path $JobDirectory 'state.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=New-Object IO.StreamReader $stream
            return ($reader.ReadToEnd()|ConvertFrom-Json)
        } catch [IO.IOException]{if($attempt -eq 19){throw};Start-Sleep -Milliseconds 25}
        finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
    }
}
function Save-State($s) {
    $s.updated_utc = [DateTime]::UtcNow.ToString('o')
    $path = Join-Path $JobDirectory 'state.json'; $tmp = $path + '.new'
    [IO.File]::WriteAllText($tmp, ($s | ConvertTo-Json -Depth 14), (New-Object Text.UTF8Encoding $true))
    # Atomic replacement: power loss must not leave a half-written undo journal.
    for($attempt=0;$attempt -lt 20;$attempt++){
        try {
            if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, $path + '.bak') } else { [IO.File]::Move($tmp, $path) }
            break
        } catch [IO.IOException]{if($attempt -eq 19){throw};Start-Sleep -Milliseconds 25}
    }
}
function Adapter($step) {
    $a = Get-NetAdapter -IncludeHidden -InterfaceIndex ([int]$step.interface_index) -ErrorAction Stop
    if ([string]$a.InterfaceGuid -ne [string]$step.interface_guid) { throw 'Adapter identity changed; refusing to alter a recycled index' }
    $a
}
function Run-Netsh($argsList) {
    $psi = New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\netsh.exe"
    # All values originate from validated indices and IPv4 addresses.
    $psi.Arguments = ($argsList -join ' '); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $p = New-Object Diagnostics.Process; $p.StartInfo=$psi
    try {
        [void]$p.Start(); $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(8000)) { $p.Kill(); throw 'netsh DNS operation timeout; rollback remains armed' }
        if ($p.ExitCode -ne 0) { throw 'netsh DNS operation failed' }
    } finally { $p.Dispose() }
}
function Set-Dns4($step, $servers) {
    $null = Adapter $step
    if (-not @($servers).Count) { Run-Netsh @('interface','ipv4','set','dnsservers',"name=$($step.interface_index)",'source=dhcp'); return }
    Run-Netsh @('interface','ipv4','set','dnsservers',"name=$($step.interface_index)",'source=static',"address=$($servers[0])",'validate=no')
    for ($n = 1; $n -lt $servers.Count; $n++) { Run-Netsh @('interface','ipv4','add','dnsservers',"name=$($step.interface_index)","address=$($servers[$n])","index=$($n + 1)",'validate=no') }
}
function Service($step) {
    $service = Get-CimInstance Win32_Service -Filter ("Name='" + $step.name.Replace("'", "''") + "'") -ErrorAction Stop
    if (-not $service -or $service.PathName -ne $step.service_path) { throw 'Service identity changed; refusing replacement binary' }
    $service
}
function Service-State($step, $running) {
    $null = Service $step
    Add-Type -AssemblyName System.ServiceProcess
    $controller = New-Object System.ServiceProcess.ServiceController $step.name
    try {
        if ($running) {
            if ($controller.Status -eq 'StopPending') { $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(8)) }
            $controller.Refresh()
            if ($controller.Status -ne 'Running') { $controller.Start() }
            $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(8))
        } else {
            $controller.Stop()
            $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(8))
        }
    } finally { $controller.Dispose() }
}
function Run-Script($step, $kind) {
    $bytes=[Convert]::FromBase64String([string]$step.($kind+'_b64'))
    $hash=[Security.Cryptography.SHA256]::Create()
    try { $actual=[BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
    if ($actual -ne [string]$step.($kind+'_sha256')) { throw 'Recovery script hash mismatch' }
    $path=Join-Path $JobDirectory ($actual+'.ps1')
    [IO.File]::WriteAllBytes($path,$bytes)
    # No credentials/command output enter the relay log. Scripts must implement
    # idempotent undo and must not detach their own background processes.
    $code='$ErrorActionPreference="Stop"; $global:LASTEXITCODE=0; try { & '''+$path.Replace("'","''")+''' *> $null; if($LASTEXITCODE -ne 0){exit 1};exit 0 } catch {exit 1}'
    $psi=New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.WorkingDirectory=$JobDirectory
    $p=New-Object Diagnostics.Process; $p.StartInfo=$psi; $started=$false
    try {
        [void]$p.Start();$started=$true
        if(-not $p.WaitForExit([int]$step.timeout_s * 1000)){throw 'Guarded script timed out'}
        if($p.ExitCode -ne 0){throw 'Guarded script failed; inspect its authored logic. Output is suppressed.'}
    } finally {
        if($started -and -not $p.HasExited){& "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>$null | Out-Null}
        $p.Dispose()
    }
}
function Apply-Step($step) {
    switch ($step.op) {
        'script' { Run-Script $step 'apply' }
        'adapter_disable' { Adapter $step | Disable-NetAdapter -Confirm:$false -ErrorAction Stop }
        'mtu_set' { $null = Adapter $step; Set-NetIPInterface -InterfaceIndex $step.interface_index -AddressFamily IPv4 -NlMtuBytes $step.mtu -PolicyStore ActiveStore -ErrorAction Stop }
        'dns_set' { Set-Dns4 $step @($step.servers) }
        'route_remove' {
            $null = Adapter $step
            $route = @(Get-NetRoute -PolicyStore ActiveStore -DestinationPrefix $step.destination -InterfaceIndex $step.interface_index -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $step.gateway })
            if ($route.Count -ne 1 -or [int]$route[0].RouteMetric -ne [int]$step.metric) { throw 'Route changed since snapshot' }
            $route[0] | Remove-NetRoute -Confirm:$false -ErrorAction Stop
        }
        'service_stop' { Service-State $step $false }
        default { throw 'Unsupported mutation' }
    }
}
function Undo-Step($step) {
    switch ($step.op) {
        'script' { Run-Script $step 'undo' }
        'adapter_disable' {
            $a = Adapter $step
            if ([string]$a.AdminStatus -ne 'Up') { $a | Enable-NetAdapter -Confirm:$false -ErrorAction Stop }
        }
        'dns_set' { Set-Dns4 $step @($step.before_servers) }
        'mtu_set' { $null = Adapter $step; Set-NetIPInterface -InterfaceIndex $step.interface_index -AddressFamily IPv4 -NlMtuBytes $step.before_mtu -PolicyStore ActiveStore -ErrorAction Stop }
        'route_remove' {
            $null = Adapter $step
            $existing = @(Get-NetRoute -PolicyStore ActiveStore -DestinationPrefix $step.destination -InterfaceIndex $step.interface_index -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $step.gateway })
            if ($existing.Count -eq 0) { $null = New-NetRoute -DestinationPrefix $step.destination -InterfaceIndex $step.interface_index -NextHop $step.gateway -RouteMetric $step.metric -PolicyStore ActiveStore -ErrorAction Stop }
            elseif ($existing.Count -ne 1 -or [int]$existing[0].RouteMetric -ne [int]$step.metric) { throw 'A competing route replaced the snapshot; manual review required' }
        }
        'service_stop' {
            Service-State $step $true
        }
    }
}
function Remove-Guard($s) { Unregister-ScheduledTask -TaskName $s.task_name -Confirm:$false -ErrorAction SilentlyContinue }
function Restore-Entries($s) {
    $failures = @()
    for ($i = $s.undo.Count - 1; $i -ge 0; $i--) {
        if ($s.undo[$i].restored) { continue }
        try { Undo-Step $s.undo[$i]; $s.undo[$i].restored = $true; Save-State $s }
        catch { $failures += @{ index = $i; message = $_.Exception.Message } }
    }
    $s.errors = $failures
    Save-State $s
}
function Rollback($s) {
    $s | Add-Member -NotePropertyName rollback_actor -NotePropertyValue @{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;pid=$PID;action=$Action;at=[DateTime]::UtcNow.ToString('o')} -Force
    $s.status = 'rolling_back'; Save-State $s
    Restore-Entries $s
    if ($s.errors.Count) { $s.status = 'rollback_failed' } else { $s.status = 'rolled_back'; Remove-Guard $s }
    Save-State $s
}

function Invoke-RecoveryWorker {
    $jobPath = [IO.Path]::GetFullPath($JobDirectory)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($jobPath.ToLowerInvariant()))).Replace('-','').Substring(0,24) } finally { $hash.Dispose() }
    $mutex = New-Object Threading.Mutex $false, ('Global\HelperNetworkRecovery-' + $key)
    try {
        $locked = $false
        try { $locked = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Recovery worker busy; retry status/rollback shortly' }
        try {
            $s = Read-State
            if ($Action -eq 'preflight') {
                $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $s | Add-Member -NotePropertyName guard_identity -NotePropertyValue $sid -Force
                $s.guard_ready = $sid -eq 'S-1-5-18'; $s.guard_pid = $PID; Save-State $s; return
            }
            if ($s.status -in @('committed','rolled_back')) { return }
            if ($Action -eq 'commit') {
                if ($s.status -ne 'awaiting_commit' -or [DateTime]::UtcNow -ge [DateTime]::Parse($s.deadline_utc).ToUniversalTime()) { throw 'Job is not eligible for commit; deadline or recovery already reached' }
                if (-not $s.allow_commit) { throw 'This scenario always rolls back; it cannot be committed' }
                $s.status = 'committed'; Save-State $s; Remove-Guard $s; return
            }
            if ($Action -eq 'recover' -or [DateTime]::UtcNow -ge [DateTime]::Parse($s.deadline_utc).ToUniversalTime()) { Rollback $s; return }
            if ($s.status -ne 'armed') { return }
            $s.status = 'running'; Save-State $s
        } finally { $mutex.ReleaseMutex(); $locked = $false }
        try {
            foreach ($step in $s.steps) {
                if ($step.op -eq 'wait') {
                    $end = [DateTime]::UtcNow.AddSeconds([int]$step.seconds)
                    while ([DateTime]::UtcNow -lt $end) {
                        Start-Sleep -Milliseconds 250
                        $current = Read-State
                        if ($current.status -ne 'running' -or [DateTime]::UtcNow -ge [DateTime]::Parse($current.deadline_utc).ToUniversalTime()) { break }
                    }
                    continue
                }
                try { $locked = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked = $true }
                if (-not $locked) { throw 'Mutation lock timeout' }
                try {
                    $s = Read-State
                    if ($s.status -ne 'running') { return }
                    if ([DateTime]::UtcNow -ge [DateTime]::Parse($s.deadline_utc).ToUniversalTime()) { Rollback $s; return }
                    if ($step.op -eq 'restore') {
                        Restore-Entries $s
                        if ($s.errors.Count) { throw 'Intermediate restore failed' }
                        continue
                    }
                    if ($step.op -eq 'probe') {
                        if (-not ('NRecovery.Network' -as [type])) { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $JobDirectory 'network.cs')).Replace('__BUILD__','Recovery')) }
                        $u = [Uri]$step.url; $target = New-Object 'NRecovery.Network+Target' -Property @{ host = $u.DnsSafeHost; port = $u.Port; http = $true; tls = $u.Scheme -eq 'https'; path = $u.AbsolutePath }
                        $path = [NRecovery.Network]::Paths([int]$step.interface_index, $false)[0]
                        $result = [NRecovery.Network]::Check($path, $target, 1, 1000, $false, '1.1.1.1', [DateTime]::UtcNow.AddSeconds(5))
                        $row = @{ at = [DateTime]::UtcNow.ToString('o'); interface_index = $path.index; host = $target.host; dns = @($result.dns); samples = @($result.samples); findings = $result.findings }
                        if (-not $s.PSObject.Properties['probes']) { $s | Add-Member -NotePropertyName probes -NotePropertyValue @() }
                        $s.probes = @($s.probes) + @($row); Save-State $s; continue
                    }
                    # Persist undo BEFORE applying, so termination between the two
                    # operations still leaves a recoverable journal.
                    $step | Add-Member -NotePropertyName restored -NotePropertyValue $false -Force
                    $s.undo = @($s.undo) + @($step); Save-State $s
                    Apply-Step $step
                } finally { $mutex.ReleaseMutex(); $locked = $false }
            }
            try { $locked = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked = $true }
            if (-not $locked) { throw 'Completion lock timeout' }
            try {
                $s = Read-State
                if ($s.status -eq 'running') {
                    if ($s.allow_commit) { $s.status = 'awaiting_commit'; Save-State $s }
                    else { Rollback $s }
                }
            } finally { $mutex.ReleaseMutex(); $locked = $false }
        } catch {
            try { $locked = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked = $true }
            if ($locked) { try { $s = Read-State; $s.failure = $_.Exception.Message; Save-State $s; if ($s.status -notin @('rolled_back','committed')) { Rollback $s } } finally { $mutex.ReleaseMutex(); $locked = $false } }
            throw
        }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

# Test harness can load functions without invoking mutations.
if ($env:HELPER_RECOVERY_LIBRARY_ONLY -ne '1') { Invoke-RecoveryWorker }
