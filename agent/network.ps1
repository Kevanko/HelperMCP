# Embedded by the relay into the one-line Windows agent; no extra bootstrap download.
function Ensure-Network {
    if (-not ('N__BUILD__.Network' -as [type])) { throw 'Network module is missing; update the complete Helper agent bundle.' }
}

function Network-Targets($a) {
    $targets = New-Object 'Collections.Generic.List[N__BUILD__.Network+Target]'
    $urls = @($a.urls | Where-Object { $_ })
    if (-not $urls.Count -and -not $a.endpoints) { $urls = @('https://www.microsoft.com/', 'https://www.youtube.com/', 'https://discord.com/') }
    foreach ($url in $urls) {
        $u = $null
        if (-not [Uri]::TryCreate([string]$url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin @('https', 'http') -or $u.UserInfo -or $u.Query -or $u.Fragment) { throw 'Use an http(s) URL without credentials, query or fragment; never pass subscription secrets as a site URL.' }
        $targets.Add((New-Object 'N__BUILD__.Network+Target' -Property @{ host = $u.DnsSafeHost; port = $u.Port; tls = $u.Scheme -eq 'https'; http = $true; path = $u.PathAndQuery }))
    }
    foreach ($e in @($a.endpoints | Where-Object { $_ })) {
        if (-not $e.host -or $e.host -match '[\s/@?#]' -or [int]$e.port -lt 1 -or [int]$e.port -gt 65535) { throw 'Endpoint requires host and port 1..65535; extract these from the client, without UUID/password/subscription URL.' }
        if ($e.server_name -and [Uri]::CheckHostName([string]$e.server_name) -eq [UriHostNameType]::Unknown) { throw 'server_name must be a TLS hostname without credentials or path' }
        $targets.Add((New-Object 'N__BUILD__.Network+Target' -Property @{ host = [string]$e.host; port = [int]$e.port; tls = [bool]$e.tls; http = $false; server_name = [string]$e.server_name }))
    }
    if ($targets.Count -gt 8) { throw 'At most 8 targets per call; split larger subscriptions into batches.' }
    $targets.ToArray()
}

function Do-NetCheck($a) {
    if ($script:NetworkBusy) { throw 'A network check is already running; collect its result before starting another.' }
    $script:NetworkBusy = $true
    $task = $null
    try {
    Ensure-Network
    $mode = if ($a.mode) { [string]$a.mode } else { 'quick' }
    if ($mode -notin @('quick', 'sites', 'vpn', 'dns', 'speed', 'rkn', 'inventory', 'load', 'routes', 'profile')) { throw 'Unknown network mode' }
    if ($mode -eq 'profile') { return Do-ProfileCheck $a }
    if ($mode -eq 'routes') { return Network-Routes }
    if ($mode -eq 'inventory') { return Network-Inventory $a.config_path $a.inventory_offset $a.inventory_limit }
    if ($mode -eq 'rkn') { return Do-RknCheck $a }
    $index = [int]$a.interface_index
    if ($index -lt 0) { throw 'interface_index must be >= 0' }
    $paths = [N__BUILD__.Network]::Paths($index, (-not $a.single_path -and $mode -ne 'load'))
    $targets = [N__BUILD__.Network+Target[]]@(Network-Targets $a)
    $ms = if ($a.timeout_ms) { [int]$a.timeout_ms } else { 1500 }
    $repeat = if ($a.samples) { [int]$a.samples } else { 3 }
    if ($ms -lt 300 -or $ms -gt 3000 -or $repeat -lt 1 -or $repeat -gt 5) { throw 'timeout_ms: 300..3000; samples: 1..5' }
    $resolver = if ($a.resolver) { [string]$a.resolver } else { '1.1.1.1' }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($resolver, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'resolver must be an IPv4 address; it is queried without changing Windows DNS' }
    $tools = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $NetToolsRx } | ForEach-Object { "$($_.ProcessName):$($_.Id)" })
    $filters = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'WinDivert|zapret|goodbyedpi|wintun|wireguard' } | ForEach-Object { "$($_.Name):$($_.Status)" })
    $before = [F__BUILD__.Sys]::CpuLoad(150)
    $out = [ordered]@{ measured_at = [DateTime]::UtcNow.ToString('o'); mode = $mode; helper_path = [F__BUILD__.Route]::Status(); tools = $tools; filters = $filters; cpu_before_pct = $before; memory = [F__BUILD__.Sys]::Mem(); notes = @('Read-only: no VPN switching, adapter restart, DNS or route changes.', 'Physical binding bypasses route selection, NOT WinDivert/WFP. Clean access without zapret is unproven while filters may be active.', 'Link speed and adapter throughput are not internet speed. Download figures are bounded payload goodput to the chosen target, not line capacity.', 'A successful ping/TCP/TLS is not proof that a VPN, Discord voice, video or game works.'); results = @() }
    if ($mode -eq 'load') {
        if (-not $a.load_url) { throw 'load mode needs load_url: a non-secret http(s) download URL. At most 3 MiB; no VPN switching.' }
        $download = @(Network-Targets @{ urls = @($a.load_url) })[0]
        $task = [N__BUILD__.Network]::StartLoad($paths[0], $targets[0], $download, $ms, $resolver)
        while (-not $task.IsCompleted) { Pump-Light; Start-Sleep -Milliseconds 150 }
        $out.load_comparison = $task.GetAwaiter().GetResult()
    } elseif ($mode -eq 'dns') {
        $rows = @(); $budget = [Diagnostics.Stopwatch]::StartNew()
        :dnsPaths foreach ($p in $paths) { foreach ($t in $targets) {
            $servers = @($p.dns | Select-Object -First 2) + @($resolver, '8.8.8.8') | Select-Object -Unique
            if ($p.index -eq 0) { $servers = @('system') + @($servers) }
            foreach ($server in $servers) {
                if ($budget.Elapsed.TotalSeconds -gt 55) { $out.notes += 'DNS time budget exhausted; remaining targets NOT TESTED.'; break dnsPaths }
                Pump-Light
                $rows += @{ path = $p; host = $t.host; answer = [N__BUILD__.Network]::Resolve($p, $t.host, $server, $ms) }
            }
        } }
        $out.results = $rows
    } else {
        $task = [N__BUILD__.Network]::StartBatch($paths, $targets, $repeat, $ms, ($mode -eq 'speed'), $resolver)
        while (-not $task.IsCompleted) { Pump-Light; Start-Sleep -Milliseconds 150 }
        $out.results = @($task.GetAwaiter().GetResult())
    }
    $out.cpu_after_pct = [F__BUILD__.Sys]::CpuLoad(150)
    $out.performance = ([F__BUILD__.Sys]::Perf() | ConvertFrom-Json)
    if (-not $a.detail -and $mode -ne 'dns') {
        $out.results = @($out.results | ForEach-Object {
            $r = $_; $samples = @($r.samples)
            $stats = @{}
            foreach ($field in 'tcp_ms','tls_ms','first_byte_ms','total_ms') {
                $values = @($samples | ForEach-Object { $_.$field } | Where-Object { $_ -ge 0 } | Sort-Object)
                if ($values.Count) { $stats[$field] = @($values[0], $values[[int][math]::Floor($values.Count / 2)], $values[-1]) }
            }
            @{ adapter = $r.route.name; interface_index = $r.route.index; host = $r.target.host; port = $r.target.port; server_name = $r.target.server_name;
               dns = @($r.dns | ForEach-Object { @{ server = $_.server; addresses = $_.addresses; error = $_.error } });
               ips = @($samples.ip | Select-Object -Unique); sources = @($samples.source | Where-Object { $_ } | Select-Object -Unique);
               timing_min_median_max = $stats; samples = $samples.Count; failed = @($samples | Where-Object { $_.error }).Count;
               http_status = @($samples.status | Where-Object { $_ -gt 0 } | Select-Object -Unique);
               errors = @($samples | Where-Object { $_.error } | ForEach-Object { "$($_.stage):$($_.error)" } | Select-Object -Unique);
               bytes = @($samples.bytes); download_mbps = $(if ($mode -eq 'speed') { @($samples.download_mbps) } else { $null }); findings = $r.findings }
        })
    }
    @{ text = ($out | ConvertTo-Json -Depth 12 -Compress) }
    } finally { if ($task) { [N__BUILD__.Network]::CancelWork() }; $script:NetworkBusy = $false }
}

function Do-RknCheck($a) {
    # The pinned upstream CLI has no interface option. The child wrapper binds only
    # its own IPv4 sockets and resolver. It cannot defeat WinDivert/WFP filters.
    $exe = Resolve-Exe 'uv'
    if (-not $exe) { Ensure-Uv 'uv'; $exe = Resolve-Exe 'uv' }
    if (-not $exe) { throw 'Could not prepare uv for RKN Checker; no network verdict was produced. Native quick/sites/dns/vpn checks need no Python.' }
    $index = [int]$a.interface_index
    if ($index -lt 0) { throw 'interface_index must be >= 0' }
    $paths = [N__BUILD__.Network]::Paths($index, $false)
    $dir = Join-Path $env:TEMP ('helpermcp-rkn-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir); $script:TmpDirs += $dir
    $runner = Join-Path $dir 'rkn_runner.py'
    [IO.File]::WriteAllBytes($runner, [Convert]::FromBase64String('__RKN_RUNNER_B64__'))
    $config = @{ interface_index = $index; source = $paths[0].source; urls = @($a.urls | Where-Object { $_ }); timeout = 2; workers = 4; detail = [bool]$a.detail; resolvers = @($paths[0].dns) + @('1.1.1.1', '8.8.8.8') }
    if ($config.urls.Count -gt 8) { throw 'At most 8 URLs' }
    foreach ($url in $config.urls) { $u = $null; if (-not [Uri]::TryCreate([string]$url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin @('http','https') -or $u.UserInfo -or $u.Query -or $u.Fragment) { throw 'RKN URLs must be http(s) without credentials, query or fragment' } }
    $file = Join-Path $dir 'config.json'
    [IO.File]::WriteAllText($file, ($config | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = (@('run', '--no-project', '--python', '3.12', '--with', 'rkn-block-checker==0.6.0', 'python', $runner, $file) | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding $false; $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $psi.WorkingDirectory = $dir
    $psi.EnvironmentVariables.Remove('PYTHONPATH'); $psi.EnvironmentVariables.Remove('PYTHONHOME')
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'; $psi.EnvironmentVariables['UV_NO_PROGRESS'] = '1'; $psi.EnvironmentVariables['UV_HTTP_TIMEOUT'] = '10'
    $p = New-Object Diagnostics.Process; $p.StartInfo = $psi; $started = $false
    try {
        [void]$p.Start(); $started = $true; $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.WaitForExit(200)) {
            Pump-Light
            if ($timer.Elapsed.TotalSeconds -gt 120) { throw 'RKN timed out; no network verdict was produced.' }
        }
        if ($p.ExitCode -ne 0) { throw "RKN Checker did not finish (exit $($p.ExitCode)); check uv/package availability. No network verdict was produced." }
        @{ text = $stdout.Result }
    } finally {
        if ($started -and -not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null }
        $p.Dispose(); Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
YamlDotNet 18.1.0 (MIT), distributed with the optional local profile parser.
__YAML_LICENSE__
#>
function Ensure-ProfileParser {
    if ('P__BUILD__.Profiles' -as [type]) { return }
    $dir = Join-Path $StateDir 'dependencies'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $dll = Join-Path $dir 'YamlDotNet-18.1.0.dll'; $expected = '__YAML_SHA256__'
    $bytes = if ((Test-Path -LiteralPath $dll) -and (Get-Item -LiteralPath $dll).Length -eq 298496) { [IO.File]::ReadAllBytes($dll) } else { $null }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $valid = $bytes -and [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() -eq $expected
        if (-not $valid) {
            $pending = $dll + '.' + [guid]::NewGuid().ToString('N') + '.pending'
            $progress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest ($RELAY + '/a/deps/yamldotnet-18.1.0.dll') -Headers @{ Authorization = 'Bearer ' + $script:Token } -UseBasicParsing -TimeoutSec 20 -OutFile $pending
                if ((Get-Item -LiteralPath $pending).Length -ne 298496) { throw 'YAML dependency size mismatch' }
                $bytes = [IO.File]::ReadAllBytes($pending)
                if ([BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() -ne $expected) { throw 'YAML dependency hash mismatch' }
                if ([IO.File]::Exists($dll)) { [IO.File]::Replace($pending,$dll,[NullString]::Value) } else { [IO.File]::Move($pending,$dll) }
            } finally { $ProgressPreference = $progress; if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) } }
        }
        # Load exactly the bytes whose hash was checked, not a replaceable path.
        [void][Reflection.Assembly]::Load($bytes)
    } finally { $hash.Dispose() }
    Add-Type -ReferencedAssemblies $dll -TypeDefinition @'
__PROFILE_CS__
'@
}

function Network-Inventory($path, $offset = 0, $limit = 64) {
    $offset = [int]$offset; $limit = if ($limit) { [int]$limit } else { 64 }
    if ($offset -lt 0 -or $offset -gt 100000 -or $limit -lt 1 -or $limit -gt 128) { throw 'inventory_offset must be 0..100000 and inventory_limit 1..128' }
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'config_path must name an existing local subscription/config export; do not pass the secret subscription URL.' }
    if ((Get-Item -LiteralPath $path).Length -gt 4MB) { throw 'Config exceeds 4 MiB' }
    $text = [IO.File]::ReadAllText($path)
    $items = New-Object Collections.ArrayList
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    function Add-Endpoint($hostName, $portNumber, $protocol) {
        if ($hostName -isnot [string] -or -not $hostName -or $hostName.Length -gt 253 -or [Uri]::CheckHostName($hostName) -eq [UriHostNameType]::Unknown -or $hostName -match '[\s/@?#\x00-\x1f]' -or -not $portNumber) { return }
        $number = 0; if (-not [int]::TryParse([string]$portNumber, [ref]$number)) { return }; $portNumber = $number
        if ($portNumber -lt 1 -or $portNumber -gt 65535) { return }
        if ([string]$protocol -notmatch '^(vless|vmess|trojan|shadowsocks|ss|ssr|socks|socks5|http|hysteria|hysteria2|hy2|tuic|wireguard)$') { $protocol = 'unknown' }
        $udp = [string]$protocol -match 'hysteria|hy2|tuic|wireguard'
        $key = "$hostName`:$portNumber/$protocol"
        if ($seen.Add($key)) { [void]$items.Add(@{ key = $key; host = [string]$hostName; port = $portNumber; protocol = [string]$protocol; requires_udp_test = $udp }) }
    }
    function Decode-Base64($value) {
        $value = ($value -replace '\s','').Replace('-','+').Replace('_','/')
        $value = $value.PadRight($value.Length + ((4 - $value.Length % 4) % 4), '=')
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))
    }
    if ($text.Trim() -match '^[A-Za-z0-9+/=_\s-]+$') { try { $text = Decode-Base64 $text } catch { } }
    $jsonParsed = $false; $format = 'uri'; $warnings = @()
    try {
        $json = $text | ConvertFrom-Json -ErrorAction Stop
        $jsonParsed = $true; $format = 'json'
        foreach ($group in @($json) + @($json.outbounds) + @($json.proxies)) {
            if (-not $group) { continue }
            $protocol = if ($group.protocol) { $group.protocol } else { $group.type }
            Add-Endpoint $group.server $group.server_port $protocol
            if ($group.server -is [string]) { Add-Endpoint $group.server $group.port $protocol }
            foreach ($server in @($group.settings.vnext) + @($group.settings.servers)) { if ($server) { Add-Endpoint $server.address $server.port $protocol } }
        }
    } catch { }
    foreach ($line in ($text -split '\r?\n')) {
        $line = $line.Trim()
        try {
            if ($line -match '^vmess://(.+)') { $j = (Decode-Base64 $Matches[1]) | ConvertFrom-Json; Add-Endpoint $j.add $j.port 'vmess'; continue }
            if ($line -match '^(vless|trojan|ss|ssr|hysteria2|hy2|hysteria|tuic)://') {
                $u = New-Object Uri $line
                $portNumber = $u.Port
                if ($portNumber -lt 1 -and $u.Scheme -match 'trojan|hysteria|hy2|tuic') { $portNumber = 443 }
                Add-Endpoint $u.DnsSafeHost $portNumber $u.Scheme
            }
        } catch { }
    }
    if (-not $jsonParsed -and -not $items.Count) {
        $format = 'yaml'; $parserReady = $false
        try {
            Ensure-ProfileParser
            $parserReady = $true
        } catch { $warnings += 'YAML parser dependency unavailable or integrity check failed; retry when the relay is reachable.' }
        if ($parserReady) { try {
            foreach ($endpoint in [P__BUILD__.Profiles]::Yaml($text)) { Add-Endpoint $endpoint.host $endpoint.port $endpoint.protocol }
        } catch { $warnings += 'Invalid YAML export or parsing limit exceeded; input values omitted.' } }
    }
    $rows = @($items | Select-Object -Skip $offset -First $limit | ForEach-Object { @{ host = $_.host; port = $_.port; protocol = $_.protocol; requires_udp_test = $_.requires_udp_test } })
    $next = if ($offset + $rows.Count -lt $items.Count) { $offset + $rows.Count } else { $null }
    @{ text = (@{ endpoints = $rows; count = $items.Count; returned_count = $rows.Count; offset = $offset; next_offset = $next; format = $format; warnings = $warnings; status = $(if ($items.Count) { 'endpoints_extracted' } else { 'no_endpoints_or_unsupported_format' }); notes = @('Local JSON, YAML, URI-list and base64 URI-list exports. YAML supports scalar keys, inline maps, aliases and merge keys with bounded work; remote providers are not downloaded. SSR and opaque databases may need a client export.', 'No credentials are returned. No profile was activated. Reachability is not an authenticated VPN check.', 'For REALITY use protocol-aware verification; generic TLS may reject it. UDP-only transports cannot be diagnosed using TCP.') } | ConvertTo-Json -Depth 6 -Compress) }
}

function Network-Routes {
    Ensure-Network
    $paths = @([N__BUILD__.Network]::Paths(0, $true)); $findings = New-Object Collections.ArrayList
    $routes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop |
        Sort-Object DestinationPrefix,InterfaceIndex,RouteMetric |
        Select-Object DestinationPrefix,NextHop,InterfaceIndex,RouteMetric,Protocol)
    $interfaces = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop |
        Select-Object InterfaceIndex,InterfaceAlias,ConnectionState,InterfaceMetric,NlMtu,Dhcp)
    foreach ($p in $paths) {
        if ($p.index -eq 0) { continue }
        foreach ($server in $p.dns) {
            if (-not $p.vpn -and [N__BUILD__.Network]::Fake($server)) { [void]$findings.Add(@{ code='physical_fake_dns'; interface_index=$p.index; evidence=$server; confidence='observed'; next='Compare bound resolver queries before any change; fake-dns template only after original DNS mode is captured.' }) }
        }
        foreach ($route in $routes | Where-Object { $_.InterfaceIndex -eq $p.index -and $_.DestinationPrefix -match '^198\.(18|19)\.' -and $_.NextHop -ne '0.0.0.0' }) {
            if (-not $p.vpn) { [void]$findings.Add(@{ code='fake_range_via_physical_gateway'; interface_index=$p.index; evidence=$route; confidence='candidate_conflict'; next='Check owning VPN and exact prefix/next hop; do not bulk-delete fake-IP routes.' }) }
        }
    }
    $vpns = @($paths | Where-Object { $_.vpn })
    if ($vpns.Count -gt 1) { [void]$findings.Add(@{code='multiple_tunnels'; evidence=@($vpns.name); confidence='candidate_conflict'; next='Compare selected destination routes and client DNS ownership; multiple adapters alone are not a failure.'}) }
    $splitDefaults = @($routes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/1','128.0.0.0/1') })
    if ($splitDefaults.Count) { [void]$findings.Add(@{code='split_default_routes';evidence=$splitDefaults;confidence='observed';next='/1 routes outrank /0 regardless of metric; inspect the owner, not just default gateway.'}) }
    $proxy = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $drivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'WinDivert|wintun|tap0901|wireguard' } | Select-Object Name,State,StartMode)
    @{text=(@{helper_path=[F__BUILD__.Route]::Status();paths=$paths;interfaces=$interfaces;routes=$routes;filter_drivers=$drivers;wininet_proxy=@{enabled=[bool]$proxy.ProxyEnable;server_present=[bool]$proxy.ProxyServer;pac_present=[bool]$proxy.AutoConfigURL};findings=@($findings);notes=@('Read-only IPv4 route evidence, not WFP/filter dump. Prefix length outranks metric; interface metric also contributes.', 'No route, firewall, DNS, proxy, VPN or service was changed. Candidate conflicts need repeat application/path tests.')} | ConvertTo-Json -Depth 9 -Compress)}
}

__NETWORK_PROFILE_PS__
