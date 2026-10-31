# The relay embeds the worker. It is saved outside the repository, next to the
# saved session, only when an explicit guarded network job is requested.
function Recovery-Root { Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'HelperMCP-NetworkRecovery' }
function Recovery-PrincipalSid($userId) {
    try {
        $name = ([string]$userId).Trim()
        if (-not $name) { return '' }
        if ($name -match '^S-\d(-\d+)+$') { return (New-Object Security.Principal.SecurityIdentifier $name).Value }
        return (New-Object Security.Principal.NTAccount $name).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { return '' }
}
function Recovery-SecureDirectory($dir) {
    if ((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery directory cannot be a reparse point' }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule ((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    # A non-elevated user can inspect status but must not replace a SYSTEM worker.
    $reader = New-Object Security.AccessControl.FileSystemAccessRule ([Security.Principal.WindowsIdentity]::GetCurrent().User, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    [void]$acl.AddAccessRule($reader)
    Set-Acl -LiteralPath $dir -AclObject $acl
}
function Recovery-Job($id) {
    if ([string]$id -notmatch '^[a-f0-9]{24}$') { throw 'Invalid recovery job id' }
    $dir = Join-Path (Recovery-Root) $id
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'state.json'))) { throw 'Unknown local recovery job' }
    $dir
}
function Recovery-Read($dir) {
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        $stream=$null; $reader=$null
        try {
            $stream=[IO.File]::Open((Join-Path $dir 'state.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=New-Object IO.StreamReader $stream
            return ($reader.ReadToEnd() | ConvertFrom-Json)
        } catch [IO.IOException] { if($attempt -eq 19){throw}; Start-Sleep -Milliseconds 25 }
        finally { if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()} }
    }
}
function Recovery-Summary($dir) {
    $s = Recovery-Read $dir
    @{ id = $s.id; status = $s.status; deadline_utc = $s.deadline_utc; created_utc = $s.created_utc; allow_commit = $s.allow_commit; guard_ready = $s.guard_ready; guard_identity = $s.guard_identity; rollback_actor = $s.rollback_actor; failure = $s.failure; errors = @($s.errors); probes = @($s.probes); undo_total = @($s.undo).Count; undo_remaining = @($s.undo | Where-Object { -not $_.restored }).Count; steps = @($s.steps | ForEach-Object { @{ op = $_.op; interface_index = $_.interface_index; service = $_.name; seconds = $_.seconds } }) }
}
function Recovery-Templates {
    @(
        @{ id = 'guard-selftest'; purpose = 'Verify SYSTEM preflight and local worker with a bound probe; no network settings changed'; parameters = 'interface_index, url' },
        @{ id = 'disconnect'; purpose = 'Disable specified adapters temporarily, then restore and probe; always rollback'; parameters = 'interface_indices[], seconds=10, url' },
        @{ id = 'adapter-cycle'; purpose = 'Cycle one adapter, preserving its identity; always rollback'; parameters = 'interface_index, seconds=3, url' },
        @{ id = 'zapret-ab'; purpose = 'Probe before/without/after the selected zapret service; no TUN switching'; parameters = 'service, interface_index, url' },
        @{ id = 'warp-cycle'; purpose = 'Stop/start the selected running WARP service, not registration reset'; parameters = 'service, interface_index, url' },
        @{ id = 'fake-dns'; purpose = 'Trial real IPv4 DNS with original static/DHCP mode saved'; parameters = 'interface_index, servers[], url' },
        @{ id = 'stale-route'; purpose = 'Trial removal of one exact nonpersistent manual route'; parameters = 'interface_index, destination, gateway, url' },
        @{ id = 'mtu-trial'; purpose = 'IPv4 MTU trial with exact original value restored'; parameters = 'interface_index, mtu=1400, url' }
    )
}
function Recovery-TemplateSteps($a) {
    $index = [int]$a.interface_index
    $url = if ($a.url) { [string]$a.url } else { 'https://www.microsoft.com/' }
    $probe = @{ op = 'probe'; interface_index = $index; url = $url }
    switch ([string]$a.template) {
        'guard-selftest' { @{op='wait';seconds=1}; $probe }
        'disconnect' {
            $indices = @($a.interface_indices | Select-Object -Unique)
            if (-not $indices.Count -or $indices.Count -gt 6) { throw 'disconnect requires 1..6 explicit interface_indices' }
            foreach ($i in $indices) { @{ op = 'adapter_disable'; interface_index = [int]$i } }
            @{ op = 'wait'; seconds = $(if ($a.seconds) { [int]$a.seconds } else { 10 }) }
            @{ op = 'restore' }; @{ op = 'wait'; seconds = 5 }; $probe
        }
        'adapter-cycle' { @{ op = 'adapter_disable'; interface_index = $index }; @{ op = 'wait'; seconds = $(if ($a.seconds) { [int]$a.seconds } else { 3 }) }; @{ op = 'restore' }; @{ op = 'wait'; seconds = 5 }; $probe }
        { $_ -in @('zapret-ab','warp-cycle') } {
            if ($a.template -eq 'warp-cycle' -and [string]$a.service -notmatch '^(warp-svc|CloudflareWARP)$') { throw 'warp-cycle requires the exact WARP service name' }
            if ($a.template -eq 'zapret-ab' -and [string]$a.service -notmatch '^(zapret[\w.-]*|winws[\w.-]*|GoodbyeDPI)$') { throw 'zapret-ab requires the exact zapret service name' }
            $probe; @{ op = 'service_stop'; name = [string]$a.service }; @{ op = 'wait'; seconds = 3 }; $probe; @{ op = 'restore' }; @{ op = 'wait'; seconds = 5 }; $probe
        }
        'fake-dns' { $probe; @{ op = 'dns_set'; interface_index = $index; servers = @($a.servers) }; @{ op = 'wait'; seconds = 2 }; $probe }
        'stale-route' { $probe; @{ op = 'route_remove'; interface_index = $index; destination = [string]$a.destination; gateway = [string]$a.gateway }; $probe }
        'mtu-trial' { $probe; @{ op = 'mtu_set'; interface_index = $index; mtu = $(if ($a.mtu) { [int]$a.mtu } else { 1400 }) }; $probe }
        default { throw 'Unknown recovery template; use op=templates' }
    }
}
function Recovery-Launch($dir, $action) {
    $psi = New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Arg (Join-Path $dir 'worker.ps1')) + ' -JobDirectory ' + (Quote-Arg $dir) + ' -Action ' + $action
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables.Remove('HELPER_RECOVERY_LIBRARY_ONLY')
    [Diagnostics.Process]::Start($psi)
}
function Recovery-Snapshot($step) {
    $op = [string]$step.op
    if ($op -eq 'script') {
        $timeout = if ($step.timeout_s) { [int]$step.timeout_s } else { 10 }
        if ($timeout -lt 2 -or $timeout -gt 20) { throw 'Guarded script timeout_s must be 2..20' }
        $copy = @{ op='script'; timeout_s=$timeout }
        foreach ($kind in 'apply','undo') {
            $path = [string]$step.($kind + '_path')
            if (-not $path -or [IO.Path]::GetExtension($path) -ne '.ps1' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'script requires existing local apply_path AND undo_path .ps1 files' }
            $file = Get-Item -LiteralPath $path
            if ($file.Length -gt 256KB -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery scripts must be regular .ps1 files <=256 KiB' }
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $text = [IO.File]::ReadAllText($file.FullName); $errors=$null
            [Management.Automation.Language.Parser]::ParseInput($text,[ref]$null,[ref]$errors) | Out-Null
            if ($errors) { throw 'Guarded script has PowerShell syntax errors; no changes were made' }
            # Normalize UTF-8 BOM for Windows PowerShell 5.1, then freeze a copy.
            $encoding=New-Object Text.UTF8Encoding $true
            $bytes = $encoding.GetPreamble() + $encoding.GetBytes($text.TrimStart([char]0xfeff))
            $hash=[Security.Cryptography.SHA256]::Create()
            try { $copy[$kind+'_sha256']=[BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
            $copy[$kind+'_b64']=[Convert]::ToBase64String($bytes)
        }
        return $copy
    }
    if ($op -eq 'restore') { return @{ op = 'restore' } }
    if ($op -eq 'probe') {
        $uri = $null
        if (-not [Uri]::TryCreate([string]$step.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('https','http') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Background probe needs http(s) URL without credentials/query/fragment' }
        return @{ op = 'probe'; url = $uri.AbsoluteUri; interface_index = [int]$step.interface_index }
    }
    if ($op -eq 'wait') {
        if ([int]$step.seconds -lt 1 -or [int]$step.seconds -gt 60) { throw 'wait seconds must be 1..60' }
        return @{ op = 'wait'; seconds = [int]$step.seconds }
    }
    $copy = @{ op = $op }
    if ($op -in @('adapter_disable','dns_set','route_remove','mtu_set')) {
        $a = Get-NetAdapter -IncludeHidden -InterfaceIndex ([int]$step.interface_index) -ErrorAction Stop
        if ([string]$a.AdminStatus -ne 'Up') { throw 'Only administratively enabled adapters can be modified' }
        $copy.interface_index = [int]$a.ifIndex; $copy.interface_guid = [string]$a.InterfaceGuid
    }
    switch ($op) {
        'adapter_disable' { }
        'mtu_set' {
            $mtu = [int]$step.mtu
            if ($mtu -lt 1280 -or $mtu -gt 1500) { throw 'IPv4 MTU test limited to 1280..1500' }
            $before = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop
            $copy.before_mtu = [int]$before.NlMtu; $copy.mtu = $mtu
        }
        'dns_set' {
            $servers = @($step.servers | Where-Object { $_ })
            if (-not $servers.Count -or $servers.Count -gt 3) { throw 'Specify 1..3 IPv4 DNS servers' }
            foreach ($server in $servers) {
                $ip = $null
                if (-not [Net.IPAddress]::TryParse([string]$server, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [N__BUILD__.Network]::Fake([string]$server) -or [string]$server -eq '0.0.0.0') { throw 'DNS must use real unicast IPv4 servers' }
            }
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + [string]$a.InterfaceGuid
            $static = [string](Get-ItemProperty -LiteralPath $key -ErrorAction Stop).NameServer
            $copy.before_servers = @($static -split '[,;\s]+' | Where-Object { $_ }); $copy.servers = $servers
        }
        'route_remove' {
            $routes = @(Get-NetRoute -PolicyStore ActiveStore -DestinationPrefix ([string]$step.destination) -InterfaceIndex $a.ifIndex -ErrorAction Stop | Where-Object { $_.NextHop -eq [string]$step.gateway })
            if ($routes.Count -ne 1) { throw 'Route selector must match exactly one ActiveStore route' }
            $r = $routes[0]
            if ([string]$r.Protocol -ne 'NetMgmt') { throw 'Only manually managed routes are supported; DHCP/kernel routes must not be removed' }
            $copy.destination = [string]$r.DestinationPrefix; $copy.gateway = [string]$r.NextHop; $copy.metric = [int]$r.RouteMetric
            $persistent = @(Get-NetRoute -PolicyStore PersistentStore -DestinationPrefix $copy.destination -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $copy.gateway })
            if ($persistent.Count) { throw 'Persistent routes are excluded from temporary route removal; edit through their owning configuration' }
        }
        'service_stop' {
            $name = [string]$step.name
            if ($name -notmatch '^(warp-svc|CloudflareWARP|zapret[\w.-]*|winws[\w.-]*|GoodbyeDPI)$') { throw 'Guarded service operation supports only explicit WARP/zapret/GoodbyeDPI services; core Windows services are excluded' }
            $svc = Get-CimInstance Win32_Service -Filter ("Name='" + $name + "'") -ErrorAction Stop
            if (-not $svc -or $svc.State -ne 'Running') { throw 'Service must currently be running' }
            $copy.name = $name; $copy.service_path = [string]$svc.PathName
            $dependents = @((Get-Service -Name $name).DependentServices | Where-Object { $_.Status -eq 'Running' })
            if ($dependents.Count) { throw 'Running dependent services prevent a bounded service rollback' }
        }
        default { throw 'Unsupported scenario step; allowed: wait, adapter_disable, dns_set, route_remove, service_stop' }
    }
    $copy
}
function Do-NetRecover($a) {
    $mutex = $null; $locked = $false
    try {
        if ($a.op -eq 'start') {
            $mutex = New-Object Threading.Mutex $false, 'Global\HelperNetworkRecovery-Prepare'
            try { $locked = $mutex.WaitOne(1000) } catch [Threading.AbandonedMutexException] { $locked = $true }
            if (-not $locked) { throw 'Another recovery preparation is running' }
        }
        Recovery-Operation $a
    } finally { if ($locked) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() } }
}
function Recovery-Operation($a) {
    $op = if ($a.op) { [string]$a.op } else { 'list' }
    if ($op -eq 'templates') { return @{ text = (@{ templates = @(Recovery-Templates); recipe = 'network-recovery' } | ConvertTo-Json -Depth 6 -Compress) } }
    if ($op -eq 'list') {
        $jobs = @(); $root = Recovery-Root
        if (Test-Path -LiteralPath $root) { foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 20)) { try { $jobs += Recovery-Summary $dir.FullName } catch { } } }
        return @{ text = (@{ jobs = $jobs } | ConvertTo-Json -Depth 7 -Compress) }
    }
    if ($op -eq 'status') { return @{ text = ((Recovery-Summary (Recovery-Job $a.job)) | ConvertTo-Json -Depth 7 -Compress) } }
    if ($op -in @('rollback','commit')) {
        if (-not (Test-Admin)) { throw 'Recovery/commit needs the elevated Helper that armed the job; the independent SYSTEM rollback remains scheduled.' }
        $dir = Recovery-Job $a.job
        if ($op -eq 'commit') {
            # This authenticated tool round trip alone is not enough: check that
            # the relay still accepts the session token on our current path.
            $check = Api '/a/event' @{ type = 'network-recovery'; msg = 'commit connectivity postcheck' } $script:Token 8
            if ($check.StatusCode -ne 200) { throw 'Commit denied: relay postcheck did not succeed' }
        }
        $p = Recovery-Launch $dir $(if ($op -eq 'commit') { 'commit' } else { 'recover' })
        try { if (-not $p.WaitForExit(15000)) { return @{ text = (@{ job = $a.job; status = 'worker_running'; next = 'net_recover status' } | ConvertTo-Json -Compress) } }; if ($p.ExitCode -ne 0) { throw 'Recovery action failed; inspect job status. Scheduled rollback remains armed.' } } finally { $p.Dispose() }
        return @{ text = ((Recovery-Summary $dir) | ConvertTo-Json -Depth 7 -Compress) }
    }
    if ($op -ne 'start') { throw 'Unknown net_recover operation' }
    if (-not (Test-Admin)) { throw 'Guarded network changes require an elevated Helper. No changes were made; use util elevate first.' }
    Ensure-Network
    $ttl = if ($a.rollback_after_s) { [int]$a.rollback_after_s } else { 120 }
    if ($ttl -lt 45 -or $ttl -gt 300) { throw 'rollback_after_s must be 45..300' }
    if ($a.template -and $a.steps) { throw 'Choose template OR steps, not both' }
    $raw = @(if ($a.template) { Recovery-TemplateSteps $a } else { $a.steps | Where-Object { $_ } })
    if (-not $raw.Count -or $raw.Count -gt 12) { throw 'Supply 1..12 declarative scenario steps' }
    $root = Recovery-Root; [void](New-Item -ItemType Directory -Path $root -Force)
    Recovery-SecureDirectory $root
    foreach ($other in @(Get-ChildItem -LiteralPath $root -Directory)) {
        try { $prior = Recovery-Read $other.FullName } catch { throw 'An unreadable recovery journal exists; inspect it before another mutation' }
        if ($prior.status -notin @('committed','rolled_back','preparation_failed')) { throw 'Another network recovery job is pending; inspect/rollback it first' }
    }
    $steps = @(); $waits = 0; $seen = @{}
    foreach ($step in $raw) {
        $snapshot = Recovery-Snapshot $step
        if ($snapshot.op -eq 'wait') { $waits += $snapshot.seconds }
        elseif ($snapshot.op -eq 'script') { $waits += $snapshot.timeout_s }
        elseif ($snapshot.op -notin @('restore','probe')) {
            $key = "$($snapshot.op):$($snapshot.interface_index):$($snapshot.name):$($snapshot.destination):$($snapshot.gateway)"
            if ($seen[$key]) { throw 'Duplicate mutations of one resource in the same job are not supported' }; $seen[$key] = $true
        }
        $steps += $snapshot
    }
    if (@($steps | Where-Object {$_.op -eq 'script'}).Count -and -not $a.script_rollback_reviewed) { throw 'Custom scripts require script_rollback_reviewed=true after inspecting the explicit undo script; automatic inference of a script rollback is impossible.' }
    if ($waits -gt $ttl - 20) { throw 'Scenario waits leave insufficient time before rollback; shorten them or increase rollback_after_s' }
    if ($a.allow_commit -and @($steps | Where-Object { $_.op -eq 'adapter_disable' }).Count) { throw 'Adapter disconnect scenarios always roll back; permanent adapter disabling is excluded' }
    $id = [guid]::NewGuid().ToString('N').Substring(0,24); $dir = Join-Path $root $id
    [void](New-Item -ItemType Directory -Path $dir)
    # Recovery runs elevated at boot: prevent ordinary local users from replacing
    # the worker or journal. The current user, SYSTEM and Administrators only.
    Recovery-SecureDirectory $dir
    $worker = Join-Path $dir 'worker.ps1'
    [IO.File]::WriteAllBytes($worker, [Convert]::FromBase64String('__RECOVERY_WORKER_B64__'))
    [IO.File]::WriteAllBytes((Join-Path $dir 'network.cs'), [Convert]::FromBase64String('__RECOVERY_NETWORK_B64__'))
    $state = @{ id = $id; task_name = 'HelperMCP-NetworkRollback-' + $id; status = 'armed'; steps = $steps; undo = @(); errors = @(); failure = $null; guard_ready = $false; guard_pid = 0; allow_commit = [bool]$a.allow_commit; created_utc = [DateTime]::UtcNow.ToString('o'); updated_utc = [DateTime]::UtcNow.ToString('o'); deadline_utc = [DateTime]::UtcNow.AddSeconds($ttl).ToString('o') }
    [IO.File]::WriteAllText((Join-Path $dir 'state.json'), ($state | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $true))
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Arg $worker) + ' -JobDirectory ' + (Quote-Arg $dir) + ' -Action recover'
    try {
        $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
        $timed = New-ScheduledTaskTrigger -Once -At ([DateTime]::UtcNow.AddSeconds($ttl).ToLocalTime()) -RepetitionInterval (New-TimeSpan -Minutes 1)
        $boot = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
        $null = Register-ScheduledTask -TaskName $state.task_name -Action $taskAction -Trigger @($timed,$boot) -Principal $principal -Settings $settings -Force -ErrorAction Stop
        # Prove SYSTEM can actually read and execute this worker BEFORE mutation.
        $preflight = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ($arguments -replace '-Action recover$', '-Action preflight')
        $null = Set-ScheduledTask -TaskName $state.task_name -Action $preflight
        Start-ScheduledTask -TaskName $state.task_name
        $until = [DateTime]::UtcNow.AddSeconds(12)
        while ([DateTime]::UtcNow -lt $until -and -not (Recovery-Read $dir).guard_ready) { Start-Sleep -Milliseconds 150 }
        if (-not (Recovery-Read $dir).guard_ready) { throw 'Rollback task preflight failed; no network changes were made' }
        if ((Recovery-Read $dir).guard_identity -ne 'S-1-5-18') { throw 'Rollback preflight did not run as SYSTEM; no network changes were made' }
        $null = Set-ScheduledTask -TaskName $state.task_name -Action $taskAction
        $verified = Get-ScheduledTask -TaskName $state.task_name
        if ([string]$verified.Actions.Arguments -ne $arguments) { throw 'Rollback task readback mismatch' }
        if (-not $verified.Settings.Enabled -or @($verified.Triggers).Count -ne 2 -or (Recovery-PrincipalSid $verified.Principal.UserId) -ne 'S-1-5-18') { throw 'Rollback task principal/triggers/enabled readback mismatch' }
        $p = Recovery-Launch $dir 'run'; $p.Dispose()
    } catch {
        $preparationError = $_
        $state.status = 'preparation_failed'; $state.failure = $preparationError.Exception.Message
        # Preflight may still be exiting. Never mask the preparation error with a
        # sharing violation, or rewrite the journal in place while it is read.
        try {
            $failedPath=Join-Path $dir 'state.json'; $failedTemp=$failedPath+'.prepare-failed'
            [IO.File]::WriteAllText($failedTemp,($state|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $true))
            for($attempt=0;$attempt -lt 20;$attempt++){
                try{[IO.File]::Replace($failedTemp,$failedPath,$failedPath+'.prepare.bak');break}
                catch [IO.IOException]{if($attempt -eq 19){throw};Start-Sleep -Milliseconds 25}
            }
        } catch { Write-Warning ('Could not record preparation failure: '+$_.Exception.Message) }
        Unregister-ScheduledTask -TaskName $state.task_name -Confirm:$false -ErrorAction SilentlyContinue
        throw $preparationError
    }
    @{ text = (@{ job = $id; status = 'armed_background'; rollback_after_s = $ttl; allow_commit = [bool]$a.allow_commit; next = 'net_recover status; commit only after repeat diagnostics and application validation'; warning = 'The local SYSTEM rollback restores captured settings without relay/agent. Power loss, OS/driver hangs or physical link faults can still prevent recovery.' } | ConvertTo-Json -Compress) }
}
